//! Files between this command and the shared session client (rust/client, the Windows and iOS core) over loopback,
//! both ways: binary frames when both show files_fast_draft1, JSON chunks when one does not, cancels and dropped
//! sessions that leave no partial, resuming after an interruption, and the 1.0 hardening of partial files.
//!
//! The CLI end runs its real session (session.rs, a tailnet-style dial over plain TCP) with the daemon's routing
//! (`route`), and every byte passes a counting proxy, so the tests see which form went on the wire.

use super::*;
use crate::daemon::own_features;
use crate::session::{self, Event, Local, Mode, Outgoing as Wire, PinLookup, Spec};
use bridgey_core::{Client, Config, Event as CoreEvent, MemoryStorage, Next as CoreNext};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Condvar;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{oneshot, watch};

const WAIT: Duration = Duration::from_secs(60);
const MIB: usize = 1024 * 1024;

fn temp(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("bridgey-cli-files-{tag}-{}", crypto::uuid4()));
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// Bytes that are not all the same, so a misplaced chunk would change the hash.
fn pattern(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i * 31 % 251) as u8).collect()
}

/// Files in a folder (none hidden from this: partials start with a dot).
fn names(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir).map(|r| r.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    v.sort();
    v
}

fn local(name: &str) -> Arc<Local> {
    let identity = crypto::SigningKey::from_pkcs8(&crypto::SigningKey::generate_pkcs8()).unwrap();
    let identity_public = crypto::b64(&identity.public_raw());
    Arc::new(Local { device_id: crypto::uuid4(), device_name: std::sync::RwLock::new(name.into()), identity: Arc::new(identity), identity_public })
}

// region The shared session client

struct Shared {
    client: Arc<Client>,
    log: Arc<(Mutex<Vec<CoreEvent>>, Condvar)>,
    dir: PathBuf,
}

impl Shared {
    async fn start(fast: bool) -> Shared {
        let dir = temp("client");
        let received = dir.join("received");
        let client = tokio::task::spawn_blocking(move || {
            let mut config = Config::new("Shared client", "linux");
            config.port = 0;
            config.discovery = false;
            // Never dials anything by itself: only the CLI's connections, through the test's proxy.
            config.manual_connect = true;
            config.receive_dir = Some(received);
            config.defaults.set("files", true);
            config.fast_transfers = fast;
            Arc::new(Client::start(config, Arc::new(MemoryStorage::default())).expect("client starts"))
        })
        .await
        .unwrap();
        let log: Arc<(Mutex<Vec<CoreEvent>>, Condvar)> = Arc::default();
        {
            let (client, log) = (client.clone(), log.clone());
            std::thread::spawn(move || loop {
                match client.next_event(Duration::from_millis(200)) {
                    CoreNext::Event(e) => {
                        if let CoreEvent::PairingCode { pairing, .. } = &e {
                            let _ = client.confirm_pairing(*pairing, true);
                        }
                        log.0.lock().unwrap().push(e);
                        log.1.notify_all();
                    }
                    CoreNext::Timeout => {}
                    CoreNext::Closed => return,
                }
            });
        }
        Shared { client, log, dir }
    }

    fn addr(&self) -> SocketAddr {
        SocketAddr::from(([127, 0, 0, 1], self.client.port()))
    }

    fn received(&self) -> PathBuf {
        self.dir.join("received")
    }

    /// The first event `f` picks, waiting up to a minute.
    async fn wait<T>(&self, what: &str, f: impl Fn(&CoreEvent) -> Option<T>) -> T {
        let deadline = std::time::Instant::now() + WAIT;
        loop {
            if let Some(found) = self.log.0.lock().unwrap().iter().find_map(&f) {
                return found;
            }
            assert!(std::time::Instant::now() < deadline, "{what}: not seen; events: {:#?}", self.log.0.lock().unwrap());
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    fn clear(&self) {
        self.log.0.lock().unwrap().clear();
    }

    async fn stop(self) {
        let client = self.client.clone();
        tokio::task::spawn_blocking(move || client.stop()).await.unwrap();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

// endregion

// region A counting proxy

/// Forwards connections to `target`, counting bytes each way (up: to the target). The first connection closes, both
/// ways at once, once `cut_up` or `cut_down` bytes have gone that way: a link that drops mid-transfer.
struct Proxy {
    addr: SocketAddr,
    up: Arc<AtomicU64>,
    down: Arc<AtomicU64>,
}

async fn pump(mut from: tokio::net::tcp::OwnedReadHalf, mut to: tokio::net::tcp::OwnedWriteHalf, count: Arc<AtomicU64>, cut: Option<u64>, stop: watch::Sender<bool>, mut stopped: watch::Receiver<bool>) {
    let mut buf = vec![0u8; 64 * 1024];
    let mut moved = 0u64;
    loop {
        let n = tokio::select! {
            r = from.read(&mut buf) => match r { Ok(0) | Err(_) => break, Ok(n) => n },
            _ = stopped.changed() => break,
        };
        let n = match cut {
            Some(c) if moved + n as u64 >= c => {
                let last = (c - moved) as usize;
                let _ = to.write_all(&buf[..last]).await;
                count.fetch_add(last as u64, Ordering::Relaxed);
                break;
            }
            _ => n,
        };
        if to.write_all(&buf[..n]).await.is_err() {
            break;
        }
        moved += n as u64;
        count.fetch_add(n as u64, Ordering::Relaxed);
    }
    let _ = stop.send(true);
}

async fn proxy(target: SocketAddr, cut_up: Option<u64>, cut_down: Option<u64>) -> Proxy {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (up, down) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0)));
    let (u, d) = (up.clone(), down.clone());
    tokio::spawn(async move {
        let mut cuts = Some((cut_up, cut_down));
        while let Ok((inside, _)) = listener.accept().await {
            let Ok(outside) = TcpStream::connect(target).await else { continue };
            let (cut_up, cut_down) = cuts.take().unwrap_or((None, None));
            let (ir, iw) = inside.into_split();
            let (or, ow) = outside.into_split();
            let (stop, stopped) = watch::channel(false);
            tokio::spawn(pump(ir, ow, u.clone(), cut_up, stop.clone(), stopped.clone()));
            tokio::spawn(pump(or, iw, d.clone(), cut_down, stop, stopped));
        }
    });
    Proxy { addr, up, down }
}

// endregion

// region The CLI end: its session, and the daemon's routing of files

struct Cli {
    handle: Handle,
    /// The other device's latest features.update map.
    features: Arc<Mutex<Map<String, Value>>>,
    /// Replies by transfer ID, as the daemon's waiters.
    waiters: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<Reply>>>>,
    closed: Arc<Mutex<Option<String>>>,
}

/// Dials `addr` (the proxy before the shared client) as `bridgey pair --to` does and pairs; files go to `inbox`.
async fn dial(local: &Arc<Local>, addr: SocketAddr, inbox: &Inbox, switches: Switches, local_id: u64) -> Cli {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let pins: PinLookup = Arc::new(|_| None);
    let stream = TcpStream::connect(addr).await.unwrap();
    let spec = Spec { local_id, port: 0, token: String::new(), exporter: String::new(), tunnel: "test".into(), quic_client: true, mode: Mode::Dial, direct: Some(stream) };
    session::spawn(spec, local.clone(), pins, tx);
    let features: Arc<Mutex<Map<String, Value>>> = Arc::default();
    let waiters: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<Reply>>>> = Arc::default();
    let closed: Arc<Mutex<Option<String>>> = Arc::default();
    let (ready_tx, ready) = oneshot::channel::<Handle>();
    {
        let (inbox, features, waiters, closed) = (inbox.clone(), features.clone(), waiters.clone(), closed.clone());
        tokio::spawn(async move {
            let mut ready_tx = Some(ready_tx);
            let mut handle: Option<Handle> = None;
            while let Some(e) = rx.recv().await {
                match e {
                    Event::Code { confirm, .. } => {
                        let _ = confirm.send(true);
                    }
                    Event::Authenticated { handle: h, .. } => {
                        // As the daemon does: this install's map first.
                        h.send_json("features.update", &own_features(false, switches));
                        handle = Some(h.clone());
                        if let Some(t) = ready_tx.take() {
                            let _ = t.send(h);
                        }
                    }
                    Event::Frame { local_id, peer_id, message, plaintext } => {
                        let payload: Option<Value> = plaintext.as_ref().and_then(|p| serde_json::from_slice(p).ok());
                        if message.kind == "features.update" {
                            if let Some(map) = payload.as_ref().and_then(|p| p["features"].as_object()) {
                                *features.lock().unwrap() = map.clone();
                            }
                            continue;
                        }
                        let Some(h) = handle.clone() else { continue };
                        let resume = || features.lock().unwrap().get(resume::FEATURE) == Some(&Value::Bool(true));
                        if message.kind.starts_with("files.") && route(&inbox, &h, local_id, &peer_id, resume, &message, plaintext.as_deref()) {
                            continue;
                        }
                        let Some(id) = message.transfer_id.clone() else { continue };
                        if let Some(w) = waiters.lock().unwrap().get(&id) {
                            let _ = w.send(Reply { kind: message.kind.clone(), message: *message, payload, plaintext });
                        }
                    }
                    Event::Chunk { local_id, peer_id, transfer_id, sequence, data } => inbox.chunk(local_id, &peer_id, &transfer_id, Some(sequence), &data, fast::MAX_PLAINTEXT),
                    Event::Closed { local_id, reason, .. } => {
                        inbox.closed(local_id, &reason);
                        *closed.lock().unwrap() = Some(reason);
                        waiters.lock().unwrap().clear();
                        return;
                    }
                }
            }
        });
    }
    let handle = tokio::time::timeout(WAIT, ready).await.expect("paired in time").unwrap();
    let cli = Cli { handle, features, waiters, closed };
    let deadline = std::time::Instant::now() + WAIT;
    while cli.features.lock().unwrap().is_empty() {
        assert!(std::time::Instant::now() < deadline, "no features.update from the client");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    cli
}

impl Cli {
    fn plan(&self, size: u64, switches: Switches) -> Plan {
        Plan::new(&self.features.lock().unwrap(), size, switches)
    }

    /// `bridgey send` of one file, as ops.rs runs it.
    async fn send(&self, path: &Path, plan: Plan) -> Result<u64, Failed> {
        let file = prepare(path).await.unwrap();
        let (id, mid) = (crypto::uuid4(), crypto::uuid4());
        let (tx, mut rx) = mpsc::unbounded_channel();
        self.waiters.lock().unwrap().insert(id.clone(), tx);
        let o = Outgoing { transfer_id: &id, offer_id: &mid, path, name: "sent.bin", mime: "application/octet-stream", file: &file, plan, peer_name: "the client", me: "cli" };
        let (progress, _p) = mpsc::unbounded_channel();
        let r = send(&self.handle, &mut rx, &o, &progress).await;
        self.waiters.lock().unwrap().remove(&id);
        r
    }

    async fn wait_closed(&self) -> String {
        let deadline = std::time::Instant::now() + WAIT;
        loop {
            if let Some(r) = self.closed.lock().unwrap().clone() {
                return r;
            }
            assert!(std::time::Instant::now() < deadline, "the session did not end");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

struct Received {
    inbox: Inbox,
    reports: Arc<Mutex<Vec<Report>>>,
    dir: PathBuf,
}

fn inbox(resume: bool) -> Received {
    let dir = temp("inbox");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let inbox = Inbox::new(InboxConfig { dir: dir.join("in"), receive: true, resume, records: Some(dir.join("file-resume.json")) }, tx);
    let reports: Arc<Mutex<Vec<Report>>> = Arc::default();
    let r = reports.clone();
    tokio::spawn(async move {
        while let Some(x) = rx.recv().await {
            r.lock().unwrap().push(x);
        }
    });
    Received { inbox, reports, dir }
}

impl Drop for Received {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

impl Received {
    fn files(&self) -> PathBuf {
        self.dir.join("in")
    }

    async fn wait<T>(&self, what: &str, f: impl Fn(&Report) -> Option<T>) -> T {
        let deadline = std::time::Instant::now() + WAIT;
        loop {
            if let Some(found) = self.reports.lock().unwrap().iter().find_map(&f) {
                return found;
            }
            assert!(std::time::Instant::now() < deadline, "{what}: not seen; reports: {:#?}", self.reports.lock().unwrap());
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    async fn saved(&self) -> (PathBuf, u64) {
        self.wait("file saved", |r| match r {
            Report::Saved { path, resumed_from, .. } => Some((path.clone(), *resumed_from)),
            _ => None,
        })
        .await
    }

    fn clear(&self) {
        self.reports.lock().unwrap().clear();
    }
}

/// Pairs a fresh CLI install with a fresh shared client through a counting proxy.
async fn setup(client_fast: bool, switches: Switches, resume: bool, cut: (Option<u64>, Option<u64>)) -> (Shared, Received, Arc<Local>, Cli, Proxy) {
    let shared = Shared::start(client_fast).await;
    let p = proxy(shared.addr(), cut.0, cut.1).await;
    let (received, me, cli) = pair(&shared, p.addr, switches, resume).await;
    (shared, received, me, cli, p)
}

async fn pair(shared: &Shared, addr: SocketAddr, switches: Switches, resume: bool) -> (Received, Arc<Local>, Cli) {
    let received = inbox(resume);
    let me = local("cli");
    shared.client.allow_pairing(Duration::from_secs(60));
    let cli = dial(&me, addr, &received.inbox, switches, 1).await;
    shared.wait("the CLI's map", |e| matches!(e, CoreEvent::Features { remote, .. } if remote.get("files")).then_some(())).await;
    (received, me, cli)
}

fn write(dir: &Path, name: &str, data: &[u8]) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, data).unwrap();
    path
}

async fn client_saved(shared: &Shared) -> PathBuf {
    shared
        .wait("the client saved it", |e| match e {
            CoreEvent::FileDone { incoming: true, path: Some(p), .. } => Some(PathBuf::from(p)),
            _ => None,
        })
        .await
}

// endregion

// region Advertising and falling back

#[test]
fn the_map_shows_fast_frames_and_resume_and_plans_follow_the_peer() {
    let map = own_features(false, Switches::default());
    let f = map["features"].as_object().unwrap();
    assert_eq!(f.get(fast::FEATURE), Some(&Value::Bool(true)), "files_fast_draft1 is a capability: always advertised");
    assert_eq!(f.get(resume::FEATURE), Some(&Value::Bool(true)));
    let off = own_features(false, Switches { fast: false, resume: false });
    assert_eq!(off["features"][fast::FEATURE], Value::Bool(false));
    assert_eq!(off["features"][resume::FEATURE], Value::Bool(false));
    // The newest map the agent vectors pin (protocol/test-vectors/agent-v1.json, agentFeatures; older cases are maps
    // earlier installs send).
    let vectors: Value = serde_json::from_str(&fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/agent-v1.json")).unwrap()).unwrap();
    let newest = vectors["agentFeatures"].as_array().unwrap().last().unwrap();
    assert_eq!(newest["plaintext"], map, "the newest agentFeatures case in agent-v1.json is what this command advertises");
    assert_eq!(newest["expect"], map["features"]);

    let big = 8 * MIB as u64;
    let both: Map<String, Value> = [(fast::FEATURE, true), (resume::FEATURE, true)].into_iter().map(|(k, v)| (k.to_string(), Value::Bool(v))).collect();
    assert_eq!(Plan::new(&both, big, Switches::default()), Plan { fast: true, resumable: true });
    assert_eq!(Plan::new(&both, big, Switches::default()).chunk(), fast::CHUNK);
    // A peer without the keys (an older app, upstream Bridgey) gets JSON chunks and an ordinary offer.
    let none = Map::new();
    let legacy = Plan::new(&none, big, Switches::default());
    assert_eq!(legacy, Plan { fast: false, resumable: false });
    assert_eq!(legacy.chunk(), transfer::FILE_CHUNK);
    // A key that is not JSON true is not shown.
    let odd: Map<String, Value> = [(fast::FEATURE.to_string(), Value::String("true".into()))].into_iter().collect();
    assert!(!Plan::new(&odd, big, Switches::default()).fast);
    // One block or less is never offered resumable; switches off win.
    assert!(!Plan::new(&both, resume::BLOCK, Switches::default()).resumable);
    assert_eq!(Plan::new(&both, big, Switches { fast: false, resume: false }), Plan { fast: false, resumable: false });
}

// endregion

// region Both directions

/// A multi-megabyte file from the CLI to the session client goes in binary frames (the bytes on the wire are the
/// file's, not 4/3 of them as base64 in JSON), and arrives exactly.
#[tokio::test(flavor = "multi_thread")]
async fn cli_to_client_in_binary_frames() {
    let (shared, received, _me, cli, p) = setup(true, Switches::default(), true, (None, None)).await;
    let data = pattern(5 * MIB + 12_345);
    let path = write(&received.dir, "big.bin", &data);
    let plan = cli.plan(data.len() as u64, Switches::default());
    assert_eq!(plan, Plan { fast: true, resumable: true }, "the client shows both keys");
    let before = p.up.load(Ordering::Relaxed);
    assert_eq!(cli.send(&path, plan).await.unwrap(), 0);
    let saved = client_saved(&shared).await;
    assert_eq!(fs::read(&saved).unwrap(), data);
    let wire = p.up.load(Ordering::Relaxed) - before;
    assert!(wire < data.len() as u64 * 105 / 100, "binary frames: {wire} bytes on the wire for {}", data.len());
    assert!(!names(&shared.received()).iter().any(|n| n.ends_with(".part")));
    shared.stop().await;
}

/// ...and from the session client to the CLI's inbox, where it is saved under its own name with no partial left.
#[tokio::test(flavor = "multi_thread")]
async fn client_to_cli_in_binary_frames() {
    let (shared, received, me, _cli, p) = setup(true, Switches::default(), true, (None, None)).await;
    let data = pattern(6 * MIB + 7);
    let path = write(&shared.dir, "photo.jpg", &data);
    let before = p.down.load(Ordering::Relaxed);
    let t = shared.client.send_file(&me.device_id, &path, None, None).unwrap();
    let (saved, resumed) = received.saved().await;
    assert_eq!(resumed, 0);
    assert_eq!(saved.file_name().unwrap(), "photo.jpg");
    assert_eq!(fs::read(&saved).unwrap(), data);
    shared.wait("the client was told", |e| matches!(e, CoreEvent::FileDone { transfer, incoming: false, .. } if *transfer == t).then_some(())).await;
    let wire = p.down.load(Ordering::Relaxed) - before;
    assert!(wire < data.len() as u64 * 105 / 100, "binary frames: {wire} bytes on the wire for {}", data.len());
    assert_eq!(names(&received.files()), vec!["photo.jpg".to_string()]);
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(fs::metadata(&saved).unwrap().permissions().mode() & 0o777, 0o600, "received files are this user's only");
    // A second file with the same name never overwrites the first.
    let t2 = shared.client.send_file(&me.device_id, &path, None, None).unwrap();
    shared.wait("the second was saved", |e| matches!(e, CoreEvent::FileDone { transfer, incoming: false, .. } if *transfer == t2).then_some(())).await;
    assert_eq!(names(&received.files()), vec!["photo 2.jpg".to_string(), "photo.jpg".to_string()]);
    shared.stop().await;
}

/// With a device that does not show files_fast_draft1 every chunk is JSON, both ways; and with this install's
/// switch off the client sends JSON to it.
#[tokio::test(flavor = "multi_thread")]
async fn json_chunks_with_a_peer_without_the_key() {
    let (shared, received, me, cli, p) = setup(false, Switches::default(), true, (None, None)).await;
    assert!(!cli.plan(4 * MIB as u64, Switches::default()).fast, "the client does not show the key");
    let data = pattern(2 * MIB + 99);
    let path = write(&received.dir, "out.bin", &data);
    let before = p.up.load(Ordering::Relaxed);
    cli.send(&path, cli.plan(data.len() as u64, Switches::default())).await.unwrap();
    assert_eq!(fs::read(client_saved(&shared).await).unwrap(), data);
    let wire = p.up.load(Ordering::Relaxed) - before;
    assert!(wire > data.len() as u64 * 130 / 100, "JSON chunks: {wire} bytes on the wire for {}", data.len());
    let path = write(&shared.dir, "in.bin", &data);
    let before = p.down.load(Ordering::Relaxed);
    shared.client.send_file(&me.device_id, &path, None, None).unwrap();
    assert_eq!(fs::read(received.saved().await.0).unwrap(), data);
    assert!(p.down.load(Ordering::Relaxed) - before > data.len() as u64 * 130 / 100);
    shared.stop().await;

    // This install with files_fast_draft1 off: the client sends it JSON chunks.
    let off = Switches { fast: false, resume: true };
    let (shared, received, me, _cli, p) = setup(true, off, true, (None, None)).await;
    let path = write(&shared.dir, "in.bin", &data);
    let before = p.down.load(Ordering::Relaxed);
    shared.client.send_file(&me.device_id, &path, None, None).unwrap();
    assert_eq!(fs::read(received.saved().await.0).unwrap(), data);
    assert!(p.down.load(Ordering::Relaxed) - before > data.len() as u64 * 130 / 100);
    shared.stop().await;
}

// endregion

// region Cancels and interruptions

/// A transfer cancelled at either end, or cut off without resume, leaves no partial file anywhere.
#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_transfer_leaves_no_partial() {
    // The client cancels a file it is sending to the CLI, after 1 MiB.
    let (shared, received, me, cli, _p) = setup(true, Switches::default(), true, (None, None)).await;
    let data = pattern(8 * MIB);
    let path = write(&shared.dir, "big.bin", &data);
    shared.client.set_send_limit_for_tests(MIB as u64);
    let t = shared.client.send_file(&me.device_id, &path, None, None).unwrap();
    received.wait("the inbox has it", |r| matches!(r, Report::Incoming { .. }).then_some(())).await;
    // The client stops after 1 MiB (its test limit): wait until the inbox's partial holds it.
    let deadline = std::time::Instant::now() + WAIT;
    while !fs::read_dir(received.files()).unwrap().filter_map(|e| e.ok()).any(|e| e.metadata().is_ok_and(|m| m.len() >= MIB as u64)) {
        assert!(std::time::Instant::now() < deadline, "1 MiB never arrived");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(names(&received.files()).len(), 1, "one hidden partial while it comes in");
    shared.client.cancel_file(t).unwrap();
    received.wait("cancelled", |r| matches!(r, Report::Failed { reason, .. } if reason == "cancelled_remote").then_some(())).await;
    assert_eq!(names(&received.files()), Vec::<String>::new(), "no partial, no file");
    assert!(received.inbox.kept().is_empty(), "a cancel keeps nothing for later");

    // The client cancels a file the CLI is sending to it, as soon as it comes in.
    shared.client.set_send_limit_for_tests(0);
    shared.clear();
    let out = write(&received.dir, "out.bin", &pattern(64 * MIB));
    let watcher = {
        let (client, log) = (shared.client.clone(), shared.log.clone());
        tokio::spawn(async move {
            loop {
                let found = log.0.lock().unwrap().iter().find_map(|e| match e {
                    CoreEvent::FileIncoming { transfer, .. } => Some(*transfer),
                    _ => None,
                });
                if let Some(t) = found {
                    client.cancel_file(t).unwrap();
                    return;
                }
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
    };
    let r = cli.send(&out, cli.plan(64 * MIB as u64, Switches::default())).await;
    watcher.await.unwrap();
    let f = r.expect_err("cancelled on the client");
    assert_eq!(f.state, "cancelled");
    shared.wait("the client dropped it", |e| matches!(e, CoreEvent::FileFailed { incoming: true, .. }).then_some(())).await;
    assert!(!names(&shared.received()).iter().any(|n| n.ends_with(".part")), "the client kept no partial: {:?}", names(&shared.received()));
    shared.stop().await;

    // The link drops after 600 KiB of a file coming in while resuming is off here: the partial goes.
    let (shared, received, me, _cli, _p) = setup(true, Switches::default(), false, (None, Some(600 * 1024))).await;
    let path = write(&shared.dir, "big.bin", &data);
    shared.client.send_file(&me.device_id, &path, None, None).unwrap();
    received.wait("interrupted", |r| matches!(r, Report::Failed { reason, .. } if reason == "interrupted").then_some(())).await;
    assert_eq!(names(&received.files()), Vec::<String>::new());
    shared.stop().await;
}

/// A file cut off mid-transfer continues from what the receiver kept, both ways: the CLI's inbox resumes a file from
/// the client, and the client resumes one from the CLI (files_resume_draft1).
#[tokio::test(flavor = "multi_thread")]
async fn an_interrupted_file_resumes_both_ways() {
    // The client to the CLI: the link drops after 3.5 MiB of a 6 MiB file.
    let (shared, received, me, cli, _p) = setup(true, Switches::default(), true, (None, Some(3 * MIB as u64 + MIB as u64 / 2))).await;
    let data = pattern(6 * MIB + 5);
    let path = write(&shared.dir, "video.mp4", &data);
    shared.client.send_file(&me.device_id, &path, None, None).unwrap();
    received.wait("interrupted", |r| matches!(r, Report::Failed { reason, .. } if reason == "interrupted").then_some(())).await;
    cli.wait_closed().await;
    let kept = received.inbox.kept();
    assert_eq!(kept.len(), 1, "the partial is kept for the next attempt");
    let length = kept[0].length;
    assert!(length >= MIB as u64 && length % resume::BLOCK == 0, "whole verified blocks only: {length}");
    // Again, on a new session: the inbox proposes its bytes and the rest follows.
    received.clear();
    shared.clear();
    shared.client.allow_pairing(Duration::from_secs(60));
    let p = proxy(shared.addr(), None, None).await;
    let _cli = dial(&me, p.addr, &received.inbox, Switches::default(), 2).await;
    shared.wait("the CLI's map again", |e| matches!(e, CoreEvent::Features { remote, .. } if remote.get(resume::FEATURE)).then_some(())).await;
    shared.client.send_file(&me.device_id, &path, None, None).unwrap();
    let (saved, resumed) = received.saved().await;
    assert_eq!(resumed, length, "continued after the kept bytes");
    assert_eq!(fs::read(&saved).unwrap(), data);
    assert!(received.inbox.kept().is_empty(), "saved: nothing kept any more");
    assert_eq!(names(&received.files()), vec!["video.mp4".to_string()]);
    shared.stop().await;

    // The CLI to the client: the link drops after 3.5 MiB.
    let (shared, received, me, cli, _p) = setup(true, Switches::default(), true, (Some(3 * MIB as u64 + MIB as u64 / 2), None)).await;
    let out = write(&received.dir, "out.bin", &data);
    let f = cli.send(&out, cli.plan(data.len() as u64, Switches::default())).await.expect_err("cut off");
    assert_eq!((f.state, f.error.code.as_str()), ("interrupted", "interrupted_resumable"), "{:?}", f.error);
    shared.wait("the client lost the session", |e| matches!(e, CoreEvent::FileFailed { incoming: true, .. }).then_some(())).await;
    shared.clear();
    shared.client.allow_pairing(Duration::from_secs(60));
    let p = proxy(shared.addr(), None, None).await;
    let cli = dial(&me, p.addr, &received.inbox, Switches::default(), 2).await;
    let before = p.up.load(Ordering::Relaxed);
    let from = cli.send(&out, cli.plan(data.len() as u64, Switches::default())).await.unwrap();
    assert!(from >= MIB as u64 && from % resume::BLOCK == 0, "the client kept whole blocks: {from}");
    assert_eq!(fs::read(client_saved(&shared).await).unwrap(), data);
    let wire = p.up.load(Ordering::Relaxed) - before;
    assert!(wire < (data.len() as u64 - from) * 110 / 100 + 64 * 1024, "only the rest went again: {wire} bytes");
    shared.stop().await;
}

// endregion

// region Partial files (security review 1.0, F1)

fn offer_message(id: &str) -> Message {
    let mut m = Message::new("files.offer", "s");
    m.transfer_id = Some(id.into());
    m
}

fn offer_plain(id: &str, data: &[u8], resumable: bool) -> Vec<u8> {
    let sha = ring::digest::digest(&ring::digest::SHA256, data);
    json!({"transferId": id, "name": "doc.pdf", "mimeType": "application/pdf", "size": data.len(), "sha256": crypto::b64(sha.as_ref()), "resumable": resumable}).to_string().into_bytes()
}

/// What the inbox sent: outer kinds (files.accept, files.cancel, ...) and encrypted ones (files.resume).
fn sent(rx: &mut mpsc::UnboundedReceiver<Wire>) -> Vec<String> {
    let mut out = Vec::new();
    while let Ok(w) = rx.try_recv() {
        match w {
            Wire::Plain(m) => out.push(m.kind.clone()),
            Wire::Encrypted { kind, .. } => out.push(kind),
            _ => {}
        }
    }
    out
}

async fn settle(rx: &mut mpsc::UnboundedReceiver<Wire>, want: &str) -> Vec<String> {
    let deadline = std::time::Instant::now() + WAIT;
    let mut all = Vec::new();
    loop {
        all.extend(sent(rx));
        if all.iter().any(|k| k == want) {
            return all;
        }
        assert!(std::time::Instant::now() < deadline, "{want} never sent: {all:?}");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

const PEER: &str = "7e57d00d-0000-4000-8000-0000000000aa";

/// New partials: a dangling link (or anything) at the partial's name is never opened or followed.
#[test]
fn a_new_partial_never_follows_a_link() {
    let dir = temp("create");
    let victim = dir.join("victim");
    let part = transfer::part_path(&dir, &crypto::uuid4());
    std::os::unix::fs::symlink(&victim, &part).unwrap();
    assert!(create_partial(&part).is_err(), "O_EXCL | O_NOFOLLOW: a dangling link is a taken name");
    assert!(!victim.exists(), "the link's target was never created");
    let fresh = transfer::part_path(&dir, &crypto::uuid4());
    let f = create_partial(&fresh).unwrap();
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(f.metadata().unwrap().permissions().mode() & 0o777, 0o600);
    fs::remove_dir_all(&dir).unwrap();
}

/// Publishing checks the partial's name still names the file written: a link or another file swapped in is never
/// moved into the inbox, and the file it points at is untouched.
#[test]
fn a_swapped_partial_is_never_published() {
    let dir = temp("publish");
    let victim = dir.join("victim");
    fs::write(&victim, b"keep me").unwrap();
    for swap in ["link", "file"] {
        let part = transfer::part_path(&dir, &crypto::uuid4());
        let mut f = create_partial(&part).unwrap();
        f.write_all(b"received bytes").unwrap();
        fs::remove_file(&part).unwrap();
        if swap == "link" {
            std::os::unix::fs::symlink(&victim, &part).unwrap();
        } else {
            fs::write(&part, b"something else").unwrap();
        }
        assert!(publish(&f, &part, &dir, "doc.pdf").is_err(), "{swap} in the partial's place");
        assert!(!dir.join("doc.pdf").exists(), "{swap}: nothing published");
        let _ = fs::remove_file(&part);
    }
    assert_eq!(fs::read(&victim).unwrap(), b"keep me");
    // The file written, still at its name, is published.
    let part = transfer::part_path(&dir, &crypto::uuid4());
    let mut f = create_partial(&part).unwrap();
    f.write_all(b"received bytes").unwrap();
    let saved = publish(&f, &part, &dir, "doc.pdf").unwrap();
    assert_eq!(fs::read(saved).unwrap(), b"received bytes");
    assert!(!part.exists());
    fs::remove_dir_all(&dir).unwrap();
}

/// A kept partial is opened without following a link and only as a plain file of this user with one name; one that
/// was swapped for a link or given a second name is dropped (the link, never its target) and the file comes from byte
/// zero. One whose bytes changed fails the re-read through the transfer's own handle and starts again too. One that
/// checks out is proposed with `files.resume`.
#[tokio::test(flavor = "multi_thread")]
async fn kept_partials_are_checked_before_a_resume() {
    let data = pattern(3 * MIB);
    let verified = 2 * MIB;
    for case in ["link", "second name", "changed", "intact"] {
        let r = inbox(true);
        let victim = r.dir.join("victim");
        fs::write(&victim, pattern(verified)).unwrap();
        // An attempt that kept two verified blocks.
        let (h, mut rx) = Handle::for_tests(7);
        let first = crypto::uuid4();
        r.inbox.offer(&h, 7, PEER, true, &offer_message(&first), Some(&offer_plain(&first, &data, true)));
        assert_eq!(sent(&mut rx), vec!["files.accept"]);
        for (seq, block) in data[..verified].chunks(fast::CHUNK).enumerate() {
            r.inbox.chunk(7, PEER, &first, Some(seq as u64), block, fast::MAX_PLAINTEXT);
        }
        r.inbox.closed(7, "closed_by_peer");
        let kept = r.inbox.kept();
        assert_eq!((kept.len(), kept[0].length), (1, verified as u64), "{case}");
        let part = kept[0].part_path();
        match case {
            "link" => {
                fs::remove_file(&part).unwrap();
                std::os::unix::fs::symlink(&victim, &part).unwrap();
            }
            "second name" => fs::hard_link(&part, r.dir.join("other name")).map(|_| ()).unwrap(),
            "changed" => {
                let mut f = fs::OpenOptions::new().write(true).open(&part).unwrap();
                f.write_all(b"not what was received").unwrap();
            }
            _ => {}
        }
        // The next attempt, on a new session.
        let (h, mut rx) = Handle::for_tests(8);
        let second = crypto::uuid4();
        r.inbox.offer(&h, 8, PEER, true, &offer_message(&second), Some(&offer_plain(&second, &data, true)));
        let answers = match case {
            "intact" => settle(&mut rx, "files.resume").await,
            _ => settle(&mut rx, "files.accept").await,
        };
        assert!(!answers.iter().any(|k| k == "files.cancel"), "{case}: {answers:?}");
        if case == "intact" {
            assert!(!answers.iter().any(|k| k == "files.accept"), "{case}: {answers:?}");
        } else {
            assert!(!answers.iter().any(|k| k == "files.resume"), "{case}: never resumed: {answers:?}");
        }
        assert_eq!(fs::read(&victim).unwrap(), pattern(verified), "{case}: the link's target is untouched");
        if case == "link" {
            assert!(fs::symlink_metadata(&part).is_err() || !fs::symlink_metadata(&part).unwrap().file_type().is_symlink(), "the link went");
        }
        if case == "second name" {
            assert_eq!(fs::read(r.dir.join("other name")).unwrap().len(), verified, "the other name keeps its bytes");
        }
        r.inbox.closed(8, "forgotten");
        let _ = fs::remove_dir_all(&r.dir);
    }
}

/// The inbox refuses files while `inbox.receive` is off, offers that break the rules, and chunks out of order or
/// from another session; a forgotten device takes its kept partials with it.
#[tokio::test(flavor = "multi_thread")]
async fn the_inbox_keeps_to_its_rules() {
    let dir = temp("rules");
    let (tx, _rx) = mpsc::unbounded_channel();
    let off = Inbox::new(InboxConfig { dir: dir.join("in"), receive: false, resume: true, records: None }, tx);
    let (h, mut out) = Handle::for_tests(1);
    let id = crypto::uuid4();
    off.offer(&h, 1, PEER, true, &offer_message(&id), Some(&offer_plain(&id, b"abc", false)));
    assert_eq!(sent(&mut out), vec!["files.rejected"]);
    assert!(!dir.join("in").exists(), "nothing made while off");

    let r = inbox(true);
    let (h, mut out) = Handle::for_tests(1);
    // A transfer ID that is not the outer one, a missing hash, and a folder entry are cancelled.
    let id = crypto::uuid4();
    r.inbox.offer(&h, 1, PEER, true, &offer_message(&crypto::uuid4()), Some(&offer_plain(&id, b"abc", false)));
    let mut no_hash: Value = serde_json::from_slice(&offer_plain(&id, b"abc", false)).unwrap();
    no_hash.as_object_mut().unwrap().remove("sha256");
    r.inbox.offer(&h, 1, PEER, true, &offer_message(&id), Some(no_hash.to_string().as_bytes()));
    let mut folder: Value = serde_json::from_slice(&offer_plain(&id, b"abc", false)).unwrap();
    folder["folderTransferId"] = json!(crypto::uuid4());
    r.inbox.offer(&h, 1, PEER, true, &offer_message(&id), Some(folder.to_string().as_bytes()));
    assert_eq!(sent(&mut out), vec!["files.cancel", "files.cancel", "files.cancel"]);
    // A name with a path in it lands under its last part; a chunk from another session is ignored; a gap cancels.
    let data = pattern(100_000);
    let mut plain: Value = serde_json::from_slice(&offer_plain(&id, &data, false)).unwrap();
    plain["name"] = json!("../../etc/passwd");
    r.inbox.offer(&h, 1, PEER, true, &offer_message(&id), Some(plain.to_string().as_bytes()));
    assert_eq!(sent(&mut out), vec!["files.accept"]);
    r.inbox.chunk(2, PEER, &id, Some(0), &data[..1000], fast::MAX_PLAINTEXT);
    r.inbox.chunk(1, "7e57d00d-0000-4000-8000-0000000000bb", &id, Some(0), &data[..1000], fast::MAX_PLAINTEXT);
    assert!(sent(&mut out).is_empty(), "not from the session or device the file is with");
    r.inbox.chunk(1, PEER, &id, Some(0), &data[..50_000], fast::MAX_PLAINTEXT);
    assert_eq!(sent(&mut out), vec!["files.chunk.ack"]);
    r.inbox.chunk(1, PEER, &id, Some(0), &data[50_000..], transfer::MAX_CHUNK_IN);
    assert_eq!(sent(&mut out), vec!["files.cancel"], "a repeated sequence, and a JSON chunk over 48 KiB, cancel");
    assert_eq!(names(&r.files()), Vec::<String>::new());
    // A good one: saved as passwd, the whole file's hash checked.
    let id = crypto::uuid4();
    let mut plain: Value = serde_json::from_slice(&offer_plain(&id, &data, false)).unwrap();
    plain["name"] = json!("../../etc/passwd");
    r.inbox.offer(&h, 1, PEER, true, &offer_message(&id), Some(plain.to_string().as_bytes()));
    r.inbox.chunk(1, PEER, &id, Some(0), &data, fast::MAX_PLAINTEXT);
    let sha = ring::digest::digest(&ring::digest::SHA256, &data);
    r.inbox.complete(1, PEER, Some(json!({"transferId": id, "sha256": crypto::b64(sha.as_ref())}).to_string().as_bytes()));
    assert_eq!(sent(&mut out), vec!["files.accept", "files.chunk.ack", "files.complete.ack"]);
    assert_eq!(names(&r.files()), vec!["passwd".to_string()]);
    // A file whose bytes do not match the offer is not saved.
    let id = crypto::uuid4();
    r.inbox.offer(&h, 1, PEER, true, &offer_message(&id), Some(&offer_plain(&id, &data, false)));
    let mut wrong = data.clone();
    wrong[7] ^= 1;
    r.inbox.chunk(1, PEER, &id, Some(0), &wrong, fast::MAX_PLAINTEXT);
    r.inbox.complete(1, PEER, Some(json!({"transferId": id, "sha256": crypto::b64(sha.as_ref())}).to_string().as_bytes()));
    assert_eq!(sent(&mut out), vec!["files.accept", "files.chunk.ack", "files.cancel"]);
    assert_eq!(names(&r.files()), vec!["passwd".to_string()]);
    // Forgetting the device deletes what it left for a later attempt.
    let big = pattern(2 * MIB);
    let id = crypto::uuid4();
    r.inbox.offer(&h, 1, PEER, true, &offer_message(&id), Some(&offer_plain(&id, &big, true)));
    r.inbox.chunk(1, PEER, &id, Some(0), &big[..MIB], fast::MAX_PLAINTEXT);
    r.inbox.chunk(1, PEER, &id, Some(1), &big[MIB..MIB + 10], fast::MAX_PLAINTEXT);
    r.inbox.closed(1, "closed_by_peer");
    assert_eq!(r.inbox.kept().len(), 1);
    assert_eq!(names(&r.files()).iter().filter(|n| n.ends_with(".part")).count(), 1);
    r.inbox.forget(PEER);
    assert!(r.inbox.kept().is_empty());
    assert_eq!(names(&r.files()), vec!["passwd".to_string()]);
    let _ = fs::remove_dir_all(&r.dir);
    let _ = fs::remove_dir_all(&dir);
}

/// Kept partials survive a restart through their records, and a start sweeps records whose partial is gone.
#[tokio::test(flavor = "multi_thread")]
async fn records_survive_a_restart() {
    let r = inbox(true);
    let big = pattern(3 * MIB);
    let (h, _out) = Handle::for_tests(1);
    let id = crypto::uuid4();
    r.inbox.offer(&h, 1, PEER, true, &offer_message(&id), Some(&offer_plain(&id, &big, true)));
    r.inbox.chunk(1, PEER, &id, Some(0), &big[..MIB], fast::MAX_PLAINTEXT);
    r.inbox.chunk(1, PEER, &id, Some(1), &big[MIB..2 * MIB], fast::MAX_PLAINTEXT);
    r.inbox.chunk(1, PEER, &id, Some(2), &big[2 * MIB..2 * MIB + 1], fast::MAX_PLAINTEXT);
    r.inbox.closed(1, "heartbeat_timeout");
    let kept = r.inbox.kept();
    assert_eq!((kept.len(), kept[0].length), (1, 2 * MIB as u64), "two whole blocks verified");
    let config = InboxConfig { dir: r.files(), receive: true, resume: true, records: Some(r.dir.join("file-resume.json")) };
    let (tx, _rx) = mpsc::unbounded_channel();
    assert_eq!(Inbox::new(config.clone(), tx.clone()).kept(), kept, "read back at start");
    fs::remove_file(kept[0].part_path()).unwrap();
    assert!(Inbox::new(config, tx).kept().is_empty(), "a record without its partial is swept");
    let _ = fs::remove_dir_all(&r.dir);
}

// endregion

// region Throughput over loopback (cargo test --release -p bridgey-cli -- --ignored --nocapture throughput)

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn throughput() {
    let mb: usize = std::env::var("BENCH_MB").ok().and_then(|v| v.parse().ok()).unwrap_or(256);
    let data = pattern(mb * MIB);
    for (form, fast) in [("binary frames", true), ("JSON chunks", false)] {
        let switches = Switches { fast, resume: false };
        // Straight to the client: no proxy in the way.
        let shared = Shared::start(fast).await;
        let (received, me, cli) = pair(&shared, shared.addr(), switches, false).await;
        let path = write(&received.dir, "bench.bin", &data);
        // Hashing for the offer is not timed (the base revision's measurement left it out too); the client's own
        // hashing pass is inside its time below.
        let file = prepare(&path).await.unwrap();
        let (id, mid) = (crypto::uuid4(), crypto::uuid4());
        let (tx, mut rx) = mpsc::unbounded_channel();
        cli.waiters.lock().unwrap().insert(id.clone(), tx);
        let o = Outgoing { transfer_id: &id, offer_id: &mid, path: &path, name: "bench.bin", mime: "application/octet-stream", file: &file, plan: cli.plan(data.len() as u64, switches), peer_name: "the client", me: "cli" };
        let (progress, _p) = mpsc::unbounded_channel();
        let started = std::time::Instant::now();
        send(&cli.handle, &mut rx, &o, &progress).await.unwrap();
        let up = started.elapsed().as_secs_f64();
        let _ = fs::remove_file(client_saved(&shared).await);
        let path = write(&shared.dir, "bench.bin", &data);
        let started = std::time::Instant::now();
        shared.client.send_file(&me.device_id, &path, None, None).unwrap();
        let saved = received.saved().await.0;
        let down = started.elapsed().as_secs_f64();
        let _ = fs::remove_file(saved);
        println!("BENCH after {form}: CLI to client {mb} MiB in {up:.2} s = {:.0} MiB/s; client to CLI {down:.2} s = {:.0} MiB/s", mb as f64 / up, mb as f64 / down);
        shared.stop().await;
        let _ = fs::remove_dir_all(&received.dir);
    }
}

// endregion
