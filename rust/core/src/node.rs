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
use crate::turn::{self, Allocation};
use bridgey_connect_proto::rdv::{Msg, RelayGrant};
use bridgey_connect_proto::signal::{Candidate, Description, Signal};
use bridgey_connect_proto::{b64, derive, seal};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
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
}

fn default_port() -> u16 {
    42_458
}

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
    started: Instant,
    tunnel: Mutex<Option<String>>,
    relay_retried: AtomicBool,
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
        });
        tokio::spawn(node.clone().accept_loop());
        tokio::spawn(node.clone().bridge_loop(bridge));
        tokio::spawn(node.clone().tick_loop());
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

    pub fn udp_port(&self) -> u16 {
        self.mux.port()
    }

    pub fn bridge_port(&self) -> u16 {
        self.bridge_port
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
        let client = rdv_client::start(url, self.node_key.clone(), self.cfg.app.clone(), signer, tx);
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

    fn restart_rdv(self: &Arc<Self>) {
        if let Some(old) = self.rdv.lock().unwrap().take() {
            old.stop();
        }
        self.rdv_connected.store(false, Ordering::Relaxed);
        self.online.lock().unwrap().clear();
        self.start_rdv();
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
            RdvEvent::Connected => {
                self.rdv_connected.store(true, Ordering::Relaxed);
                self.rdv_failures.store(0, Ordering::Relaxed);
                *self.rdv_since.lock().unwrap() = Some(Instant::now());
                self.register();
                self.publish_presence("online");
            }
            RdvEvent::Disconnected(reason) => {
                self.rdv_connected.store(false, Ordering::Relaxed);
                self.online.lock().unwrap().clear();
                self.log(&format!("control service disconnected: {reason}"));
                // A connection that worked and dropped is retried quietly; one that cannot be made at all is
                // reported, so the app can say the Round Robin service is out of reach (LAN and VPN still work).
                // A single failure is not reported either: a process Android has just started can be refused
                // the network for its first moments, and the client retries within a second.
                let lost = matches!(reason.as_str(), "closed" | "keepalive_timeout" | "send_failed");
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
                *self.online.lock().unwrap() = online.into_iter().collect();
                self.publish_presence("online");
                self.peers_seen_online(&peers);
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
                if online {
                    let peer = self.rdv_ids.lock().unwrap().get(&rdv).cloned();
                    if let Some(peer) = peer {
                        self.peers_seen_online(&[peer]);
                    }
                    self.connect_waiting("presence");
                }
            }
            Msg::Signal { rdv, side, sid, body } => self.on_signal(rdv, side, sid, body),
            Msg::Undeliverable { sid, .. } => self.end_ice(&sid, "undeliverable"),
            Msg::RelayGrantMsg { sid, relay } => self.on_grant(sid, relay),
            Msg::RelayDenied { sid, code, .. } => self.log(&format!("relay denied for {}: {code}", &sid[..4.min(sid.len())])),
            Msg::Error { code, .. } => self.log(&format!("control service error: {code}")),
            _ => {}
        }
    }

    // endregion

    // region Peers and the race

    pub fn set_peers(self: &Arc<Self>, list: Vec<PeerConfig>) -> Result<(), String> {
        {
            let mut peers = self.peers.lock().unwrap();
            let mut next = HashMap::new();
            for cfg in list {
                let secret: [u8; 32] = b64::std_decode(&cfg.pair_secret).and_then(|s| s.try_into().ok()).ok_or("pairSecret must be 32 bytes")?;
                if cfg.side > 1 {
                    return Err("side must be 0 or 1".into());
                }
                let previous = peers.remove(&cfg.id);
                let (next_attempt, failures) = match &previous {
                    // A peer that just dropped is raced after 1.5 s, so a LAN TCP reconnect can win first.
                    Some(p) if p.cfg.connected && !cfg.connected => (Instant::now() + Duration::from_millis(1_500), 0),
                    Some(p) => (p.next_attempt, p.failures),
                    None => (Instant::now() + Duration::from_millis(1_500), 0),
                };
                next.insert(cfg.id.clone(), Peer { sig_key: derive::sig_key(&secret), secret, cfg, next_attempt, failures });
            }
            *peers = next;
        }
        self.register();
        let node = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(1_600)).await;
            node.connect_waiting("disconnected");
        });
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
                    for _ in 0..80 {
                        if node.has_tunnel(&peer, Route::Relay) {
                            return;
                        }
                        if node.rdv_connected.load(Ordering::Relaxed) {
                            if node.peer_online(&peer) {
                                node.offer_ice(peer).await;
                                return;
                            }
                            let settled = node.rdv_since.lock().unwrap().map(|t| t.elapsed() > Duration::from_secs(2)).unwrap_or(true);
                            if settled {
                                return;
                            }
                        }
                        tokio::time::sleep(Duration::from_millis(100)).await;
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
                    }
                    None if better_than.is_none() => {
                        p.failures = p.failures.saturating_add(1);
                        // Full jitter, 1 s base, 60 s cap (the existing reconnect backoff).
                        let cap = (1_000u64 << p.failures.min(6)).min(60_000);
                        let wait = u64::from_be_bytes(random_bytes::<8>()) % cap;
                        p.next_attempt = Instant::now() + Duration::from_millis(wait.max(500));
                        drop(peers);
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
        if !self.mux.relay_only.load(Ordering::Relaxed) {
            for local in IceAgent::host_candidates(self.mux.port()) {
                agent.add_local(local);
            }
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
            started: Instant::now(),
            tunnel: Mutex::new(None),
            relay_retried: AtomicBool::new(false),
        });
        self.ice.lock().unwrap().insert(sid, session.clone());
        tokio::spawn(self.clone().ice_events(session.clone(), events));
        Some(session)
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
        self.rdv_send(Msg::RelayRequest { rdv, sid: sid.clone(), side: session.side, rtts: None, need: Some("udp".into()), est_bytes: None, exclude: None });
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
                let Some(session) = self.new_session(&peer, sid.clone(), rdv.clone()) else { return };
                *session.last_remote_seq.lock().unwrap() = desc.seq;
                self.apply_description(&session, &desc);
                self.send_signal(&session, Signal::Answer(self.description(&session)));
                self.rdv_send(Msg::RelayClaim { rdv, sid, side: session.side });
            }
            Signal::Answer(desc) => {
                if let Some(session) = existing {
                    self.apply_description(&session, &desc);
                }
            }
            Signal::Cand { cands, .. } => {
                if let Some(session) = existing {
                    for cand in &cands {
                        session.agent.add_remote(cand);
                    }
                    self.bind_relay_channels(&session);
                }
            }
            Signal::Bye { .. } => self.end_ice(&sid, "bye"),
            Signal::Restart { .. } => {}
        }
    }

    fn apply_description(&self, session: &Arc<IceSession>, desc: &Description) {
        *session.remote_cert.lock().unwrap() = Some(desc.cert.clone());
        session.agent.set_remote_credentials(&desc.ufrag, &desc.pwd);
        for cand in &desc.cands {
            session.agent.add_remote(cand);
        }
        self.bind_relay_channels(session);
    }

    fn on_grant(self: &Arc<Self>, sid: String, grant: RelayGrant) {
        let Some(session) = self.ice.lock().unwrap().get(&sid).cloned() else { return };
        let node = self.clone();
        tokio::spawn(async move {
            let Some((host, port)) = grant.urls.iter().find_map(|u| turn::parse_udp_url(u)) else { return };
            let Some(server) = tokio::net::lookup_host((host.as_str(), port)).await.ok().and_then(|mut it| it.next()) else { return };
            let server = addrs::canonical(server);
            // Server-reflexive candidate from the relay's STUN (hole punching, spec 6.5).
            if !node.mux.relay_only.load(Ordering::Relaxed) {
                if let Some((mapped, _)) = turn::reflexive(&node.mux, server).await {
                    let local = Local { via: Via::Direct, addr: mapped, kind: "srflx", pri: crate::ice::priority(crate::ice::TYPE_SRFLX, mapped.ip()), relay: None, net: None };
                    session.agent.add_local(local.clone());
                    node.trickle(&session, vec![local.candidate()]);
                }
            }
            // The relay waits 1 s for a direct pair, unless only the relay can work.
            let grace = Duration::from_millis(1_000).saturating_sub(session.started.elapsed());
            if !node.mux.relay_only.load(Ordering::Relaxed) {
                tokio::time::sleep(grace).await;
                if session.agent.is_selected() {
                    return;
                }
            }
            let allocation = match node.allocation(server, &grant).await {
                Ok(a) => a,
                Err(e) => {
                    node.log(&format!("relay {} allocation failed: {e}", grant.id));
                    // Ask for another relay once; ICE pairs relay addresses on different servers too.
                    if !session.relay_retried.swap(true, Ordering::Relaxed) {
                        node.rdv_send(Msg::RelayRequest {
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
            *session.allocation.lock().unwrap() = Some(allocation.clone());
            let local = Local {
                via: Via::Turn(server),
                addr: allocation.relayed,
                kind: "relay",
                pri: crate::ice::priority(crate::ice::TYPE_RELAY, allocation.relayed.ip()),
                relay: Some(grant.id.clone()),
                net: None,
            };
            session.agent.add_local(local.clone());
            node.trickle(&session, vec![local.candidate()]);
            node.bind_relay_channels(&session);
        });
    }

    async fn allocation(&self, server: SocketAddr, grant: &RelayGrant) -> Result<Arc<Allocation>, String> {
        let _one = self.allocating.lock().await;
        let pending = self.releasing.lock().unwrap().remove(&server);
        if let Some(release) = pending {
            let _ = tokio::time::timeout(Duration::from_secs(3), release).await;
        }
        if let Some(existing) = self.allocations.lock().unwrap().get(&server).cloned() {
            return Ok(existing);
        }
        let allocation = Allocation::allocate(self.mux.clone(), server, &grant.id, &grant.username, &grant.credential).await?;
        self.allocations.lock().unwrap().insert(server, allocation.clone());
        Ok(allocation)
    }

    fn trickle(&self, session: &IceSession, cands: Vec<Candidate>) {
        let seq = session.seq.fetch_add(1, Ordering::Relaxed) + 1;
        self.send_signal(session, Signal::Cand { sid: session.agent.sid.clone(), cands, done: false, ts: now_ms(), seq });
    }

    /// Our relay candidate reaches the peer's candidates through bound channels (permissions).
    fn bind_relay_channels(&self, session: &Arc<IceSession>) {
        let Some(allocation) = session.allocation.lock().unwrap().clone() else { return };
        let remotes: Vec<SocketAddr> = session.agent.remote_addresses().into_iter().filter(|a| a.is_ipv4() == allocation.relayed.is_ipv4()).collect();
        for remote in remotes {
            if self.mux.has_channel(allocation.server, remote) {
                continue;
            }
            let allocation = allocation.clone();
            tokio::spawn(async move {
                let _ = allocation.bind(remote).await;
            });
        }
    }

    async fn ice_events(self: Arc<Self>, session: Arc<IceSession>, mut events: mpsc::UnboundedReceiver<IceEvent>) {
        let mut maintained = false;
        while let Some(event) = events.recv().await {
            match event {
                IceEvent::Selected { route, relay, rtt } => {
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
            if !still_used {
                self.allocations.lock().unwrap().remove(&allocation.server);
                let server = allocation.server;
                let release = tokio::spawn(async move { allocation.release().await });
                self.releasing.lock().unwrap().insert(server, release);
            }
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

    pub fn network_changed(self: &Arc<Self>, reason: &str) {
        {
            let mut peers = self.peers.lock().unwrap();
            for p in peers.values_mut() {
                p.failures = 0;
                p.next_attempt = Instant::now();
            }
        }
        self.restart_rdv();
        self.upgrade_all(reason);
        self.connect_waiting(reason);
    }

    /// The app came to the foreground: try better routes and waiting peers, keep the presence socket.
    pub fn foreground(self: &Arc<Self>) {
        {
            let mut peers = self.peers.lock().unwrap();
            for p in peers.values_mut() {
                p.next_attempt = p.next_attempt.min(Instant::now());
            }
        }
        self.upgrade_all("foreground");
        self.connect_waiting("foreground");
    }

    pub fn set_relay_only(self: &Arc<Self>, on: bool) {
        self.mux.relay_only.store(on, Ordering::Relaxed);
        self.network_changed("relay_only");
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
