//! The session client a new platform runs: it listens on the Bridgey port, finds devices, pairs with
//! protocol 2, reconnects to trusted devices, keeps one session per device, and reports what happens as
//! events. The rules are the apps' (docs/protocol.md, docs/reconnect-reliability.md); the values are in one
//! place below.

use crate::events::{Event, EventQueue, Next, SendStatus};
use crate::fast;
use crate::features::FeatureMap;
use crate::session::{self, Admission, Authenticated, Handle, Local, Offer, OutgoingFile, Role};
use crate::trust::{Identity, KnownAddress, Storage, TrustStore, TrustedDevice};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Notify};

/// Bridgey's port, unchanged from upstream.
pub const DEFAULT_PORT: u16 = 42_458;
/// Delays between reconnect attempts after a drop; the last repeats for the rest of the fast phase (Reconnect.kt).
const FAST_DELAYS: [u64; 5] = [2, 5, 15, 30, 60];
const FAST_PHASE: Duration = Duration::from_secs(3_600);
const SLOW_DELAY: Duration = Duration::from_secs(600);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
/// A live session silent this long loses to a new one for the same device, whichever side dialled.
const STALE_SESSION: Duration = Duration::from_secs(15);
/// Waiting for the other end's Allow pairing: a new dial every 3 s for two minutes.
const ALLOW_RETRY: Duration = Duration::from_secs(3);
const ALLOW_WAIT: Duration = Duration::from_secs(120);
/// Allow pairing lasts two minutes by default and never more than ten.
pub const ALLOW_DEFAULT: Duration = Duration::from_secs(120);
const ALLOW_MAX: Duration = Duration::from_secs(600);
/// Committed offers answered from devices this end does not trust: at most three a minute.
const OFFERS_PER_MINUTE: usize = 3;
/// A "wants to pair" card at most this often per device.
const REQUEST_SPACING: Duration = Duration::from_secs(10);
/// Senders give up on an acknowledgement after this long rather than show "sending" forever.
const ACK_TIMEOUT: Duration = Duration::from_secs(10);
const PING_TIMEOUT: Duration = Duration::from_secs(5);
/// Quick actions (links) are "not confirmed" after eight seconds (docs/protocol.md "Quick actions").
const QUICK_TIMEOUT: Duration = Duration::from_secs(8);
/// Connections that have not authenticated yet, at once.
const MAX_PENDING: usize = 16;

pub struct Config {
    pub device_name: String,
    /// `windows`, `linux`, `ios`: the DNS-SD `platform` value.
    pub platform: String,
    /// 0 picks a free port (tests); the apps use 42458.
    pub port: u16,
    pub listen: bool,
    pub discovery: bool,
    pub event_capacity: usize,
    /// This device's switches for devices that have none of their own.
    pub defaults: FeatureMap,
    /// Where received files are saved. None refuses files (`files.rejected`), whatever the switches say.
    pub receive_dir: Option<PathBuf>,
    /// Connect only to devices named with `connect` (a share extension), instead of keeping every trusted device
    /// connected.
    pub manual_connect: bool,
    /// Binary file frames (files_fast_draft1) with devices that show them.
    pub fast_transfers: bool,
}

impl Config {
    pub fn new(device_name: &str, platform: &str) -> Config {
        let mut defaults = FeatureMap::all_off();
        defaults.set("clipboard", true);
        defaults.set("ping", true);
        Config {
            device_name: device_name.into(),
            platform: platform.into(),
            port: DEFAULT_PORT,
            listen: true,
            discovery: true,
            event_capacity: 1024,
            defaults,
            receive_dir: None,
            manual_connect: false,
            fast_transfers: true,
        }
    }
}

/// What an acknowledgement is waited for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pending {
    Clipboard,
    Ping,
    Link,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ClientError {
    InvalidArgument(&'static str),
    NotConnected,
    FeatureOff,
    TooLarge,
    UnknownDevice,
    Stopped,
    Storage(String),
    Io(String),
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            ClientError::InvalidArgument(w) => write!(f, "invalid argument: {w}"),
            ClientError::NotConnected => f.write_str("not connected"),
            ClientError::FeatureOff => f.write_str("feature off on one of the devices"),
            ClientError::TooLarge => f.write_str("too large"),
            ClientError::UnknownDevice => f.write_str("unknown device"),
            ClientError::Stopped => f.write_str("stopped"),
            ClientError::Storage(e) => write!(f, "storage: {e}"),
            ClientError::Io(e) => write!(f, "{e}"),
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The same host whatever form the address came in (an IPv4-mapped IPv6 address is its IPv4 address).
fn same_host(a: IpAddr, b: IpAddr) -> bool {
    let canon = |ip: IpAddr| match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        v4 => v4,
    };
    canon(a) == canon(b)
}

fn host_text(ip: IpAddr) -> String {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(|v4| v4.to_string()).unwrap_or_else(|| v6.to_string()),
        IpAddr::V4(v4) => v4.to_string(),
    }
}

struct Live {
    handle: Handle,
    device_id: Option<String>,
    dialled: bool,
    authenticated: bool,
    code_shown: bool,
    replaced: bool,
    /// The person's pairing this session belongs to.
    attempt: Option<u64>,
    watch: Option<mpsc::UnboundedSender<Outcome>>,
}

#[derive(Debug)]
enum Outcome {
    Authenticated,
    Closed { reason: String, answered: bool },
}

struct Attempt {
    id: u64,
    expected: Option<String>,
    name: String,
    addrs: Vec<SocketAddr>,
    session: Option<u64>,
    /// An offer from the device being paired with that this end answered instead (crossed pairing).
    adopted: Option<u64>,
    cancelled: bool,
    wake: Arc<Notify>,
}

struct Discovered {
    device_id: Option<String>,
    name: String,
    platform: Option<String>,
    addrs: Vec<SocketAddr>,
}

#[derive(Default)]
struct State {
    sessions: HashMap<u64, Live>,
    connected: HashMap<String, u64>,
    armed_until: Option<Instant>,
    pairing: Option<Attempt>,
    /// The session with a first pairing in progress that this end answered.
    incoming_pairing: Option<u64>,
    offers: VecDeque<Instant>,
    requests: HashMap<String, Instant>,
    discovered: HashMap<String, Discovered>,
    remote: HashMap<String, FeatureMap>,
    /// Waiting for an answer, by message ID (clipboard, ping) or request ID (links).
    pending: HashMap<String, (u64, String, Pending)>,
    loops: HashMap<String, Arc<Notify>>,
    /// Transfers in either direction and the device each is with, for cancelling.
    transfers: HashMap<u64, String>,
    /// With manual_connect: the devices the host asked to connect to.
    wanted: HashSet<String>,
    /// Each device's files waiting to be hashed, in the order they were sent.
    hashing: HashMap<String, mpsc::UnboundedSender<HashJob>>,
    /// Files sent but not handed to a session yet (still hashing or waiting to be).
    unhanded: HashSet<u64>,
    /// Each connected device's battery, as it last said.
    battery: HashMap<String, (u8, bool)>,
    /// Connected devices that said they are ringing.
    ringing: HashSet<String>,
    /// presence.state per device: the session it went on, the last sequence, when and what was sent.
    presence: HashMap<String, (u64, u64, Instant, crate::notifications::Presence)>,
}

/// A file to hash before it is offered.
struct HashJob {
    transfer: u64,
    path: PathBuf,
    name: String,
    mime: String,
}

pub(crate) struct Inner {
    local: Local,
    platform: String,
    port: AtomicU64,
    storage: Arc<dyn Storage>,
    defaults: RwLock<FeatureMap>,
    receive_dir: RwLock<Option<PathBuf>>,
    manual: bool,
    fast_transfers: AtomicBool,
    /// Tests only: the size of the chunks sent (0: the protocol's).
    chunk_size: AtomicUsize,
    /// This device's battery, sent to devices that show Battery.
    battery: Mutex<Option<(u8, bool)>>,
    trust: Mutex<TrustStore>,
    state: Mutex<State>,
    events: EventQueue,
    ids: AtomicU64,
    stopped: AtomicBool,
    /// Codes from messages, and Also read codes in email (both off by default).
    codes: Mutex<(bool, bool)>,
    /// This device's activity, for presence.state.
    activity: Mutex<crate::notifications::Presence>,
    rt: tokio::runtime::Handle,
    me: Weak<Inner>,
    #[cfg(feature = "mdns")]
    discovery: Mutex<Option<crate::discovery::Discovery>>,
}

pub struct Client {
    inner: Arc<Inner>,
    runtime: Mutex<Option<tokio::runtime::Runtime>>,
}

impl Client {
    /// Loads (or creates) the identity, loads the trusted devices, binds the port, starts discovery and
    /// reconnects to every trusted device.
    pub fn start(config: Config, storage: Arc<dyn Storage>) -> Result<Client, ClientError> {
        let identity = Identity::load_or_create(storage.as_ref()).map_err(ClientError::Storage)?;
        let trust = TrustStore::load(storage.as_ref()).map_err(ClientError::Storage)?;
        let name = session::sanitized_name(Some(&config.device_name));
        let platform: String = config.platform.chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '-').take(16).collect();
        if platform.is_empty() {
            return Err(ClientError::InvalidArgument("platform"));
        }
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("bridgey-client").enable_all().build().map_err(|e| ClientError::Io(e.to_string()))?;
        let inner = Arc::new_cyclic(|me| Inner {
            local: Local { device_id: identity.device_id.clone(), name: RwLock::new(name), identity: identity.key, identity_public: identity.public },
            platform,
            port: AtomicU64::new(0),
            storage,
            defaults: RwLock::new(config.defaults.clone()),
            receive_dir: RwLock::new(config.receive_dir.clone()),
            manual: config.manual_connect,
            fast_transfers: AtomicBool::new(config.fast_transfers),
            chunk_size: AtomicUsize::new(0),
            battery: Mutex::new(None),
            trust: Mutex::new(trust),
            state: Mutex::new(State::default()),
            events: EventQueue::new(config.event_capacity),
            ids: AtomicU64::new(1),
            stopped: AtomicBool::new(false),
            codes: Mutex::new((false, false)),
            activity: Mutex::new(crate::notifications::Presence::Unknown),
            rt: runtime.handle().clone(),
            me: me.clone(),
            #[cfg(feature = "mdns")]
            discovery: Mutex::new(None),
        });
        if config.listen {
            let listener = runtime.block_on(bind(config.port)).map_err(|e| ClientError::Io(format!("port {}: {e}", config.port)))?;
            inner.port.store(u64::from(listener.0.local_addr().map(|a| a.port()).unwrap_or(config.port)), Ordering::Relaxed);
            for l in [Some(listener.0), listener.1].into_iter().flatten() {
                let me = inner.clone();
                runtime.spawn(async move { me.accept_loop(l).await });
            }
        }
        #[cfg(feature = "mdns")]
        if config.discovery {
            let port = inner.port() ;
            match crate::discovery::Discovery::start(Arc::downgrade(&inner), &inner.local.device_id, &inner.local.name(), &inner.platform, port, config.listen) {
                Ok(d) => *inner.discovery.lock().unwrap() = Some(d),
                Err(e) => inner.emit(Event::Error { text: format!("discovery: {e}") }),
            }
        }
        let trusted: Vec<String> = inner.trust.lock().unwrap().all().iter().map(|d| d.device_id.clone()).collect();
        for id in trusted {
            inner.ensure_loop(&id);
        }
        {
            let me = Arc::downgrade(&inner);
            runtime.spawn(async move {
                loop {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    let Some(inner) = me.upgrade() else { return };
                    // The presence keepalive, even when the host stops sampling.
                    let connected: Vec<String> = inner.state.lock().unwrap().connected.keys().cloned().collect();
                    for id in connected {
                        inner.send_presence(&id, false);
                    }
                }
            });
        }
        Ok(Client { inner, runtime: Mutex::new(Some(runtime)) })
    }

    pub fn device_id(&self) -> &str {
        &self.inner.local.device_id
    }

    pub fn port(&self) -> u16 {
        self.inner.port()
    }

    pub fn next_event(&self, timeout: Duration) -> Next {
        self.inner.events.next(timeout)
    }

    /// Stops listening, discovery and every session, and wakes every `next_event`.
    pub fn stop(&self) {
        if self.inner.stopped.swap(true, Ordering::SeqCst) {
            return;
        }
        #[cfg(feature = "mdns")]
        if let Some(d) = self.inner.discovery.lock().unwrap().take() {
            d.stop();
        }
        self.inner.events.close();
        let sessions: Vec<Handle> = self.inner.state.lock().unwrap().sessions.values().map(|l| l.handle.clone()).collect();
        for h in sessions {
            h.close("stopped");
        }
        if let Some(rt) = self.runtime.lock().unwrap().take() {
            rt.shutdown_timeout(Duration::from_millis(500));
        }
    }

    pub fn set_device_name(&self, name: &str) -> Result<(), ClientError> {
        let name = session::sanitized_name(Some(name));
        *self.inner.local.name.write().unwrap() = name.clone();
        #[cfg(feature = "mdns")]
        if let Some(d) = self.inner.discovery.lock().unwrap().as_mut() {
            d.rename(&name);
        }
        Ok(())
    }

    /// Lets another device pair with this one for `duration` (zero turns it off). A pairing screen being open
    /// counts as allowing pairing, so hosts call this when it opens and closes.
    pub fn allow_pairing(&self, duration: Duration) {
        let mut st = self.inner.state.lock().unwrap();
        st.armed_until = if duration.is_zero() { None } else { Some(Instant::now() + duration.min(ALLOW_MAX)) };
    }

    /// Pairs with a device: its discovered ID and addresses, or an address typed in. Returns the pairing ID
    /// that events carry and that `confirm_pairing` and `cancel_pairing` take.
    pub fn pair(&self, device_id: Option<&str>, host: Option<&str>, port: u16) -> Result<u64, ClientError> {
        self.inner.check()?;
        let expected = device_id.filter(|d| crate::crypto::is_uuid(d)).map(|d| d.to_ascii_lowercase());
        if expected.as_deref() == Some(self.inner.local.device_id.as_str()) {
            return Err(ClientError::InvalidArgument("that is this device"));
        }
        let mut addrs: Vec<SocketAddr> = Vec::new();
        let mut name = String::new();
        if let Some(host) = host.filter(|h| !h.trim().is_empty()) {
            let port = if port == 0 { DEFAULT_PORT } else { port };
            let ip: IpAddr = host.trim().trim_start_matches('[').trim_end_matches(']').parse().map_err(|_| ClientError::InvalidArgument("host must be an IP address"))?;
            addrs.push(SocketAddr::new(ip, port));
            name = host.to_string();
        }
        {
            let st = self.inner.state.lock().unwrap();
            if let Some(id) = &expected {
                for d in st.discovered.values().filter(|d| d.device_id.as_deref() == Some(id.as_str())) {
                    name = d.name.clone();
                    for a in &d.addrs {
                        if !addrs.contains(a) {
                            addrs.push(*a);
                        }
                    }
                }
            }
        }
        if let Some(id) = &expected {
            if let Some(t) = self.inner.trust.lock().unwrap().get(id) {
                if name.is_empty() {
                    name = t.name.clone();
                }
                for a in &t.addresses {
                    if let Ok(ip) = a.host.parse::<IpAddr>() {
                        let s = SocketAddr::new(ip, a.port);
                        if !addrs.contains(&s) {
                            addrs.push(s);
                        }
                    }
                }
            }
        }
        if addrs.is_empty() {
            return Err(ClientError::UnknownDevice);
        }
        let id = self.inner.next_id();
        let wake = Arc::new(Notify::new());
        let previous = {
            let mut st = self.inner.state.lock().unwrap();
            st.pairing.replace(Attempt { id, expected, name: if name.is_empty() { "Bridgey device".into() } else { name }, addrs, session: None, adopted: None, cancelled: false, wake })
        };
        if let Some(p) = previous {
            self.inner.finish_attempt_quietly(p);
        }
        let me = self.inner.clone();
        self.inner.rt.spawn(async move { me.attempt_loop(id).await });
        Ok(id)
    }

    /// The person's answer to the code (true: it matches).
    pub fn confirm_pairing(&self, pairing: u64, accept: bool) -> Result<(), ClientError> {
        let handle = self.inner.pairing_session(pairing).ok_or(ClientError::UnknownDevice)?;
        handle.confirm(accept);
        Ok(())
    }

    pub fn cancel_pairing(&self, pairing: u64) -> Result<(), ClientError> {
        let mut st = self.inner.state.lock().unwrap();
        if let Some(a) = st.pairing.as_mut().filter(|a| a.id == pairing) {
            a.cancelled = true;
            a.wake.notify_one();
            let sessions: Vec<u64> = [a.session, a.adopted].into_iter().flatten().collect();
            for s in sessions {
                if let Some(l) = st.sessions.get(&s).filter(|l| !l.authenticated) {
                    l.handle.close("cancelled");
                }
            }
            return Ok(());
        }
        if let Some(l) = st.sessions.get(&pairing).filter(|l| !l.authenticated) {
            l.handle.close("cancelled");
            return Ok(());
        }
        Err(ClientError::UnknownDevice)
    }

    /// Forgets a trusted device: its pin, its switches and its addresses. A new pairing is needed to connect again.
    pub fn forget(&self, device_id: &str) -> Result<(), ClientError> {
        let (removed, name) = {
            let mut trust = self.inner.trust.lock().unwrap();
            let name = trust.get(device_id).map(|d| d.name.clone()).unwrap_or_default();
            let removed = trust.remove(device_id);
            if removed {
                trust.save(self.inner.storage.as_ref()).map_err(ClientError::Storage)?;
            }
            (removed, name)
        };
        if !removed {
            return Err(ClientError::UnknownDevice);
        }
        let id = device_id.to_ascii_lowercase();
        {
            let mut st = self.inner.state.lock().unwrap();
            for l in st.sessions.values().filter(|l| l.device_id.as_deref() == Some(id.as_str())) {
                l.handle.close("forgotten");
            }
            if let Some(n) = st.loops.remove(&id) {
                n.notify_one();
            }
            st.wanted.remove(&id);
        }
        self.inner.emit(Event::TrustChanged { device_id: id, name, trusted: false });
        Ok(())
    }

    /// Sends text to a connected device's clipboard. The result arrives as `ClipboardSent` with the request ID.
    pub fn send_clipboard(&self, device_id: &str, text: &str) -> Result<u64, ClientError> {
        self.inner.check()?;
        if text.is_empty() {
            return Err(ClientError::InvalidArgument("empty text"));
        }
        if text.len() > session::CLIPBOARD_MAX {
            return Err(ClientError::TooLarge);
        }
        let (handle, id) = self.inner.feature_session(device_id, "clipboard")?;
        let message_id = crate::crypto::uuid4();
        let request = self.inner.next_id();
        self.inner.state.lock().unwrap().pending.insert(message_id.clone(), (request, id.clone(), Pending::Clipboard));
        if !handle.send_clipboard(text.to_string(), message_id.clone()) {
            self.inner.state.lock().unwrap().pending.remove(&message_id);
            return Err(ClientError::NotConnected);
        }
        self.inner.expire(message_id, ACK_TIMEOUT);
        Ok(request)
    }

    /// One short sound on the other device (`ping.v1`); the result arrives as `PingResult`.
    pub fn ping(&self, device_id: &str) -> Result<u64, ClientError> {
        self.inner.check()?;
        let (handle, id) = self.inner.feature_session(device_id, "ping")?;
        let message_id = crate::crypto::uuid4();
        let request = self.inner.next_id();
        self.inner.state.lock().unwrap().pending.insert(message_id.clone(), (request, id, Pending::Ping));
        if !handle.ping(message_id.clone()) {
            self.inner.state.lock().unwrap().pending.remove(&message_id);
            return Err(ClientError::NotConnected);
        }
        self.inner.expire(message_id, PING_TIMEOUT);
        Ok(request)
    }

    /// Sends a file to a connected device: hashed first, then offered, then sent in chunks once accepted. Files to
    /// one device go one at a time, in order. The result arrives as `FileDone` or `FileFailed` with the returned
    /// transfer ID, with `FileProgress` meanwhile. `name` defaults to the file's own name and `mime` to one from it.
    pub fn send_file(&self, device_id: &str, path: &Path, name: Option<&str>, mime: Option<&str>) -> Result<u64, ClientError> {
        self.inner.check()?;
        let meta = std::fs::metadata(path).map_err(|e| ClientError::InvalidArgument(if e.kind() == std::io::ErrorKind::NotFound { "no such file" } else { "unreadable file" }))?;
        if !meta.is_file() {
            return Err(ClientError::InvalidArgument("not a file"));
        }
        if meta.len() > crate::transfer::MAX_FILE {
            return Err(ClientError::TooLarge);
        }
        let (_, id) = self.inner.feature_session(device_id, "files")?;
        let own = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let name = crate::transfer::safe_name(name.filter(|n| !n.trim().is_empty()).unwrap_or(&own));
        let mime = mime.filter(|m| !m.is_empty() && m.len() <= 128).map(str::to_string).unwrap_or_else(|| crate::transfer::mime_for(&name).to_string());
        let transfer = self.inner.next_id();
        let job = HashJob { transfer, path: path.to_path_buf(), name, mime };
        let mut st = self.inner.state.lock().unwrap();
        st.transfers.insert(transfer, id.clone());
        st.unhanded.insert(transfer);
        // One queue per device, so files are hashed and offered in the order they were sent.
        let queue = st.hashing.entry(id.clone()).or_insert_with(|| {
            let (tx, rx) = mpsc::unbounded_channel();
            let me = self.inner.clone();
            self.inner.rt.spawn(me.hash_loop(id.clone(), rx));
            tx
        });
        if let Err(e) = queue.send(job) {
            st.transfers.remove(&transfer);
            st.unhanded.remove(&transfer);
            st.hashing.remove(&id);
            drop(st);
            self.inner.emit(Event::FileFailed { transfer, device_id: id, incoming: false, name: e.0.name, reason: "stopped".into() });
        }
        Ok(transfer)
    }

    /// Stops a transfer in either direction; the other device is told. `FileFailed` follows with `cancelled`.
    pub fn cancel_file(&self, transfer: u64) -> Result<(), ClientError> {
        self.inner.check()?;
        let device = {
            let mut st = self.inner.state.lock().unwrap();
            let device = st.transfers.get(&transfer).cloned().ok_or(ClientError::UnknownDevice)?;
            // Not with a session yet: it ends here.
            if st.unhanded.remove(&transfer) {
                st.transfers.remove(&transfer);
                drop(st);
                self.inner.emit(Event::FileFailed { transfer, device_id: device, incoming: false, name: String::new(), reason: "cancelled".into() });
                return Ok(());
            }
            device
        };
        let handle = {
            let st = self.inner.state.lock().unwrap();
            st.connected.get(&device).and_then(|s| st.sessions.get(s)).map(|l| l.handle.clone())
        };
        match handle {
            Some(h) if h.cancel_file(transfer) => Ok(()),
            _ => {
                // Still hashing (no session has it yet), or the session ended: it fails here.
                let removed = self.inner.state.lock().unwrap().transfers.remove(&transfer);
                if removed.is_some() {
                    self.inner.emit(Event::FileFailed { transfer, device_id: device, incoming: false, name: String::new(), reason: "cancelled".into() });
                }
                Ok(())
            }
        }
    }

    /// Sends a link (http or https) to a connected device with Links on at both ends. It is queued there for the
    /// person to open; a Mac with "Open links from other devices right away" opens it. The result arrives as
    /// `LinkSent` with the returned request ID.
    pub fn send_link(&self, device_id: &str, url: &str) -> Result<u64, ClientError> {
        self.inner.check()?;
        let url = url.trim();
        if !crate::transfer::valid_link(url) {
            return Err(ClientError::InvalidArgument("not an http or https link"));
        }
        let (handle, id) = self.inner.feature_session(device_id, "links")?;
        // A Mac that shows links_open_draft1 understands "open" (Send to device); others queue an "offer".
        let open = self.inner.state.lock().unwrap().remote.get(&id).is_some_and(|r| r.get("links_open_draft1"));
        let request_id = crate::crypto::uuid4();
        let request = self.inner.next_id();
        self.inner.state.lock().unwrap().pending.insert(request_id.clone(), (request, id, Pending::Link));
        if !handle.send_link(url.to_string(), request_id.clone(), open) {
            self.inner.state.lock().unwrap().pending.remove(&request_id);
            return Err(ClientError::NotConnected);
        }
        self.inner.expire(request_id, QUICK_TIMEOUT);
        Ok(request)
    }

    /// Connects to a trusted device now and keeps it connected (needed with `manual_connect`; elsewhere it retries
    /// at once, like a network change).
    pub fn connect(&self, device_id: &str) -> Result<(), ClientError> {
        self.inner.check()?;
        let id = device_id.to_ascii_lowercase();
        if self.inner.trust.lock().unwrap().get(&id).is_none() {
            return Err(ClientError::UnknownDevice);
        }
        self.inner.state.lock().unwrap().wanted.insert(id.clone());
        self.inner.ensure_loop(&id);
        Ok(())
    }

    /// Where received files go from now on; None refuses files.
    pub fn set_receive_dir(&self, dir: Option<&Path>) {
        *self.inner.receive_dir.write().unwrap() = dir.map(Path::to_path_buf);
    }

    /// Turns one of this device's switches on or off, for one trusted device or (without one) as the default.
    /// Connected devices get the new map at once.
    pub fn set_feature(&self, device_id: Option<&str>, key: &str, on: bool) -> Result<(), ClientError> {
        if key.is_empty() || key.len() > 64 || !key.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') {
            return Err(ClientError::InvalidArgument("feature key"));
        }
        let targets: Vec<String> = match device_id {
            Some(id) => {
                let mut trust = self.inner.trust.lock().unwrap();
                let d = trust.get_mut(id).ok_or(ClientError::UnknownDevice)?;
                d.features.insert(key.into(), on);
                let id = d.device_id.clone();
                trust.save(self.inner.storage.as_ref()).map_err(ClientError::Storage)?;
                vec![id]
            }
            None => {
                self.inner.defaults.write().unwrap().set(key, on);
                self.inner.state.lock().unwrap().connected.keys().cloned().collect()
            }
        };
        for id in targets {
            self.inner.send_policy(&id);
        }
        Ok(())
    }

    /// A device found by the host's own discovery (Bonjour on iOS, or an address the person typed).
    pub fn add_discovered(&self, device_id: Option<&str>, name: &str, platform: Option<&str>, host: &str, port: u16) -> Result<(), ClientError> {
        let ip: IpAddr = host.trim().parse().map_err(|_| ClientError::InvalidArgument("host must be an IP address"))?;
        let port = if port == 0 { DEFAULT_PORT } else { port };
        let key = format!("host:{}", SocketAddr::new(ip, port));
        self.inner.discovered(key, device_id.map(str::to_string), name.to_string(), platform.map(str::to_string), vec![SocketAddr::new(ip, port)]);
        Ok(())
    }

    /// A device the host found itself has gone (its Bonjour service was removed).
    pub fn remove_discovered(&self, host: &str, port: u16) -> Result<(), ClientError> {
        let ip: IpAddr = host.trim().parse().map_err(|_| ClientError::InvalidArgument("host must be an IP address"))?;
        let port = if port == 0 { DEFAULT_PORT } else { port };
        self.inner.lost(&format!("host:{}", SocketAddr::new(ip, port)));
        Ok(())
    }

    /// This device's battery (None: no battery). Sent at once to connected devices that show Battery, and to each
    /// device when it connects.
    pub fn set_battery(&self, battery: Option<(u8, bool)>) {
        let battery = battery.map(|(level, charging)| (level.min(100), charging));
        let changed = {
            let mut b = self.inner.battery.lock().unwrap();
            let changed = *b != battery;
            *b = battery;
            changed
        };
        if changed {
            let connected: Vec<String> = self.inner.state.lock().unwrap().connected.keys().cloned().collect();
            for id in connected {
                self.inner.send_battery(&id);
            }
        }
    }

    /// Rings a connected device until someone stops it (`ring`), or stops it. Its answer arrives as `FindState`.
    pub fn find(&self, device_id: &str, ring: bool) -> Result<(), ClientError> {
        self.inner.check()?;
        let handle = if ring { self.inner.feature_session(device_id, "find_device")?.0 } else { self.inner.connected_session(device_id)? };
        let kind = if ring { "find.start" } else { "find.stop" };
        if handle.send_encrypted(kind, session::find_payload().into_bytes(), crate::crypto::uuid4()) {
            Ok(())
        } else {
            Err(ClientError::NotConnected)
        }
    }

    /// This device stopped ringing (the person pressed Stop): the device that rang it is told.
    pub fn find_stopped(&self, device_id: &str) -> Result<(), ClientError> {
        let handle = self.inner.connected_session(device_id)?;
        if handle.send_encrypted("find.stopped", session::find_payload().into_bytes(), crate::crypto::uuid4()) {
            Ok(())
        } else {
            Err(ClientError::NotConnected)
        }
    }

    /// Binary file frames with devices that show them (on by default). Off sends 24 KiB JSON chunks.
    pub fn set_fast_transfers(&self, on: bool) {
        self.inner.fast_transfers.store(on, Ordering::Relaxed);
        let connected: Vec<String> = self.inner.state.lock().unwrap().connected.keys().cloned().collect();
        for id in connected {
            self.inner.send_policy(&id);
        }
    }

    /// Dismisses a phone notification on the phone (`notifications.dismiss`).
    pub fn dismiss_notification(&self, device_id: &str, notification_id: &str) -> Result<(), ClientError> {
        self.inner.encrypted_to(device_id, "notifications", "notifications.dismiss", crate::notifications::dismiss_payload(notification_id))
    }

    /// Runs one of a phone notification's actions, with a reply where the action takes one (`notifications.action`).
    pub fn notification_action(&self, device_id: &str, notification_id: &str, token: &str, reply: Option<&str>) -> Result<(), ClientError> {
        if token.is_empty() || token.chars().count() > 64 || notification_id.is_empty() {
            return Err(ClientError::InvalidArgument("action"));
        }
        self.inner.encrypted_to(device_id, "notifications", "notifications.action", crate::notifications::action_payload(notification_id, token, reply))
    }

    /// Codes from messages and Also read codes in email, on this device.
    pub fn set_codes(&self, sms: bool, email: bool) {
        *self.inner.codes.lock().unwrap() = (sms, email);
    }

    /// Asks the phone to show its "link this phone" prompt (`codes.link_request`).
    pub fn codes_link_request(&self, device_id: &str) -> Result<(), ClientError> {
        self.inner.encrypted_to(device_id, crate::notifications::SMS_CODES, "codes.link_request", serde_json::json!({"version": 1}).to_string())
    }

    /// Whether the Bluetooth LE advertisement the phone asked for started (`codes.advertise_result`).
    pub fn codes_advertise_result(&self, device_id: &str, service_uuid: &str, ok: bool, reason: Option<&str>) -> Result<(), ClientError> {
        if !crate::crypto::is_uuid(service_uuid) {
            return Err(ClientError::InvalidArgument("service UUID"));
        }
        self.inner.encrypted_to(device_id, crate::notifications::SMS_CODES, "codes.advertise_result", crate::notifications::advertise_result_payload(service_uuid, ok, reason))
    }

    /// This device's activity (the host samples it every two seconds). Phones that show device presence get it when
    /// it changes and every ten seconds, so they can send alerts to the device in use.
    pub fn set_presence(&self, presence: crate::notifications::Presence) {
        *self.inner.activity.lock().unwrap() = presence;
        let connected: Vec<String> = self.inner.state.lock().unwrap().connected.keys().cloned().collect();
        for id in connected {
            self.inner.send_presence(&id, false);
        }
    }

    /// Tests and the scripted peer only (not in the C ABI): sends what a phone sends, so a desktop client can be
    /// tested against it. `payload` is the JSON plaintext.
    #[doc(hidden)]
    pub fn send_as_phone_for_tests(&self, device_id: &str, kind: &str, payload: &str) -> Result<(), ClientError> {
        let (kind, feature): (&'static str, &str) = match kind {
            "notifications.post" => ("notifications.post", "notifications"),
            "notifications.remove" => ("notifications.remove", "notifications"),
            "codes.status" => ("codes.status", crate::notifications::SMS_CODES),
            "codes.advertise" => ("codes.advertise", crate::notifications::SMS_CODES),
            "codes.advertise_stop" => ("codes.advertise_stop", crate::notifications::SMS_CODES),
            _ => return Err(ClientError::InvalidArgument("kind")),
        };
        self.inner.encrypted_to(device_id, feature, kind, payload.to_string())
    }

    /// Tests and recorded vectors only: chunks of this many bytes (0: the protocol's 24 KiB or 256 KiB).
    #[doc(hidden)]
    pub fn set_chunk_size_for_tests(&self, bytes: usize) {
        self.inner.chunk_size.store(bytes, Ordering::Relaxed);
    }

    /// The network changed: try every trusted device that is not connected again, from the fast delays.
    pub fn network_changed(&self) {
        let loops: Vec<Arc<Notify>> = self.inner.state.lock().unwrap().loops.values().cloned().collect();
        for n in loops {
            n.notify_one();
        }
    }

    /// Everything the host shows, for its first screen and after a `Dropped` event.
    pub fn snapshot(&self) -> Value {
        self.inner.snapshot()
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.stop();
    }
}

async fn bind(port: u16) -> std::io::Result<(TcpListener, Option<TcpListener>)> {
    let v4 = TcpListener::bind(SocketAddr::from(([0, 0, 0, 0], port))).await?;
    let port = v4.local_addr()?.port();
    // IPv6 as well where the system keeps the two apart (Windows); where it does not, this bind fails quietly.
    let v6 = TcpListener::bind(SocketAddr::from(([0u16; 8], port))).await.ok();
    Ok((v4, v6))
}

impl Inner {
    fn arc(&self) -> Arc<Inner> {
        self.me.upgrade().expect("client alive")
    }

    fn next_id(&self) -> u64 {
        self.ids.fetch_add(1, Ordering::Relaxed)
    }

    fn port(&self) -> u16 {
        self.port.load(Ordering::Relaxed) as u16
    }

    fn check(&self) -> Result<(), ClientError> {
        if self.stopped.load(Ordering::SeqCst) {
            Err(ClientError::Stopped)
        } else {
            Ok(())
        }
    }

    fn emit(&self, event: Event) {
        self.events.push(event);
    }

    fn policy_for(&self, device_id: &str) -> FeatureMap {
        let defaults = self.defaults.read().unwrap().clone();
        let mut policy = match self.trust.lock().unwrap().get(device_id) {
            Some(d) => d.policy(&defaults),
            None => defaults,
        };
        // A capability, not a setting: this client reads binary frames whenever it supports them.
        policy.set(fast::FEATURE, self.fast_transfers.load(Ordering::Relaxed));
        policy
    }

    /// The session of a connected device, whatever its switches.
    fn connected_session(&self, device_id: &str) -> Result<Handle, ClientError> {
        let id = device_id.to_ascii_lowercase();
        let st = self.state.lock().unwrap();
        let session = st.connected.get(&id).ok_or(ClientError::NotConnected)?;
        Ok(st.sessions.get(session).ok_or(ClientError::NotConnected)?.handle.clone())
    }

    fn send_battery(&self, device_id: &str) {
        let Some((level, charging)) = *self.battery.lock().unwrap() else { return };
        if let Ok((handle, _)) = self.feature_session(device_id, "battery") {
            handle.send_encrypted("battery.update", session::battery_payload(level, charging).into_bytes(), crate::crypto::uuid4());
        }
    }

    fn feature_session(&self, device_id: &str, feature: &str) -> Result<(Handle, String), ClientError> {
        let id = device_id.to_ascii_lowercase();
        let st = self.state.lock().unwrap();
        let session = st.connected.get(&id).ok_or(ClientError::NotConnected)?;
        let handle = st.sessions.get(session).ok_or(ClientError::NotConnected)?.handle.clone();
        let remote_on = st.remote.get(&id).is_some_and(|r| r.get(feature));
        drop(st);
        if !remote_on || !self.policy_for(&id).get(feature) {
            return Err(ClientError::FeatureOff);
        }
        Ok((handle, id))
    }

    fn send_policy(&self, device_id: &str) {
        let (handle, remote) = {
            let st = self.state.lock().unwrap();
            let Some(s) = st.connected.get(device_id) else { return };
            let Some(l) = st.sessions.get(s) else { return };
            (l.handle.clone(), st.remote.get(device_id).cloned())
        };
        handle.send_features();
        if let Some(remote) = remote {
            self.emit(Event::Features { device_id: device_id.into(), local: self.policy_for(device_id), remote });
        }
    }

    fn expire(&self, message_id: String, after: Duration) {
        let me = self.arc();
        self.rt.spawn(async move {
            tokio::time::sleep(after).await;
            let pending = me.state.lock().unwrap().pending.remove(&message_id);
            if let Some((request, device_id, what)) = pending {
                me.emit(answer(what, request, device_id, SendStatus::TimedOut));
            }
        });
    }

    fn pairing_session(&self, pairing: u64) -> Option<Handle> {
        let st = self.state.lock().unwrap();
        let session = match st.pairing.as_ref().filter(|a| a.id == pairing) {
            Some(a) => a.adopted.or(a.session)?,
            None => pairing,
        };
        st.sessions.get(&session).filter(|l| !l.authenticated).map(|l| l.handle.clone())
    }

    fn register(&self, session: u64, handle: Handle, dialled: bool, attempt: Option<u64>, device_id: Option<String>, watch: Option<mpsc::UnboundedSender<Outcome>>) {
        let live = Live { handle, device_id, dialled, authenticated: false, code_shown: false, replaced: false, attempt, watch };
        self.state.lock().unwrap().sessions.insert(session, live);
    }

    async fn accept_loop(self: Arc<Self>, listener: TcpListener) {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            };
            if self.stopped.load(Ordering::SeqCst) {
                return;
            }
            let pending = self.state.lock().unwrap().sessions.values().filter(|l| !l.authenticated).count();
            if pending >= MAX_PENDING {
                continue;
            }
            let session = self.next_id();
            let handle = session::spawn(session, stream, Role::Accept, self.clone());
            self.register(session, handle, false, None, None, None);
        }
    }

    async fn dial(addrs: &[SocketAddr]) -> Option<TcpStream> {
        for addr in addrs {
            if let Ok(Ok(s)) = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await {
                return Some(s);
            }
        }
        None
    }

    /// The person's pairing: dial, and while the other end has not allowed pairing, dial again every 3 s.
    async fn attempt_loop(self: Arc<Self>, id: u64) {
        let (tx, mut rx) = mpsc::unbounded_channel::<Outcome>();
        let mut waiting_since: Option<Instant> = None;
        let finish = |me: &Arc<Inner>, reason: &str| {
            let taken = me.state.lock().unwrap().pairing.take_if(|a| a.id == id);
            if let Some(a) = taken {
                me.emit(Event::PairingFinished { pairing: id, device_id: a.expected.clone(), name: Some(a.name.clone()), ok: false, reason: reason.into() });
            }
        };
        loop {
            let (addrs, wake, cancelled, busy) = {
                let st = self.state.lock().unwrap();
                let Some(a) = st.pairing.as_ref().filter(|a| a.id == id) else { return };
                // Dial only when neither this end's own dial nor an answered crossed offer is still running.
                let busy = a.adopted.is_some() || a.session.is_some_and(|s| st.sessions.contains_key(&s));
                (a.addrs.clone(), a.wake.clone(), a.cancelled, busy)
            };
            if cancelled {
                return finish(&self, "cancelled");
            }
            if !busy {
                let Some(stream) = Self::dial(&addrs).await else { return finish(&self, "unreachable") };
                let session = self.next_id();
                let handle = session::spawn(session, stream, Role::Pair, self.clone());
                let expected = self.state.lock().unwrap().pairing.as_ref().and_then(|a| a.expected.clone());
                self.register(session, handle, true, Some(id), expected, Some(tx.clone()));
                match self.state.lock().unwrap().pairing.as_mut().filter(|a| a.id == id) {
                    Some(a) => a.session = Some(session),
                    None => return,
                }
            }
            // The outcome of this dial; a wake means a cancel, or the crossed offer this end answered ended.
            let outcome = tokio::select! {
                o = rx.recv() => o,
                _ = wake.notified() => None,
            };
            let (cancelled, adopted) = {
                let st = self.state.lock().unwrap();
                match st.pairing.as_ref().filter(|a| a.id == id) {
                    Some(a) => (a.cancelled, a.adopted.is_some()),
                    None => return,
                }
            };
            if cancelled {
                return finish(&self, "cancelled");
            }
            match outcome {
                Some(Outcome::Authenticated) => {
                    self.state.lock().unwrap().pairing.take_if(|a| a.id == id);
                    return;
                }
                // This end answered the other device's own offer instead: wait for that session.
                Some(Outcome::Closed { .. }) if adopted => continue,
                Some(Outcome::Closed { reason, answered, .. }) if reason == "cancelled_remote:not_armed" && !answered => {
                    if waiting_since.is_none() {
                        waiting_since = Some(Instant::now());
                        let name = self.state.lock().unwrap().pairing.as_ref().map(|a| a.name.clone()).unwrap_or_default();
                        self.emit(Event::PairingWaiting { pairing: id, name });
                    }
                    if waiting_since.is_some_and(|t| t.elapsed() >= ALLOW_WAIT) {
                        return finish(&self, "not_allowed");
                    }
                    tokio::select! {
                        _ = tokio::time::sleep(ALLOW_RETRY) => {}
                        _ = wake.notified() => {}
                    }
                }
                Some(Outcome::Closed { reason, .. }) => return finish(&self, &reason),
                None => {}
            }
        }
    }

    /// Ends a pairing the person replaced with a new one, without an event.
    fn finish_attempt_quietly(&self, a: Attempt) {
        let st = self.state.lock().unwrap();
        for s in [a.session, a.adopted].into_iter().flatten() {
            if let Some(l) = st.sessions.get(&s).filter(|l| !l.authenticated) {
                l.handle.close("cancelled");
            }
        }
        a.wake.notify_one();
    }

    /// Hashes one device's files in order and hands each to its session, which offers them one at a time.
    async fn hash_loop(self: Arc<Self>, device_id: String, mut jobs: mpsc::UnboundedReceiver<HashJob>) {
        while let Some(job) = jobs.recv().await {
            let HashJob { transfer, path, name, mime } = job;
            let fail = |reason: &str| {
                let mut st = self.state.lock().unwrap();
                st.transfers.remove(&transfer);
                // Cancelled meanwhile: that already said so.
                if st.unhanded.remove(&transfer) {
                    drop(st);
                    self.emit(Event::FileFailed { transfer, device_id: device_id.clone(), incoming: false, name: name.clone(), reason: reason.into() });
                }
            };
            // Cancelled before its turn.
            if !self.state.lock().unwrap().unhanded.contains(&transfer) {
                continue;
            }
            let hashed = {
                let path = path.clone();
                tokio::task::spawn_blocking(move || crate::transfer::hash_file(&path)).await
            };
            let Ok(Ok((sha256, size))) = hashed else {
                fail("unreadable");
                continue;
            };
            if size > crate::transfer::MAX_FILE {
                fail("unreadable");
                continue;
            }
            let file = OutgoingFile { transfer, path, name: name.clone(), mime, size, sha256 };
            match self.feature_session(&device_id, "files") {
                Ok((handle, _)) => {
                    // Handed over under the lock, so a cancel goes either here or to the session, never neither.
                    let mut st = self.state.lock().unwrap();
                    if !st.unhanded.remove(&transfer) {
                        continue;
                    }
                    if !handle.send_file(file) {
                        st.transfers.remove(&transfer);
                        drop(st);
                        self.emit(Event::FileFailed { transfer, device_id: device_id.clone(), incoming: false, name: name.clone(), reason: "not_connected".into() });
                    }
                }
                Err(ClientError::NotConnected) => fail("not_connected"),
                Err(_) => fail("rejected"),
            }
        }
    }

    fn ensure_loop(&self, device_id: &str) {
        let mut st = self.state.lock().unwrap();
        // A share extension keeps only the devices it was asked for connected.
        if self.manual && !st.wanted.contains(device_id) {
            return;
        }
        if let Some(n) = st.loops.get(device_id) {
            n.notify_one();
            return;
        }
        let notify = Arc::new(Notify::new());
        st.loops.insert(device_id.to_string(), notify.clone());
        drop(st);
        let me = self.arc();
        let id = device_id.to_string();
        self.rt.spawn(async move { me.reconnect_loop(id, notify).await });
    }

    fn addresses_for(&self, device_id: &str) -> Vec<SocketAddr> {
        let mut out: Vec<SocketAddr> = Vec::new();
        if let Some(d) = self.trust.lock().unwrap().get(device_id) {
            for a in &d.addresses {
                if let Ok(ip) = a.host.parse::<IpAddr>() {
                    out.push(SocketAddr::new(ip, a.port));
                }
            }
        }
        for d in self.state.lock().unwrap().discovered.values().filter(|d| d.device_id.as_deref() == Some(device_id)) {
            for a in &d.addrs {
                if !out.contains(a) {
                    out.push(*a);
                }
            }
        }
        out
    }

    /// Keeps one trusted device connected: try at once, then on the apps' schedule; discovery, a network change
    /// or a drop starts the fast delays again.
    async fn reconnect_loop(self: Arc<Self>, device_id: String, notify: Arc<Notify>) {
        let mut attempts = 0usize;
        let mut fast_since = Instant::now();
        let mut first = true;
        loop {
            if self.stopped.load(Ordering::SeqCst) || self.trust.lock().unwrap().get(&device_id).is_none() {
                self.state.lock().unwrap().loops.remove(&device_id);
                return;
            }
            if self.state.lock().unwrap().connected.contains_key(&device_id) {
                notify.notified().await;
                attempts = 0;
                fast_since = Instant::now();
                first = false;
                continue;
            }
            if !first {
                let delay = if fast_since.elapsed() >= FAST_PHASE { SLOW_DELAY } else { Duration::from_secs(FAST_DELAYS[attempts.min(FAST_DELAYS.len() - 1)]) };
                tokio::select! {
                    _ = tokio::time::sleep(delay) => {}
                    _ = notify.notified() => { attempts = 0; fast_since = Instant::now(); }
                }
                if self.state.lock().unwrap().connected.contains_key(&device_id) {
                    continue;
                }
            }
            first = false;
            let addrs = self.addresses_for(&device_id);
            let mut connected = false;
            for addr in addrs {
                if self.state.lock().unwrap().connected.contains_key(&device_id) {
                    connected = true;
                    break;
                }
                let Ok(Ok(stream)) = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr)).await else { continue };
                let (tx, mut rx) = mpsc::unbounded_channel();
                let session = self.next_id();
                let handle = session::spawn(session, stream, Role::Reconnect { device_id: device_id.clone() }, self.clone());
                self.register(session, handle, true, None, Some(device_id.clone()), Some(tx));
                if let Some(Outcome::Authenticated) = rx.recv().await {
                    connected = true;
                    break;
                }
            }
            if !connected {
                attempts += 1;
            }
        }
    }

    fn discovered(&self, key: String, device_id: Option<String>, name: String, platform: Option<String>, addrs: Vec<SocketAddr>) {
        let device_id = device_id.filter(|d| crate::crypto::is_uuid(d)).map(|d| d.to_ascii_lowercase());
        if device_id.as_deref() == Some(self.local.device_id.as_str()) || addrs.is_empty() {
            return;
        }
        let name = session::sanitized_name(Some(&name));
        let first = addrs[0];
        {
            let mut st = self.state.lock().unwrap();
            st.discovered.insert(key, Discovered { device_id: device_id.clone(), name: name.clone(), platform: platform.clone(), addrs });
        }
        self.emit(Event::Found { device_id: device_id.clone(), name, platform, host: host_text(first.ip()), port: first.port() });
        if let Some(id) = device_id {
            let trusted = {
                let mut trust = self.trust.lock().unwrap();
                match trust.get_mut(&id) {
                    Some(d) => {
                        d.remember(KnownAddress { host: host_text(first.ip()), port: first.port(), source: "discovery".into(), last_seen_ms: now_ms() });
                        true
                    }
                    None => false,
                }
            };
            if trusted {
                self.ensure_loop(&id);
            }
        }
    }

    pub(crate) fn lost(&self, key: &str) {
        let removed = self.state.lock().unwrap().discovered.remove(key);
        if let Some(d) = removed {
            if let Some(a) = d.addrs.first() {
                self.emit(Event::Lost { device_id: d.device_id, host: host_text(a.ip()), port: a.port() });
            }
        }
    }

    #[cfg(feature = "mdns")]
    pub(crate) fn found(&self, key: String, device_id: Option<String>, name: String, platform: Option<String>, addrs: Vec<SocketAddr>) {
        self.discovered(key, device_id, name, platform, addrs);
    }

    fn snapshot(&self) -> Value {
        let st = self.state.lock().unwrap();
        let trust = self.trust.lock().unwrap();
        let defaults = self.defaults.read().unwrap().clone();
        let armed = st.armed_until.map(|t| t.saturating_duration_since(Instant::now()).as_secs()).unwrap_or(0);
        let devices: Vec<Value> = trust
            .all()
            .iter()
            .map(|d| {
                json!({
                    "deviceId": d.device_id,
                    "name": d.name,
                    "platform": d.platform,
                    "connected": st.connected.contains_key(&d.device_id),
                    "pairedAtMs": d.paired_at_ms,
                    "lastConnectedMs": d.last_connected_ms,
                    "local": d.policy(&defaults).to_json(),
                    "remote": st.remote.get(&d.device_id).map(FeatureMap::to_json),
                    "battery": st.battery.get(&d.device_id).map(|(level, charging)| json!({"level": level, "charging": charging})),
                    "ringing": st.ringing.contains(&d.device_id),
                })
            })
            .collect();
        let mut seen = HashSet::new();
        let nearby: Vec<Value> = st
            .discovered
            .values()
            .filter(|d| d.device_id.as_ref().is_none_or(|id| seen.insert(id.clone())))
            .map(|d| {
                json!({
                    "deviceId": d.device_id,
                    "name": d.name,
                    "platform": d.platform,
                    "host": d.addrs.first().map(|a| host_text(a.ip())),
                    "port": d.addrs.first().map(|a| a.port()),
                    "trusted": d.device_id.as_ref().is_some_and(|id| trust.get(id).is_some()),
                })
            })
            .collect();
        json!({
            "deviceId": self.local.device_id,
            "name": self.local.name(),
            "platform": self.platform,
            "port": self.port(),
            "allowPairingSeconds": armed,
            "defaults": defaults.to_json(),
            "devices": devices,
            "nearby": nearby,
        })
    }

    fn platform_hint(&self, device_id: &str) -> Option<String> {
        self.state.lock().unwrap().discovered.values().find(|d| d.device_id.as_deref() == Some(device_id)).and_then(|d| d.platform.clone())
    }

    fn listening_port_of(&self, device_id: &str, ip: IpAddr) -> u16 {
        let st = self.state.lock().unwrap();
        st.discovered
            .values()
            .filter(|d| d.device_id.as_deref() == Some(device_id))
            .flat_map(|d| d.addrs.iter())
            .find(|a| same_host(a.ip(), ip))
            .map(|a| a.port())
            .unwrap_or(DEFAULT_PORT)
    }
}

impl session::Host for Inner {
    fn local(&self) -> &Local {
        &self.local
    }

    fn next_id(&self) -> u64 {
        Inner::next_id(self)
    }

    fn receive_dir(&self) -> Option<PathBuf> {
        self.receive_dir.read().unwrap().clone()
    }

    fn chunk_size(&self, fast: bool) -> usize {
        match self.chunk_size.load(Ordering::Relaxed) {
            0 if fast => fast::CHUNK,
            0 => crate::transfer::FILE_CHUNK,
            n if fast => n.min(fast::MAX_PLAINTEXT),
            n => n.min(crate::transfer::FILE_CHUNK),
        }
    }

    fn pin(&self, device_id: &str) -> Option<String> {
        self.trust.lock().unwrap().get(device_id).map(|d| d.identity_key.clone())
    }

    fn admit(&self, offer: &Offer) -> Admission {
        let mut st = self.state.lock().unwrap();
        let now = Instant::now();
        while st.offers.front().is_some_and(|t| now.duration_since(*t) > Duration::from_secs(60)) {
            st.offers.pop_front();
        }
        // Crossed pairing: both people started pairing with each other. The dial from the lower device ID goes
        // on; the higher end answers it (its own dial is parked), the lower end refuses without a card.
        let crossed = st.pairing.as_ref().filter(|a| {
            !a.cancelled
                && a.expected.as_deref() == Some(offer.device_id)
                && a.addrs.iter().any(|x| same_host(x.ip(), offer.peer.ip()))
                && !a.session.and_then(|s| st.sessions.get(&s)).is_some_and(|l| l.code_shown)
        });
        if let Some((attempt, own)) = crossed.map(|a| (a.id, a.session)) {
            if self.local.device_id.as_str() < offer.device_id {
                return Admission::Refuse("not_armed");
            }
            if st.offers.len() >= OFFERS_PER_MINUTE {
                return Admission::Refuse("rate_limited");
            }
            st.offers.push_back(now);
            if let Some(a) = st.pairing.as_mut() {
                a.adopted = Some(offer.session);
            }
            if let Some(l) = st.sessions.get_mut(&offer.session) {
                l.attempt = Some(attempt);
            }
            if let Some(l) = own.and_then(|s| st.sessions.get(&s)) {
                l.handle.close("crossed");
            }
            return Admission::Answer;
        }
        // The device this end is already pairing with dialled too, but this end's pairing is past the answer (its code
        // shows): its offer is redundant. Refuse it as busy, with no "wants to pair" card for a device mid-pairing.
        if st.pairing.as_ref().is_some_and(|a| !a.cancelled && a.expected.as_deref() == Some(offer.device_id)) {
            return Admission::Refuse("busy");
        }
        let busy = st.incoming_pairing.is_some_and(|s| s != offer.session && st.sessions.contains_key(&s)) || st.pairing.as_ref().is_some_and(|a| !a.cancelled);
        let armed = st.armed_until.is_some_and(|t| t > now);
        if !armed {
            let card = st.requests.get(offer.device_id).is_none_or(|t| now.duration_since(*t) >= REQUEST_SPACING);
            if card {
                st.requests.insert(offer.device_id.to_string(), now);
                drop(st);
                self.emit(Event::PairingRequest { device_id: offer.device_id.to_string(), name: offer.name.to_string() });
            }
            return Admission::Refuse("not_armed");
        }
        if busy {
            return Admission::Refuse("busy");
        }
        if st.offers.len() >= OFFERS_PER_MINUTE {
            return Admission::Refuse("rate_limited");
        }
        st.offers.push_back(now);
        st.incoming_pairing = Some(offer.session);
        Admission::Answer
    }

    fn policy(&self, device_id: &str) -> FeatureMap {
        self.policy_for(device_id)
    }

    fn authenticated(&self, auth: Authenticated) -> bool {
        let device = auth.device_id.clone();
        let (attempt, watch) = {
            let mut st = self.state.lock().unwrap();
            // One session per device: when both ends dialled, keep the one dialled by the lower device ID (the newer
            // one if the same side dialled both), unless the live one has gone silent; then the new one wins.
            if let Some(&old) = st.connected.get(&device) {
                if old != auth.session {
                    if let Some(o) = st.sessions.get(&old) {
                        let dialler = |dialled: bool| if dialled { self.local.device_id.clone() } else { device.clone() };
                        let silent = o.handle.silent_for() > STALE_SESSION;
                        let (old_d, new_d) = (dialler(o.dialled), dialler(auth.dialled));
                        let keep_new = silent || old_d == new_d || new_d < old_d;
                        if !keep_new {
                            return false;
                        }
                        o.handle.close("replaced");
                    }
                    if let Some(o) = st.sessions.get_mut(&old) {
                        o.replaced = true;
                    }
                }
            }
            st.connected.insert(device.clone(), auth.session);
            let live = st.sessions.get_mut(&auth.session);
            let (attempt, watch) = match live {
                Some(l) => {
                    l.authenticated = true;
                    l.device_id = Some(device.clone());
                    (l.attempt, l.watch.clone())
                }
                None => (None, None),
            };
            if auth.paired {
                st.armed_until = None;
                if st.incoming_pairing == Some(auth.session) {
                    st.incoming_pairing = None;
                }
            }
            (attempt, watch)
        };
        let host = host_text(auth.peer.ip());
        let port = if auth.dialled { auth.peer.port() } else { self.listening_port_of(&device, auth.peer.ip()) };
        let address = KnownAddress { host, port, source: if auth.dialled { "outbound" } else { "inbound" }.into(), last_seen_ms: now_ms() };
        let saved = {
            let mut trust = self.trust.lock().unwrap();
            if auth.paired {
                let mut d = TrustedDevice {
                    device_id: device.clone(),
                    name: auth.name.clone(),
                    platform: self.platform_hint(&device),
                    identity_key: auth.identity_key.clone(),
                    protocol: 2,
                    paired_at_ms: now_ms(),
                    last_connected_ms: Some(now_ms()),
                    addresses: vec![],
                    features: HashMap::new(),
                };
                d.remember(address);
                trust.put(d);
            } else if let Some(d) = trust.get_mut(&device) {
                d.name = auth.name.clone();
                d.last_connected_ms = Some(now_ms());
                d.remember(address);
                if d.platform.is_none() {
                    d.platform = self.platform_hint(&device);
                }
            }
            trust.save(self.storage.as_ref())
        };
        if let Err(e) = saved {
            self.emit(Event::Error { text: format!("could not save trusted devices: {e}") });
        }
        if auth.paired {
            self.emit(Event::TrustChanged { device_id: device.clone(), name: auth.name.clone(), trusted: true });
            self.emit(Event::PairingFinished { pairing: attempt.unwrap_or(auth.session), device_id: Some(device.clone()), name: Some(auth.name.clone()), ok: true, reason: "paired".into() });
        }
        self.emit(Event::Connected { device_id: device.clone(), name: auth.name });
        if let Some(w) = watch {
            let _ = w.send(Outcome::Authenticated);
        }
        // An attempt that adopted the other device's offer hears about it through its own channel.
        if let Some(a) = attempt {
            let st = self.state.lock().unwrap();
            if let Some(p) = st.pairing.as_ref().filter(|p| p.id == a && p.adopted == Some(auth.session)) {
                p.wake.notify_one();
            }
        }
        if auth.paired {
            self.state.lock().unwrap().pairing.take_if(|p| Some(p.id) == attempt);
        }
        self.ensure_loop(&device);
        true
    }

    fn event(&self, event: session::Event) {
        match event {
            session::Event::Code { session, device_id, name, code } => {
                let pairing = {
                    let mut st = self.state.lock().unwrap();
                    let attempt = st.sessions.get_mut(&session).map(|l| {
                        l.code_shown = true;
                        l.device_id = Some(device_id.clone());
                        l.attempt
                    });
                    attempt.flatten().unwrap_or(session)
                };
                self.emit(Event::PairingCode { pairing, device_id, name, code });
            }
            session::Event::Features { device_id, features, .. } => {
                let battery = features.get("battery");
                self.state.lock().unwrap().remote.insert(device_id.clone(), features.clone());
                self.emit(Event::Features { local: self.policy_for(&device_id), device_id: device_id.clone(), remote: features });
                if battery {
                    self.send_battery(&device_id);
                }
                self.send_presence(&device_id, true);
            }
            session::Event::Battery { device_id, level, charging } => {
                self.state.lock().unwrap().battery.insert(device_id.clone(), (level, charging));
                self.emit(Event::Battery { device_id, level, charging });
            }
            session::Event::Find { device_id, ring } => self.emit(Event::FindRequested { device_id, ring }),
            session::Event::Payload { device_id, kind, plain } => self.payload(device_id, kind, &plain),
            session::Event::FindAck { device_id, ringing } => {
                {
                    let mut st = self.state.lock().unwrap();
                    if ringing {
                        st.ringing.insert(device_id.clone());
                    } else {
                        st.ringing.remove(&device_id);
                    }
                }
                self.emit(Event::FindState { device_id, ringing });
            }
            session::Event::Clipboard { device_id, text, html, .. } => self.emit(Event::Clipboard { device_id, text, html }),
            session::Event::ClipboardResult { message_id, delivered, .. } => {
                let pending = self.state.lock().unwrap().pending.remove_entry(&message_id);
                match pending {
                    Some((_, (request, device_id, Pending::Clipboard))) => {
                        self.emit(Event::ClipboardSent { request, device_id, status: if delivered { SendStatus::Delivered } else { SendStatus::Rejected } });
                    }
                    Some((k, v)) => {
                        self.state.lock().unwrap().pending.insert(k, v);
                    }
                    None => {}
                }
            }
            session::Event::Ping { device_id } => self.emit(Event::Ping { device_id }),
            session::Event::PingAck { message_id, .. } => {
                let pending = self.state.lock().unwrap().pending.remove_entry(&message_id);
                match pending {
                    Some((_, (request, device_id, Pending::Ping))) => self.emit(Event::PingResult { request, device_id, status: SendStatus::Delivered }),
                    Some((k, v)) => {
                        self.state.lock().unwrap().pending.insert(k, v);
                    }
                    None => {}
                }
            }
            session::Event::QuickResult { device_id, request_id, accepted, opened } => {
                let mut st = self.state.lock().unwrap();
                // Only the device the link went to can answer for it.
                if st.pending.get(&request_id).is_some_and(|p| p.2 == Pending::Link && p.1 == device_id) {
                    let (request, device_id, _) = st.pending.remove(&request_id).unwrap();
                    drop(st);
                    self.emit(Event::LinkSent { request, device_id, status: if accepted { SendStatus::Delivered } else { SendStatus::Rejected }, opened });
                }
            }
            session::Event::Link { device_id, url } => self.emit(Event::Link { device_id, url }),
            session::Event::FileIncoming { transfer, device_id, name, size, mime } => {
                self.state.lock().unwrap().transfers.insert(transfer, device_id.clone());
                self.emit(Event::FileIncoming { transfer, device_id, name, size, mime });
            }
            session::Event::FileProgress { transfer, device_id, incoming, bytes, total } => self.emit(Event::FileProgress { transfer, device_id, incoming, bytes, total }),
            session::Event::FileDone { transfer, device_id, incoming, name, path, size } => {
                self.state.lock().unwrap().transfers.remove(&transfer);
                self.emit(Event::FileDone { transfer, device_id, incoming, name, path, size });
            }
            session::Event::FileFailed { transfer, device_id, incoming, name, reason } => {
                self.state.lock().unwrap().transfers.remove(&transfer);
                self.emit(Event::FileFailed { transfer, device_id, incoming, name, reason });
            }
            session::Event::Closed { session, device_id, reason, authenticated, paired, answered } => self.closed(session, device_id, reason, authenticated, paired, answered),
        }
    }
}

impl Inner {
    fn closed(&self, session: u64, device_id: Option<String>, reason: String, authenticated: bool, paired: bool, answered: bool) {
        let mut st = self.state.lock().unwrap();
        let Some(live) = st.sessions.remove(&session) else { return };
        let mut disconnected = None;
        if let Some(id) = device_id.clone().or(live.device_id.clone()) {
            if st.connected.get(&id) == Some(&session) {
                st.connected.remove(&id);
                st.remote.remove(&id);
                st.battery.remove(&id);
                st.ringing.remove(&id);
                st.presence.remove(&id);
                disconnected = Some(id);
            }
        }
        if st.incoming_pairing == Some(session) {
            st.incoming_pairing = None;
        }
        let failed: Vec<(String, u64, String, Pending)> = match &disconnected {
            Some(id) => st.pending.iter().filter(|(_, v)| &v.1 == id).map(|(k, v)| (k.clone(), v.0, v.1.clone(), v.2)).collect(),
            None => vec![],
        };
        for (k, ..) in &failed {
            st.pending.remove(k);
        }
        let adopted_by = live.attempt.and_then(|a| st.pairing.as_ref().filter(|p| p.id == a && p.adopted == Some(session)).map(|p| p.wake.clone()));
        let loop_notify = disconnected.as_ref().and_then(|id| st.loops.get(id).cloned());
        drop(st);
        if let Some(w) = &live.watch {
            let _ = w.send(Outcome::Closed { reason: reason.clone(), answered });
        }
        if let Some(wake) = adopted_by {
            // The other device's own offer that this end answered ended: before its code, the parked pairing
            // goes on; after it, the pairing is over.
            if live.code_shown {
                self.emit(Event::PairingFinished { pairing: live.attempt.unwrap(), device_id: device_id.clone(), name: None, ok: false, reason: reason.clone() });
                self.state.lock().unwrap().pairing.take_if(|p| Some(p.id) == live.attempt);
            } else if let Some(a) = self.state.lock().unwrap().pairing.as_mut().filter(|p| Some(p.id) == live.attempt) {
                a.adopted = None;
            }
            wake.notify_one();
        }
        for (_, request, device, what) in failed {
            self.emit(answer(what, request, device, SendStatus::Failed));
        }
        // An offer this end answered that ended before pairing finished.
        if !authenticated && paired && answered && !live.dialled && live.attempt.is_none() {
            self.emit(Event::PairingFinished { pairing: session, device_id: device_id.clone(), name: None, ok: false, reason: reason.clone() });
        }
        if let Some(id) = disconnected {
            if !live.replaced {
                self.emit(Event::Disconnected { device_id: id.clone(), reason });
            }
            if let Some(n) = loop_notify {
                n.notify_one();
            }
        }
    }
}

/// Notifications, codes and presence (docs/session-client.md).
impl Inner {
    fn encrypted_to(&self, device_id: &str, feature: &str, kind: &'static str, plaintext: String) -> Result<(), ClientError> {
        self.check()?;
        let (handle, _) = self.feature_session(device_id, feature)?;
        if handle.send_encrypted(kind, plaintext.into_bytes(), crate::crypto::uuid4()) {
            Ok(())
        } else {
            Err(ClientError::NotConnected)
        }
    }

    /// presence.state to one device that shows device presence at both ends: when the state changed, every ten
    /// seconds as a keepalive (the phone forgets a sample after 20), or at once (`force`, after its features arrive).
    fn send_presence(&self, device_id: &str, force: bool) {
        use crate::notifications::{presence_payload, Presence, PRESENCE};
        let Ok((handle, _)) = self.feature_session(device_id, PRESENCE) else { return };
        let presence = *self.activity.lock().unwrap();
        let payload = {
            let mut st = self.state.lock().unwrap();
            let Some(&session) = st.connected.get(device_id) else { return };
            let entry = st.presence.entry(device_id.to_string()).or_insert((session, 0, Instant::now() - Duration::from_secs(60), Presence::Unknown));
            if entry.0 != session {
                *entry = (session, 0, Instant::now() - Duration::from_secs(60), Presence::Unknown);
            }
            // Active idle seconds change every sample; the class (active, idle, locked) is what counts as a change.
            let class = |p: Presence| match p {
                Presence::Input { idle } if idle < 120 => 0,
                Presence::Input { .. } => 1,
                Presence::Locked => 2,
                Presence::Unknown => 3,
            };
            let due = force || entry.1 == 0 || class(entry.3) != class(presence) || entry.2.elapsed() >= Duration::from_secs(10);
            if !due {
                return;
            }
            entry.1 += 1;
            entry.2 = Instant::now();
            entry.3 = presence;
            presence_payload(entry.1, presence)
        };
        handle.send_encrypted("presence.state", payload.into_bytes(), crate::crypto::uuid4());
    }

    /// A notification or codes message the session opened.
    fn payload(&self, device_id: String, kind: &str, plain: &[u8]) {
        use crate::notifications as n;
        match kind {
            "notifications.post" => {
                let routing = self.policy_for(&device_id).get(n::ROUTING) && self.state.lock().unwrap().remote.get(&device_id).is_some_and(|r| r.get(n::ROUTING));
                let Some(mut notification) = n::decode_post(plain, routing) else { return };
                let (sms, email) = *self.codes.lock().unwrap();
                if sms {
                    let fields = bridgey_codes::NotificationFields {
                        package_name: notification.package_name.clone(),
                        sms_default_app: notification.sms_default_app,
                        redacted: notification.redacted,
                        text: notification.text.clone(),
                        email_app: notification.email_app,
                        preview: notification.preview.clone(),
                        email_codes: email,
                    };
                    notification.code = crate::codes::find(&fields, &notification.title, &notification.application_name);
                }
                self.emit(Event::Notification { device_id, notification: Box::new(notification) });
            }
            "notifications.remove" => {
                if let Some((notification_id, call_ended)) = n::decode_remove(plain) {
                    self.emit(Event::NotificationRemoved { device_id, notification_id, call_ended });
                }
            }
            "codes.status" => {
                if let Some(status) = n::decode_codes_status(plain) {
                    self.emit(Event::CodesStatus { device_id, status });
                }
            }
            "codes.advertise" | "codes.advertise_stop" => {
                if let Some((service_uuid, linked)) = n::decode_advertise(plain) {
                    self.emit(Event::CodesAdvertise { device_id, service_uuid, start: kind == "codes.advertise", linked: linked.unwrap_or(false) });
                }
            }
            _ => {}
        }
    }
}

/// The event that answers a send: its result, whatever the send was.
fn answer(what: Pending, request: u64, device_id: String, status: SendStatus) -> Event {
    match what {
        Pending::Clipboard => Event::ClipboardSent { request, device_id, status },
        Pending::Ping => Event::PingResult { request, device_id, status },
        Pending::Link => Event::LinkSent { request, device_id, status, opened: false },
    }
}
