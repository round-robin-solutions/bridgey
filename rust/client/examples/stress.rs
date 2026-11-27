//! The stress driver (docs/testing-stress.md): a scripted Bridgey device, built on the session client, that pairs or
//! reconnects with a real app over LAN TCP and runs transfer scenarios against it with assertions. 1 GiB, 4 GiB and many
//! small files both ways with SHA-256 checks; cancels from either end at random points; connection drops, silent
//! stalls and restarts of either side mid-file (single files resume from the receiver's last verified 1 MiB block,
//! files_resume_draft1); reconnect loops. It writes one JSON report with timings and throughput.
//!
//! The app is driven through a control program (`--app`); scripts/rr/stress-mac.sh and stress-android.sh provide one
//! for the throwaway Mac test instance and for the stress build on an emulator. It is run as `<program> <verb> [args]`
//! and prints one JSON object (`"ok": false` with `"error"` when a verb fails):
//!
//!   pair-prepare | pair-confirm   Allow pairing; press Codes match on the prompt showing now
//!   send <name:size:seed>...      the app makes those files (the bytes of `Gen`) and sends them here, in order
//!   cancel                        Cancel on every transfer
//!   kill | start                  end the app's process at once; start it again (returns once it listens)
//!   status                        {"active": <single-file transfers running>, "free": <bytes free, or -1>}
//!   received <name>...            {"files": [{"name", "size", "sha256"} or {"name", "missing": true}]}
//!   partials                      {"partials": [{"name", "size"}]}: kept or half-written single files
//!   clean                         deletes every stress-* file the app received or made
//!
//! Every connection goes through a TCP proxy in this process, so a scenario can cut it (both ends see the socket close)
//! or hold it (nothing moves, as when Wi-Fi goes quiet, until heartbeats end the session). The peer does not listen,
//! so the app's own dials cannot go around the proxy; the peer redials through it.
//!
//!   stress run --app "<program> [args]" --target 127.0.0.1:42497 --work <dir> [--peer-platform android|macos]
//!              [--scenarios all|quick|<name>,...] [--big 1G,4G] [--mid 1G] [--small 200] [--rounds 2] [--loops 20]
//!              [--seed N] [--proxy-port 42491] [--report <file>] [--name <peer name>]
//!   stress gen <path> <size> <seed>     writes a file of `Gen` bytes and prints its SHA-256
//!   stress sha <size> <seed>            prints the SHA-256 such a file has
//!   stress list                         prints the scenario names
//!   stress serve <port> <control port> <dir>      a session-client device standing in for the app (the harness's
//!                                                 own check, no device needed), driven by
//!   stress app-control <control port> <verb> ...  as `--app`
//!
//!   stress soak ...                     hours of mixed traffic with process samples (stress/soak.rs)
//!   stress accept ...                   upgrade acceptance across an app upgrade (stress/accept.rs)
//!
//! The peer's identity and pairing live in `<work>/state`, so a second run reconnects without pairing again.

#[path = "stress/accept.rs"]
mod accept;
#[path = "stress/soak.rs"]
mod soak;

use bridgey_core::{Client, Config, Event, FileStorage, Next};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MIB: u64 = 1 << 20;
const BUFFER: usize = 1 << 20;
/// A clean cut: the receiver keeps what it verified, less one block, and the sender's window is at most 32 MiB ahead
/// of what the receiver has (fast transfers), so a resume may start at most this far before what the sender had sent.
const CUT_LOSS: u64 = 40 * MIB;
/// A killed receiver keeps only its last 64 MiB checkpoint.
const KILL_LOSS: u64 = 64 * MIB + CUT_LOSS;
/// A receiver this end runs keeps everything it verified, less one block.
const OWN_LOSS: u64 = 2 * MIB;

// ---------------------------------------------------------------------------------------------------------------
// File bytes

/// SplitMix64 from the seed, each word little-endian, the last one cut short. The Android stress build makes the same
/// bytes (StressBytes), so either end knows a file's SHA-256 without reading it from the other.
struct Gen(u64);

impl Gen {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Every call but the last must fill a whole number of words.
    fn fill(&mut self, buf: &mut [u8]) {
        for chunk in buf.chunks_mut(8) {
            let word = self.next().to_le_bytes();
            chunk.copy_from_slice(&word[..chunk.len()]);
        }
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The `Gen` bytes of a file, handed to `sink` 1 MiB at a time; returns their SHA-256.
fn generate(size: u64, seed: u64, mut sink: impl FnMut(&[u8]) -> std::io::Result<()>) -> std::io::Result<String> {
    let mut gen = Gen(seed);
    let mut buf = vec![0u8; BUFFER];
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut left = size;
    while left > 0 {
        let n = left.min(BUFFER as u64) as usize;
        gen.fill(&mut buf[..n]);
        ctx.update(&buf[..n]);
        sink(&buf[..n])?;
        left -= n as u64;
    }
    Ok(hex(ctx.finish().as_ref()))
}

fn write_generated(path: &Path, size: u64, seed: u64) -> std::io::Result<String> {
    let tmp = path.with_extension("tmp");
    let mut file = std::io::BufWriter::with_capacity(BUFFER, std::fs::File::create(&tmp)?);
    let sha = generate(size, seed, |b| file.write_all(b))?;
    file.flush()?;
    drop(file);
    std::fs::rename(&tmp, path)?;
    Ok(sha)
}

fn file_sha(path: &Path) -> std::io::Result<(u64, String)> {
    let mut file = std::fs::File::open(path)?;
    let mut buf = vec![0u8; BUFFER];
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut total = 0u64;
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
        total += n as u64;
    }
    Ok((total, hex(ctx.finish().as_ref())))
}

fn parse_size(text: &str) -> u64 {
    let t = text.trim().to_ascii_uppercase();
    let (number, unit) = t.split_at(t.find(|c: char| c.is_ascii_alphabetic()).unwrap_or(t.len()));
    let n: f64 = number.parse().unwrap_or_else(|_| panic!("bad size {text}"));
    let unit = match unit.trim_end_matches("IB").trim_end_matches('B') {
        "" => 1.0,
        "K" => 1024.0,
        "M" => MIB as f64,
        "G" => (1024 * MIB) as f64,
        other => panic!("bad size unit {other}"),
    };
    (n * unit) as u64
}

fn size_label(size: u64) -> String {
    if size >= 1024 * MIB && size.is_multiple_of(1024 * MIB) {
        format!("{}g", size / (1024 * MIB))
    } else if size >= MIB && size.is_multiple_of(MIB) {
        format!("{}m", size / MIB)
    } else {
        format!("{size}b")
    }
}

fn mb(bytes: u64) -> f64 {
    (bytes as f64 / MIB as f64 * 10.0).round() / 10.0
}

fn rate(bytes: u64, seconds: f64) -> f64 {
    if seconds <= 0.0 {
        0.0
    } else {
        (bytes as f64 / MIB as f64 / seconds * 10.0).round() / 10.0
    }
}

fn secs(d: Duration) -> f64 {
    (d.as_secs_f64() * 1000.0).round() / 1000.0
}

/// Choices that a seed repeats (cut points, sizes).
struct Rng(Gen);

impl Rng {
    fn unit(&mut self) -> f64 {
        (self.0.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    fn between(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.unit()
    }

    fn below(&mut self, n: u64) -> u64 {
        if n == 0 {
            0
        } else {
            self.0.next() % n
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// The proxy every connection goes through

struct Conn {
    a: TcpStream,
    b: TcpStream,
    closed: Arc<AtomicBool>,
}

struct ProxyState {
    target: SocketAddr,
    hold: AtomicBool,
    /// Bytes a second each way per connection (0: as fast as it goes).
    rate: AtomicU64,
    conns: Mutex<Vec<Conn>>,
    accepted: AtomicU64,
}

struct Proxy {
    port: u16,
    st: Arc<ProxyState>,
}

impl Proxy {
    fn start(port: u16, target: SocketAddr) -> std::io::Result<Proxy> {
        let listener = TcpListener::bind(("127.0.0.1", port))?;
        let port = listener.local_addr()?.port();
        let st = Arc::new(ProxyState { target, hold: AtomicBool::new(false), rate: AtomicU64::new(0), conns: Mutex::new(Vec::new()), accepted: AtomicU64::new(0) });
        let accept = st.clone();
        std::thread::spawn(move || {
            for client in listener.incoming().flatten() {
                accept.accepted.fetch_add(1, Ordering::Relaxed);
                let st = accept.clone();
                std::thread::spawn(move || st.join(client));
            }
        });
        Ok(Proxy { port, st })
    }

    /// Closes every connection: both ends see the socket close.
    fn cut(&self) -> usize {
        let conns = std::mem::take(&mut *self.st.conns.lock().unwrap());
        for c in &conns {
            c.closed.store(true, Ordering::SeqCst);
            let _ = c.a.shutdown(Shutdown::Both);
            let _ = c.b.shutdown(Shutdown::Both);
        }
        conns.len()
    }

    /// Nothing moves either way while held; the sockets stay open.
    fn hold(&self, on: bool) {
        self.st.hold.store(on, Ordering::SeqCst);
    }

    /// Caps each direction of each connection (0 lifts it), so a cancel or a kill sent through the app's control
    /// program lands mid-file even on a link that moves a gigabyte a second.
    fn limit(&self, bytes_per_second: u64) {
        self.st.rate.store(bytes_per_second, Ordering::SeqCst);
    }
}

impl ProxyState {
    fn join(self: Arc<Self>, client: TcpStream) {
        let Ok(server) = TcpStream::connect_timeout(&self.target, Duration::from_secs(5)) else { return };
        let _ = client.set_nodelay(true);
        let _ = server.set_nodelay(true);
        let closed = Arc::new(AtomicBool::new(false));
        let (Ok(a), Ok(b), Ok(c2), Ok(s2)) = (client.try_clone(), server.try_clone(), client.try_clone(), server.try_clone()) else { return };
        {
            let mut conns = self.conns.lock().unwrap();
            conns.retain(|c| !c.closed.load(Ordering::SeqCst));
            conns.push(Conn { a, b, closed: closed.clone() });
        }
        let (me, flag) = (self.clone(), closed.clone());
        std::thread::spawn(move || pump(c2, s2, &me, &flag));
        pump(server, client, &self, &closed);
    }
}

fn pump(mut from: TcpStream, mut to: TcpStream, st: &ProxyState, closed: &AtomicBool) {
    let _ = from.set_read_timeout(Some(Duration::from_millis(200)));
    let mut buf = vec![0u8; 256 * 1024];
    let (mut since, mut moved) = (Instant::now(), 0u64);
    while !closed.load(Ordering::SeqCst) {
        if st.hold.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(50));
            continue;
        }
        match from.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    break;
                }
                let rate = st.rate.load(Ordering::Relaxed);
                if rate == 0 {
                    continue;
                }
                if since.elapsed() > Duration::from_secs(1) {
                    (since, moved) = (Instant::now(), 0);
                }
                moved += n as u64;
                let due = Duration::from_secs_f64(moved as f64 / rate as f64);
                if let Some(wait) = due.checked_sub(since.elapsed()) {
                    std::thread::sleep(wait);
                }
            }
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted) => {}
            Err(_) => break,
        }
    }
    closed.store(true, Ordering::SeqCst);
    let _ = from.shutdown(Shutdown::Both);
    let _ = to.shutdown(Shutdown::Both);
}

// ---------------------------------------------------------------------------------------------------------------
// The peer and what it has seen

#[derive(Clone, Default, Debug)]
struct Transfer {
    incoming: bool,
    name: String,
    total: u64,
    bytes: u64,
    /// The first progress above zero. When it is a whole number of blocks it is where the file resumed: the sender
    /// reports the offset the receiver proposed, the receiver the length it proposed, before any chunk moves.
    first_bytes: Option<u64>,
    resumed_at: Option<u64>,
    seen: Option<Instant>,
    moving: Option<Instant>,
    ended: Option<Instant>,
    done: bool,
    failed: Option<String>,
    path: Option<String>,
}

#[derive(Default)]
struct PeerState {
    connected: Option<String>,
    connected_at: Option<Instant>,
    features: Option<Value>,
    disconnects: u64,
    last_disconnect: Option<(Instant, String)>,
    paired: Option<(bool, String, Option<String>)>,
    code: Option<String>,
    /// Pairing prompts seen since the peer started: a reconnect after an upgrade must show none.
    pairing_prompts: u64,
    transfers: HashMap<u64, Transfer>,
    /// Clipboard texts the app sent here (the newest last, at most 500), and the result of each send from here.
    clips_in: std::collections::VecDeque<(Instant, String)>,
    clip_results: HashMap<u64, String>,
    errors: u64,
    dropped: u64,
}

struct Shared {
    st: Mutex<PeerState>,
    cv: Condvar,
    log: Mutex<std::fs::File>,
    t0: Instant,
}

impl Shared {
    fn wait<T>(&self, timeout: Duration, mut f: impl FnMut(&mut PeerState) -> Option<T>) -> Option<T> {
        let deadline = Instant::now() + timeout;
        let mut st = self.st.lock().unwrap();
        loop {
            if let Some(v) = f(&mut st) {
                return Some(v);
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            st = self.cv.wait_timeout(st, (deadline - now).min(Duration::from_millis(250))).unwrap().0;
        }
    }

    fn note(&self, v: Value) {
        let mut line = Map::new();
        line.insert("t".into(), json!(secs(self.t0.elapsed())));
        if let Value::Object(m) = v {
            line.extend(m);
        }
        let _ = writeln!(self.log.lock().unwrap(), "{}", Value::Object(line));
    }

    fn apply(&self, client: &Client, e: Event) {
        let now = Instant::now();
        let mut st = self.st.lock().unwrap();
        match e {
            Event::PairingCode { pairing, code, name, .. } => {
                self.note(json!({"event": "code", "code": code, "name": name}));
                st.code = Some(code);
                st.pairing_prompts += 1;
                let _ = client.confirm_pairing(pairing, true);
            }
            Event::PairingFinished { ok, reason, device_id, .. } => {
                self.note(json!({"event": "paired", "ok": ok, "reason": reason, "deviceId": device_id}));
                st.paired = Some((ok, reason, device_id));
            }
            Event::Connected { device_id, name } => {
                self.note(json!({"event": "connected", "deviceId": device_id, "name": name}));
                st.connected = Some(device_id);
                st.connected_at = Some(now);
                st.features = None;
            }
            Event::Disconnected { device_id, reason } => {
                self.note(json!({"event": "disconnected", "deviceId": device_id, "reason": reason}));
                if st.connected.as_deref() == Some(device_id.as_str()) {
                    st.connected = None;
                    st.features = None;
                }
                st.disconnects += 1;
                st.last_disconnect = Some((now, reason));
            }
            Event::Features { device_id, remote, .. } => {
                let remote = remote.to_json();
                self.note(json!({"event": "features", "deviceId": device_id, "remote": remote}));
                if st.connected.as_deref() == Some(device_id.as_str()) {
                    st.features = Some(remote);
                }
            }
            Event::FileIncoming { transfer, name, size, .. } => {
                self.note(json!({"event": "incoming", "transfer": transfer, "name": name, "size": size}));
                let t = st.transfers.entry(transfer).or_default();
                t.incoming = true;
                t.name = name;
                t.total = size;
                t.seen.get_or_insert(now);
            }
            Event::FileProgress { transfer, incoming, bytes, total, .. } => {
                let t = st.transfers.entry(transfer).or_default();
                t.incoming = incoming;
                t.total = total;
                t.bytes = bytes;
                t.seen.get_or_insert(now);
                if bytes > 0 && t.first_bytes.is_none() {
                    t.first_bytes = Some(bytes);
                    if bytes.is_multiple_of(MIB) {
                        t.resumed_at = Some(bytes);
                    }
                    t.moving = Some(now);
                }
                let resumed = t.resumed_at;
                self.note(json!({"event": "progress", "transfer": transfer, "incoming": incoming, "bytes": bytes, "total": total, "resumedAt": resumed}));
            }
            Event::FileDone { transfer, incoming, name, path, size, .. } => {
                self.note(json!({"event": "done", "transfer": transfer, "incoming": incoming, "name": name, "path": path, "size": size}));
                let t = st.transfers.entry(transfer).or_default();
                t.incoming = incoming;
                t.done = true;
                t.bytes = size;
                t.total = size;
                t.path = path;
                t.ended = Some(now);
                if t.name.is_empty() {
                    t.name = name;
                }
            }
            Event::FileFailed { transfer, incoming, name, reason, .. } => {
                self.note(json!({"event": "failed", "transfer": transfer, "incoming": incoming, "name": name, "reason": reason}));
                let t = st.transfers.entry(transfer).or_default();
                t.incoming = incoming;
                t.failed = Some(reason);
                t.ended = Some(now);
                if t.name.is_empty() {
                    t.name = name;
                }
            }
            Event::Clipboard { text, .. } => {
                self.note(json!({"event": "clipboard", "chars": text.chars().count()}));
                st.clips_in.push_back((now, text));
                while st.clips_in.len() > 500 {
                    st.clips_in.pop_front();
                }
            }
            Event::ClipboardSent { request, status, .. } => {
                let status = format!("{status:?}").to_ascii_lowercase();
                self.note(json!({"event": "clipboard_sent", "request": request, "status": status}));
                st.clip_results.insert(request, status);
            }
            Event::Error { text } => {
                self.note(json!({"event": "error", "text": text}));
                st.errors += 1;
            }
            Event::Dropped { count } => {
                self.note(json!({"event": "dropped", "count": count}));
                st.dropped += count;
            }
            _ => {}
        }
        drop(st);
        self.cv.notify_all();
    }
}

struct PeerConfig {
    name: String,
    platform: String,
    state: PathBuf,
    received: PathBuf,
    /// Clipboard on (soak and acceptance runs); the stress scenarios keep it off.
    clipboard: bool,
}

fn start_peer(cfg: &PeerConfig, sh: &Arc<Shared>) -> Result<Arc<Client>, String> {
    let mut config = Config::new(&cfg.name, &cfg.platform);
    config.listen = false;
    config.discovery = false;
    config.receive_dir = Some(cfg.received.clone());
    // Files, and the clipboard only when asked for (nothing of a real clipboard is involved: the apps under test send
    // the texts they are told to). No ping: it plays a sound on the app's device.
    config.defaults.set("files", true);
    config.defaults.set("clipboard", cfg.clipboard);
    config.defaults.set("ping", false);
    let storage = Arc::new(FileStorage::new(&cfg.state)?);
    let client = Arc::new(Client::start(config, storage).map_err(|e| format!("peer start: {e}"))?);
    {
        let mut st = sh.st.lock().unwrap();
        st.connected = None;
        st.features = None;
        // A new client numbers its transfers from 1 again.
        st.transfers.clear();
    }
    let (c, s) = (client.clone(), sh.clone());
    std::thread::spawn(move || loop {
        match c.next_event(Duration::from_millis(500)) {
            Next::Closed => return,
            Next::Timeout => {}
            Next::Event(e) => s.apply(&c, e),
        }
    });
    Ok(client)
}

// ---------------------------------------------------------------------------------------------------------------
// The app, through its control program

struct App {
    program: String,
    args: Vec<String>,
}

impl App {
    fn call(&self, verb: &str, rest: &[String]) -> Result<Value, String> {
        let out = Command::new(&self.program).args(&self.args).arg(verb).args(rest).output().map_err(|e| format!("{verb}: {e}"))?;
        let stdout = String::from_utf8_lossy(&out.stdout);
        let line = stdout.lines().rev().find(|l| l.trim_start().starts_with('{')).unwrap_or("");
        let v: Value = serde_json::from_str(line).unwrap_or(Value::Null);
        if !out.status.success() || v.get("ok") == Some(&Value::Bool(false)) || v.is_null() {
            let err = String::from_utf8_lossy(&out.stderr);
            let why = v.get("error").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| err.lines().last().unwrap_or("").to_string());
            return Err(format!("app {verb}: {why}"));
        }
        Ok(v)
    }

    fn verb(&self, verb: &str) -> Result<Value, String> {
        self.call(verb, &[])
    }
}

// ---------------------------------------------------------------------------------------------------------------
// One run

struct Opts {
    target: SocketAddr,
    proxy_port: u16,
    big: Vec<u64>,
    mid: u64,
    small: usize,
    rounds: usize,
    loops: usize,
    seed: u64,
}

struct Scenario {
    name: String,
    t0: Instant,
    failures: Vec<String>,
    metrics: Map<String, Value>,
    rounds: Vec<Value>,
}

impl Scenario {
    fn check(&mut self, ok: bool, what: impl Into<String>) {
        if !ok {
            let what = what.into();
            eprintln!("  FAIL {}: {what}", self.name);
            self.failures.push(what);
        }
    }

    fn metric(&mut self, key: &str, v: impl Into<Value>) {
        self.metrics.insert(key.into(), v.into());
    }
}

struct Run {
    opts: Opts,
    app: App,
    proxy: Proxy,
    sh: Arc<Shared>,
    cfg: PeerConfig,
    client: Arc<Client>,
    device: Option<String>,
    rng: Rng,
    src: PathBuf,
    run_id: String,
    counter: u64,
    app_down: bool,
    expected: HashMap<(u64, u64), String>,
    sources: HashMap<(u64, u64), (PathBuf, String)>,
}

type Step = Result<(), String>;

impl Run {
    fn name(&mut self, tag: &str) -> String {
        self.counter += 1;
        format!("stress-{tag}-{}-{}.bin", self.run_id, self.counter)
    }

    /// Below 2^63, so the Android control (Kotlin `Long`) reads it as it is.
    fn seed(&mut self) -> u64 {
        self.rng.0.next() >> 1
    }

    fn device(&self) -> Result<String, String> {
        self.device.clone().ok_or_else(|| "not paired".to_string())
    }

    fn connected(&self) -> bool {
        let st = self.sh.st.lock().unwrap();
        st.connected.is_some() && st.connected == self.device && st.features.is_some()
    }

    /// Connected with features from the app, asking the peer to dial at once now and then. Returns the seconds taken.
    fn ensure_connected(&self, timeout: Duration) -> Result<f64, String> {
        let device = self.device()?;
        let t0 = Instant::now();
        let deadline = t0 + timeout;
        loop {
            let _ = self.client.connect(&device);
            let ok = self.sh.wait(Duration::from_secs(3), |st| (st.connected.as_deref() == Some(device.as_str()) && st.features.is_some()).then_some(()));
            if ok.is_some() {
                return Ok(secs(t0.elapsed()));
            }
            if Instant::now() >= deadline {
                return Err(format!("not connected after {}s", timeout.as_secs()));
            }
        }
    }

    fn wait_disconnected(&self, timeout: Duration) -> Option<f64> {
        let t0 = Instant::now();
        self.sh.wait(timeout, |st| st.connected.is_none().then_some(())).map(|_| secs(t0.elapsed()))
    }

    fn transfer(&self, id: u64) -> Transfer {
        self.sh.st.lock().unwrap().transfers.get(&id).cloned().unwrap_or_default()
    }

    /// A source file of `Gen` bytes in the work folder, made once per size and seed.
    fn source(&mut self, size: u64, seed: u64) -> Result<(PathBuf, String), String> {
        if let Some(s) = self.sources.get(&(size, seed)) {
            return Ok(s.clone());
        }
        let path = self.src.join(format!("{}-{seed:016x}.bin", size_label(size)));
        let sha_path = path.with_extension("sha256");
        let cached = std::fs::read_to_string(&sha_path).ok().filter(|_| std::fs::metadata(&path).is_ok_and(|m| m.len() == size));
        let sha = match cached {
            Some(s) => s.trim().to_string(),
            None => {
                let sha = write_generated(&path, size, seed).map_err(|e| format!("source: {e}"))?;
                std::fs::write(&sha_path, &sha).map_err(|e| e.to_string())?;
                sha
            }
        };
        self.sources.insert((size, seed), (path.clone(), sha.clone()));
        Ok((path, sha))
    }

    fn expected(&mut self, size: u64, seed: u64) -> String {
        if let Some(s) = self.expected.get(&(size, seed)) {
            return s.clone();
        }
        let sha = generate(size, seed, |_| Ok(())).expect("generating in memory");
        self.expected.insert((size, seed), sha.clone());
        sha
    }

    /// Sends a file from this end under `name`; returns the transfer.
    fn send(&self, path: &Path, name: &str) -> Result<u64, String> {
        let device = self.device()?;
        let id = self.client.send_file(&device, path, Some(name), None).map_err(|e| format!("send {name}: {e}"))?;
        let mut st = self.sh.st.lock().unwrap();
        let t = st.transfers.entry(id).or_default();
        t.name = name.to_string();
        t.seen.get_or_insert(Instant::now());
        Ok(id)
    }

    /// The app sends files made from these specs.
    fn app_send(&self, files: &[(String, u64, u64)]) -> Step {
        let specs: Vec<String> = files.iter().map(|(n, size, seed)| format!("{n}:{size}:{seed}")).collect();
        self.app.call("send", &specs).map(|_| ())
    }

    /// The newest transfer coming in under `name` that started after `since`.
    fn wait_incoming(&self, name: &str, since: Instant, timeout: Duration) -> Option<u64> {
        self.sh.wait(timeout, |st| st.transfers.iter().filter(|(_, t)| t.incoming && t.name == name && t.seen.is_some_and(|s| s >= since)).map(|(id, _)| *id).max())
    }

    fn wait_bytes(&self, id: u64, bytes: u64, timeout: Duration) -> Result<u64, String> {
        self.sh
            .wait(timeout, |st| st.transfers.get(&id).filter(|t| t.bytes >= bytes || t.ended.is_some()).map(|t| (t.bytes, t.ended.is_some(), t.failed.clone())))
            .ok_or_else(|| format!("transfer {id} did not reach {} MiB", mb(bytes)))
            .and_then(|(b, ended, failed)| if ended && b < bytes { Err(format!("transfer {id} ended at {} MiB ({failed:?})", mb(b))) } else { Ok(b) })
    }

    fn wait_end(&self, id: u64, timeout: Duration) -> Result<Transfer, String> {
        self.sh.wait(timeout, |st| st.transfers.get(&id).filter(|t| t.ended.is_some()).cloned()).ok_or_else(|| format!("transfer {id} did not end in {}s", timeout.as_secs()))
    }

    fn timeout_for(&self, size: u64) -> Duration {
        Duration::from_secs(180 + size / (4 * MIB))
    }

    fn app_received(&self, names: &[String]) -> Result<HashMap<String, (u64, String)>, String> {
        let mut out = HashMap::new();
        for batch in names.chunks(50) {
            let v = self.app.call("received", batch)?;
            for f in v.get("files").and_then(Value::as_array).cloned().unwrap_or_default() {
                let name = f.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                if f.get("missing").and_then(Value::as_bool) == Some(true) {
                    continue;
                }
                let size = f.get("size").and_then(Value::as_u64).unwrap_or(0);
                let sha = f.get("sha256").and_then(Value::as_str).unwrap_or("").to_string();
                out.insert(name, (size, sha));
            }
        }
        Ok(out)
    }

    fn app_partials(&self) -> Result<Vec<String>, String> {
        let v = self.app.verb("partials")?;
        Ok(v.get("partials").and_then(Value::as_array).cloned().unwrap_or_default().iter().map(|p| p.get("name").and_then(Value::as_str).unwrap_or("?").to_string()).collect())
    }

    /// Waits up to `timeout` for the app to hold `text` as its newest received clipboard text (the Mac test instance
    /// reports it in a status file it rewrites five times a second); returns what it held last and the seconds taken.
    fn app_clip_holds(&self, text: &str, timeout: Duration) -> (Option<String>, f64) {
        let t0 = Instant::now();
        loop {
            let held = self.app.verb("clip-status").ok().and_then(|v| v.get("text").and_then(Value::as_str).map(str::to_string));
            if held.as_deref() == Some(text) || t0.elapsed() >= timeout {
                return (held, secs(t0.elapsed()));
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    fn app_active(&self) -> Result<u64, String> {
        Ok(self.app.verb("status")?.get("active").and_then(Value::as_u64).unwrap_or(0))
    }

    /// Waits until the app shows no running transfer and no partial; returns what is left after `timeout`.
    fn app_settled(&self, timeout: Duration) -> (u64, Vec<String>) {
        let deadline = Instant::now() + timeout;
        loop {
            let active = self.app_active().unwrap_or(u64::MAX);
            let partials = self.app_partials().unwrap_or_else(|e| vec![e]);
            if (active == 0 && partials.is_empty()) || Instant::now() >= deadline {
                return (active, partials);
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    fn peer_partials(&self) -> Vec<String> {
        std::fs::read_dir(&self.cfg.received)
            .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.starts_with(".bridgey-") && n.ends_with(".part")).collect())
            .unwrap_or_default()
    }

    /// Records of partials this end keeps for `size` bytes (files_resume_draft1, in the peer's storage).
    fn peer_records(&self, size: u64) -> usize {
        let text = std::fs::read_to_string(self.cfg.state.join("file-resume.json")).unwrap_or_default();
        let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
        v.get("records").and_then(Value::as_array).map(|a| a.iter().filter(|r| r.get("size").and_then(Value::as_u64) == Some(size)).count()).unwrap_or(0)
    }

    /// Checks the file this end received against the bytes it should hold, then deletes it.
    fn check_received(&self, sc: &mut Scenario, t: &Transfer, sha: &str) {
        match t.path.as_deref().map(|p| (p, file_sha(Path::new(p)))) {
            Some((p, Ok((size, got)))) => {
                sc.check(got == sha, format!("{}: SHA-256 {got}, expected {sha} ({size} bytes)", t.name));
                let _ = std::fs::remove_file(p);
            }
            Some((p, Err(e))) => sc.check(false, format!("{}: cannot read {p}: {e}", t.name)),
            None => sc.check(false, format!("{}: no path", t.name)),
        }
    }

    fn check_app_copy(&self, sc: &mut Scenario, name: &str, size: u64, sha: &str) {
        match self.app_received(&[name.to_string()]) {
            Ok(files) => match files.get(name) {
                Some((s, got)) => sc.check(*s == size && got == sha, format!("{name} on the app: {s} bytes, SHA-256 {got}; expected {size}, {sha}")),
                None => sc.check(false, format!("{name} is not on the app")),
            },
            Err(e) => sc.check(false, e),
        }
    }

    /// Between scenarios: the link open, the app up and connected, nothing running, every stress file gone.
    fn settle(&mut self) -> Step {
        self.proxy.hold(false);
        self.proxy.limit(0);
        if self.app_down {
            self.app.verb("start")?;
            self.app_down = false;
        }
        self.ensure_connected(Duration::from_secs(120))?;
        let running: Vec<u64> = self.sh.st.lock().unwrap().transfers.iter().filter(|(_, t)| t.ended.is_none()).map(|(id, _)| *id).collect();
        for id in running {
            let _ = self.client.cancel_file(id);
        }
        let _ = self.app.verb("cancel");
        let _ = self.app_settled(Duration::from_secs(15));
        self.app.verb("clean")?;
        if let Ok(d) = std::fs::read_dir(&self.cfg.received) {
            for e in d.flatten() {
                let _ = std::fs::remove_file(e.path());
            }
        }
        Ok(())
    }

    fn restart_peer(&mut self) -> Step {
        self.client.stop();
        std::thread::sleep(Duration::from_millis(500));
        self.client = start_peer(&self.cfg, &self.sh)?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Scenarios

const ALL: &[&str] = &[
    "pair", "send-big", "recv-big", "small-send", "small-recv", "cancel-peer-send", "cancel-app-recv", "cancel-peer-recv", "cancel-app-send", "drop-send", "drop-recv", "stall-send",
    "stall-recv", "restart-app-send", "restart-app-recv", "restart-peer-send", "restart-peer-recv", "multi-drop-send", "multi-drop-recv", "reconnect-loop",
];
const QUICK: &[&str] = &["pair", "send-big", "recv-big", "small-send", "small-recv", "cancel-peer-send", "cancel-app-send", "drop-send", "drop-recv", "restart-app-send", "reconnect-loop"];

fn run_scenario(run: &mut Run, sc: &mut Scenario) -> Step {
    match sc.name.as_str() {
        "pair" => pair(run, sc),
        "send-big" => {
            for size in run.opts.big.clone() {
                send_whole(run, sc, size)?;
            }
            Ok(())
        }
        "recv-big" => {
            for size in run.opts.big.clone() {
                recv_whole(run, sc, size)?;
            }
            Ok(())
        }
        "small-send" => small(run, sc, false),
        "small-recv" => small(run, sc, true),
        "cancel-peer-send" => cancel(run, sc, false, false),
        "cancel-app-recv" => cancel(run, sc, false, true),
        "cancel-peer-recv" => cancel(run, sc, true, false),
        "cancel-app-send" => cancel(run, sc, true, true),
        "drop-send" => interrupt(run, sc, false, Cut::Drop),
        "drop-recv" => interrupt(run, sc, true, Cut::Drop),
        "stall-send" => interrupt(run, sc, false, Cut::Stall),
        "stall-recv" => interrupt(run, sc, true, Cut::Stall),
        "restart-app-send" => interrupt(run, sc, false, Cut::KillApp),
        "restart-app-recv" => interrupt(run, sc, true, Cut::KillApp),
        "restart-peer-send" => interrupt(run, sc, false, Cut::RestartPeer),
        "restart-peer-recv" => interrupt(run, sc, true, Cut::RestartPeer),
        "multi-drop-send" => multi_drop(run, sc, false),
        "multi-drop-recv" => multi_drop(run, sc, true),
        "reconnect-loop" => reconnect_loop(run, sc),
        other => Err(format!("unknown scenario {other}")),
    }
}

/// Pairs (the app allows pairing and confirms the code) or, when this peer already trusts a device, reconnects.
fn pair(run: &mut Run, sc: &mut Scenario) -> Step {
    let snapshot = run.client.snapshot();
    let trusted: Vec<String> = snapshot["devices"].as_array().cloned().unwrap_or_default().iter().filter_map(|d| d["deviceId"].as_str().map(str::to_string)).collect();
    if let Some(id) = trusted.first() {
        run.device = Some(id.clone());
        match run.ensure_connected(Duration::from_secs(60)) {
            Ok(s) => {
                sc.metric("mode", "reconnect");
                sc.metric("connect_seconds", s);
            }
            Err(_) => {
                // The app forgot this peer (a fresh install): pair again.
                let _ = run.client.forget(id);
                run.device = None;
            }
        }
    }
    if run.device.is_none() {
        let t0 = Instant::now();
        run.app.verb("pair-prepare")?;
        {
            let mut st = run.sh.st.lock().unwrap();
            st.paired = None;
            st.code = None;
        }
        run.client.pair(None, Some("127.0.0.1"), run.proxy.port).map_err(|e| format!("pair: {e}"))?;
        let deadline = Instant::now() + Duration::from_secs(120);
        let device = loop {
            let finished = run.sh.wait(Duration::from_secs(1), |st| st.paired.clone());
            if let Some((ok, reason, device)) = finished {
                if !ok {
                    return Err(format!("pairing failed: {reason}"));
                }
                break device.ok_or("paired without a device ID")?;
            }
            if run.sh.st.lock().unwrap().code.is_some() {
                let _ = run.app.verb("pair-confirm");
            }
            if Instant::now() >= deadline {
                return Err("pairing did not finish in 120 s".into());
            }
        };
        run.device = Some(device);
        sc.metric("mode", "paired");
        sc.metric("pair_seconds", secs(t0.elapsed()));
        sc.metric("code", run.sh.st.lock().unwrap().code.clone().unwrap_or_default());
        sc.metric("connect_seconds", run.ensure_connected(Duration::from_secs(60))?);
    }
    let features = run.sh.st.lock().unwrap().features.clone().unwrap_or(Value::Null);
    for key in ["files", "files_fast_draft1", "files_resume_draft1"] {
        sc.check(features.get(key).and_then(Value::as_bool) == Some(true), format!("the app does not show {key}"));
    }
    sc.metric("app_device", run.device.clone().unwrap_or_default());
    sc.metric("app_features", features);
    Ok(())
}

/// A whole file from this end to the app, checked there.
fn send_whole(run: &mut Run, sc: &mut Scenario, size: u64) -> Step {
    // The app refuses a file without room for it and 64 MiB more.
    let free = run.app.verb("status")?.get("free").and_then(Value::as_i64).unwrap_or(-1);
    if free >= 0 && (free as u64) < size + 96 * MIB {
        sc.rounds.push(json!({"size": size, "skipped": format!("the app has {} MiB free", mb(free as u64))}));
        sc.check(false, format!("send {}: skipped, the app has only {} MiB free", size_label(size), mb(free as u64)));
        return Ok(());
    }
    let seed = 0x5EED_0000 + size / MIB;
    let t_gen = Instant::now();
    let (path, sha) = run.source(size, seed)?;
    let gen_seconds = secs(t_gen.elapsed());
    let name = run.name(&format!("send-{}", size_label(size)));
    let t0 = Instant::now();
    let id = run.send(&path, &name)?;
    let t = run.wait_end(id, run.timeout_for(size))?;
    let total = secs(t0.elapsed());
    sc.check(t.done, format!("{name}: {:?}", t.failed));
    sc.check(t.resumed_at.is_none(), format!("{name}: a fresh send resumed at {:?}", t.resumed_at));
    let moving = t.moving.zip(t.ended).map(|(a, b)| secs(b - a)).unwrap_or(0.0);
    let t_check = Instant::now();
    if t.done {
        run.check_app_copy(sc, &name, size, &sha);
    }
    let (active, partials) = run.app_settled(Duration::from_secs(10));
    sc.check(active == 0 && partials.is_empty(), format!("{name}: after it, the app shows {active} running and partials {partials:?}"));
    sc.rounds.push(json!({"size": size, "name": name, "done": t.done, "seconds_total": total, "seconds_moving": moving,
        "mib_per_s": rate(size, moving), "source_seconds": gen_seconds, "check_seconds": secs(t_check.elapsed())}));
    let _ = run.app.verb("clean");
    Ok(())
}

/// A whole file from the app to this end, checked here.
fn recv_whole(run: &mut Run, sc: &mut Scenario, size: u64) -> Step {
    // The app writes the file it sends first.
    let free = run.app.verb("status")?.get("free").and_then(Value::as_i64).unwrap_or(-1);
    if free >= 0 && (free as u64) < size + 32 * MIB {
        sc.rounds.push(json!({"size": size, "skipped": format!("the app has {} MiB free", mb(free as u64))}));
        sc.check(false, format!("recv {}: skipped, the app has only {} MiB free", size_label(size), mb(free as u64)));
        return Ok(());
    }
    let seed = 0xA99_0000 + size / MIB;
    let name = run.name(&format!("recv-{}", size_label(size)));
    let sha = run.expected(size, seed);
    let since = Instant::now();
    run.app_send(&[(name.clone(), size, seed)])?;
    // The app writes the source first (an emulator takes a while for gigabytes), then hashes and offers it.
    let id = run.wait_incoming(&name, since, run.timeout_for(size)).ok_or_else(|| format!("{name} never came"))?;
    let offered = secs(since.elapsed());
    let t = run.wait_end(id, run.timeout_for(size))?;
    sc.check(t.done, format!("{name}: {:?}", t.failed));
    sc.check(t.resumed_at.is_none(), format!("{name}: a fresh send resumed at {:?}", t.resumed_at));
    let moving = t.moving.zip(t.ended).map(|(a, b)| secs(b - a)).unwrap_or(0.0);
    if t.done {
        run.check_received(sc, &t, &sha);
    }
    sc.check(run.peer_partials().is_empty(), format!("{name}: partials left here {:?}", run.peer_partials()));
    sc.rounds.push(json!({"size": size, "name": name, "done": t.done, "seconds_until_offered": offered, "seconds_moving": moving, "mib_per_s": rate(size, moving)}));
    let _ = run.app.verb("clean");
    Ok(())
}

/// Many small files, sizes from 0 bytes to 3 MiB (a few just over the 1 MiB resume threshold), in one batch.
fn small(run: &mut Run, sc: &mut Scenario, from_app: bool) -> Step {
    let n = run.opts.small.max(4);
    let mut files: Vec<(String, u64, u64)> = Vec::new();
    for i in 0..n {
        let size = match i {
            0 => 0,
            1 => MIB,
            2 => MIB + 1,
            3 => 1,
            _ => match run.rng.below(4) {
                0 => run.rng.below(4096),
                1 | 2 => 4096 + run.rng.below(256 * 1024),
                _ => 256 * 1024 + run.rng.below(3 * MIB),
            },
        };
        let tag = if from_app { "srecv" } else { "ssend" };
        let name = run.name(tag);
        let seed = run.seed();
        files.push((name, size, seed));
    }
    let total: u64 = files.iter().map(|f| f.1).sum();
    let t0 = Instant::now();
    let mut ok = 0usize;
    if from_app {
        let since = Instant::now();
        run.app_send(&files)?;
        let names: Vec<String> = files.iter().map(|f| f.0.clone()).collect();
        let done = run.sh.wait(Duration::from_secs(300 + total / MIB * 2), |st| {
            let ended = st.transfers.values().filter(|t| t.incoming && t.ended.is_some() && t.seen.is_some_and(|s| s >= since) && names.contains(&t.name)).count();
            (ended >= names.len()).then_some(())
        });
        sc.check(done.is_some(), "not every file arrived in time");
        let transfers: Vec<Transfer> = run.sh.st.lock().unwrap().transfers.values().filter(|t| t.incoming && t.seen.is_some_and(|s| s >= since)).cloned().collect();
        for (name, size, seed) in &files {
            let sha = run.expected(*size, *seed);
            match transfers.iter().find(|t| &t.name == name && t.done) {
                Some(t) => {
                    let before = sc.failures.len();
                    run.check_received(sc, t, &sha);
                    if sc.failures.len() == before {
                        ok += 1;
                    }
                }
                None => sc.check(false, format!("{name} ({size} bytes): {:?}", transfers.iter().find(|t| &t.name == name).and_then(|t| t.failed.clone()))),
            }
        }
    } else {
        let mut ids = Vec::new();
        let mut shas = HashMap::new();
        for (name, size, seed) in &files {
            let (path, sha) = run.source(*size, *seed)?;
            shas.insert(name.clone(), (*size, sha));
            ids.push((run.send(&path, name)?, name.clone()));
        }
        for (id, name) in &ids {
            let t = run.wait_end(*id, Duration::from_secs(300))?;
            sc.check(t.done, format!("{name}: {:?}", t.failed));
        }
        let names: Vec<String> = ids.iter().map(|(_, n)| n.clone()).collect();
        let copies = run.app_received(&names)?;
        for name in &names {
            let (size, sha) = &shas[name];
            match copies.get(name) {
                Some((s, got)) if s == size && got == sha => ok += 1,
                Some((s, got)) => sc.check(false, format!("{name} on the app: {s} bytes {got}, expected {size} {sha}")),
                None => sc.check(false, format!("{name} ({size} bytes) is not on the app")),
            }
        }
    }
    let seconds = secs(t0.elapsed());
    let (active, partials) = run.app_settled(Duration::from_secs(10));
    sc.check(active == 0 && partials.is_empty(), format!("after the batch the app shows {active} running and partials {partials:?}"));
    sc.check(run.peer_partials().is_empty(), format!("partials left here {:?}", run.peer_partials()));
    sc.metric("files", n);
    sc.metric("verified", ok);
    sc.metric("bytes", total);
    sc.metric("seconds", seconds);
    sc.metric("files_per_s", (n as f64 / seconds * 10.0).round() / 10.0);
    sc.metric("mib_per_s", rate(total, seconds));
    Ok(())
}

/// Cancels a mid-size file at a random point, from this end or the app's, in either direction. Then both ends must
/// agree it is over: the right reason here, nothing running and no partial on either side, no record kept here, and
/// the same file sent again starts from zero and arrives whole. A cancelled file the app sent must not come back
/// after a reconnect either.
fn cancel(run: &mut Run, sc: &mut Scenario, from_app: bool, by_app: bool) -> Step {
    let size = run.opts.mid;
    for round in 0..run.opts.rounds {
        let seed = 0xCA_0000 + round as u64 + if from_app { 0x100 } else { 0 };
        let name = run.name(if from_app { "crecv" } else { "csend" });
        let mut r = Map::new();
        // The file takes at least five seconds either way, so a cancel lands mid-file even on a fast link (a hosted
        // runner finished 64 MiB before this end's own cancel). The app's cancel goes through its control program and
        // lands later, so its point is earlier. A file that still finished first is tried again near its start.
        let mut attempt = 0;
        let (id, sha, t_cancel) = loop {
            attempt += 1;
            run.proxy.limit(size / 5);
            let at = match (attempt, by_app) {
                (1, true) => run.rng.between(0.05, 0.5),
                (1, false) => run.rng.between(0.05, 0.95),
                _ => run.rng.between(0.02, 0.1),
            };
            let cut = (size as f64 * at) as u64;
            r.insert("cut_fraction".into(), json!((at * 1000.0).round() / 1000.0));
            let since = Instant::now();
            let (id, sha) = if from_app {
                let sha = run.expected(size, seed);
                run.app_send(&[(name.clone(), size, seed)])?;
                (run.wait_incoming(&name, since, run.timeout_for(size)).ok_or("the file never came")?, sha)
            } else {
                let (path, sha) = run.source(size, seed)?;
                (run.send(&path, &name)?, sha)
            };
            let reached = run.wait_bytes(id, cut, run.timeout_for(size))?;
            let t_cancel = Instant::now();
            if by_app {
                run.app.verb("cancel")?;
            } else if let Err(e) = run.client.cancel_file(id) {
                // Refused only when the transfer already ended: finished first, tried again below.
                if !run.wait_end(id, Duration::from_secs(5)).is_ok_and(|t| t.done) {
                    return Err(format!("cancel: {e}"));
                }
            }
            let t = run.wait_end(id, Duration::from_secs(30))?;
            r.insert("cancelled_at_mib".into(), json!(mb(reached)));
            if t.done && attempt < 3 {
                r.insert("first_try_finished_before_the_cancel".into(), json!(true));
                run.settle()?;
                continue;
            }
            break (id, sha, t_cancel);
        };
        run.proxy.limit(0);
        let t = run.transfer(id);
        r.insert("seconds_to_end".into(), json!(t.ended.map(|e| secs(e.saturating_duration_since(t_cancel)))));
        r.insert("reason".into(), json!(t.failed));
        let want = if by_app { "cancelled_remote" } else { "cancelled" };
        sc.check(t.failed.as_deref() == Some(want), format!("round {round}: ended with {:?} (done {}), expected {want}", t.failed, t.done));
        let (active, partials) = run.app_settled(Duration::from_secs(15));
        sc.check(active == 0, format!("round {round}: the app still shows {active} transfer(s) running"));
        sc.check(partials.is_empty(), format!("round {round}: partials left on the app {partials:?}"));
        sc.check(run.peer_partials().is_empty(), format!("round {round}: partials left here {:?}", run.peer_partials()));
        sc.check(run.peer_records(size) == 0, format!("round {round}: a resume record kept here after a cancel"));
        if from_app {
            // A cancelled file is not sent again by itself after a reconnect.
            run.proxy.cut();
            run.wait_disconnected(Duration::from_secs(15));
            run.ensure_connected(Duration::from_secs(60))?;
            let back = run.wait_incoming(&name, t_cancel, Duration::from_secs(15));
            sc.check(back.is_none(), format!("round {round}: the cancelled file came back after a reconnect"));
            if let Some(b) = back {
                let _ = run.client.cancel_file(b);
                let _ = run.wait_end(b, Duration::from_secs(30));
            }
        }
        // The same file again: from byte zero (nothing was kept) and whole.
        let since = Instant::now();
        let again = if from_app {
            run.app_send(&[(name.clone(), size, seed)])?;
            run.wait_incoming(&name, since, run.timeout_for(size)).ok_or("the file did not come again")?
        } else {
            let (path, _) = run.source(size, seed)?;
            run.send(&path, &name)?
        };
        let t2 = run.wait_end(again, run.timeout_for(size))?;
        sc.check(t2.done, format!("round {round}: sending it again: {:?}", t2.failed));
        sc.check(t2.resumed_at.is_none(), format!("round {round}: sending it again resumed at {:?} after a cancel", t2.resumed_at));
        if t2.done {
            if from_app {
                run.check_received(sc, &t2, &sha);
            } else {
                run.check_app_copy(sc, &name, size, &sha);
            }
        }
        r.insert("again_seconds".into(), json!(t2.moving.zip(t2.ended).map(|(a, b)| secs(b - a))));
        sc.rounds.push(Value::Object(r));
        run.settle()?;
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Cut {
    /// The connection closes (both ends see it).
    Drop,
    /// Nothing moves until both ends' heartbeats give up, then the link comes back.
    Stall,
    /// The app's process ends at once and starts again.
    KillApp,
    /// This end stops and starts again with the same identity and storage.
    RestartPeer,
}

/// Interrupts a mid-size file at a random point and checks it resumes. Files the app sends come back by themselves
/// on reconnect (Resume interrupted files automatically, on by default), except after the app restarts (its list is
/// in memory), when the runner sends the file again. Files this end sends are sent again here (the session client does
/// not retry by itself). The resume must start at a whole block, at most what the receiver could have verified, and
/// not much less; the file must arrive whole.
fn interrupt(run: &mut Run, sc: &mut Scenario, from_app: bool, how: Cut) -> Step {
    let size = run.opts.mid;
    let rounds = if matches!(how, Cut::Stall) { 1 } else { run.opts.rounds };
    for round in 0..rounds {
        let seed = 0x1E_0000 + (round as u64) + ((how as u64) << 8) + if from_app { 0x1000 } else { 0 };
        let tag = format!("{}{how:?}", if from_app { "r" } else { "s" }).to_ascii_lowercase();
        let name = run.name(&tag);
        let mut r = Map::new();
        // A file that finished before the cut landed is tried once more, cut nearer its start. The file takes at least
        // five seconds, so the cut lands near its point (progress comes four times a second) and a kill, which goes
        // through the app's control program, lands mid-file.
        let mut attempt = 0;
        let (at_cut, t_cut, sha, path) = loop {
            attempt += 1;
            run.proxy.limit(size / 5);
            // A kill needs a 64 MiB checkpoint behind it to have anything to resume from.
            let kill_floor = (0.3f64).max(80.0 * MIB as f64 / size as f64).min(0.7);
            let at = match (attempt, how) {
                (1, Cut::KillApp) => run.rng.between(kill_floor, 0.75_f64.max(kill_floor + 0.05)),
                (1, _) => run.rng.between(0.1, 0.75),
                (_, Cut::KillApp) => run.rng.between(kill_floor, kill_floor + 0.05),
                _ => run.rng.between(0.05, 0.3),
            };
            let cut = (size as f64 * at) as u64;
            r.insert("cut_fraction".into(), json!((at * 1000.0).round() / 1000.0));
            let since = Instant::now();
            let (id, sha, path) = if from_app {
                let sha = run.expected(size, seed);
                run.app_send(&[(name.clone(), size, seed)])?;
                (run.wait_incoming(&name, since, run.timeout_for(size)).ok_or("the file never came")?, sha, None)
            } else {
                let (path, sha) = run.source(size, seed)?;
                (run.send(&path, &name)?, sha, Some(path))
            };
            let reached = run.wait_bytes(id, cut, run.timeout_for(size))?;
            let t_cut = Instant::now();
            match how {
                Cut::Drop => {
                    run.proxy.cut();
                }
                Cut::Stall => run.proxy.hold(true),
                Cut::KillApp => {
                    run.app.verb("kill")?;
                    run.app_down = true;
                }
                Cut::RestartPeer => {}
            }
            let before = run.transfer(id);
            let at_cut = before.bytes.max(reached);
            r.insert("cut_at_mib".into(), json!(mb(at_cut)));
            let mut finished = if how == Cut::RestartPeer {
                let done = before.done;
                run.restart_peer()?;
                done
            } else {
                let t = run.wait_end(id, Duration::from_secs(if how == Cut::Stall { 120 } else { 30 }))?;
                r.insert("first_attempt_ended".into(), json!(t.failed));
                r.insert("seconds_to_notice".into(), json!(secs(t_cut.elapsed())));
                if !t.done {
                    sc.check(t.failed.as_deref() == Some("interrupted"), format!("round {round}: the first attempt ended with {:?}, expected interrupted", t.failed));
                }
                t.done
            };
            if how == Cut::Stall {
                run.wait_disconnected(Duration::from_secs(90));
                run.proxy.hold(false);
                run.proxy.cut();
            } else if how != Cut::RestartPeer {
                // The file can end here before the session's own end is reported: reconnect only after it.
                run.wait_disconnected(Duration::from_secs(15));
            }
            if how == Cut::KillApp {
                let t_start = Instant::now();
                run.app.verb("start")?;
                run.app_down = false;
                r.insert("app_start_seconds".into(), json!(secs(t_start.elapsed())));
            }
            // The last bytes can reach the receiver after the last progress this end saw: then the file is whole there.
            if !finished {
                finished = if from_app {
                    run.cfg.received.join(&name).exists()
                } else {
                    run.app_partials().is_ok_and(|p| p.is_empty()) && run.app_received(std::slice::from_ref(&name)).is_ok_and(|f| f.get(&name).is_some_and(|(n, _)| *n == size))
                };
            }
            if finished && attempt == 1 {
                r.insert("first_try_finished_before_the_cut".into(), json!(true));
                run.settle()?;
                continue;
            }
            sc.check(!finished, format!("round {round}: the file finished before the cut twice"));
            break (at_cut, t_cut, sha, path);
        };
        run.proxy.limit(0);
        if from_app {
            let kept = run.peer_partials();
            sc.check(kept.len() == 1, format!("round {round}: this end kept {kept:?}, expected one partial"));
        } else if let Ok(p) = run.app_partials() {
            // After a kill, the partial outlived it: its record from the start or the last checkpoint, past the start-up
            // sweep.
            r.insert("app_partials".into(), json!(p));
            sc.check(p.len() == 1, format!("round {round}: the app kept {p:?}, expected one partial"));
        }
        let back = run.ensure_connected(Duration::from_secs(120))?;
        r.insert("reconnect_seconds".into(), json!(secs(t_cut.elapsed())));
        r.insert("connect_after_ready_seconds".into(), json!(back));
        let connected_at = Instant::now();
        let again = if from_app {
            let auto = run.wait_incoming(&name, t_cut, Duration::from_secs(45));
            r.insert("auto_retry".into(), json!(auto.is_some()));
            match (auto, how) {
                (Some(a), _) => {
                    r.insert("auto_retry_seconds".into(), json!(run.transfer(a).seen.map(|s| secs(s.saturating_duration_since(connected_at)))));
                    if how == Cut::KillApp {
                        r.insert("note".into(), json!("the app sent it again after its restart"));
                    }
                    a
                }
                (None, Cut::KillApp) => {
                    // Expected: the retry list lives in memory. The same file sent again still resumes here.
                    let since = Instant::now();
                    run.app_send(&[(name.clone(), size, seed)])?;
                    run.wait_incoming(&name, since, run.timeout_for(size)).ok_or("the file did not come again")?
                }
                (None, _) => {
                    sc.check(false, format!("round {round}: the app did not send the file again by itself within 45 s"));
                    let since = Instant::now();
                    run.app_send(&[(name.clone(), size, seed)])?;
                    run.wait_incoming(&name, since, run.timeout_for(size)).ok_or("the file did not come again")?
                }
            }
        } else {
            run.send(path.as_deref().unwrap(), &name)?
        };
        let t = run.wait_end(again, run.timeout_for(size))?;
        let resumed = t.resumed_at.unwrap_or(0);
        let lost = at_cut.saturating_sub(resumed);
        r.insert("resumed_at_mib".into(), json!(mb(resumed)));
        r.insert("lost_mib".into(), json!(mb(lost)));
        r.insert("second_attempt_seconds".into(), json!(t.moving.zip(t.ended).map(|(a, b)| secs(b - a))));
        sc.check(t.done, format!("round {round}: the second attempt: {:?}", t.failed));
        sc.check(resumed > 0, format!("round {round}: it started again from zero (cut at {} MiB)", mb(at_cut)));
        sc.check(resumed.is_multiple_of(MIB) && resumed <= size, format!("round {round}: resumed at {resumed}, not a whole block within the file"));
        // This end is the receiver: it keeps all it verified. The app as receiver keeps its verified bytes on a clean end
        // and its last checkpoint when killed; the sender may be up to its window ahead.
        let allowed = if from_app { OWN_LOSS } else if how == Cut::KillApp { KILL_LOSS } else { CUT_LOSS };
        sc.check(lost <= allowed, format!("round {round}: resumed {} MiB before the cut point, more than the {} MiB expected", mb(lost), mb(allowed)));
        sc.check(resumed <= at_cut + 64 * MIB, format!("round {round}: resumed at {} MiB, past what had been sent ({} MiB)", mb(resumed), mb(at_cut)));
        if t.done {
            if from_app {
                run.check_received(sc, &t, &sha);
            } else {
                run.check_app_copy(sc, &name, size, &sha);
            }
        }
        sc.check(run.peer_partials().is_empty(), format!("round {round}: partials left here after it finished {:?}", run.peer_partials()));
        sc.rounds.push(Value::Object(r));
        run.settle()?;
    }
    Ok(())
}

/// One mid-size file cut five times on its way, resuming each time.
fn multi_drop(run: &mut Run, sc: &mut Scenario, from_app: bool) -> Step {
    let size = run.opts.mid;
    let seed = 0x3D_0000 + if from_app { 1 } else { 0 };
    let name = run.name(if from_app { "mrecv" } else { "msend" });
    let sha;
    let path;
    let since = Instant::now();
    let mut id = if from_app {
        sha = run.expected(size, seed);
        path = None;
        run.app_send(&[(name.clone(), size, seed)])?;
        run.wait_incoming(&name, since, run.timeout_for(size)).ok_or("the file never came")?
    } else {
        let (p, s) = run.source(size, seed)?;
        sha = s;
        path = Some(p.clone());
        run.send(&p, &name)?
    };
    let t0 = Instant::now();
    let mut lost_total = 0u64;
    let mut cuts = Vec::new();
    // At least five seconds a file, so each cut lands near its point and some bytes move between cuts.
    run.proxy.limit(size / 5);
    for k in 1..=5u64 {
        let cut = (size * k / 7).max(run.transfer(id).bytes + size / 14);
        if run.wait_bytes(id, cut, run.timeout_for(size)).is_err() {
            break;
        }
        let at_cut = run.transfer(id).bytes;
        let t_cut = Instant::now();
        run.proxy.cut();
        let first = run.wait_end(id, Duration::from_secs(30))?;
        if first.done {
            // It finished before this cut landed: nothing left to interrupt.
            cuts.push(json!({"cut_at_mib": mb(at_cut), "finished_before_the_cut": true}));
            run.ensure_connected(Duration::from_secs(60))?;
            break;
        }
        sc.check(first.failed.as_deref() == Some("interrupted"), format!("cut {k}: ended with {:?}", first.failed));
        run.wait_disconnected(Duration::from_secs(15));
        run.ensure_connected(Duration::from_secs(60))?;
        id = if from_app {
            match run.wait_incoming(&name, t_cut, Duration::from_secs(45)) {
                Some(a) => a,
                None => {
                    sc.check(false, format!("cut {k}: the app did not send it again by itself"));
                    let s = Instant::now();
                    run.app_send(&[(name.clone(), size, seed)])?;
                    run.wait_incoming(&name, s, run.timeout_for(size)).ok_or("the file did not come again")?
                }
            }
        } else {
            run.send(path.as_deref().unwrap(), &name)?
        };
        let resumed = run.sh.wait(Duration::from_secs(150), |st| st.transfers.get(&id).and_then(|t| t.first_bytes.or(t.ended.map(|_| 0))));
        let resumed_at = run.transfer(id).resumed_at.unwrap_or(0);
        sc.check(resumed.is_some() && resumed_at > 0, format!("cut {k}: did not resume (cut at {} MiB)", mb(at_cut)));
        lost_total += at_cut.saturating_sub(resumed_at);
        cuts.push(json!({"cut_at_mib": mb(at_cut), "resumed_at_mib": mb(resumed_at), "reconnect_seconds": secs(t_cut.elapsed())}));
    }
    run.proxy.limit(0);
    let t = run.wait_end(id, run.timeout_for(size))?;
    sc.check(t.done, format!("{name}: {:?}", t.failed));
    if t.done {
        if from_app {
            run.check_received(sc, &t, &sha);
        } else {
            run.check_app_copy(sc, &name, size, &sha);
        }
    }
    sc.metric("cuts", Value::Array(cuts));
    sc.metric("lost_mib_total", mb(lost_total));
    sc.metric("seconds", secs(t0.elapsed()));
    Ok(())
}

/// Cut and reconnect again and again; each time a 4 KiB file must go through (a ping would play a sound on the app's
/// device). Times each reconnect and each file.
fn reconnect_loop(run: &mut Run, sc: &mut Scenario) -> Step {
    let mut times = Vec::new();
    let mut probes = Vec::new();
    let (path, _) = run.source(4096, 0x10_0B)?;
    for i in 0..run.opts.loops {
        let t0 = Instant::now();
        run.proxy.cut();
        if run.wait_disconnected(Duration::from_secs(15)).is_none() {
            sc.check(false, format!("cycle {i}: no disconnect seen"));
        }
        match run.ensure_connected(Duration::from_secs(60)) {
            Ok(_) => times.push(secs(t0.elapsed())),
            Err(e) => {
                sc.check(false, format!("cycle {i}: {e}"));
                continue;
            }
        }
        let tp = Instant::now();
        let name = run.name("loop");
        match run.send(&path, &name).and_then(|id| run.wait_end(id, Duration::from_secs(30))) {
            Ok(t) if t.done => probes.push(secs(tp.elapsed())),
            Ok(t) => sc.check(false, format!("cycle {i}: the probe file {:?}", t.failed)),
            Err(e) => sc.check(false, format!("cycle {i}: {e}")),
        }
    }
    let stats = |v: &[f64]| {
        let mut s = v.to_vec();
        s.sort_by(|a, b| a.total_cmp(b));
        if s.is_empty() {
            json!(null)
        } else {
            json!({"n": s.len(), "min": s[0], "median": s[s.len() / 2], "p90": s[(s.len() * 9 / 10).min(s.len() - 1)], "max": s[s.len() - 1]})
        }
    };
    sc.metric("cycles", run.opts.loops);
    sc.metric("reconnect_seconds", stats(&times));
    sc.metric("probe_file_seconds", stats(&probes));
    Ok(())
}

// ---------------------------------------------------------------------------------------------------------------

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("gen") if args.len() == 4 => {
            let sha = write_generated(Path::new(&args[1]), parse_size(&args[2]), args[3].parse().expect("seed")).expect("write");
            println!("{sha}");
        }
        Some("sha") if args.len() == 3 => println!("{}", generate(parse_size(&args[1]), args[2].parse().expect("seed"), |_| Ok(())).expect("generate")),
        Some("list") => println!("{}", ALL.join("\n")),
        Some("run") => std::process::exit(run(&args[1..])),
        Some("soak") => std::process::exit(soak::main(&args[1..])),
        Some("accept") => std::process::exit(accept::main(&args[1..])),
        Some("serve") if args.len() == 4 => serve(args[1].parse().expect("port"), args[2].parse().expect("control port"), Path::new(&args[3])),
        Some("app-control") if args.len() >= 3 => app_control(args[1].parse().expect("control port"), &args[2..]),
        _ => {
            eprintln!("usage: stress run --app \"<program> [args]\" --target HOST:PORT --work DIR [options] | gen PATH SIZE SEED | sha SIZE SEED | list");
            eprintln!("       stress soak --app ... --target ... --work ... --minutes N [options] | accept --app ... --target ... --work ... [options]");
            eprintln!("       stress serve PORT CONTROL_PORT DIR | app-control CONTROL_PORT VERB [ARGS]");
            std::process::exit(2);
        }
    }
}

/// The options every driver command shares (`run`, `soak`, `accept`); each flag takes one value.
const COMMON_FLAGS: &[&str] = &["--app", "--target", "--work", "--report", "--peer-platform", "--name", "--big", "--mid", "--small", "--rounds", "--loops", "--seed", "--proxy-port"];

fn parse_flags(args: &[String], extra: &[&str]) -> Result<HashMap<String, String>, String> {
    let mut out = HashMap::new();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if !COMMON_FLAGS.contains(&arg.as_str()) && !extra.contains(&arg.as_str()) {
            return Err(format!("unknown argument {arg}"));
        }
        let value = it.next().ok_or_else(|| format!("{arg} needs a value"))?;
        out.insert(arg.clone(), value.clone());
    }
    Ok(out)
}

/// The peer, its proxy and the app's control program, from the shared options. `clipboard` turns the peer's clipboard on.
fn start_run(flags: &HashMap<String, String>, clipboard: bool) -> Result<Run, String> {
    let get = |k: &str| flags.get(k).cloned();
    let mut opts = Opts { target: "127.0.0.1:0".parse().unwrap(), proxy_port: 42_491, big: vec![1024 * MIB, 4096 * MIB], mid: 1024 * MIB, small: 200, rounds: 2, loops: 20, seed: now_unix() };
    if let Some(v) = get("--big") {
        opts.big = v.split(',').filter(|s| !s.is_empty()).map(parse_size).collect();
    }
    if let Some(v) = get("--mid") {
        opts.mid = parse_size(&v);
    }
    let number = |k: &str| -> Result<Option<u64>, String> { get(k).map(|v| v.parse::<u64>().map_err(|_| format!("{k} must be a number"))).transpose() };
    if let Some(v) = number("--small")? {
        opts.small = v as usize;
    }
    if let Some(v) = number("--rounds")? {
        opts.rounds = v as usize;
    }
    if let Some(v) = number("--loops")? {
        opts.loops = v as usize;
    }
    if let Some(v) = number("--seed")? {
        opts.seed = v;
    }
    if let Some(v) = number("--proxy-port")? {
        opts.proxy_port = u16::try_from(v).map_err(|_| "--proxy-port is a port".to_string())?;
    }
    let (Some(app), Some(target), Some(work)) = (get("--app"), get("--target"), get("--work").map(PathBuf::from)) else {
        return Err("needs --app, --target and --work".into());
    };
    opts.target = target.parse().map_err(|_| "--target must be HOST:PORT with an IP address".to_string())?;
    let mut parts = app.split_whitespace().map(str::to_string);
    let app = App { program: parts.next().ok_or("--app is empty")?, args: parts.collect() };
    let src = work.join("src");
    let received = work.join("received");
    let state = work.join("state");
    for d in [&src, &received, &state] {
        std::fs::create_dir_all(d).map_err(|e| format!("work folders: {e}"))?;
    }
    let log = std::fs::OpenOptions::new().create(true).append(true).open(work.join("events.jsonl")).map_err(|e| format!("events log: {e}"))?;
    let sh = Arc::new(Shared { st: Mutex::new(PeerState::default()), cv: Condvar::new(), log: Mutex::new(log), t0: Instant::now() });
    let cfg = PeerConfig {
        name: get("--name").unwrap_or_else(|| "Bridgey stress peer".into()),
        platform: get("--peer-platform").unwrap_or_else(|| "android".into()),
        state,
        received,
        clipboard,
    };
    let proxy = Proxy::start(opts.proxy_port, opts.target).map_err(|e| format!("proxy on port {}: {e}", opts.proxy_port))?;
    let client = start_peer(&cfg, &sh)?;
    let seed = opts.seed;
    let run = Run {
        rng: Rng(Gen(seed)),
        opts,
        app,
        proxy,
        sh: sh.clone(),
        cfg,
        client,
        device: None,
        src,
        run_id: format!("{:06x}", seed & 0xFF_FFFF),
        counter: 0,
        app_down: false,
        expected: HashMap::new(),
        sources: HashMap::new(),
    };
    Ok(run)
}

fn run(args: &[String]) -> i32 {
    let flags = match parse_flags(args, &["--scenarios"]) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("run: {e}");
            return 2;
        }
    };
    let scenarios = flags.get("--scenarios").cloned().unwrap_or_else(|| "all".into());
    let names: Vec<String> = match scenarios.as_str() {
        "all" => ALL.iter().map(|s| s.to_string()).collect(),
        "quick" => QUICK.iter().map(|s| s.to_string()).collect(),
        list => {
            let mut v: Vec<String> = list.split(',').map(str::to_string).collect();
            if v.first().map(String::as_str) != Some("pair") {
                v.insert(0, "pair".into());
            }
            v
        }
    };
    for n in &names {
        assert!(ALL.contains(&n.as_str()), "unknown scenario {n} (stress list)");
    }
    let mut run = match start_run(&flags, false) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{e}");
            return if e.starts_with("needs") { 2 } else { 1 };
        }
    };
    let report = flags.get("--report").map(PathBuf::from).unwrap_or_else(|| run.cfg.state.parent().unwrap_or(Path::new(".")).join("report.json"));
    let sh = run.sh.clone();
    let seed = run.opts.seed;
    sh.note(json!({"event": "start", "seed": seed, "scenarios": names}));
    let started = now_unix();
    let mut results = Vec::new();
    let mut failed = 0usize;
    for name in &names {
        eprintln!("== {name}");
        let mut sc = Scenario { name: name.clone(), t0: Instant::now(), failures: Vec::new(), metrics: Map::new(), rounds: Vec::new() };
        sh.note(json!({"event": "scenario", "name": name}));
        let outcome = run_scenario(&mut run, &mut sc);
        if let Err(e) = &outcome {
            eprintln!("  ERROR {name}: {e}");
            sc.failures.push(format!("stopped: {e}"));
        }
        let settle = if name == "pair" && run.device.is_none() { Err("not paired".to_string()) } else { run.settle() };
        if let Err(e) = &settle {
            sc.failures.push(format!("afterwards: {e}"));
        }
        let ok = sc.failures.is_empty();
        if !ok {
            failed += 1;
        }
        eprintln!("  {} in {:.1}s", if ok { "ok" } else { "FAILED" }, sc.t0.elapsed().as_secs_f64());
        let mut entry = json!({"name": sc.name, "ok": ok, "seconds": secs(sc.t0.elapsed()), "failures": sc.failures, "metrics": sc.metrics});
        if !sc.rounds.is_empty() {
            entry["rounds"] = Value::Array(sc.rounds);
        }
        results.push(entry);
        let doc = json!({
            "tool": "bridgey-stress", "started": started, "finished": now_unix(), "seed": seed,
            "target": run.opts.target.to_string(), "peer_platform": run.cfg.platform,
            "sizes": {"big": run.opts.big, "mid": run.opts.mid, "small_files": run.opts.small, "rounds": run.opts.rounds, "loops": run.opts.loops},
            "expectations_mib": {"cut_loss": mb(CUT_LOSS), "kill_loss": mb(KILL_LOSS), "own_loss": mb(OWN_LOSS)},
            "proxy_connections": run.proxy.st.accepted.load(Ordering::Relaxed),
            "peer_disconnects": sh.st.lock().unwrap().disconnects,
            "passed": results.len() - failed, "failed": failed, "scenarios": results,
        });
        let _ = std::fs::write(&report, serde_json::to_string_pretty(&doc).unwrap());
        if settle.is_err() && (name == "pair" || !run.connected()) {
            eprintln!("cannot reach the app any more; stopping");
            break;
        }
    }
    run.client.stop();
    eprintln!("report: {} ({failed} failed)", report.display());
    if failed == 0 {
        0
    } else {
        1
    }
}

// ---------------------------------------------------------------------------------------------------------------
// A stand-in app: the session client on the other end, so the harness itself can be checked anywhere (`serve`), with
// the apps' automatic retry of interrupted files on reconnect. `kill` restarts it in-process (a clean stop, not a
// crash), and it forgets its retry list as the apps do.

struct Standin {
    port: u16,
    dir: PathBuf,
    client: Mutex<Option<Arc<Client>>>,
    /// Transfers not ended, outgoing ones with their source, and interrupted outgoing files to send again.
    running: Mutex<HashMap<u64, Option<(PathBuf, String)>>>,
    retry: Mutex<Vec<(PathBuf, String)>>,
    device: Mutex<Option<String>>,
    /// The newest clipboard text it received, and its "version" (raised by `upgrade`).
    clip: Mutex<Option<String>>,
    version: AtomicU64,
}

impl Standin {
    fn start_client(self: &Arc<Self>) -> Arc<Client> {
        let mut config = Config::new("Stress stand-in", "macos");
        config.port = self.port;
        config.discovery = false;
        config.receive_dir = Some(self.dir.join("received"));
        config.defaults.set("files", true);
        config.defaults.set("clipboard", true);
        let storage = Arc::new(FileStorage::new(self.dir.join("state")).expect("state"));
        let client = Arc::new(Client::start(config, storage).expect("stand-in starts"));
        let (c, me) = (client.clone(), self.clone());
        std::thread::spawn(move || loop {
            match c.next_event(Duration::from_millis(500)) {
                Next::Closed => return,
                Next::Timeout => {}
                Next::Event(e) => me.event(&c, e),
            }
        });
        self.running.lock().unwrap().clear();
        self.retry.lock().unwrap().clear();
        *self.client.lock().unwrap() = Some(client.clone());
        client
    }

    fn client(&self) -> Arc<Client> {
        self.client.lock().unwrap().clone().expect("client")
    }

    fn event(&self, c: &Client, e: Event) {
        match e {
            Event::PairingCode { pairing, .. } => {
                let _ = c.confirm_pairing(pairing, true);
            }
            Event::Connected { device_id, .. } => *self.device.lock().unwrap() = Some(device_id),
            Event::Clipboard { text, .. } => *self.clip.lock().unwrap() = Some(text),
            Event::Features { device_id, remote, .. } if remote.get("files") => {
                let again: Vec<(PathBuf, String)> = std::mem::take(&mut *self.retry.lock().unwrap());
                for (path, name) in again {
                    if let Ok(t) = c.send_file(&device_id, &path, Some(&name), None) {
                        self.running.lock().unwrap().insert(t, Some((path.clone(), name.clone())));
                    }
                }
            }
            Event::FileIncoming { transfer, .. } => {
                self.running.lock().unwrap().entry(transfer).or_insert(None);
            }
            Event::FileDone { transfer, .. } => {
                self.running.lock().unwrap().remove(&transfer);
            }
            Event::FileFailed { transfer, reason, .. } => {
                if let Some(Some(source)) = self.running.lock().unwrap().remove(&transfer) {
                    if reason == "interrupted" {
                        self.retry.lock().unwrap().push(source);
                    }
                }
            }
            _ => {}
        }
    }

    fn handle(self: &Arc<Self>, line: &str) -> Value {
        let mut words = line.split_whitespace();
        let verb = words.next().unwrap_or("");
        let rest: Vec<&str> = words.collect();
        let received = self.dir.join("received");
        let ok = json!({"ok": true});
        match verb {
            "pair-prepare" => {
                self.client().allow_pairing(Duration::from_secs(120));
                ok
            }
            "pair-confirm" => ok,
            "send" => {
                let Some(device) = self.device.lock().unwrap().clone() else { return json!({"ok": false, "error": "not connected"}) };
                for spec in rest {
                    let parts: Vec<&str> = spec.split(':').collect();
                    let (Some(name), Some(size), Some(seed)) = (parts.first(), parts.get(1).and_then(|v| v.parse::<u64>().ok()), parts.get(2).and_then(|v| v.parse::<u64>().ok())) else {
                        return json!({"ok": false, "error": "bad spec"});
                    };
                    let path = self.dir.join("src").join(name);
                    if std::fs::metadata(&path).map(|m| m.len()).ok() != Some(size) && write_generated(&path, size, seed).is_err() {
                        return json!({"ok": false, "error": "cannot write the source"});
                    }
                    match self.client().send_file(&device, &path, Some(name), None) {
                        Ok(t) => {
                            self.running.lock().unwrap().insert(t, Some((path, name.to_string())));
                        }
                        Err(e) => return json!({"ok": false, "error": e.to_string()}),
                    }
                }
                ok
            }
            "cancel" => {
                let ids: Vec<u64> = self.running.lock().unwrap().keys().copied().collect();
                for id in ids {
                    let _ = self.client().cancel_file(id);
                }
                ok
            }
            "kill" => {
                self.client().stop();
                *self.client.lock().unwrap() = None;
                ok
            }
            "start" => {
                if self.client.lock().unwrap().is_none() {
                    self.start_client();
                }
                ok
            }
            "status" => json!({"ok": true, "active": self.running.lock().unwrap().len(), "free": -1}),
            // The soak and acceptance verbs (stress/soak.rs, stress/accept.rs), so the harness checks itself here too.
            "clipboard-on" | "grants" => ok,
            "clip-send" => {
                let Some(device) = self.device.lock().unwrap().clone() else { return json!({"ok": false, "error": "not connected"}) };
                match self.client().send_clipboard(&device, &rest.join(" ")) {
                    Ok(_) => ok,
                    Err(e) => json!({"ok": false, "error": e.to_string()}),
                }
            }
            "clip-status" => json!({"ok": true, "text": self.clip.lock().unwrap().clone()}),
            "proc" => {
                let mut v = soak::self_metrics();
                v["ok"] = json!(true);
                v["pid"] = json!(std::process::id());
                v
            }
            "settings" | "upgrade" => {
                // A restart, as the apps restart to read settings or for an update; `upgrade` raises the version.
                let from = self.version.load(Ordering::SeqCst);
                let to = if verb == "upgrade" { self.version.fetch_add(1, Ordering::SeqCst) + 1 } else { from };
                self.client().stop();
                std::thread::sleep(Duration::from_millis(300));
                self.start_client();
                json!({"ok": true, "from": format!("standin-{from}"), "to": format!("standin-{to}")})
            }
            "snapshot" => {
                let doc = json!({"ok": true, "versionName": format!("standin-{}", self.version.load(Ordering::SeqCst)), "versionCode": self.version.load(Ordering::SeqCst)});
                match rest.first().map(|path| std::fs::write(path, doc.to_string())) {
                    Some(Ok(())) => ok,
                    _ => json!({"ok": false, "error": "snapshot needs a path it can write"}),
                }
            }
            "partials" => {
                let parts: Vec<Value> = std::fs::read_dir(&received)
                    .map(|d| d.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.starts_with(".bridgey-")).map(|n| json!({"name": n})).collect())
                    .unwrap_or_default();
                json!({"ok": true, "partials": parts})
            }
            "received" => {
                let files: Vec<Value> = rest
                    .iter()
                    .map(|n| match file_sha(&received.join(n)) {
                        Ok((size, sha)) => json!({"name": n, "size": size, "sha256": sha}),
                        Err(_) => json!({"name": n, "missing": true}),
                    })
                    .collect();
                json!({"ok": true, "files": files})
            }
            "clean" => {
                for d in [received, self.dir.join("src")] {
                    if let Ok(entries) = std::fs::read_dir(&d) {
                        for e in entries.flatten() {
                            let n = e.file_name().to_string_lossy().into_owned();
                            if n.starts_with("stress-") || n.starts_with(".bridgey-") {
                                let _ = std::fs::remove_file(e.path());
                            }
                        }
                    }
                }
                ok
            }
            _ => json!({"ok": false, "error": "unknown verb"}),
        }
    }
}

fn serve(port: u16, control_port: u16, dir: &Path) {
    for d in ["received", "state", "src"] {
        std::fs::create_dir_all(dir.join(d)).expect("folders");
    }
    let me = Arc::new(Standin {
        port,
        dir: dir.to_path_buf(),
        client: Mutex::new(None),
        running: Mutex::new(HashMap::new()),
        retry: Mutex::new(Vec::new()),
        device: Mutex::new(None),
        clip: Mutex::new(None),
        version: AtomicU64::new(1),
    });
    me.start_client();
    let listener = TcpListener::bind(("127.0.0.1", control_port)).expect("control port");
    eprintln!("stand-in on {port}, control on {control_port}");
    for conn in listener.incoming().flatten() {
        let mut line = String::new();
        let mut reader = std::io::BufReader::new(conn.try_clone().expect("clone"));
        if std::io::BufRead::read_line(&mut reader, &mut line).is_ok() {
            let answer = me.handle(line.trim());
            let mut conn = conn;
            let _ = writeln!(conn, "{answer}");
        }
    }
}

fn app_control(control_port: u16, words: &[String]) {
    let mut conn = TcpStream::connect(("127.0.0.1", control_port)).expect("stand-in control");
    writeln!(conn, "{}", words.join(" ")).expect("write");
    let mut answer = String::new();
    let _ = conn.read_to_string(&mut answer);
    print!("{answer}");
}
