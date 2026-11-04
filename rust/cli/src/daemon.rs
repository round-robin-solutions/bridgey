//! The background agent (`bridgey daemon`): one process per profile that owns the Connect anywhere node,
//! the sessions with paired devices, pending asks, code queries and transfers. Every other command talks to
//! it over `run/daemon.sock` (0600 in a 0700 folder, the caller's user checked), so commands running at the
//! same time share one session (Bridgey closes duplicate sessions from one device).
//!
//! It runs as the user service (`bridgey service install`, never exits), or is started by the first command
//! that needs it and exits after `daemon.idle_exit` (10 minutes) without use, like ssh's ControlMaster.

use crate::config::Config;
use crate::crypto::{self, SigningKey};
use crate::errors::CliError;
use crate::invite::Invite;
use crate::ipc::{self, Conn};
use crate::paths::{write_private, Paths};
use crate::session::{self, AuthPeer, Event, Handle, Local, Mode};
use crate::store::{Keys, Peer, Trust};
use crate::time::now_ms;
use crate::wire::Message;
use bridgey_connect::node::{Learned, Node, PeerConfig, StartConfig};
use bridgey_connect_proto::derive;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot, Notify};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Draft keys this command reads (the apps keep the same list in the same order, new keys last).
pub const OWN_FEATURES: &[(&str, bool)] = &[
    ("clipboard", true),
    ("files", true),
    ("notifications", false),
    ("battery", true),
    ("find_device", true),
    ("ping", true),
    ("links", false),
    ("media", false),
    ("calls", false),
    ("connect_draft1", true),
    ("agent_draft1", true),
    ("notify_draft1", true),
    ("ask_draft1", true),
    ("clipboard_request_draft1", true),
    ("agent_codes_draft1", true),
    // Detect codes: true only while this build has the model runner and a model is installed (detect.rs).
    ("codes_detect_draft1", false),
];

/// Grant name (as `bridgey grants` shows it) to the phone's feature key and the words the phone uses.
pub const GRANTS: &[(&str, &str, &str, &str)] = &[
    ("files", "files", "Send you files", "To Download/Bridgey/<this device>"),
    ("clipboard", "clipboard", "Set your clipboard", "Text it copies lands on this phone"),
    ("clipboard_request", "clipboard_request_draft1", "Ask for your clipboard", "You tap Send each time"),
    ("notify", "notify_draft1", "Send you notifications", "In Agent messages"),
    ("ask", "ask_draft1", "Ask you questions", "In Agent questions, with answer buttons"),
    ("ring", "find_device", "Ring this phone", "Stops by itself after 60 seconds"),
    ("battery", "battery", "See battery", "Level and charging"),
    ("codes", "agent_codes_draft1", "Read codes", "One-time codes your Mac finds in messages and mail"),
    ("codes_detect", "codes_detect_draft1", "Detect codes", "Reads your code messages when no Mac is reading"),
    ("notifications", "notifications", "Read your notifications", "Not available yet"),
];

pub fn grant_wire(name: &str) -> Option<&'static str> {
    GRANTS.iter().find(|g| g.0 == name).map(|g| g.1)
}

pub fn grant_title(name: &str) -> &'static str {
    GRANTS.iter().find(|g| g.0 == name).map(|g| g.2).unwrap_or("that")
}

pub fn relay_name(id: &str) -> String {
    match id {
        "bom" => "Mumbai".into(),
        "sin" => "Singapore".into(),
        "sxb" => "Europe".into(),
        "cf" => "Cloudflare".into(),
        other => other.to_string(),
    }
}

#[derive(Clone)]
pub struct Reply {
    pub kind: String,
    pub message: Message,
    pub payload: Option<Value>,
}

struct Live {
    handle: Handle,
    tunnel: String,
    since: u64,
}

struct PendingInvite {
    invite: Invite,
    /// This end joins someone else's invite (test hook `bridgey pair --join`).
    joining: bool,
    to_client: mpsc::UnboundedSender<InviteEvent>,
    session: Option<u64>,
}

pub enum InviteEvent {
    Code { code: String, peer_name: String, confirm: oneshot::Sender<bool> },
    Paired { peer: AuthPeer },
    Failed(String),
}

#[derive(Clone, Debug)]
pub struct Ask {
    pub device: String,
    pub expires_at: u64,
    pub state: String,
    pub answer: Option<Value>,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TransferInfo {
    pub transfer_id: String,
    pub device: String,
    pub name: String,
    pub bytes: u64,
    pub total: u64,
    pub state: String,
    pub started_at: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ended_at: Option<u64>,
}

#[derive(Default)]
struct St {
    trust: Trust,
    sessions: HashMap<String, Live>,
    invites: HashMap<String, PendingInvite>,
    invite_sessions: HashMap<u64, String>,
    features: HashMap<String, Map<String, Value>>,
    battery: HashMap<String, (u8, bool, u64)>,
    waiters: HashMap<String, mpsc::UnboundedSender<Reply>>,
    asks: HashMap<String, Ask>,
    transfers: Vec<TransferInfo>,
    presence: String,
    online: Vec<String>,
    core_state: Option<Value>,
    rings: HashMap<String, String>,
    contributions: HashMap<String, [u8; 32]>,
    last_failure: HashMap<String, String>,
    /// What the last features.update said about Detect codes.
    detect_advertised: bool,
    /// Peers that sent agent.hello in their session: agents, never phones, so never a source of code candidates.
    agent_peers: std::collections::HashSet<String>,
    /// Pairings over the tailnet in progress: the session's local ID to the `bridgey pair` waiting for it.
    direct: HashMap<u64, mpsc::UnboundedSender<InviteEvent>>,
}

/// Code candidates read at once; more are answered `failed` with `busy`.
const DETECT_IN_FLIGHT: usize = 4;

pub struct Daemon {
    pub paths: Paths,
    pub config: Config,
    pub local: Arc<Local>,
    node_key: Arc<SigningKey>,
    pub node: Arc<Node>,
    st: Mutex<St>,
    pub changed: Notify,
    events: mpsc::UnboundedSender<Event>,
    next_local: AtomicU64,
    pub started: u64,
    pub service: bool,
    idle_exit: Option<Duration>,
    last_used: Mutex<Instant>,
    pub clients: AtomicUsize,
    pub stop: Notify,
    detector: std::sync::OnceLock<Arc<crate::detect::Detector>>,
    detect_slots: crate::detect::DetectSlots,
}

pub struct WaitGuard<'a> {
    daemon: &'a Daemon,
    keys: Vec<String>,
}

impl Drop for WaitGuard<'_> {
    fn drop(&mut self) {
        let mut st = self.daemon.st.lock().unwrap();
        for k in &self.keys {
            st.waiters.remove(k);
        }
    }
}

/// The first 8 characters of an ID, for log lines.
pub fn short(id: &str) -> String {
    crate::session::printable(id, 8)
}

fn log(msg: &str) {
    eprintln!("{} {msg}", crate::time::rfc3339(now_ms()));
}

impl Daemon {
    pub async fn run(paths: Paths, service: bool) -> Result<(), String> {
        paths.ensure().map_err(|e| e.to_string())?;
        let lock = acquire_lock(&paths)?;
        let config = Config::load(&paths)?;
        let keys = Keys::load(&paths)?;
        let trust = Trust::load(&paths)?;
        let name = config.str("device_name").unwrap_or_else(crate::config::default_device_name);
        let local = Arc::new(Local { device_id: trust.device_id.clone(), device_name: std::sync::RwLock::new(name), identity_public: keys.identity_public(), identity: Arc::new(keys.identity) });
        let node_key = Arc::new(keys.node);
        let (core_tx, mut core_rx) = mpsc::unbounded_channel::<String>();
        let sink: bridgey_connect::node::EventSink = Arc::new(move |e: String| {
            let _ = core_tx.send(e);
        });
        let control = config.control_url();
        let start = StartConfig {
            port: config.udp_port(),
            control_url: Some(control).filter(|c| !c.is_empty()),
            app: format!("bridgey-rr-cli/{VERSION} {}", std::env::consts::OS),
            node_key: crypto::b64url(&node_key.public_raw()),
            relay_only: std::env::var("BRIDGEY_RELAY_ONLY").is_ok_and(|v| v == "1"),
            state: std::fs::read(paths.state.join("core.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()),
            relay_keepalive_s: 25,
        };
        let node = Node::start(start, sink).await?;
        let (ev_tx, mut ev_rx) = mpsc::unbounded_channel::<Event>();
        let idle_exit = if service { None } else { Some(config.duration("daemon.idle_exit", Duration::from_secs(600))) };
        // Open questions from an earlier run, so an answer the phone delivers at the next session is kept.
        let asks: HashMap<String, Ask> = std::fs::read(paths.state.join("asks.json"))
            .ok()
            .and_then(|b| serde_json::from_slice::<Vec<Value>>(&b).ok())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|a| {
                let id = a["askId"].as_str()?.to_string();
                let expires_at = a["expiresAt"].as_u64()?;
                (expires_at + 86_400_000 > now_ms()).then(|| (id, Ask { device: a["device"].as_str().unwrap_or("").to_string(), expires_at, state: match a["state"].as_str() {
                    // The answer itself was never written down: ask the phone again (it keeps answers 24 hours).
                    Some("answered") | None => "sent".to_string(),
                    Some(s) => s.to_string(),
                }, answer: None }))
            })
            .collect();
        let daemon = Arc::new(Daemon {
            paths: paths.clone(),
            config,
            local,
            node_key,
            node,
            st: Mutex::new(St { trust, asks, presence: "connecting".into(), ..Default::default() }),
            changed: Notify::new(),
            events: ev_tx,
            next_local: AtomicU64::new(1),
            started: now_ms(),
            service,
            idle_exit,
            last_used: Mutex::new(Instant::now()),
            clients: AtomicUsize::new(0),
            stop: Notify::new(),
            detector: std::sync::OnceLock::new(),
            detect_slots: crate::detect::DetectSlots::new(DETECT_IN_FLIGHT),
        });
        log(&format!("bridgey {VERSION} daemon started (profile {}, device {}, udp {}, {})", paths.profile, short(&daemon.local.device_id), daemon.node.udp_port(), if service { "service" } else { "on demand" }));
        daemon.sync_peers();
        {
            let d = daemon.clone();
            tokio::spawn(async move {
                while let Some(e) = core_rx.recv().await {
                    d.on_core(&e);
                }
            });
        }
        {
            let d = daemon.clone();
            tokio::spawn(async move {
                while let Some(e) = ev_rx.recv().await {
                    d.on_session(e);
                }
            });
        }
        {
            let d = daemon.clone();
            tokio::spawn(async move { d.housekeeping().await });
        }
        let socket = paths.socket();
        let _ = std::fs::remove_file(&socket);
        let listener = ipc::listen(&socket).map_err(|e| format!("{}: {e}", socket.display()))?;
        let shutdown = async {
            #[cfg(unix)]
            {
                let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("signal");
                let mut int = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt()).expect("signal");
                tokio::select! { _ = term.recv() => {}, _ = int.recv() => {} }
            }
        };
        tokio::pin!(shutdown);
        loop {
            tokio::select! {
                _ = &mut shutdown => break,
                _ = daemon.stop.notified() => { log("asked to stop"); break }
                _ = daemon.idle_wait() => { log("idle, exiting"); break }
                accepted = listener.accept() => {
                    let Ok((stream, _)) = accepted else { continue };
                    if !ipc::same_user(&stream) {
                        continue;
                    }
                    let peer = ipc::peer(&stream);
                    let d = daemon.clone();
                    tokio::spawn(async move { d.serve(Conn::new(stream), peer).await });
                }
            }
        }
        let _ = std::fs::remove_file(&socket);
        if let Some(detector) = daemon.detector.get() {
            detector.shutdown();
        }
        daemon.save_core_state();
        daemon.node.shutdown().await;
        drop(lock);
        log("stopped");
        Ok(())
    }

    async fn idle_wait(&self) {
        let Some(idle) = self.idle_exit else { return std::future::pending().await };
        loop {
            tokio::time::sleep(Duration::from_secs(15)).await;
            let busy = self.clients.load(Ordering::Relaxed) > 0 || {
                let st = self.st.lock().unwrap();
                !st.waiters.is_empty() || !st.invites.is_empty() || st.transfers.iter().any(|t| t.state == "sending")
            };
            if busy {
                *self.last_used.lock().unwrap() = Instant::now();
            } else if self.last_used.lock().unwrap().elapsed() >= idle {
                return;
            }
        }
    }

    fn save_core_state(&self) {
        if let Some(state) = self.st.lock().unwrap().core_state.clone() {
            let _ = write_private(&self.paths.state.join("core.json"), state.to_string().as_bytes());
        }
    }

    async fn housekeeping(self: Arc<Self>) {
        let mut tick = tokio::time::interval(Duration::from_secs(30));
        loop {
            tick.tick().await;
            let now = now_ms();
            let mut st = self.st.lock().unwrap();
            st.invites.retain(|_, i| i.invite.expires_s.saturating_mul(1000) > now || i.session.is_some());
            st.asks.retain(|_, a| a.expires_at + 86_400_000 > now);
            if st.transfers.len() > 50 {
                let extra = st.transfers.len() - 50;
                st.transfers.drain(..extra);
            }
            let detect = crate::detect::available(&self.paths);
            if detect != st.detect_advertised {
                // A model was downloaded or removed: every connected phone hears it now.
                let handles: Vec<Handle> = st.sessions.values().map(|l| l.handle.clone()).collect();
                drop(st);
                let features = self.own_features();
                for h in handles {
                    h.send_json("features.update", &features);
                }
            }
        }
    }

    /// This install's features.update: the fixed map, with Detect codes as it stands now.
    fn own_features(&self) -> Value {
        let detect = crate::detect::available(&self.paths);
        self.st.lock().unwrap().detect_advertised = detect;
        let features: Map<String, Value> = OWN_FEATURES.iter().map(|(k, v)| (k.to_string(), Value::Bool(if *k == "codes_detect_draft1" { detect } else { *v }))).collect();
        json!({"version": 1, "features": features})
    }

    /// `codes.candidate` from a phone that granted Detect codes: read it with the shared reader off the async threads,
    /// answer `codes.detected`, and write one audit entry (phone, app, outcome; never the text or the code).
    fn on_candidate(self: &Arc<Self>, peer: &str, handle: Handle, payload: Option<Value>) {
        let (granted, from_phone) = {
            let st = self.st.lock().unwrap();
            let granted = st.features.get(peer).and_then(|f| f.get("codes_detect_draft1")) == Some(&Value::Bool(true));
            let platform = st.trust.peers.get(peer).map(|p| p.platform.clone()).unwrap_or_default();
            (granted, crate::detect::candidate_allowed(&platform, st.agent_peers.contains(peer)))
        };
        // Only a phone sends candidates; anything else is dropped without an answer.
        if !from_phone {
            return;
        }
        let Some(candidate) = payload.as_ref().and_then(crate::detect::decode_candidate) else { return };
        let record = |outcome: &str, d: &Daemon| {
            crate::audit::record(&d.paths, json!({"at": now_ms(), "command": "codes.detect", "device": peer, "outcome": outcome, "detail": format!("{} {}", candidate.source, candidate.app)}));
        };
        if !granted || !crate::detect::available(&self.paths) {
            // Not granted here (a stale map) or no model: say so, so the phone stops waiting. No slot is taken.
            let reason = if granted { bridgey_codes::Failure::ModelMissing } else { bridgey_codes::Failure::NotConfigured };
            handle.send_json("codes.detected", &crate::detect::detected_payload(&candidate.id, &bridgey_codes::Outcome::Fallback(reason)));
            record(reason.wire(), self);
            return;
        }
        // The slot is held by its guard until the read is answered, whatever path it takes.
        let Some(slot) = self.detect_slots.take() else {
            handle.send_json("codes.detected", &json!({"version": 1, "candidateId": candidate.id, "outcome": "failed", "reason": "busy"}));
            record("busy", self);
            return;
        };
        let detector = self.detector.get_or_init(|| Arc::new(crate::detect::Detector::new(&self.paths))).clone();
        let d = self.clone();
        let peer = peer.to_string();
        tokio::spawn(async move {
            let _slot = slot;
            let c = candidate.clone();
            let outcome = tokio::task::spawn_blocking(move || detector.read(&c)).await.unwrap_or(bridgey_codes::Outcome::Fallback(bridgey_codes::Failure::Unavailable));
            handle.send_json("codes.detected", &crate::detect::detected_payload(&candidate.id, &outcome));
            crate::audit::record(&d.paths, json!({"at": now_ms(), "command": "codes.detect", "device": peer, "outcome": outcome.word(), "detail": format!("{} {}", candidate.source, candidate.app)}));
            log(&format!("codes.detect from {}: {}", short(&peer), outcome.word()));
        });
    }

    // region Core and sessions

    pub fn sync_peers(&self) {
        let list: Vec<PeerConfig> = {
            let st = self.st.lock().unwrap();
            let mut list: Vec<PeerConfig> = st
                .trust
                .peers
                .values()
                .filter_map(|p| {
                    let secret = p.pair_secret.clone()?;
                    let addresses = p
                        .learned
                        .addrs
                        .iter()
                        .filter_map(|a| Some(Learned { a: a["a"].as_str()?.to_string(), p: p.learned.port, kind: a["kind"].as_str().unwrap_or("").to_string(), vpn: a["vpn"].as_str().map(str::to_string) }))
                        .collect();
                    Some(PeerConfig { id: p.device_id.clone(), side: derive::side(&self.local.device_id, &p.device_id), pair_secret: secret, addresses, connected: st.sessions.contains_key(&p.device_id), invite: false })
                })
                .collect();
            for (label, i) in &st.invites {
                list.push(PeerConfig { id: label.clone(), side: if i.joining { 0 } else { 1 }, pair_secret: crypto::b64(&i.invite.secret), addresses: vec![], connected: i.session.is_some(), invite: true });
            }
            list
        };
        if let Err(e) = self.node.set_peers(list) {
            log(&format!("core peers: {e}"));
        }
    }

    fn on_core(self: &Arc<Self>, text: &str) {
        let Ok(e) = serde_json::from_str::<Value>(text) else { return };
        match e["e"].as_str().unwrap_or("") {
            "sign" => {
                let data = e["data"].as_str().and_then(crypto::unb64).unwrap_or_default();
                let sig = self.node_key.sign(&data);
                self.node.sign_result(e["id"].as_u64().unwrap_or(0), Some(sig));
            }
            "tunnel" => self.on_tunnel(&e),
            "presence" => {
                let mut st = self.st.lock().unwrap();
                st.presence = e["state"].as_str().unwrap_or("").to_string();
                st.online = e["peers"].as_array().map(|a| a.iter().filter_map(|p| p.as_str().map(str::to_string)).collect()).unwrap_or_default();
                drop(st);
                self.changed.notify_waiters();
            }
            "state" => {
                self.st.lock().unwrap().core_state = Some(e["state"].clone());
                self.save_core_state();
            }
            "connect.failed" => {
                if let Some(p) = e["peer"].as_str().filter(|p| self.st.lock().unwrap().trust.peers.contains_key(*p)) {
                    self.st.lock().unwrap().last_failure.insert(p.to_string(), e["reason"].as_str().unwrap_or("unreachable").chars().take(32).collect());
                    self.changed.notify_waiters();
                }
            }
            "tunnel.closed" => {}
            "log" if std::env::var("BRIDGEY_DEBUG").is_ok() => log(&format!("core: {}", e["msg"].as_str().unwrap_or(""))),
            _ => {}
        }
    }

    fn on_tunnel(self: &Arc<Self>, e: &Value) {
        let tunnel = e["tunnel"].as_str().unwrap_or("").to_string();
        let peer = e["peer"].as_str().map(str::to_string);
        let quic_client = e["quicClient"].as_bool().unwrap_or(false);
        let local_id = self.next_local.fetch_add(1, Ordering::Relaxed);
        let mode = match &peer {
            Some(label) if label.starts_with("invite:") => {
                let mut st = self.st.lock().unwrap();
                match st.invites.get_mut(label) {
                    Some(i) if i.session.is_none() && quic_client == i.joining => {
                        i.session = Some(local_id);
                        let hash = i.invite.hash();
                        let joining = i.joining;
                        st.invite_sessions.insert(local_id, label.clone());
                        if joining { Mode::Join { invite_hash: hash } } else { Mode::Invite { invite_hash: hash } }
                    }
                    _ => {
                        drop(st);
                        self.node.close_tunnel(&tunnel);
                        return;
                    }
                }
            }
            Some(p) => Mode::Reconnect { expected: Some(p.clone()) },
            None => Mode::Reconnect { expected: None },
        };
        log(&format!("tunnel {tunnel} route={} relay={} quic_client={quic_client}", e["route"].as_str().unwrap_or(""), e["relay"].as_str().unwrap_or("-")));
        let spec = session::Spec {
            local_id,
            port: e["port"].as_u64().unwrap_or(0) as u16,
            token: e["token"].as_str().unwrap_or("").to_string(),
            exporter: e["exporter"].as_str().unwrap_or("").to_string(),
            tunnel,
            quic_client,
            mode,
            direct: None,
        };
        let d = self.clone();
        let pins: session::PinLookup = Arc::new(move |id: &str| d.st.lock().unwrap().trust.peers.values().find(|p| p.device_id.eq_ignore_ascii_case(id)).map(|p| p.identity_key.clone()));
        session::spawn(spec, self.local.clone(), pins, self.events.clone());
    }

    fn on_session(self: &Arc<Self>, e: Event) {
        match e {
            Event::Code { local_id, code, peer_name, confirm } => {
                let st = self.st.lock().unwrap();
                let tx = st.invite_sessions.get(&local_id).and_then(|l| st.invites.get(l)).map(|i| i.to_client.clone()).or_else(|| st.direct.get(&local_id).cloned());
                drop(st);
                match tx {
                    Some(tx) => {
                        let _ = tx.send(InviteEvent::Code { code, peer_name, confirm });
                    }
                    None => {
                        let _ = confirm.send(false);
                    }
                }
            }
            Event::Authenticated { local_id, peer, handle, invite, direct, tunnel } => {
                if !direct {
                    self.node.tunnel_authenticated(&tunnel);
                }
                let mut st = self.st.lock().unwrap();
                if direct && !st.direct.contains_key(&local_id) {
                    // A pairing whose `bridgey pair` gave up (its window ended, or it was cancelled): never saved.
                    drop(st);
                    handle.close("pairing_window_ended");
                    return;
                }
                if direct {
                    // A first pairing over the tailnet: a device of a kind this end does not know yet ("tailnet"); its own
                    // features.update says "cli" if it is another server. Never "phone", so it never sends candidates here.
                    let now = now_ms();
                    let previous = st.trust.peers.get(&peer.device_id).cloned();
                    st.trust.peers.insert(
                        peer.device_id.clone(),
                        Peer { device_id: peer.device_id.clone(), name: peer.name.clone(), platform: "tailnet".into(), identity_key: peer.identity_key.clone(), paired_at: now, last_seen_at: now, ..previous.unwrap_or_default() },
                    );
                    let _ = st.trust.save(&self.paths);
                    if let Some(tx) = st.direct.remove(&local_id) {
                        let _ = tx.send(InviteEvent::Paired { peer: peer.clone() });
                    }
                }
                if invite {
                    let label = st.invite_sessions.remove(&local_id);
                    // This end joined another install's invite (test hook): the peer is a server, not a phone.
                    let joined = label.as_ref().and_then(|l| st.invites.get(l)).is_some_and(|i| i.joining);
                    let now = now_ms();
                    let previous = st.trust.peers.get(&peer.device_id).cloned();
                    st.trust.peers.insert(
                        peer.device_id.clone(),
                        Peer { device_id: peer.device_id.clone(), name: peer.name.clone(), platform: if joined { "cli".into() } else { "phone".into() }, identity_key: peer.identity_key.clone(), paired_at: now, last_seen_at: now, ..previous.unwrap_or_default() },
                    );
                    let _ = st.trust.save(&self.paths);
                    if let Some(i) = label.and_then(|l| st.invites.remove(&l)) {
                        let _ = i.to_client.send(InviteEvent::Paired { peer: peer.clone() });
                    }
                }
                if let Some(old) = st.sessions.insert(peer.device_id.clone(), Live { handle: handle.clone(), tunnel, since: now_ms() }) {
                    if old.handle.local_id != handle.local_id {
                        old.handle.close("superseded");
                    }
                }
                if let Some(p) = st.trust.peers.get_mut(&peer.device_id) {
                    p.last_seen_at = now_ms();
                    if !peer.name.is_empty() {
                        p.name = peer.name.clone();
                    }
                }
                let _ = st.trust.save(&self.paths);
                st.last_failure.remove(&peer.device_id);
                drop(st);
                log(&format!("session with {} authenticated", short(&peer.device_id)));
                handle.send_json("features.update", &self.own_features());
                handle.send_json("agent.hello", &json!({"version": 1, "platform": "cli", "app": format!("bridgey {VERSION}"), "os": format!("{} {}", std::env::consts::OS, std::env::consts::ARCH)}));
                self.sync_peers();
                self.changed.notify_waiters();
            }
            Event::Frame { local_id, peer_id, message, plaintext } => self.on_frame(local_id, &peer_id, *message, plaintext),
            Event::Closed { local_id, peer_id, reason, authenticated } => {
                let mut st = self.st.lock().unwrap();
                if let Some(tx) = st.direct.remove(&local_id) {
                    let _ = tx.send(InviteEvent::Failed(reason.clone()));
                }
                if let Some(label) = st.invite_sessions.remove(&local_id) {
                    if let Some(i) = st.invites.get_mut(&label) {
                        let _ = i.to_client.send(InviteEvent::Failed(reason.clone()));
                        i.session = None;
                    }
                }
                if let Some(p) = &peer_id {
                    if st.sessions.get(p).is_some_and(|l| l.handle.local_id == local_id) {
                        st.sessions.remove(p);
                        st.features.remove(p);
                        st.agent_peers.remove(p);
                    }
                    if !authenticated && st.trust.peers.contains_key(p) {
                        st.last_failure.insert(p.clone(), crate::session::printable(&reason, 64));
                    }
                }
                drop(st);
                log(&format!("session {local_id} closed: {}", crate::session::printable(&reason, 64)));
                self.sync_peers();
                self.changed.notify_waiters();
            }
        }
    }

    fn current(&self, peer: &str, local_id: u64) -> Option<Handle> {
        self.st.lock().unwrap().sessions.get(peer).filter(|l| l.handle.local_id == local_id).map(|l| l.handle.clone())
    }

    fn on_frame(self: &Arc<Self>, local_id: u64, peer: &str, m: Message, plaintext: Option<Vec<u8>>) {
        let Some(handle) = self.current(peer, local_id) else { return };
        let payload: Option<Value> = plaintext.as_ref().and_then(|p| serde_json::from_slice(p).ok());
        match m.kind.as_str() {
            "features.update" => {
                let Some(map) = payload.as_ref().filter(|p| p["version"] == 1).and_then(|p| p["features"].as_object()).cloned() else { return };
                let connect = map.get("connect_draft1") == Some(&Value::Bool(true));
                {
                    let mut st = self.st.lock().unwrap();
                    // A device paired over the tailnet says what it is in its own (authenticated) map: another server
                    // advertises agent_draft1 and sends no grants. A phone or a Mac stays "tailnet" here.
                    let is_agent = map.get("agent_draft1") == Some(&Value::Bool(true)) && map.get("notify_draft1") == Some(&Value::Bool(true));
                    if let Some(p) = st.trust.peers.get_mut(peer).filter(|p| p.platform == "tailnet" && is_agent) {
                        p.platform = "cli".into();
                        let _ = st.trust.save(&self.paths);
                    }
                    st.features.insert(peer.to_string(), map);
                }
                self.changed.notify_waiters();
                if connect {
                    self.send_addresses(peer, &handle);
                }
                return;
            }
            "connect.addresses" => {
                let Some(p) = payload else { return };
                let theirs = p["pairCheck"].as_str().map(str::to_string);
                let mine = {
                    let mut st = self.st.lock().unwrap();
                    let Some(rec) = st.trust.peers.get_mut(peer) else { return };
                    let port = p["port"].as_u64().filter(|v| (1..=65535).contains(v)).unwrap_or(42458) as u16;
                    let addrs: Vec<Value> = p["addrs"]
                        .as_array()
                        .map(|a| {
                            a.iter()
                                .filter_map(|x| {
                                    let ip = x["a"].as_str()?.parse::<std::net::IpAddr>().ok()?;
                                    let kind = x["kind"].as_str().filter(|k| ["lan", "vpn", "public6"].contains(k))?;
                                    let mut o = json!({"a": ip.to_string(), "kind": kind});
                                    if let Some(v) = x["vpn"].as_str().filter(|v| ["tailscale", "other"].contains(v)) { o["vpn"] = json!(v); }
                                    Some(o)
                                })
                                .take(16)
                                .collect()
                        })
                        .unwrap_or_default();
                    let changed = rec.learned.port != port || rec.learned.addrs != addrs;
                    rec.learned.port = port;
                    rec.learned.addrs = addrs;
                    let mine = rec.pair_secret.as_deref().and_then(crypto::unb64).map(|s| derive::pair_check(&s));
                    if changed {
                        let _ = st.trust.save(&self.paths);
                    }
                    mine
                };
                self.sync_peers();
                if (mine.is_none() || mine != theirs) && self.local.device_id.as_str() < peer {
                    let contribution = crypto::random::<32>();
                    self.st.lock().unwrap().contributions.insert(peer.to_string(), contribution);
                    handle.send_json("connect.setup", &json!({"version": 1, "contribution": crypto::b64(&contribution), "rotate": mine.is_some()}));
                }
                return;
            }
            "connect.setup" => {
                let Some(p) = payload else { return };
                let Some(theirs) = p["contribution"].as_str().and_then(crypto::unb64).filter(|c| c.len() == 32) else { return };
                let pending = self.st.lock().unwrap().contributions.remove(peer);
                let mine = match pending {
                    Some(c) => c,
                    None => {
                        let c = crypto::random::<32>();
                        handle.send_json("connect.setup", &json!({"version": 1, "contribution": crypto::b64(&c), "rotate": p["rotate"].as_bool().unwrap_or(false)}));
                        c
                    }
                };
                let local = self.local.device_id.as_str();
                let (low, high) = derive::ordered(local, peer);
                let (c_low, c_high) = if local < peer { (mine.as_slice(), theirs.as_slice()) } else { (theirs.as_slice(), mine.as_slice()) };
                let secret = derive::pair_secret(c_low, c_high, low, high);
                {
                    let mut st = self.st.lock().unwrap();
                    if let Some(rec) = st.trust.peers.get_mut(peer) {
                        rec.pair_secret = Some(crypto::b64(&secret));
                    }
                    let _ = st.trust.save(&self.paths);
                }
                handle.send_json("connect.setup.ack", &json!({"version": 1}));
                log(&format!("pair secret set with {}", short(peer)));
                self.sync_peers();
                self.changed.notify_waiters();
                return;
            }
            "battery.update" => {
                if let Some(p) = payload {
                    if let (Some(level), Some(charging)) = (p["level"].as_u64().filter(|l| *l <= 100), p["isCharging"].as_bool()) {
                        self.st.lock().unwrap().battery.insert(peer.to_string(), (level as u8, charging, now_ms()));
                        self.changed.notify_waiters();
                    }
                }
                return;
            }
            "agent.hello" => {
                self.st.lock().unwrap().agent_peers.insert(peer.to_string());
                return;
            }
            "codes.candidate" => {
                self.on_candidate(peer, handle, payload);
                return;
            }
            "agent.grants" => {
                if let Some(p) = payload.filter(|p| p["version"] == 1 && p["grants"].is_array()) {
                    // Known grant names and fields only, bounded: the phone's words are shown, never trusted.
                    let grants: Vec<Value> = p["grants"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .filter(|g| g["key"].as_str().is_some_and(|k| GRANTS.iter().any(|x| x.0 == k)))
                        .take(GRANTS.len())
                        .map(|g| {
                            let state = match g["state"].as_str() { Some("on") => "on", Some("waiting") => "waiting", _ => "off" };
                            let mut o = json!({"key": g["key"], "state": state});
                            for k in ["grantedAt", "expiresAt"] {
                                if let Some(v) = g[k].as_u64() { o[k] = json!(v); }
                            }
                            if let Some(w) = g["window"].as_str().filter(|w| ["1h", "today", "7d", "forever"].contains(w)) { o["window"] = json!(w); }
                            if let Some(s) = g["scope"].as_str() { o["scope"] = json!(crate::session::printable(s, 200)); }
                            o
                        })
                        .collect();
                    let mut st = self.st.lock().unwrap();
                    let mut changed = false;
                    if let Some(rec) = st.trust.peers.get_mut(peer) {
                        changed = rec.grants.as_ref() != Some(&Value::Array(grants.clone()));
                        rec.grants = Some(Value::Array(grants));
                        rec.grants_at = now_ms();
                    }
                    if changed {
                        let _ = st.trust.save(&self.paths);
                    }
                    drop(st);
                    self.changed.notify_waiters();
                }
                return;
            }
            _ => {}
        }
        // Answers to requests: route by the IDs the request registered.
        let p = payload.clone().unwrap_or(Value::Null);
        let key = match m.kind.as_str() {
            "ping.ack" | "clipboard.ack" | "clipboard.rejected" => m.message_id.as_ref().map(|i| format!("msg:{i}")),
            "agent.request_result" => p["ref"].as_str().map(|r| format!("msg:{r}")),
            "notify.result" => p["notifyId"].as_str().map(|i| format!("notify:{i}")),
            "ask.posted" | "ask.answer" | "ask.dismissed" | "ask.expired" | "ask.cancelled" => {
                let id = p["askId"].as_str().unwrap_or("").to_string();
                self.update_ask(&id, peer, &m.kind, &p);
                Some(format!("ask:{id}"))
            }
            "find.started" | "find.stopped" => p["alertId"].as_str().map(|i| format!("find:{i}")),
            "clipboard.response" => p["requestId"].as_str().map(|i| format!("cliprq:{i}")),
            "codes.result" => p["queryId"].as_str().map(|i| format!("codes:{i}")),
            k if k.starts_with("files.") => m.transfer_id.as_ref().map(|t| format!("xfer:{t}")),
            _ => None,
        };
        let Some(key) = key.map(|k| format!("{peer}|{k}")) else { return };
        let tx = self.st.lock().unwrap().waiters.get(&key).cloned();
        if let Some(tx) = tx {
            let _ = tx.send(Reply { kind: m.kind.clone(), message: m, payload });
        }
    }

    fn update_ask(&self, id: &str, peer: &str, kind: &str, p: &Value) {
        if !crate::crypto::is_uuid(id) {
            return;
        }
        let mut st = self.st.lock().unwrap();
        // An answer to an ask this run never saw (asked before a restart): keep it for bridgey wait, up to 256.
        if !st.asks.contains_key(id) {
            if kind != "ask.answer" || st.asks.len() >= 256 {
                return;
            }
            st.asks.insert(id.to_string(), Ask { device: peer.to_string(), expires_at: now_ms() + 86_400_000, state: "sent".into(), answer: None });
        }
        if st.asks.get(id).is_some_and(|a| a.device != peer) {
            return;
        }
        if let Some(a) = st.asks.get_mut(id) {
            if a.state == "answered" || a.state == "dismissed" || a.state == "expired" || a.state == "cancelled" {
                return;
            }
            a.state = match kind {
                "ask.posted" => "posted",
                "ask.answer" => "answered",
                "ask.dismissed" => "dismissed",
                "ask.expired" => "expired",
                _ => "cancelled",
            }
            .into();
            if kind == "ask.answer" {
                a.answer = Some(json!({"option": p["option"].as_str().map(|o| crate::session::printable(o, 32)), "text": p["text"].as_str().map(|x| x.chars().take(1000).collect::<String>()), "answeredAt": p["answeredAt"].as_u64()}));
            }
        }
        drop(st);
        self.save_asks();
    }

    pub fn save_asks(&self) {
        // IDs, devices and states only: answers stay in memory.
        let asks: Vec<Value> = self.st.lock().unwrap().asks.iter().map(|(id, a)| json!({"askId": id, "device": a.device, "expiresAt": a.expires_at, "state": a.state})).collect();
        let _ = write_private(&self.paths.state.join("asks.json"), Value::Array(asks).to_string().as_bytes());
    }

    fn send_addresses(&self, peer: &str, handle: &Handle) {
        let reply = self.node.addresses();
        let addrs: Vec<Value> = reply["addrs"].as_array().cloned().unwrap_or_default().into_iter().take(16).collect();
        let mut payload = json!({"version": 1, "port": reply["port"], "addrs": addrs});
        let secret = self.st.lock().unwrap().trust.peers.get(peer).and_then(|p| p.pair_secret.clone());
        if let Some(s) = secret.as_deref().and_then(crypto::unb64) {
            payload["pairCheck"] = json!(derive::pair_check(&s));
        }
        handle.send_json("connect.addresses", &payload);
    }

    // endregion

    // region Helpers for commands

    pub fn trust(&self) -> Trust {
        self.st.lock().unwrap().trust.clone()
    }

    pub fn resolve(&self, query: Option<&str>) -> Result<Peer, CliError> {
        let st = self.st.lock().unwrap();
        if st.trust.peers.is_empty() {
            return Err(CliError::new("not_paired", "This install is not paired yet. Run bridgey pair."));
        }
        let query = query.map(str::to_string).or_else(|| self.config.str("default_device"));
        match query {
            Some(q) => st.trust.find(&q).cloned().map_err(|m| CliError::new("unknown_device", m)),
            None if st.trust.peers.len() == 1 => Ok(st.trust.peers.values().next().unwrap().clone()),
            // Devices paired over the tailnet (Macs, other servers) do not make the phone ambiguous.
            None if st.trust.peers.values().filter(|p| p.platform == "phone").count() == 1 => Ok(st.trust.peers.values().find(|p| p.platform == "phone").unwrap().clone()),
            None => Err(CliError::new("usage", "More than one device is paired: choose one with -d or BRIDGEY_DEVICE (see bridgey devices).")),
        }
    }

    pub fn handle_for(&self, peer: &str) -> Option<Handle> {
        self.st.lock().unwrap().sessions.get(peer).map(|l| l.handle.clone()).filter(Handle::is_open)
    }

    /// The session with `peer`, connecting if needed, within `timeout`; then its feature map (waits briefly).
    pub async fn ensure(&self, peer: &Peer, timeout: Duration) -> Result<Handle, CliError> {
        let deadline = tokio::time::Instant::now() + timeout;
        let mut asked = false;
        loop {
            let notified = self.changed.notified();
            if let Some(h) = self.handle_for(&peer.device_id) {
                if self.st.lock().unwrap().features.contains_key(&peer.device_id) {
                    return Ok(h);
                }
            } else if !asked {
                asked = true;
                if peer.pair_secret.is_none() && self.trust().peers.get(&peer.device_id).is_some_and(|p| p.pair_secret.is_none()) {
                    return Err(CliError::new("unreachable", format!("{} has no Connect anywhere secret with this install yet; pair again with bridgey pair", peer.name)));
                }
                self.node.connect(&peer.device_id);
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                if let Some(h) = self.handle_for(&peer.device_id) {
                    return Ok(h);
                }
                let failure = self.st.lock().unwrap().last_failure.get(&peer.device_id).cloned();
                let presence = self.st.lock().unwrap().presence.clone();
                let mut hint = if presence != "online" { " The Round Robin control service can't be reached from this host (see bridgey doctor).".to_string() } else { " Is Bridgey running on it, with Connect away from home on?".to_string() };
                if let Some(f) = failure {
                    hint.push_str(&format!(" Last attempt: {f}."));
                }
                return Err(CliError::new("unreachable", format!("Could not reach {} within {} s.{hint}", peer.name, timeout.as_secs())));
            }
        }
    }

    pub fn features(&self, peer: &str) -> Map<String, Value> {
        self.st.lock().unwrap().features.get(peer).cloned().unwrap_or_default()
    }

    /// Fails with not_granted (exit 5) unless the phone's latest map shows the grant; incompatible (exit 10)
    /// when the phone does not know agent devices at all.
    pub fn require(&self, peer: &Peer, grant: &str) -> Result<(), CliError> {
        let map = self.features(&peer.device_id);
        if map.get("agent_draft1") != Some(&Value::Bool(true)) {
            return Err(no_agent_devices(peer));
        }
        let key = grant_wire(grant).unwrap_or(grant);
        if map.get(key) == Some(&Value::Bool(true)) {
            return Ok(());
        }
        Err(not_granted(&peer.name, grant, &self.local.name()))
    }

    /// Registers reply keys before a request goes out; the guard removes them.
    /// Keys are scoped to the device the request went to: another paired device cannot answer it.
    pub fn wait_for(&self, peer: &str, keys: Vec<String>) -> (WaitGuard<'_>, mpsc::UnboundedReceiver<Reply>) {
        let keys: Vec<String> = keys.into_iter().map(|k| format!("{peer}|{k}")).collect();
        let (tx, rx) = mpsc::unbounded_channel();
        let mut st = self.st.lock().unwrap();
        for k in &keys {
            st.waiters.insert(k.clone(), tx.clone());
        }
        (WaitGuard { daemon: self, keys }, rx)
    }

    pub fn battery(&self, peer: &str) -> Option<(u8, bool, u64)> {
        self.st.lock().unwrap().battery.get(peer).cloned()
    }

    pub fn add_ask(&self, id: &str, ask: Ask) {
        self.st.lock().unwrap().asks.insert(id.into(), ask);
        self.save_asks();
    }

    pub fn ask(&self, id: &str) -> Option<Ask> {
        self.st.lock().unwrap().asks.get(id).cloned()
    }

    pub fn set_ring(&self, peer: &str, alert: Option<String>) {
        let mut st = self.st.lock().unwrap();
        match alert {
            Some(a) => st.rings.insert(peer.into(), a),
            None => st.rings.remove(peer),
        };
    }

    pub fn ring_alert(&self, peer: &str) -> Option<String> {
        self.st.lock().unwrap().rings.get(peer).cloned()
    }

    pub fn transfers(&self) -> Vec<TransferInfo> {
        self.st.lock().unwrap().transfers.clone()
    }

    pub fn transfer_update(&self, info: TransferInfo) {
        let mut st = self.st.lock().unwrap();
        match st.transfers.iter_mut().find(|t| t.transfer_id == info.transfer_id) {
            Some(t) => *t = info,
            None => st.transfers.push(info),
        }
    }

    pub fn status_json(&self) -> Value {
        let core = self.node.status();
        let st = self.st.lock().unwrap();
        let sessions: Vec<Value> = st
            .sessions
            .iter()
            .map(|(peer, l)| {
                let tunnel = core["tunnels"].as_array().and_then(|ts| ts.iter().find(|t| t["tunnel"] == l.tunnel.as_str())).cloned().unwrap_or(Value::Null);
                json!({"device": peer, "since": l.since, "tunnel": l.tunnel, "route": tunnel["route"], "relay": tunnel["relay"], "rttMs": tunnel["rttMs"]})
            })
            .collect();
        json!({
            "version": VERSION,
            "profile": self.paths.profile,
            "deviceId": self.local.device_id,
            "deviceName": self.local.name(),
            "pid": std::process::id(),
            "startedAt": self.started,
            "service": self.service,
            "controlUrl": self.config.control_url(),
            "control": st.presence,
            "online": st.online,
            "udpPort": core["udpPort"],
            "core": core,
            "coreState": st.core_state,
            "sessions": sessions,
        })
    }

    // endregion

    // region Pairing

    /// A new invite to show, or (`join`) someone else's invite to answer.
    pub fn start_invite(&self, join: Option<Invite>) -> (Invite, mpsc::UnboundedReceiver<InviteEvent>) {
        let joining = join.is_some();
        let invite = join.unwrap_or_else(|| Invite::new(&self.config.control_url(), &self.local.name(), now_ms()));
        let (tx, rx) = mpsc::unbounded_channel();
        self.st.lock().unwrap().invites.insert(invite.label(), PendingInvite { invite: invite.clone(), joining, to_client: tx, session: None });
        self.sync_peers();
        (invite, rx)
    }

    /// One pairing over the tailnet on a direct TCP connection (dialled or accepted); its code and result go to `tx`.
    pub fn start_direct(self: &Arc<Self>, stream: tokio::net::TcpStream, mode: session::Mode, tx: mpsc::UnboundedSender<InviteEvent>) -> u64 {
        let local_id = self.next_local.fetch_add(1, Ordering::Relaxed);
        self.st.lock().unwrap().direct.insert(local_id, tx);
        let dialled = matches!(mode, session::Mode::Dial);
        let spec = session::Spec { local_id, port: 0, token: String::new(), exporter: String::new(), tunnel: format!("tailnet{local_id}"), quic_client: dialled, mode, direct: Some(stream) };
        let d = self.clone();
        let pins: session::PinLookup = Arc::new(move |id: &str| d.st.lock().unwrap().trust.peers.values().find(|p| p.device_id.eq_ignore_ascii_case(id)).map(|p| p.identity_key.clone()));
        session::spawn(spec, self.local.clone(), pins, self.events.clone());
        local_id
    }

    pub fn end_direct(&self, local_id: u64) {
        self.st.lock().unwrap().direct.remove(&local_id);
    }

    pub fn end_invite(&self, label: &str) {
        let removed = self.st.lock().unwrap().invites.remove(label);
        if removed.is_some() {
            self.sync_peers();
        }
    }

    pub fn forget(&self, peer: &str) -> bool {
        let mut st = self.st.lock().unwrap();
        let had = st.trust.peers.remove(peer).is_some();
        let _ = st.trust.save(&self.paths);
        if let Some(l) = st.sessions.remove(peer) {
            l.handle.close("forgotten");
        }
        st.features.remove(peer);
        st.battery.remove(peer);
        drop(st);
        self.sync_peers();
        had
    }

    pub fn rename(&self, name: &str) {
        *self.local.device_name.write().unwrap() = name.chars().take(64).collect();
    }

    pub fn used(&self) {
        *self.last_used.lock().unwrap() = Instant::now();
    }

    // endregion
}

pub fn not_granted(phone: &str, grant: &str, me: &str) -> CliError {
    CliError::new(
        "not_granted",
        format!("{phone} has not allowed \"{}\" for this device. Turn it on in Bridgey on the phone: Devices, {me}, Permissions (or ask with: bridgey grants request {grant}).", grant_title(grant)),
    )
    .with("feature", grant)
}

/// One daemon per profile: an exclusive lock on `run/daemon.lock`, held for the process's life.
fn acquire_lock(paths: &Paths) -> Result<std::fs::File, String> {
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::io::AsRawFd;
    let path = paths.run.join("daemon.lock");
    let file = std::fs::OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("another bridgey daemon is already running for this profile".into());
    }
    Ok(file)
}

/// The refusal when a peer's map has no agent devices: a device paired over the tailnet keeps this install
/// restricted (not granted) until someone trusts it there; anything else runs an older Bridgey.
pub fn no_agent_devices(peer: &Peer) -> CliError {
    if peer.platform == "tailnet" {
        CliError::new(
            "not_granted",
            format!("{} keeps this install restricted (paired over your tailnet): nothing is allowed until someone chooses \"Trust as my device\" there", peer.name),
        )
    } else {
        CliError::new("incompatible", format!("{} runs a Bridgey without agent devices; update the app", peer.name))
    }
}

#[cfg(test)]
mod no_agent_devices_tests {
    use super::*;

    #[test]
    fn a_tailnet_peer_is_not_granted_and_an_old_phone_is_incompatible() {
        let mac = Peer { name: "Mac".into(), platform: "tailnet".into(), ..Default::default() };
        let e = no_agent_devices(&mac);
        assert_eq!(e.code, "not_granted");
        assert!(e.message.contains("Trust as my device"));
        let phone = Peer { name: "Phone".into(), platform: "phone".into(), ..Default::default() };
        assert_eq!(no_agent_devices(&phone).code, "incompatible");
    }
}
