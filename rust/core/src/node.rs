//! The node: one UDP socket, one QUIC endpoint, the rendezvous client and the route race.
//!
//! The app hands the node its paired peers (with each pair's secret and learned addresses) and
//! whether it already has a session with each. For a peer without one, the node races the routes
//! (spec 4.3): QUIC dials to learned LAN and VPN addresses, and ICE through the control service
//! (host, server-reflexive and relay candidates). Every QUIC connection that comes up becomes a
//! tunnel: the app connects to a loopback bridge with a one-time token and runs the unchanged
//! Bridgey session over QUIC stream 0, binding its signatures to the tunnel's exporter.

use crate::addrs::{self, Route};
use crate::ice::{IceAgent, IceEvent, Local};
use crate::mux::{is_virtual, Mux, Via};
use crate::quic::{self, Identity};
use crate::rdv_client::{self, RdvClient, RdvEvent, Signer};
use crate::turn::{self, Allocation, Realm};
use bridgey_connect_proto::rdv::{self as rdvproto, Msg, Reclaim, RelayGrant, RelayInfo, WarmRequest};
use bridgey_connect_proto::signal::{Candidate, Description, Signal};
use bridgey_connect_proto::{b64, derive, seal};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, oneshot};

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartConfig {
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub control_url: Option<String>,
    #[serde(default)]
    pub app: String,
    /// The node's P-256 public key (SEC1, base64url). The private key stays in the app's keystore.
    pub node_key: String,
    #[serde(default)]
    pub relay_only: bool,
    /// What the app kept from the last run (the `state` event): relay round trips, the pool, and the warm
    /// allocation, so a restart probes at once and can end an allocation a killed process left behind.
    #[serde(default)]
    pub state: Option<Value>,
    /// Keep a relay allocation warm, with a keep-alive this often (seconds). 0: credentials only, and an
    /// allocation when a session needs one (metered networks, where every keep-alive wakes the radio).
    #[serde(default = "default_relay_keepalive")]
    pub relay_keepalive_s: u32,
}

fn default_port() -> u16 {
    42_458
}

fn default_relay_keepalive() -> u32 {
    25
}

/// The node's own relay (docs/connect-anywhere-latency.md): credentials from the sign-in, and on networks where it
/// is cheap an allocation kept open with permissions for every relay in the pool, so a session's relay path is
/// ready before the session starts.
#[derive(Default)]
struct Warm {
    /// Keep-alive for the allocation; zero means no allocation is kept (credentials only).
    keepalive: Duration,
    grant: Option<(RelayGrant, SocketAddr)>,
    allocation: Option<Arc<Allocation>>,
    allocating: bool,
    /// The pool from `welcome`, resolved.
    relays: Vec<(String, SocketAddr)>,
    rtts: BTreeMap<String, u32>,
    /// Our server-reflexive address (STUN to the nearest relay) and when it was seen.
    srflx: Option<(SocketAddr, Instant)>,
    /// From the last run: an allocation that may still hold this socket on that relay.
    left_behind: Option<LeftBehind>,
    exclude: Vec<String>,
    failures: u32,
    /// When a left-behind allocation was ended: the relay frees it on its next second, so a 437 until then is
    /// retried rather than taken as a reason to move to another relay.
    reclaimed_at: Option<Instant>,
}

#[derive(Clone)]
struct LeftBehind {
    relay: String,
    server: SocketAddr,
    username: String,
    realm: Option<Realm>,
}

/// Saved state older than this cannot have a live allocation (they last 10 minutes from the last refresh).
const LEFT_BEHIND_MAX_AGE_MS: u64 = 11 * 60 * 1000;
/// When a peer's LAN address is on this network, the app's LAN connection gets this long before the race.
const LAN_HEAD_START: Duration = Duration::from_millis(300);
/// The control service connection is trusted without a check for this long after it last heard anything.
const RDV_QUIET_LIMIT: Duration = Duration::from_secs(25);

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeerConfig {
    pub id: String,
    /// 0 when this device has the lower device ID.
    pub side: u8,
    /// Standard base64 of the 32-byte pair secret.
    pub pair_secret: String,
    #[serde(default)]
    pub addresses: Vec<Learned>,
    /// The app already has an authenticated session with this peer.
    #[serde(default)]
    pub connected: bool,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Learned {
    pub a: String,
    pub p: u16,
    #[serde(default)]
    pub kind: String,
    /// `tailscale` or `other` for a private-network address, as the peer reported it.
    #[serde(default)]
    pub vpn: Option<String>,
}

struct Peer {
    cfg: PeerConfig,
    secret: [u8; 32],
    sig_key: [u8; 32],
    next_attempt: Instant,
    failures: u32,
}

struct Tunnel {
    id: String,
    peer: Option<String>,
    conn: quinn::Connection,
    route: Mutex<(Route, Option<String>)>,
    token: [u8; 32],
    quic_client: bool,
    claimed: AtomicBool,
    /// The app finished the session handshake on it (command "authenticated"). Until then it counts
    /// against the inbound caps, and a close is a failure that backs off instead of redialling at once.
    authenticated: AtomicBool,
    /// The source address of an inbound direct dial, for the per-address cap.
    remote_ip: Option<std::net::IpAddr>,
    ice: Option<String>,
}

struct IceSession {
    agent: Arc<IceAgent>,
    peer: String,
    rdv: String,
    side: u8,
    seq: AtomicU64,
    last_remote_seq: Mutex<u64>,
    remote_cert: Mutex<Option<String>>,
    route: Mutex<(Route, Option<String>)>,
    allocation: Mutex<Option<Arc<Allocation>>>,
    tunnel: Mutex<Option<String>>,
    relay_retried: AtomicBool,
    /// The control service connection it was signalled on: one that ends takes unanswered signals with it.
    generation: u64,
    /// The other side's description arrived (the offer we answered, or the answer to ours).
    described: AtomicBool,
}

pub type EventSink = Arc<dyn Fn(String) + Send + Sync>;

pub struct Node {
    cfg: StartConfig,
    node_key: Vec<u8>,
    mux: Arc<Mux>,
    endpoint: quinn::Endpoint,
    identity: RwLock<Arc<Identity>>,
    emit: EventSink,
    peers: Mutex<HashMap<String, Peer>>,
    rdv: Mutex<Option<RdvClient>>,
    rdv_connected: AtomicBool,
    /// Control service connection attempts that failed in a row since the last success.
    rdv_failures: AtomicU32,
    /// When the control service connection last came up (presence follows within moments).
    rdv_since: Mutex<Option<Instant>>,
    online: Mutex<HashSet<String>>,
    rdv_ids: Mutex<HashMap<String, String>>,
    tunnels: Mutex<HashMap<String, Arc<Tunnel>>>,
    ice: Mutex<HashMap<String, Arc<IceSession>>>,
    racing: Mutex<HashSet<String>>,
    sign_waiters: Mutex<HashMap<u64, oneshot::Sender<Vec<u8>>>>,
    allocations: Mutex<HashMap<SocketAddr, Arc<Allocation>>>,
    /// One Allocate at a time: a second on the same 5-tuple is refused (437).
    allocating: tokio::sync::Mutex<()>,
    /// Releases in flight per relay; a new Allocate there waits for them (else 437).
    releasing: Mutex<HashMap<SocketAddr, tokio::task::JoinHandle<()>>>,
    next_id: AtomicU64,
    bridge_port: u16,
    stopped: AtomicBool,
    last_presence: Mutex<String>,
    /// When the node started, for the connection waterfall (`timing` events).
    started: Instant,
    /// What the next sign-in carries (registration, warm relay request).
    rdv_shared: Arc<rdv_client::Shared>,
    /// Counts control service connections; signalling on an older one is redone.
    rdv_generation: AtomicU64,
    /// Woken when the control service connection or presence changes, so a race waits for it without polling.
    rdv_changed: tokio::sync::Notify,
    warm: Mutex<Warm>,
    /// Each relay's realm and nonce, so an allocation there carries credentials at once.
    realms: Mutex<HashMap<SocketAddr, Realm>>,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn random_bytes<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut out).expect("random");
    out
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn keep_alive(route: Route) -> Duration {
    match route {
        Route::Lan | Route::Vpn => Duration::from_secs(25),
        _ => Duration::from_secs(15),
    }
}

impl Node {
    pub async fn start(cfg: StartConfig, emit: EventSink) -> Result<Arc<Node>, String> {
        let node_key = b64::url_decode(&cfg.node_key).filter(|k| k.len() == 65 && k[0] == 4).ok_or("nodeKey must be a P-256 SEC1 public key")?;
        let mux = Mux::bind(cfg.port).map_err(|e| format!("udp: {e}"))?;
        mux.relay_only.store(cfg.relay_only, Ordering::Relaxed);
        let identity = Arc::new(Identity::generate());
        let endpoint = quinn::Endpoint::new_with_abstract_socket(
            quic::endpoint_config(),
            Some(quic::server_config(&identity)),
            mux.clone(),
            Arc::new(quinn::TokioRuntime),
        )
        .map_err(|e| format!("quic: {e}"))?;
        let bridge = tokio::net::TcpListener::bind("127.0.0.1:0").await.map_err(|e| format!("bridge: {e}"))?;
        let bridge_port = bridge.local_addr().map_err(|e| e.to_string())?.port();
        let node = Arc::new(Node {
            cfg,
            node_key,
            mux,
            endpoint,
            identity: RwLock::new(identity),
            emit,
            peers: Mutex::new(HashMap::new()),
            rdv: Mutex::new(None),
            rdv_connected: AtomicBool::new(false),
            rdv_failures: AtomicU32::new(0),
            rdv_since: Mutex::new(None),
            online: Mutex::new(HashSet::new()),
            rdv_ids: Mutex::new(HashMap::new()),
            tunnels: Mutex::new(HashMap::new()),
            ice: Mutex::new(HashMap::new()),
            racing: Mutex::new(HashSet::new()),
            sign_waiters: Mutex::new(HashMap::new()),
            allocations: Mutex::new(HashMap::new()),
            allocating: tokio::sync::Mutex::new(()),
            releasing: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            bridge_port,
            stopped: AtomicBool::new(false),
            last_presence: Mutex::new(String::new()),
            started: Instant::now(),
            rdv_shared: Arc::new(rdv_client::Shared::default()),
            rdv_generation: AtomicU64::new(0),
            rdv_changed: tokio::sync::Notify::new(),
            warm: Mutex::new(Warm::default()),
            realms: Mutex::new(HashMap::new()),
        });
        node.restore_state();
        tokio::spawn(node.clone().accept_loop());
        tokio::spawn(node.clone().bridge_loop(bridge));
        tokio::spawn(node.clone().tick_loop());
        tokio::spawn(node.clone().warm_loop());
        node.start_rdv();
        node.log(&format!("started udp={} bridge={}", node.mux.port(), bridge_port));
        Ok(node)
    }

    fn event(&self, value: Value) {
        (self.emit)(value.to_string());
    }

    fn log(&self, msg: &str) {
        self.event(json!({"e": "log", "msg": msg}));
    }

    /// One step of a connection, for the waterfall: milliseconds since the node started and the wall clock.
    /// Never carries an address; `peer` is a paired device ID the app already knows.
    fn mark(&self, step: &str, peer: Option<&str>, detail: Option<&str>) {
        self.event(json!({"e": "timing", "step": step, "ms": self.started.elapsed().as_millis() as u64, "at": now_ms(), "peer": peer, "detail": detail}));
    }

    pub fn udp_port(&self) -> u16 {
        self.mux.port()
    }

    pub fn bridge_port(&self) -> u16 {
        self.bridge_port
    }

    fn weak(self: &Arc<Self>) -> std::sync::Weak<Node> {
        Arc::downgrade(self)
    }

    // region Rendezvous

    fn start_rdv(self: &Arc<Self>) {
        let Some(url) = self.cfg.control_url.clone().filter(|u| !u.is_empty()) else {
            self.publish_presence("disabled");
            return;
        };
        let (tx, mut rx) = mpsc::unbounded_channel();
        let weak = Arc::downgrade(self);
        let signer: Signer = Arc::new(move |message: Vec<u8>| {
            let weak = weak.clone();
            Box::pin(async move {
                let node = weak.upgrade()?;
                node.sign(message).await
            })
        });
        let client = rdv_client::start(url, self.node_key.clone(), self.cfg.app.clone(), signer, self.rdv_shared.clone(), tx);
        *self.rdv.lock().unwrap() = Some(client);
        self.publish_presence("connecting");
        let node = Arc::downgrade(self);
        tokio::spawn(async move {
            while let Some(event) = rx.recv().await {
                let Some(node) = node.upgrade() else { break };
                node.on_rdv(event);
            }
        });
    }

    /// A new control service connection now (the old one may be gone with the network it ran on). Registration,
    /// the warm relay request and the signalling of sessions under way carry over.
    fn restart_rdv(self: &Arc<Self>) {
        let client = self.rdv.lock().unwrap();
        match client.as_ref() {
            Some(client) => client.refresh(),
            None => {
                drop(client);
                self.start_rdv();
            }
        }
    }

    async fn sign(&self, message: Vec<u8>) -> Option<Vec<u8>> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.sign_waiters.lock().unwrap().insert(id, tx);
        self.event(json!({"e": "sign", "id": id, "data": b64::std_encode(&message)}));
        let result = tokio::time::timeout(Duration::from_secs(10), rx).await.ok().and_then(|r| r.ok());
        self.sign_waiters.lock().unwrap().remove(&id);
        result
    }

    pub fn sign_result(&self, id: u64, signature: Option<Vec<u8>>) {
        if let Some(tx) = self.sign_waiters.lock().unwrap().remove(&id) {
            if let Some(sig) = signature {
                let _ = tx.send(sig);
            }
        }
    }

    fn rdv_send(&self, msg: Msg) {
        if let Some(client) = self.rdv.lock().unwrap().as_ref() {
            client.send(msg);
        }
    }

    fn register(&self) {
        let ids = {
            let peers = self.peers.lock().unwrap();
            let mut map = HashMap::new();
            for peer in peers.values() {
                for date in derive::rdv_dates(now_ms()) {
                    map.insert(derive::rdv_id(&peer.secret, &date), peer.cfg.id.clone());
                }
            }
            map
        };
        let mut list: Vec<String> = ids.keys().cloned().collect();
        list.sort();
        list.truncate(64);
        *self.rdv_ids.lock().unwrap() = ids;
        // The next sign-in registers these in the same flight.
        *self.rdv_shared.ids.lock().unwrap() = list.clone();
        if self.rdv_connected.load(Ordering::Relaxed) {
            self.rdv_send(Msg::Register { ids: list });
        }
    }

    fn peer_online(&self, peer: &str) -> bool {
        let online = self.online.lock().unwrap();
        self.rdv_ids.lock().unwrap().iter().any(|(rdv, p)| p == peer && online.contains(rdv))
    }

    fn publish_presence(&self, state: &str) {
        let mut peers: Vec<String> = {
            let online = self.online.lock().unwrap();
            let ids = self.rdv_ids.lock().unwrap();
            online.iter().filter_map(|rdv| ids.get(rdv).cloned()).collect::<HashSet<_>>().into_iter().collect()
        };
        peers.sort();
        let value = json!({"e": "presence", "state": state, "peers": peers});
        let text = value.to_string();
        let mut last = self.last_presence.lock().unwrap();
        if *last != text {
            *last = text.clone();
            (self.emit)(text);
        }
    }

    fn on_rdv(self: &Arc<Self>, event: RdvEvent) {
        match event {
            RdvEvent::Timing(step) => self.mark(&format!("rdv.{step}"), None, None),
            RdvEvent::Connected { inline_ids, warm_inline, relays } => {
                self.mark("rdv.welcome", None, Some(if inline_ids.is_some() || warm_inline { "fast" } else { "challenge" }));
                let generation = self.rdv_generation.fetch_add(1, Ordering::Relaxed) + 1;
                self.rdv_connected.store(true, Ordering::Relaxed);
                self.rdv_failures.store(0, Ordering::Relaxed);
                *self.rdv_since.lock().unwrap() = Some(Instant::now());
                // Registered in the same flight unless the set changed meanwhile (the service answers `registered`).
                let current = self.rdv_shared.ids.lock().unwrap().clone();
                if inline_ids.as_ref() != Some(&current) {
                    self.register();
                }
                if !warm_inline {
                    if let Some(request) = self.rdv_shared.warm.lock().unwrap().clone() {
                        self.rdv_send(Msg::RelayWarm { request });
                    }
                }
                // A reclaim is asked once; the next sign-in asks only for credentials.
                if let Some(request) = self.rdv_shared.warm.lock().unwrap().as_mut() {
                    request.reclaim = None;
                }
                if !relays.is_empty() {
                    let node = self.clone();
                    tokio::spawn(async move { node.probe_relays(relays).await });
                }
                self.resignal(generation);
                self.publish_presence("online");
                self.rdv_changed.notify_waiters();
            }
            RdvEvent::Disconnected(reason) => {
                self.rdv_connected.store(false, Ordering::Relaxed);
                self.rdv_changed.notify_waiters();
                self.online.lock().unwrap().clear();
                self.log(&format!("control service disconnected: {reason}"));
                // A connection that worked and dropped is retried quietly; one that cannot be made at all is
                // reported, so the app can say the Round Robin service is out of reach (LAN and VPN still work).
                // A single failure is not reported either: a process Android has just started can be refused
                // the network for its first moments, and the client retries within a second.
                let lost = matches!(reason.as_str(), "closed" | "keepalive_timeout" | "send_failed" | "refresh");
                let failures = if lost { 0 } else { self.rdv_failures.fetch_add(1, Ordering::Relaxed) + 1 };
                self.publish_presence(if failures >= 2 { "unreachable" } else { "connecting" });
            }
            RdvEvent::Msg(msg) => self.on_rdv_msg(msg),
        }
    }

    fn on_rdv_msg(self: &Arc<Self>, msg: Msg) {
        match msg {
            Msg::Registered { online } => {
                let peers: Vec<String> = {
                    let ids = self.rdv_ids.lock().unwrap();
                    online.iter().filter_map(|rdv| ids.get(rdv).cloned()).collect()
                };
                self.mark("rdv.registered", None, Some(&peers.len().to_string()));
                *self.online.lock().unwrap() = online.into_iter().collect();
                self.publish_presence("online");
                self.peers_seen_online(&peers);
                self.rdv_changed.notify_waiters();
                self.connect_waiting("presence");
            }
            Msg::Presence { rdv, online } => {
                {
                    let mut set = self.online.lock().unwrap();
                    if online {
                        set.insert(rdv.clone());
                    } else {
                        set.remove(&rdv);
                    }
                }
                self.publish_presence("online");
                self.rdv_changed.notify_waiters();
                if online {
                    let peer = self.rdv_ids.lock().unwrap().get(&rdv).cloned();
                    if let Some(peer) = peer {
                        self.mark("presence.online", Some(&peer), None);
                        self.peers_seen_online(&[peer]);
                    }
                    self.connect_waiting("presence");
                }
            }
            Msg::Signal { rdv, side, sid, body } => self.on_signal(rdv, side, sid, body),
            Msg::Undeliverable { sid, .. } => self.end_ice(&sid, "undeliverable"),
            Msg::RelayGrantMsg { sid, relay } if sid == rdvproto::WARM_SID => self.on_warm_grant(relay),
            Msg::RelayGrantMsg { sid, relay } if sid == rdvproto::RECLAIM_SID => self.on_reclaim(relay),
            Msg::RelayGrantMsg { sid, relay } => self.on_grant(sid, relay),
            Msg::RelayDenied { sid, code, .. } => self.log(&format!("relay denied for {}: {code}", &sid[..4.min(sid.len())])),
            Msg::Error { code, .. } => self.log(&format!("control service error: {code}")),
            _ => {}
        }
    }

    // endregion

    // region Peers and the race

    pub fn set_peers(self: &Arc<Self>, list: Vec<PeerConfig>) -> Result<(), String> {
        let relay_only = self.mux.relay_only.load(Ordering::Relaxed);
        let mut now_connected = Vec::new();
        {
            let mut peers = self.peers.lock().unwrap();
            let mut next = HashMap::new();
            for cfg in list {
                let secret: [u8; 32] = b64::std_decode(&cfg.pair_secret).and_then(|s| s.try_into().ok()).ok_or("pairSecret must be 32 bytes")?;
                if cfg.side > 1 {
                    return Err("side must be 0 or 1".into());
                }
                let previous = peers.remove(&cfg.id);
                // A peer that just dropped, or is new to this process, is raced at once. Only when one of its LAN
                // addresses is on this network does the app's own LAN connection get a short head start, so a
                // working LAN is not raced onto the relay (happy eyeballs, docs/connect-anywhere-latency.md).
                let head_start = if relay_only || !cfg.addresses.iter().any(|a| a.kind == "lan" && a.a.parse().map(addrs::on_link).unwrap_or(false)) {
                    Duration::ZERO
                } else {
                    LAN_HEAD_START
                };
                let (next_attempt, failures) = match &previous {
                    Some(p) if p.cfg.connected && !cfg.connected => (Instant::now() + head_start, 0),
                    Some(p) => (p.next_attempt, p.failures),
                    None => (Instant::now() + head_start, 0),
                };
                if cfg.connected && !previous.as_ref().is_some_and(|p| p.cfg.connected) {
                    now_connected.push(cfg.id.clone());
                }
                next.insert(cfg.id.clone(), Peer { sig_key: derive::sig_key(&secret), secret, cfg, next_attempt, failures });
            }
            *peers = next;
        }
        self.register();
        // A peer the app just connected (on the LAN, or a tunnel) needs no ICE session still looking for it.
        for peer in now_connected {
            let pending: Vec<String> = self.ice.lock().unwrap().values().filter(|s| s.peer == peer && s.tunnel.lock().unwrap().is_none()).map(|s| s.agent.sid.clone()).collect();
            for sid in pending {
                self.end_ice(&sid, "connected");
            }
        }
        self.connect_waiting("disconnected");
        let due = self.peers.lock().unwrap().values().filter(|p| !p.cfg.connected).map(|p| p.next_attempt).filter(|t| *t > Instant::now()).min();
        if let Some(due) = due {
            let node = self.clone();
            tokio::spawn(async move {
                tokio::time::sleep_until(due.into()).await;
                node.connect_waiting("disconnected");
            });
        }
        Ok(())
    }

    /// Peers that are not connected, are due, and can be reached (learned addresses or online).
    fn connect_waiting(self: &Arc<Self>, reason: &str) {
        let due: Vec<String> = {
            let peers = self.peers.lock().unwrap();
            let now = Instant::now();
            peers
                .values()
                .filter(|p| !p.cfg.connected && p.next_attempt <= now)
                .filter(|p| !p.cfg.addresses.is_empty() || self.peer_online(&p.cfg.id))
                .map(|p| p.cfg.id.clone())
                .collect()
        };
        for peer in due {
            if !self.has_tunnel(&peer, Route::Relay) {
                self.clone().race(peer, reason.to_string(), None);
            }
        }
    }

    /// The control service just saw these peers online: a race that failed before it could signal them (the
    /// presence connection was still coming up) is not a reason to wait out its back-off.
    fn peers_seen_online(&self, ids: &[String]) {
        let mut peers = self.peers.lock().unwrap();
        for id in ids {
            if let Some(p) = peers.get_mut(id) {
                p.next_attempt = p.next_attempt.min(Instant::now());
            }
        }
    }

        fn peer_connected(&self, peer: &str) -> bool {
        self.peers.lock().unwrap().get(peer).is_some_and(|p| p.cfg.connected)
    }

    fn has_tunnel(&self, peer: &str, at_least: Route) -> bool {
        self.tunnels.lock().unwrap().values().any(|t| t.peer.as_deref() == Some(peer) && t.route.lock().unwrap().0 <= at_least)
    }

    fn best_route(&self, peer: &str) -> Option<Route> {
        self.tunnels.lock().unwrap().values().filter(|t| t.peer.as_deref() == Some(peer)).map(|t| t.route.lock().unwrap().0).min()
    }

    /// Races every route to `peer`; with `better_than`, only routes better than that (upgrades).
    pub fn race(self: Arc<Self>, peer: String, reason: String, better_than: Option<Route>) {
        if !self.racing.lock().unwrap().insert(peer.clone()) {
            return;
        }
        self.mark("race.start", Some(&peer), Some(&reason));
        tokio::spawn(async move {
            let started = Instant::now();
            let relay_only = self.mux.relay_only.load(Ordering::Relaxed);
            let addresses: Vec<(SocketAddr, Route, Option<String>)> = {
                let peers = self.peers.lock().unwrap();
                peers.get(&peer).map(|p| p.cfg.addresses.clone()).unwrap_or_default()
            }
            .into_iter()
            .filter_map(|l| {
                let vpn = l.vpn.clone();
                addrs::parse_learned(&l.a, l.p).map(|a| (a, addrs::route_of(a.ip()), vpn))
            })
            .filter(|(_, route, _)| better_than.map(|b| *route < b).unwrap_or(true))
            .take(8)
            .collect();
            let mut attempts = tokio::task::JoinSet::new();
            if !relay_only {
                for (i, (addr, route, vpn)) in addresses.into_iter().enumerate() {
                    let node = self.clone();
                    let peer = peer.clone();
                    // Two at a time, 150 ms apart (spec 4.3).
                    let delay = Duration::from_millis(150 * (i as u64 / 2));
                    attempts.spawn(async move {
                        tokio::time::sleep(delay).await;
                        node.dial_direct(peer, addr, route, vpn).await
                    });
                }
            }
            let wants_ice = better_than.map(|b| b > Route::Direct).unwrap_or(true) || relay_only;
            if wants_ice && better_than.is_none() && self.rdv.lock().unwrap().is_some() {
                // ICE joins the race as soon as the control service is up and reports the peer online, so a race
                // that starts while the presence connection is still coming up (app start, network change) does
                // not have to fail and back off before the relay is tried.
                let node = self.clone();
                let peer = peer.clone();
                attempts.spawn(async move {
                    let deadline = Instant::now() + Duration::from_secs(11);
                    while Instant::now() < deadline {
                        if node.has_tunnel(&peer, Route::Relay) || node.peer_connected(&peer) {
                            return;
                        }
                        // Woken by any change of the connection or presence (no polling delay on the way in).
                        let changed = node.rdv_changed.notified();
                        if node.rdv_connected.load(Ordering::Relaxed) {
                            if node.peer_online(&peer) {
                                let generation = node.rdv_generation.load(Ordering::Relaxed);
                                node.clone().offer_ice(peer.clone()).await;
                                // The control service connection was replaced while the signals were out (a refresh,
                                // a network change): they may be lost, so offer again on the new one.
                                if node.has_tunnel(&peer, Route::Relay) || node.rdv_generation.load(Ordering::Relaxed) == generation {
                                    return;
                                }
                                continue;
                            }
                            let settled = node.rdv_since.lock().unwrap().map(|t| t.elapsed() > Duration::from_secs(2)).unwrap_or(true);
                            if settled {
                                return;
                            }
                        }
                        tokio::select! {
                            _ = changed => {}
                            _ = tokio::time::sleep(Duration::from_millis(250)) => {}
                        }
                    }
                });
            }
            let deadline = tokio::time::sleep(Duration::from_secs(12));
            tokio::pin!(deadline);
            loop {
                tokio::select! {
                    _ = &mut deadline => { attempts.abort_all(); break }
                    next = attempts.join_next() => {
                        if next.is_none() { break }
                        if self.has_tunnel(&peer, Route::Lan) { attempts.abort_all(); break }
                    }
                }
            }
            self.racing.lock().unwrap().remove(&peer);
            let won = self.best_route(&peer);
            let mut peers = self.peers.lock().unwrap();
            if let Some(p) = peers.get_mut(&peer) {
                match won {
                    // An upgrade race that found nothing better than the tunnel it started from.
                    Some(route) if better_than.is_some_and(|b| route >= b) => {
                        drop(peers);
                        self.log(&format!("race {reason} kept {} after {} ms", route.as_str(), started.elapsed().as_millis()));
                    }
                    Some(route) => {
                        // Failures reset only when the app authenticates a session on the tunnel.
                        p.next_attempt = Instant::now() + Duration::from_secs(1);
                        drop(peers);
                        self.log(&format!("race {reason} won {} in {} ms", route.as_str(), started.elapsed().as_millis()));
                        self.mark("race.won", Some(&peer), Some(route.as_str()));
                    }
                    None if better_than.is_none() => {
                        p.failures = p.failures.saturating_add(1);
                        // Full jitter, 1 s base, 60 s cap (the existing reconnect backoff).
                        let cap = (1_000u64 << p.failures.min(6)).min(60_000);
                        let wait = u64::from_be_bytes(random_bytes::<8>()) % cap;
                        p.next_attempt = Instant::now() + Duration::from_millis(wait.max(500));
                        drop(peers);
                        self.mark("race.failed", Some(&peer), None);
                        self.event(json!({"e": "connect.failed", "peer": peer, "reason": "unreachable"}));
                    }
                    None => {}
                }
            }
        });
    }

    async fn dial_direct(self: Arc<Self>, peer: String, addr: SocketAddr, route: Route, vpn: Option<String>) {
        let config = quic::client_config(&self.identity.read().unwrap(), None, keep_alive(route));
        let Ok(connecting) = self.endpoint.connect_with(config, addr, "bridgey") else { return };
        let Ok(Ok(conn)) = tokio::time::timeout(Duration::from_secs(3), connecting).await else { return };
        if self.has_tunnel(&peer, route) {
            conn.close(0u32.into(), b"superseded");
            return;
        }
        // Tailscale is named only when the peer said so or the address is Tailscale's own IPv6 range (spec 4.1).
        let label = (route == Route::Vpn).then(|| if addrs::is_tailscale(addr.ip()) { Some("tailscale".to_string()) } else { vpn }).flatten();
        self.register_tunnel_labelled(conn, true, route, None, Some(peer), None, label);
    }

    // endregion

    // region ICE through the control service

    fn rdv_for(&self, peer: &str) -> Option<String> {
        let peers = self.peers.lock().unwrap();
        let p = peers.get(peer)?;
        Some(derive::rdv_id(&p.secret, &derive::utc_date(now_ms())))
    }

    fn side_of(&self, peer: &str) -> Option<u8> {
        self.peers.lock().unwrap().get(peer).map(|p| p.cfg.side)
    }

    fn send_signal(&self, session: &IceSession, signal: Signal) {
        let key = match self.peers.lock().unwrap().get(&session.peer) {
            Some(p) => p.sig_key,
            None => return,
        };
        let plaintext = serde_json::to_vec(&signal).expect("signal");
        let body = seal::seal(&key, &session.rdv, session.side, signal.sid(), &plaintext);
        self.rdv_send(Msg::Signal { rdv: session.rdv.clone(), side: session.side, sid: signal.sid().to_string(), body });
    }

    fn description(&self, session: &IceSession) -> Description {
        let seq = session.seq.fetch_add(1, Ordering::Relaxed) + 1;
        Description {
            sid: session.agent.sid.clone(),
            v: 1,
            ufrag: session.agent.local_ufrag.clone(),
            pwd: session.agent.local_pwd.clone(),
            cands: session.agent.locals().iter().map(Local::candidate).take(24).collect(),
            cert: self.identity.read().unwrap().cert_sha256.clone(),
            rtts: None,
            net: None,
            ts: now_ms(),
            seq,
        }
    }

    fn new_session(self: &Arc<Self>, peer: &str, sid: String, rdv: String) -> Option<Arc<IceSession>> {
        let side = self.side_of(peer)?;
        let (agent, events) = IceAgent::new(self.mux.clone(), sid.clone(), side == 0);
        let relay_only = self.mux.relay_only.load(Ordering::Relaxed);
        if !relay_only {
            for local in IceAgent::host_candidates(self.mux.port()) {
                agent.add_local(local);
            }
        }
        // The warm relay's candidates go in the first description: no grant, allocation or STUN to wait for.
        let (srflx, warm) = {
            let w = self.warm.lock().unwrap();
            (w.srflx.filter(|(_, at)| at.elapsed() < Duration::from_secs(120)).map(|(a, _)| a), w.allocation.clone())
        };
        if let Some(mapped) = srflx.filter(|_| !relay_only) {
            agent.add_local(Local { via: Via::Direct, addr: mapped, kind: "srflx", pri: crate::ice::priority(crate::ice::TYPE_SRFLX, mapped.ip()), relay: None, net: None });
        }
        if let Some(allocation) = &warm {
            agent.add_local(Local {
                via: Via::Turn(allocation.server),
                addr: allocation.relayed,
                kind: "relay",
                pri: crate::ice::priority(crate::ice::TYPE_RELAY, allocation.relayed.ip()),
                relay: Some(allocation.relay_id.clone()),
                net: None,
            });
        }
        let session = Arc::new(IceSession {
            agent,
            peer: peer.to_string(),
            rdv,
            side,
            seq: AtomicU64::new(0),
            last_remote_seq: Mutex::new(0),
            remote_cert: Mutex::new(None),
            route: Mutex::new((Route::Relay, None)),
            allocation: Mutex::new(None),
            tunnel: Mutex::new(None),
            relay_retried: AtomicBool::new(false),
            generation: self.rdv_generation.load(Ordering::Relaxed),
            described: AtomicBool::new(false),
        });
        *session.allocation.lock().unwrap() = warm;
        self.ice.lock().unwrap().insert(sid, session.clone());
        tokio::spawn(self.clone().ice_events(session.clone(), events));
        if srflx.is_none() && !relay_only {
            // No fresh server-reflexive address: find it now and trickle it.
            let node = self.clone();
            let session = session.clone();
            tokio::spawn(async move { node.trickle_srflx(&session).await });
        }
        Some(session)
    }

    /// Our server-reflexive address from the nearest relay's STUN, added to `session` and trickled.
    async fn trickle_srflx(self: &Arc<Self>, session: &Arc<IceSession>) {
        let Some(mapped) = self.refresh_srflx().await else { return };
        let local = Local { via: Via::Direct, addr: mapped, kind: "srflx", pri: crate::ice::priority(crate::ice::TYPE_SRFLX, mapped.ip()), relay: None, net: None };
        session.agent.add_local(local.clone());
        self.trickle(session, vec![local.candidate()]);
        self.mark("ice.srflx", Some(&session.peer), None);
    }

    /// The relay grant this session should use when it has no allocation: the node's own (warm) credentials, or
    /// none (then it asks the control service for a session grant, as older services require).
    fn relay_for_session(self: &Arc<Self>, session: &Arc<IceSession>) -> bool {
        if session.allocation.lock().unwrap().is_some() {
            return true;
        }
        let grant = self.warm.lock().unwrap().grant.clone();
        match grant {
            Some((grant, _)) => {
                let node = self.clone();
                let session = session.clone();
                tokio::spawn(async move { node.use_grant(session, grant).await });
                true
            }
            None => false,
        }
    }

    /// The offering side: a new ICE session, the offer, and a relay request (spec 4.3).
    async fn offer_ice(self: Arc<Self>, peer: String) {
        // An ICE session with this peer is already under way (we answered its offer): wait for it.
        let existing = self.ice.lock().unwrap().values().find(|s| s.peer == peer && s.tunnel.lock().unwrap().is_none()).cloned();
        if let Some(session) = existing {
            self.wait_for_tunnel(&session).await;
            return;
        }
        let Some(rdv) = self.rdv_for(&peer) else { return };
        let sid = b64::url_encode(&random_bytes::<16>());
        let Some(session) = self.new_session(&peer, sid.clone(), rdv.clone()) else { return };
        self.send_signal(&session, Signal::Offer(self.description(&session)));
        self.mark("ice.offer.sent", Some(&peer), None);
        if !self.relay_for_session(&session) {
            let rtts = Some(self.warm.lock().unwrap().rtts.clone()).filter(|r| !r.is_empty());
            self.rdv_send(Msg::RelayRequest { rdv, sid: sid.clone(), side: session.side, rtts, need: Some("udp".into()), est_bytes: None, exclude: None });
        }
        self.wait_for_tunnel(&session).await;
    }

    /// Waits up to 12 s for `session` to carry a tunnel. If it ends in glare, waits for the
    /// session that replaced it (the other side's offer, which this side answered).
    async fn wait_for_tunnel(&self, session: &IceSession) {
        let mut sid = session.agent.sid.clone();
        for _ in 0..120 {
            let current = self.ice.lock().unwrap().get(&sid).cloned();
            match current {
                Some(s) if s.tunnel.lock().unwrap().is_some() => return,
                Some(_) => {}
                None => {
                    let replacement = self.ice.lock().unwrap().values().find(|s| s.peer == session.peer).map(|s| s.agent.sid.clone());
                    match replacement {
                        Some(next) => sid = next,
                        None => return,
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    fn on_signal(self: &Arc<Self>, rdv: String, side: u8, sid: String, body: String) {
        let Some(peer) = self.rdv_ids.lock().unwrap().get(&rdv).cloned() else { return };
        let Some((key, local_side)) = self.peers.lock().unwrap().get(&peer).map(|p| (p.sig_key, p.cfg.side)) else { return };
        if side == local_side {
            return;
        }
        let Some(plain) = seal::open(&key, &rdv, side, &sid, &body) else { return };
        let Ok(signal) = serde_json::from_slice::<Signal>(&plain) else { return };
        if signal.sid() != sid || !signal.valid(now_ms()) {
            return;
        }
        let existing = self.ice.lock().unwrap().get(&sid).cloned();
        if let Some(session) = &existing {
            let mut last = session.last_remote_seq.lock().unwrap();
            if signal.seq() <= *last {
                return;
            }
            *last = signal.seq();
        }
        match signal {
            Signal::Offer(desc) => {
                if existing.is_some() {
                    return;
                }
                // Glare: both offered at once. The lower device ID's offer wins.
                let mine: Vec<Arc<IceSession>> = self.ice.lock().unwrap().values().filter(|s| s.peer == peer && s.tunnel.lock().unwrap().is_none()).cloned().collect();
                if !mine.is_empty() && local_side == 0 {
                    return;
                }
                for s in mine {
                    self.end_ice(&s.agent.sid, "glare");
                }
                if self.has_tunnel(&peer, Route::Relay) {
                    // Already connected: this is the other side's stale view; let it time out.
                }
                self.mark("ice.offer.received", Some(&peer), None);
                let Some(session) = self.new_session(&peer, sid.clone(), rdv.clone()) else { return };
                *session.last_remote_seq.lock().unwrap() = desc.seq;
                // Answer first (the offerer starts checking on it), then open our relay to the offerer's addresses.
                self.send_signal(&session, Signal::Answer(self.description(&session)));
                self.mark("ice.answer.sent", Some(&peer), None);
                self.apply_description(&session, &desc);
                if !self.relay_for_session(&session) {
                    self.rdv_send(Msg::RelayClaim { rdv, sid, side: session.side });
                }
            }
            Signal::Answer(desc) => {
                if let Some(session) = existing {
                    self.mark("ice.answer.received", Some(&peer), None);
                    self.apply_description(&session, &desc);
                }
            }
            Signal::Cand { cands, .. } => {
                if let Some(session) = existing {
                    for cand in &cands {
                        session.agent.add_remote(cand);
                    }
                    self.prepare_relay_paths(&session);
                }
            }
            Signal::Bye { .. } => self.end_ice(&sid, "bye"),
            Signal::Restart { .. } => {}
        }
    }

    fn apply_description(self: &Arc<Self>, session: &Arc<IceSession>, desc: &Description) {
        *session.remote_cert.lock().unwrap() = Some(desc.cert.clone());
        session.described.store(true, Ordering::Relaxed);
        session.agent.set_remote_credentials(&desc.ufrag, &desc.pwd);
        for cand in &desc.cands {
            session.agent.add_remote(cand);
        }
        self.prepare_relay_paths(session);
    }

    fn on_grant(self: &Arc<Self>, sid: String, grant: RelayGrant) {
        let Some(session) = self.ice.lock().unwrap().get(&sid).cloned() else { return };
        self.mark("relay.grant", Some(&session.peer), Some(&grant.id));
        if session.allocation.lock().unwrap().is_some() {
            return;
        }
        let node = self.clone();
        tokio::spawn(async move { node.use_grant(session, grant).await });
    }

    /// Allocates on `grant`'s relay for `session` (shared with any other session there) and adds the candidate.
    /// No head start here: the ICE agent gives direct pairs theirs, so the relay is ready when it is needed.
    async fn use_grant(self: Arc<Self>, session: Arc<IceSession>, grant: RelayGrant) {
        let Some(server) = self.resolve_relay(&grant).await else { return };
        let allocation = match self.allocate_on(server, &grant).await {
            Ok(a) => a,
            Err(e) => {
                self.log(&format!("relay {} allocation failed: {e}", grant.id));
                // Ask for another relay once; ICE pairs relay addresses on different servers too.
                if !session.relay_retried.swap(true, Ordering::Relaxed) {
                    self.rdv_send(Msg::RelayRequest {
                        rdv: session.rdv.clone(),
                        sid: session.agent.sid.clone(),
                        side: session.side,
                        rtts: None,
                        need: Some("udp".into()),
                        est_bytes: None,
                        exclude: Some(vec![grant.id.clone()]),
                    });
                }
                return;
            }
        };
        {
            let mut current = session.allocation.lock().unwrap();
            if current.is_some() {
                return;
            }
            *current = Some(allocation.clone());
        }
        self.mark("turn.allocated", Some(&session.peer), Some(&grant.id));
        // Every relay in the pool may carry the other side's relay candidate.
        let pool: Vec<std::net::IpAddr> = self.warm.lock().unwrap().relays.iter().map(|(_, a)| a.ip()).collect();
        let _ = allocation.permit(&pool).await;
        let local = Local {
            via: Via::Turn(server),
            addr: allocation.relayed,
            kind: "relay",
            pri: crate::ice::priority(crate::ice::TYPE_RELAY, allocation.relayed.ip()),
            relay: Some(grant.id.clone()),
            net: None,
        };
        session.agent.add_local(local.clone());
        self.trickle(&session, vec![local.candidate()]);
        self.prepare_relay_paths(&session);
    }

    async fn resolve_relay(&self, grant: &RelayGrant) -> Option<SocketAddr> {
        let (host, port) = grant.urls.iter().find_map(|u| turn::parse_udp_url(u))?;
        // The pool from `welcome` is already resolved.
        if let Some(addr) = self.warm.lock().unwrap().relays.iter().find(|(id, _)| *id == grant.id).map(|(_, a)| *a) {
            return Some(addr);
        }
        tokio::net::lookup_host((host.as_str(), port)).await.ok().and_then(|mut it| it.next()).map(addrs::canonical)
    }

    /// One allocation per relay for this socket, shared by every session (a second Allocate there is refused
    /// with 437). Carries credentials in the first request when the relay's realm and nonce are known.
    async fn allocate_on(&self, server: SocketAddr, grant: &RelayGrant) -> Result<Arc<Allocation>, String> {
        let _one = self.allocating.lock().await;
        let pending = self.releasing.lock().unwrap().remove(&server);
        if let Some(release) = pending {
            let _ = tokio::time::timeout(Duration::from_secs(3), release).await;
        }
        if let Some(existing) = self.allocations.lock().unwrap().get(&server).cloned() {
            return Ok(existing);
        }
        let cached = self.realms.lock().unwrap().get(&server).cloned();
        let allocation = Allocation::allocate_with(self.mux.clone(), server, &grant.id, &grant.username, &grant.credential, cached).await?;
        self.realms.lock().unwrap().insert(server, allocation.realm());
        self.allocations.lock().unwrap().insert(server, allocation.clone());
        Ok(allocation)
    }

    fn trickle(&self, session: &IceSession, cands: Vec<Candidate>) {
        let seq = session.seq.fetch_add(1, Ordering::Relaxed) + 1;
        self.send_signal(session, Signal::Cand { sid: session.agent.sid.clone(), cands, done: false, ts: now_ms(), seq });
    }

    /// Opens our relay to the other side's candidates: one CreatePermission for every address not yet allowed (pairs
    /// can then send at once, as Send indications), then a channel per address in the background (smaller frames).
    fn prepare_relay_paths(self: &Arc<Self>, session: &Arc<IceSession>) {
        let Some(allocation) = session.allocation.lock().unwrap().clone() else { return };
        let remotes: Vec<SocketAddr> = session.agent.remote_addresses().into_iter().filter(|a| a.is_ipv4() == allocation.relayed.is_ipv4()).collect();
        let mut ips: Vec<std::net::IpAddr> = remotes.iter().map(|a| a.ip()).filter(|ip| !self.mux.has_permission(allocation.server, *ip)).collect();
        ips.sort();
        ips.dedup();
        let unbound: Vec<SocketAddr> = remotes.into_iter().filter(|r| !self.mux.has_channel(allocation.server, *r)).collect();
        if ips.is_empty() && unbound.is_empty() {
            return;
        }
        let node = self.weak();
        let peer = session.peer.clone();
        tokio::spawn(async move {
            if !ips.is_empty() && allocation.permit(&ips).await.is_ok() {
                if let Some(node) = node.upgrade() {
                    node.mark("turn.permitted", Some(&peer), None);
                }
            }
            for remote in unbound {
                let allocation = allocation.clone();
                tokio::spawn(async move {
                    let _ = allocation.bind(remote).await;
                });
            }
        });
    }

    async fn ice_events(self: Arc<Self>, session: Arc<IceSession>, mut events: mpsc::UnboundedReceiver<IceEvent>) {
        let mut maintained = false;
        while let Some(event) = events.recv().await {
            match event {
                IceEvent::FirstSuccess { route } => self.mark("ice.first_success", Some(&session.peer), Some(route.as_str())),
                IceEvent::Selected { route, relay, rtt } => {
                    self.mark("ice.selected", Some(&session.peer), Some(route.as_str()));
                    *session.route.lock().unwrap() = (route, relay.clone());
                    let tunnel = session.tunnel.lock().unwrap().clone();
                    match tunnel {
                        Some(id) => {
                            if let Some(t) = self.tunnels.lock().unwrap().get(&id) {
                                *t.route.lock().unwrap() = (route, relay.clone());
                            }
                            self.event(json!({"e": "route", "tunnel": id, "route": route.as_str(), "relay": relay, "rttMs": rtt.as_millis() as u64}));
                        }
                        None if session.agent.controlling => {
                            let node = self.clone();
                            let session = session.clone();
                            tokio::spawn(async move { node.dial_ice(session, route, relay).await });
                        }
                        None => {}
                    }
                    if !maintained {
                        maintained = true;
                        tokio::spawn(session.agent.clone().maintain());
                    }
                }
                IceEvent::Failed(reason) => {
                    let tunnel = session.tunnel.lock().unwrap().clone();
                    if let Some(id) = tunnel {
                        if let Some(t) = self.tunnels.lock().unwrap().get(&id) {
                            t.conn.close(0u32.into(), b"path_failed");
                        }
                    }
                    self.end_ice(&session.agent.sid, reason);
                    break;
                }
            }
        }
    }

    async fn dial_ice(self: Arc<Self>, session: Arc<IceSession>, route: Route, relay: Option<String>) {
        let pin = session.remote_cert.lock().unwrap().clone();
        let config = quic::client_config(&self.identity.read().unwrap(), pin, keep_alive(route));
        let Ok(connecting) = self.endpoint.connect_with(config, session.agent.vaddr, "bridgey") else { return };
        match tokio::time::timeout(Duration::from_secs(8), connecting).await {
            Ok(Ok(conn)) => {
                self.mark("quic.connected", Some(&session.peer), None);
                let route_now = session.route.lock().unwrap().clone();
                let _ = relay;
                self.register_tunnel(conn, true, route_now.0, route_now.1, Some(session.peer.clone()), Some(session.clone()));
            }
            _ => self.end_ice(&session.agent.sid, "quic_failed"),
        }
    }

    fn end_ice(&self, sid: &str, reason: &str) {
        let Some(session) = self.ice.lock().unwrap().remove(sid) else { return };
        session.agent.close();
        if reason != "bye" && reason != "undeliverable" {
            let seq = session.seq.fetch_add(1, Ordering::Relaxed) + 1;
            self.send_signal(&session, Signal::Bye { sid: sid.to_string(), reason: reason.chars().take(32).collect(), ts: now_ms(), seq });
        }
        self.rdv_send(Msg::RelayRelease { sid: sid.to_string() });
        let allocation = session.allocation.lock().unwrap().take();
        if let Some(allocation) = allocation {
            let still_used = self.ice.lock().unwrap().values().any(|s| s.allocation.lock().unwrap().as_ref().map(|a| a.server) == Some(allocation.server));
            // The warm allocation outlives sessions; it is kept for the next one.
            let warm = self.warm.lock().unwrap().allocation.as_ref().is_some_and(|w| Arc::ptr_eq(w, &allocation));
            if !still_used && !warm {
                self.allocations.lock().unwrap().remove(&allocation.server);
                let server = allocation.server;
                let release = tokio::spawn(async move { allocation.release().await });
                self.releasing.lock().unwrap().insert(server, release);
            }
        }
    }

    // endregion

    // region The warm relay

    /// What the app kept from the last run: relay round trips and the pool (probed again at once), and an
    /// allocation that a killed process may have left on this socket (reclaimed after the sign-in).
    fn restore_state(self: &Arc<Self>) {
        let keepalive = Duration::from_secs(u64::from(self.cfg.relay_keepalive_s));
        let mut warm = self.warm.lock().unwrap();
        warm.keepalive = keepalive;
        let state = self.cfg.state.clone().unwrap_or(Value::Null);
        if let Some(rtts) = state.get("rtts").and_then(|r| serde_json::from_value::<BTreeMap<String, u32>>(r.clone()).ok()) {
            warm.rtts = rtts;
        }
        let relays: Vec<(String, SocketAddr)> = state
            .get("relays")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(|r| Some((r.get("id")?.as_str()?.to_string(), addrs::canonical(r.get("addr")?.as_str()?.parse().ok()?)))).collect())
            .unwrap_or_default();
        if let Some(w) = state.get("warm") {
            let fresh = w.get("at").and_then(Value::as_u64).is_some_and(|at| now_ms().saturating_sub(at) < LEFT_BEHIND_MAX_AGE_MS);
            let same_socket = state.get("port").and_then(Value::as_u64) == Some(u64::from(self.mux.port()));
            let parsed = (|| {
                Some(LeftBehind {
                    relay: w.get("relay")?.as_str()?.to_string(),
                    server: addrs::canonical(w.get("server")?.as_str()?.parse().ok()?),
                    username: w.get("username")?.as_str()?.to_string(),
                    realm: Some(Realm { realm: w.get("realm")?.as_str()?.to_string(), nonce: w.get("nonce")?.as_str()?.to_string() }),
                })
            })();
            if let Some(left) = parsed.filter(|_| fresh && same_socket) {
                self.realms.lock().unwrap().insert(left.server, left.realm.clone().unwrap_or_default());
                warm.left_behind = Some(left);
            }
        }
        // The sign-in asks for warm credentials (and the reclaim) in the same flight.
        if self.cfg.control_url.as_deref().is_some_and(|u| !u.is_empty()) {
            let reclaim = warm.left_behind.as_ref().map(|l| Reclaim { relay: l.relay.clone(), username: l.username.clone() });
            *self.rdv_shared.warm.lock().unwrap() = Some(WarmRequest { rtts: Some(warm.rtts.clone()).filter(|r| !r.is_empty()), exclude: None, reclaim });
        }
        drop(warm);
        if !relays.is_empty() {
            // Last run's pool: the server-reflexive address and round trips are ready before the sign-in is.
            let infos: Vec<RelayInfo> = relays.iter().map(|(id, addr)| RelayInfo { id: id.clone(), stun: addr.to_string() }).collect();
            let node = self.clone();
            tokio::spawn(async move { node.probe_relays(infos).await });
        }
    }

    /// STUN to every relay in the pool at once: round trips (for the relay choice) and our server-reflexive address
    /// (from the nearest). Skipped when the pool and a fresh address are already known.
    async fn probe_relays(self: Arc<Self>, relays: Vec<RelayInfo>) {
        let mut resolved = Vec::new();
        for relay in relays {
            let addr = match relay.stun.parse::<SocketAddr>() {
                Ok(a) => Some(a),
                Err(_) => tokio::net::lookup_host(relay.stun.as_str()).await.ok().and_then(|mut it| it.find(|a| a.is_ipv4())),
            };
            if let Some(addr) = addr {
                resolved.push((relay.id, addrs::canonical(addr)));
            }
        }
        {
            let mut warm = self.warm.lock().unwrap();
            let same = warm.relays == resolved;
            let fresh = warm.srflx.is_some_and(|(_, at)| at.elapsed() < Duration::from_secs(60));
            warm.relays = resolved.clone();
            if same && fresh {
                return;
            }
        }
        if self.mux.relay_only.load(Ordering::Relaxed) && resolved.is_empty() {
            return;
        }
        let mut probes = tokio::task::JoinSet::new();
        for (id, addr) in resolved {
            let mux = self.mux.clone();
            probes.spawn(async move { (id, turn::reflexive(&mux, addr).await) });
        }
        let mut best: Option<(u32, SocketAddr)> = None;
        while let Some(Ok((id, result))) = probes.join_next().await {
            let Some((mapped, rtt)) = result else { continue };
            let ms = rtt.as_millis() as u32;
            let mut warm = self.warm.lock().unwrap();
            warm.rtts.insert(id, ms);
            if best.is_none_or(|(b, _)| ms < b) {
                best = Some((ms, mapped));
                // The first answer is the nearest relay's: sessions can use the address from now on.
                warm.srflx = Some((mapped, Instant::now()));
            }
        }
        let rtts = self.warm.lock().unwrap().rtts.clone();
        if let Some(request) = self.rdv_shared.warm.lock().unwrap().as_mut() {
            request.rtts = Some(rtts).filter(|r| !r.is_empty());
        }
        self.mark("relay.probed", None, best.map(|(ms, _)| ms.to_string()).as_deref());
        self.emit_state();
    }

    /// Our server-reflexive address from the nearest relay (one STUN round trip), kept for new sessions.
    async fn refresh_srflx(&self) -> Option<SocketAddr> {
        let nearest = {
            let warm = self.warm.lock().unwrap();
            warm.relays.iter().min_by_key(|(id, _)| warm.rtts.get(id).copied().unwrap_or(u32::MAX)).map(|(_, a)| *a)
        }?;
        let (mapped, _) = turn::reflexive(&self.mux, nearest).await?;
        self.warm.lock().unwrap().srflx = Some((mapped, Instant::now()));
        Some(mapped)
    }

    /// The node's own relay credentials (from the sign-in). With a keep-alive, an allocation follows at once.
    fn on_warm_grant(self: &Arc<Self>, grant: RelayGrant) {
        self.mark("relay.warm_grant", None, Some(&grant.id));
        let node = self.clone();
        tokio::spawn(async move {
            let Some(server) = node.resolve_relay(&grant).await else { return };
            let replaced = {
                let mut warm = node.warm.lock().unwrap();
                let replaced = warm.grant.as_ref().is_some_and(|(old, _)| old.id != grant.id || old.username != grant.username);
                warm.grant = Some((grant, server));
                replaced
            };
            if replaced {
                // New credentials (a renewal, or another relay): the allocation made with the old ones ends.
                node.drop_warm_allocation(true);
            }
            node.ensure_warm().await;
        });
    }

    /// The credential of the allocation the last run left on this socket: end it, so the new one is not refused.
    fn on_reclaim(self: &Arc<Self>, grant: RelayGrant) {
        let Some(left) = self.warm.lock().unwrap().left_behind.take() else { return };
        if left.relay != grant.id || left.username != grant.username {
            return;
        }
        self.mark("relay.reclaim", None, Some(&grant.id));
        let mux = self.mux.clone();
        let weak = self.weak();
        self.warm.lock().unwrap().reclaimed_at = Some(Instant::now());
        let release = tokio::spawn(async move {
            let result = turn::release_left_behind(mux, left.server, &grant.username, &grant.credential, left.realm).await;
            if let Some(node) = weak.upgrade() {
                node.mark("relay.reclaimed", None, Some(match result {
                    Ok(true) => "ended",
                    Ok(false) => "none",
                    Err(_) => "failed",
                }));
            }
        });
        // The next Allocate on that relay waits for this release.
        self.releasing.lock().unwrap().insert(left.server, release);
    }

    /// Makes sure the warm allocation exists when it should (keep-alive on, credentials known, not relay-only off).
    async fn ensure_warm(self: &Arc<Self>) {
        let (grant, server) = {
            let mut warm = self.warm.lock().unwrap();
            if warm.keepalive.is_zero() || warm.allocation.is_some() || warm.allocating {
                return;
            }
            let Some((grant, server)) = warm.grant.clone() else { return };
            warm.allocating = true;
            (grant, server)
        };
        let result = self.allocate_on(server, &grant).await;
        // Decided under the lock, acted on after it (no lock across an await).
        let next = {
            let mut warm = self.warm.lock().unwrap();
            warm.allocating = false;
            match result {
                Ok(allocation) => {
                    warm.failures = 0;
                    warm.allocation = Some(allocation.clone());
                    Ok((allocation, warm.relays.iter().map(|(_, a)| a.ip()).collect::<Vec<std::net::IpAddr>>()))
                }
                Err(e) if e == turn::MISMATCH && warm.reclaimed_at.is_some_and(|t| t.elapsed() < Duration::from_secs(3)) => {
                    // The relay frees the reclaimed allocation on its next timer tick (about a second).
                    warm.allocating = true;
                    Err((e, None))
                }
                Err(e) => {
                    warm.failures += 1;
                    let mismatch = e == turn::MISMATCH;
                    if mismatch && !warm.exclude.contains(&grant.id) {
                        // A left-behind allocation we could not reclaim: use another relay until it lapses.
                        warm.exclude.push(grant.id.clone());
                    }
                    let request = WarmRequest { rtts: Some(warm.rtts.clone()).filter(|r| !r.is_empty()), exclude: Some(warm.exclude.clone()), reclaim: None };
                    Err((e, mismatch.then_some(request)))
                }
            }
        };
        match next {
            Ok((allocation, pool)) => {
                self.mark("relay.warm_allocated", None, Some(&grant.id));
                // Every relay in the pool may carry a peer's relay candidate: permit them all now.
                let _ = allocation.permit(&pool).await;
                self.emit_state();
            }
            Err((e, retry)) => {
                let waiting = self.warm.lock().unwrap().allocating;
                if waiting {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    self.warm.lock().unwrap().allocating = false;
                    Box::pin(self.ensure_warm()).await;
                    return;
                }
                self.log(&format!("warm relay {} failed: {e}", grant.id));
                if let Some(request) = retry {
                    self.rdv_send(Msg::RelayWarm { request });
                }
            }
        }
    }

    /// Forgets the warm allocation (a network change moved this socket, or its credentials were replaced).
    fn drop_warm_allocation(&self, release: bool) {
        let old = self.warm.lock().unwrap().allocation.take();
        if let Some(old) = old {
            let used = self.ice.lock().unwrap().values().any(|s| s.allocation.lock().unwrap().as_ref().is_some_and(|a| Arc::ptr_eq(a, &old)));
            if !used {
                self.allocations.lock().unwrap().remove(&old.server);
                let server = old.server;
                if release {
                    let task = tokio::spawn(async move { old.release().await });
                    self.releasing.lock().unwrap().insert(server, task);
                } else {
                    self.mux.remove_turn(server);
                }
            }
        }
    }

    /// Keeps the warm relay usable: a STUN round trip to it every keep-alive holds the NAT mapping open (and keeps
    /// our server-reflexive address fresh); credentials are renewed before they expire; the state is saved.
    async fn warm_loop(self: Arc<Self>) {
        let mut since_state = Duration::ZERO;
        let mut misses = 0u32;
        loop {
            let keepalive = self.warm.lock().unwrap().keepalive;
            let wait = if keepalive.is_zero() { Duration::from_secs(60) } else { keepalive };
            tokio::time::sleep(wait).await;
            if self.stopped.load(Ordering::Relaxed) {
                break;
            }
            since_state += wait;
            let (allocation, grant) = {
                let warm = self.warm.lock().unwrap();
                (warm.allocation.clone(), warm.grant.clone())
            };
            if let Some(allocation) = allocation.filter(|_| !keepalive.is_zero()) {
                match turn::reflexive(&self.mux, allocation.server).await {
                    Some((mapped, _)) => {
                        misses = 0;
                        self.warm.lock().unwrap().srflx = Some((mapped, Instant::now()));
                    }
                    None => {
                        misses += 1;
                        if misses >= 2 {
                            misses = 0;
                            self.drop_warm_allocation(false);
                        }
                    }
                }
            }
            if let Some((grant, _)) = grant {
                // Renew in the credentials' last hour; the new grant replaces the allocation.
                let left = grant.expires_at.saturating_sub(now_ms());
                if left < 3_600_000 && self.rdv_connected.load(Ordering::Relaxed) {
                    let request = self.rdv_shared.warm.lock().unwrap().clone().unwrap_or_default();
                    self.rdv_send(Msg::RelayWarm { request });
                }
            }
            self.ensure_warm().await;
            if since_state >= Duration::from_secs(240) {
                since_state = Duration::ZERO;
                self.emit_state();
            }
        }
    }

    /// What the app should keep for the next run (the `state` event): never a credential.
    fn emit_state(&self) {
        let warm = self.warm.lock().unwrap();
        let relays: Vec<Value> = warm.relays.iter().map(|(id, addr)| json!({"id": id, "addr": addr.to_string()})).collect();
        let allocation = warm.allocation.as_ref().map(|a| {
            let realm = a.realm();
            json!({"relay": a.relay_id, "server": a.server.to_string(), "username": a.username(), "realm": realm.realm, "nonce": realm.nonce, "at": now_ms()})
        });
        let state = json!({"v": 1, "port": self.mux.port(), "rtts": warm.rtts, "relays": relays, "warm": allocation});
        drop(warm);
        self.event(json!({"e": "state", "state": state}));
    }

    /// A new control service connection: signals sent on an older one may be lost. Sessions that never heard
    /// back end (the race offers again); answered ones keep their paths.
    fn resignal(&self, generation: u64) {
        let stale: Vec<String> = self
            .ice
            .lock()
            .unwrap()
            .values()
            .filter(|s| s.generation < generation && s.tunnel.lock().unwrap().is_none() && !s.agent.is_selected() && !s.described.load(Ordering::Relaxed))
            .map(|s| s.agent.sid.clone())
            .collect();
        for sid in stale {
            self.end_ice(&sid, "resignal");
        }
    }

    // endregion

    // region Tunnels and the bridge

    async fn accept_loop(self: Arc<Self>) {
        while let Some(incoming) = self.endpoint.accept().await {
            // Caps before the handshake: tunnels the app has not authenticated yet, in all and per source
            // address (ICE tunnels come from virtual addresses and were set up through sealed signalling).
            let source = addrs::canonical(incoming.remote_address());
            let (pending_total, pending_here) = {
                let tunnels = self.tunnels.lock().unwrap();
                let pending: Vec<_> = tunnels.values().filter(|t| !t.authenticated.load(Ordering::Relaxed)).collect();
                (pending.len(), pending.iter().filter(|t| t.remote_ip == Some(source.ip())).count())
            };
            if pending_total >= 16 || (!is_virtual(source) && pending_here >= 3) {
                incoming.refuse();
                continue;
            }
            let node = self.clone();
            tokio::spawn(async move {
                let Ok(Ok(conn)) = tokio::time::timeout(Duration::from_secs(10), incoming).await else { return };
                let remote = addrs::canonical(conn.remote_address());
                if is_virtual(remote) {
                    let session = node.ice.lock().unwrap().values().find(|s| s.agent.vaddr == remote).cloned();
                    let Some(session) = session else {
                        conn.close(0u32.into(), b"unknown");
                        return;
                    };
                    let pin = session.remote_cert.lock().unwrap().clone();
                    if pin.is_some() && quic::peer_cert_hash(&conn) != pin {
                        conn.close(0u32.into(), b"pin");
                        return;
                    }
                    let (route, relay) = session.route.lock().unwrap().clone();
                    node.mark("quic.accepted", Some(&session.peer), None);
                    node.register_tunnel(conn, false, route, relay, Some(session.peer.clone()), Some(session));
                } else {
                    let route = addrs::route_of(remote.ip());
                    node.register_tunnel(conn, false, route, None, None, None);
                }
            });
        }
    }

    fn register_tunnel(self: &Arc<Self>, conn: quinn::Connection, quic_client: bool, route: Route, relay: Option<String>, peer: Option<String>, ice: Option<Arc<IceSession>>) {
        self.register_tunnel_labelled(conn, quic_client, route, relay, peer, ice, None);
    }

    /// [register_tunnel] with the private network's name (`tailscale`) when the route is a VPN address.
    #[allow(clippy::too_many_arguments)]
    fn register_tunnel_labelled(
        self: &Arc<Self>,
        conn: quinn::Connection,
        quic_client: bool,
        route: Route,
        relay: Option<String>,
        peer: Option<String>,
        ice: Option<Arc<IceSession>>,
        vpn: Option<String>,
    ) {
        let Some(exporter) = quic::exporter(&conn) else {
            conn.close(0u32.into(), b"exporter");
            return;
        };
        let id = format!("t{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        if let Some(session) = &ice {
            *session.tunnel.lock().unwrap() = Some(id.clone());
        }
        let token = random_bytes::<32>();
        let tunnel = Arc::new(Tunnel {
            id: id.clone(),
            peer: peer.clone(),
            conn: conn.clone(),
            route: Mutex::new((route, relay.clone())),
            token,
            quic_client,
            claimed: AtomicBool::new(false),
            authenticated: AtomicBool::new(false),
            remote_ip: (!quic_client).then(|| addrs::canonical(conn.remote_address()).ip()).filter(|ip| !is_virtual(SocketAddr::new(*ip, 1))),
            ice: ice.as_ref().map(|s| s.agent.sid.clone()),
        });
        self.tunnels.lock().unwrap().insert(id.clone(), tunnel.clone());
        self.mark("tunnel", peer.as_deref(), Some(route.as_str()));
        self.event(json!({
            "e": "tunnel",
            "tunnel": id,
            "port": self.bridge_port,
            "token": hex(&token),
            "exporter": exporter,
            "route": route.as_str(),
            "relay": relay,
            "vpn": vpn,
            "quicClient": quic_client,
            "peer": peer,
            "rttMs": conn.rtt().as_millis() as u64,
        }));
        let node = self.clone();
        tokio::spawn(async move {
            let unclaimed = async {
                tokio::time::sleep(Duration::from_secs(15)).await;
                if !tunnel.claimed.load(Ordering::Relaxed) {
                    tunnel.conn.close(0u32.into(), b"unclaimed");
                }
                tokio::time::sleep(Duration::from_secs(15)).await;
                if !tunnel.authenticated.load(Ordering::Relaxed) {
                    tunnel.conn.close(0u32.into(), b"unauthenticated");
                }
                std::future::pending::<()>().await
            };
            let reason = tokio::select! {
                error = tunnel.conn.closed() => close_reason(&error),
                _ = unclaimed => unreachable!(),
            };
            node.tunnels.lock().unwrap().remove(&tunnel.id);
            if let Some(sid) = &tunnel.ice {
                node.end_ice(sid, "closed");
            }
            node.event(json!({"e": "tunnel.closed", "tunnel": tunnel.id, "reason": reason}));
            // A tunnel that carried the only session with a peer: find another route at once. One the app never
            // authenticated (refused, held, forgotten, lost the duplicate rule) backs off instead, so a refusal
            // cannot turn into a redial loop through the relay.
            if let Some(peer) = &tunnel.peer {
                let authenticated = tunnel.authenticated.load(Ordering::Relaxed);
                let reconnect = {
                    let mut peers = node.peers.lock().unwrap();
                    match peers.get_mut(peer) {
                        Some(p) if !p.cfg.connected && authenticated => {
                            p.next_attempt = Instant::now();
                            true
                        }
                        Some(p) if !authenticated => {
                            p.failures = p.failures.saturating_add(1);
                            let cap = (2_000u64 << p.failures.min(6)).min(120_000);
                            let wait = u64::from_be_bytes(random_bytes::<8>()) % cap;
                            p.next_attempt = Instant::now() + Duration::from_millis(wait.max(2_000));
                            false
                        }
                        _ => false,
                    }
                };
                if reconnect && !node.has_tunnel(peer, Route::Relay) {
                    node.connect_waiting("tunnel_closed");
                }
            }
        });
    }

    async fn bridge_loop(self: Arc<Self>, listener: tokio::net::TcpListener) {
        loop {
            let Ok((socket, from)) = listener.accept().await else { continue };
            if !from.ip().is_loopback() {
                continue;
            }
            let node = self.clone();
            tokio::spawn(async move { node.bridge(socket).await });
        }
    }

    /// One app connection: a token line, then the bytes of QUIC stream 0 both ways.
    async fn bridge(self: Arc<Self>, mut socket: tokio::net::TcpStream) {
        let _ = socket.set_nodelay(true);
        let mut line = [0u8; 65];
        if tokio::time::timeout(Duration::from_secs(5), socket.read_exact(&mut line)).await.map(|r| r.is_err()).unwrap_or(true) || line[64] != b'\n' {
            return;
        }
        let presented = String::from_utf8_lossy(&line[..64]).to_string();
        let tunnel = self
            .tunnels
            .lock()
            .unwrap()
            .values()
            .find(|t| constant_time_eq(hex(&t.token).as_bytes(), presented.as_bytes()))
            .cloned();
        let Some(tunnel) = tunnel else { return };
        if tunnel.claimed.swap(true, Ordering::Relaxed) {
            return;
        }
        let stream = if tunnel.quic_client {
            tunnel.conn.open_bi().await.ok()
        } else {
            tokio::time::timeout(Duration::from_secs(20), tunnel.conn.accept_bi()).await.ok().and_then(|r| r.ok())
        };
        let Some((mut send, mut recv)) = stream else {
            tunnel.conn.close(0u32.into(), b"no_stream");
            return;
        };
        self.mark("bridge.stream", tunnel.peer.as_deref(), None);
        let (mut app_read, mut app_write) = socket.into_split();
        let upstream = async {
            let _ = tokio::io::copy(&mut app_read, &mut send).await;
            let _ = send.finish();
        };
        let downstream = async {
            let _ = tokio::io::copy(&mut recv, &mut app_write).await;
            let _ = app_write.shutdown().await;
        };
        tokio::select! {
            _ = upstream => {}
            _ = downstream => {}
        }
        tunnel.conn.close(0u32.into(), b"session_ended");
    }

    // endregion

    // region Periodic work and commands

    async fn tick_loop(self: Arc<Self>) {
        let mut tick = tokio::time::interval(Duration::from_secs(5));
        let mut last_dates = derive::rdv_dates(now_ms());
        let mut since_upgrade = Duration::ZERO;
        let mut since_identity = Duration::ZERO;
        loop {
            tick.tick().await;
            if self.stopped.load(Ordering::Relaxed) {
                break;
            }
            let dates = derive::rdv_dates(now_ms());
            if dates != last_dates {
                last_dates = dates;
                self.register();
            }
            self.connect_waiting("retry");
            since_upgrade += Duration::from_secs(5);
            if since_upgrade >= Duration::from_secs(60) {
                since_upgrade = Duration::ZERO;
                self.upgrade_all("minute");
            }
            since_identity += Duration::from_secs(5);
            if since_identity >= Duration::from_secs(86_400) {
                since_identity = Duration::ZERO;
                let identity = Arc::new(Identity::generate());
                self.endpoint.set_server_config(Some(quic::server_config(&identity)));
                *self.identity.write().unwrap() = identity;
            }
        }
    }

    /// Tries routes better than each tunnel's current one (spec 4.6: network change, foreground, every minute).
    fn upgrade_all(self: &Arc<Self>, reason: &str) {
        if self.mux.relay_only.load(Ordering::Relaxed) {
            return;
        }
        let candidates: Vec<(String, Route)> = {
            let tunnels = self.tunnels.lock().unwrap();
            let mut best: HashMap<String, Route> = HashMap::new();
            for t in tunnels.values() {
                if let Some(peer) = &t.peer {
                    let route = t.route.lock().unwrap().0;
                    best.entry(peer.clone()).and_modify(|r| *r = (*r).min(route)).or_insert(route);
                }
            }
            best.into_iter().filter(|(_, r)| *r > Route::Lan).collect()
        };
        for (peer, route) in candidates {
            // Only the lower device ID upgrades: its dial wins the duplicate rule on both ends, so the other
            // side's better route would be refused every minute (it still answers the lower side's dials).
            let lower = self.peers.lock().unwrap().get(&peer).map(|p| p.cfg.side == 0).unwrap_or(false);
            if lower {
                self.clone().race(peer, reason.to_string(), Some(route));
            }
        }
    }

    /// The network changed. `metered` (when the app knows it) sets whether a relay allocation is kept warm: on
    /// mobile data every keep-alive wakes the radio, so there the node keeps credentials only.
    pub fn network_changed(self: &Arc<Self>, reason: &str, metered: Option<bool>) {
        {
            let mut peers = self.peers.lock().unwrap();
            for p in peers.values_mut() {
                p.failures = 0;
                p.next_attempt = Instant::now();
            }
        }
        {
            let mut warm = self.warm.lock().unwrap();
            if let Some(metered) = metered {
                warm.keepalive = if metered { Duration::ZERO } else { Duration::from_secs(u64::from(self.cfg.relay_keepalive_s)) };
            }
            // This socket's mapping (and so the relay's view of it) belongs to the old network.
            warm.srflx = None;
            warm.exclude.clear();
        }
        self.drop_warm_allocation(false);
        self.restart_rdv();
        let relays: Vec<RelayInfo> = self.warm.lock().unwrap().relays.iter().map(|(id, a)| RelayInfo { id: id.clone(), stun: a.to_string() }).collect();
        let node = self.clone();
        tokio::spawn(async move {
            if !relays.is_empty() {
                node.clone().probe_relays(relays).await;
            }
            node.ensure_warm().await;
        });
        self.upgrade_all(reason);
        self.connect_waiting(reason);
    }

    /// The app came to the foreground: try better routes and waiting peers. A control service connection that has
    /// been quiet for a while is replaced at once when a peer is waiting for it: after a phone slept, its socket may
    /// be one the network dropped long ago, and signalling into it would wait out TCP retransmits.
    pub fn foreground(self: &Arc<Self>) {
        let waiting = {
            let mut peers = self.peers.lock().unwrap();
            for p in peers.values_mut() {
                p.next_attempt = p.next_attempt.min(Instant::now());
            }
            peers.values().any(|p| !p.cfg.connected)
        };
        let quiet = self.rdv.lock().unwrap().as_ref().and_then(RdvClient::quiet_for).is_some_and(|q| q > RDV_QUIET_LIMIT);
        if waiting && quiet {
            self.mark("rdv.refresh", None, Some("foreground"));
            self.restart_rdv();
        }
        let node = self.clone();
        tokio::spawn(async move { node.ensure_warm().await });
        self.upgrade_all("foreground");
        self.connect_waiting("foreground");
    }

    /// Debug and live tests: every route but the relay is blocked (or unblocked). Only the UDP paths change, so
    /// the control service connection stays up, as it would when a LAN goes away without a network change.
    pub fn set_relay_only(self: &Arc<Self>, on: bool) {
        self.mux.relay_only.store(on, Ordering::Relaxed);
        {
            let mut peers = self.peers.lock().unwrap();
            for p in peers.values_mut() {
                p.failures = 0;
                p.next_attempt = p.next_attempt.min(Instant::now());
            }
        }
        self.upgrade_all("relay_only");
        self.connect_waiting("relay_only");
    }

    pub fn connect(self: &Arc<Self>, peer: &str) {
        if let Some(p) = self.peers.lock().unwrap().get_mut(peer) {
            p.next_attempt = Instant::now();
        }
        self.clone().race(peer.to_string(), "requested".into(), None);
    }

    /// The app authenticated a session on this tunnel: the peer's failures reset.
    pub fn tunnel_authenticated(&self, id: &str) {
        let peer = {
            let tunnels = self.tunnels.lock().unwrap();
            let Some(t) = tunnels.get(id) else { return };
            t.authenticated.store(true, Ordering::Relaxed);
            t.peer.clone()
        };
        self.mark("tunnel.authenticated", peer.as_deref(), None);
        if let Some(peer) = peer {
            if let Some(p) = self.peers.lock().unwrap().get_mut(&peer) {
                p.failures = 0;
            }
        }
    }

    pub fn close_tunnel(&self, id: &str) {
        if let Some(t) = self.tunnels.lock().unwrap().get(id) {
            t.conn.close(0u32.into(), b"closed_by_app");
        }
    }

    pub fn status(&self) -> Value {
        let tunnels: Vec<Value> = self
            .tunnels
            .lock()
            .unwrap()
            .values()
            .map(|t| {
                let (route, relay) = t.route.lock().unwrap().clone();
                json!({"tunnel": t.id, "peer": t.peer, "route": route.as_str(), "relay": relay, "rttMs": t.conn.rtt().as_millis() as u64, "quicClient": t.quic_client, "claimed": t.claimed.load(Ordering::Relaxed)})
            })
            .collect();
        let c = &self.mux.counters;
        json!({
            "ok": true,
            "udpPort": self.mux.port(),
            "control": self.rdv_connected.load(Ordering::Relaxed),
            "relayOnly": self.mux.relay_only.load(Ordering::Relaxed),
            "tunnels": tunnels,
            "iceSessions": self.ice.lock().unwrap().len(),
            "bytes": {"directIn": c.direct_in.load(Ordering::Relaxed), "directOut": c.direct_out.load(Ordering::Relaxed), "relayIn": c.relay_in.load(Ordering::Relaxed), "relayOut": c.relay_out.load(Ordering::Relaxed)},
        })
    }

    pub fn addresses(&self) -> Value {
        let addrs: Vec<Value> = addrs::local_addresses().into_iter().map(|a| json!({"a": a.a, "kind": a.kind, "vpn": a.vpn})).collect();
        json!({"ok": true, "port": self.mux.port(), "addrs": addrs})
    }

    /// Stops the node and releases its relay allocations (each holds relay capacity until it lapses).
    pub async fn shutdown(&self) {
        let allocations: Vec<Arc<Allocation>> = self.allocations.lock().unwrap().values().cloned().collect();
        self.stop();
        for allocation in allocations {
            let _ = tokio::time::timeout(Duration::from_millis(800), allocation.release()).await;
        }
    }

    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
        if let Some(rdv) = self.rdv.lock().unwrap().take() {
            rdv.stop();
        }
        let sids: Vec<String> = self.ice.lock().unwrap().keys().cloned().collect();
        for sid in sids {
            self.end_ice(&sid, "stopped");
        }
        self.endpoint.close(0u32.into(), b"stopped");
    }

    // endregion
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn close_reason(error: &quinn::ConnectionError) -> String {
    match error {
        quinn::ConnectionError::TimedOut => "timed_out".into(),
        quinn::ConnectionError::ApplicationClosed(close) => String::from_utf8_lossy(&close.reason).chars().take(32).collect(),
        quinn::ConnectionError::LocallyClosed => "closed".into(),
        quinn::ConnectionError::Reset => "reset".into(),
        _ => "closed_by_peer".into(),
    }
}
