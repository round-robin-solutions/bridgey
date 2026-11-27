//! One session with a Bridgey device over plain TCP, the way the apps run it on the local network or a
//! tailnet (PairingCoordinator.kt, Pairing.swift, docs/protocol.md "Pairing flow"): newline JSON frames of
//! at most 65,536 bytes, protocol 2 only, so a first pairing commits and reveals, both people compare a
//! six-digit code, and every frame after pairing carries its envelope tag and passes the replay window.
//!
//! The same state machine as the agent CLI's tunnel sessions (rust/cli/src/session.rs), with the local
//! network's `bridgey-auth-v1` transcript, the apps' 10 s heartbeat and the host deciding who may pair.

use crate::crypto::{self, Ephemeral, SigningKey};
use crate::fast::{self, Pacer};
use crate::features::{self, FeatureMap};
use crate::resume::{self, Running};
use crate::transfer::{self, FILE_CHUNK, MAX_CHUNK_IN, MAX_FILE, QUICK_MAX};
use crate::wire::{read_frames, AbortOnDrop, Message, ReadFrame, MAX_FRAME, READ_BUDGET, READ_QUEUE};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::Duration;
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::tcp::OwnedReadHalf;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, Notify};
use tokio::time::Instant;

/// The apps' local heartbeat: a ping every 10 s, a link silent for 30 s is dead (Reconnect.kt).
pub const HEARTBEAT: Duration = Duration::from_secs(10);
pub const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(30);
/// Pairing frames must finish this quickly, except while a person compares the code.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
pub const CODE_TIMEOUT: Duration = Duration::from_secs(120);
pub const MAX_BAD_FRAMES: u32 = 16;
pub const REPLAY_WINDOW: usize = 256;
/// `clipboard.update` and `clipboard.rich`: text (and HTML) up to 32 KiB before encryption.
pub const CLIPBOARD_MAX: usize = 32_768;
const COMMANDS: usize = 64;
/// File chunks waiting for the socket at once. Other frames never wait for room, so reading never waits for writing
/// and two devices sending each other files cannot block each other.
const CHUNKS_IN_FLIGHT: usize = 16;
/// How long the other device has to accept a file, and to confirm it after the last chunk.
const ACCEPT_TIMEOUT: Duration = Duration::from_secs(30);
/// A resumable offer: the receiver may first re-read up to 10 GiB it kept (files_resume_draft1). Every
/// `files.resume.wait` it sends while it reads starts this wait again.
pub(crate) const RESUME_ANSWER_TIMEOUT: Duration = Duration::from_secs(120);
/// How often a receiver re-reading a kept partial sends `files.resume.wait`, well inside the sender's wait.
pub(crate) const RESUME_WAIT_EVERY: Duration = Duration::from_secs(30);
const COMPLETE_TIMEOUT: Duration = Duration::from_secs(60);
/// A receiver that acknowledges chunks (Android) keeps at most 64 unacknowledged; one silent this long has stalled.
const CHUNK_WINDOW: i64 = 64;
const ACK_STALL: Duration = Duration::from_secs(30);
/// Files coming in at once from one device.
const MAX_INCOMING: usize = 4;
/// Progress events at most this often per transfer.
const PROGRESS_EVERY: Duration = Duration::from_millis(250);
/// What every find-device message carries: Android takes no other alert ID (PairingCoordinator.kt).
pub const FIND_ALERT: &str = "active";

pub struct Local {
    pub device_id: String,
    pub name: RwLock<String>,
    pub identity: SigningKey,
    pub identity_public: String,
}

impl Local {
    pub fn name(&self) -> String {
        self.name.read().unwrap().clone()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Role {
    /// The person's own first pairing: commit, answer, reveal, the code at both ends.
    Pair,
    /// A reconnect to a trusted device: no prompt; its pinned identity key authenticates it.
    Reconnect { device_id: String },
    /// A connection that came in: an offer decides which of the two it is.
    Accept,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Admission {
    Answer,
    /// Refused with this `pairing.cancel` reason (not_armed, busy, rate_limited).
    Refuse(&'static str),
}

pub struct Offer<'a> {
    pub session: u64,
    pub device_id: &'a str,
    pub name: &'a str,
    pub peer: SocketAddr,
}

pub struct Authenticated {
    pub session: u64,
    pub device_id: String,
    pub name: String,
    pub identity_key: String,
    /// A first pairing (with a code), not a reconnect.
    pub paired: bool,
    /// This end dialled.
    pub dialled: bool,
    pub peer: SocketAddr,
    pub handle: Handle,
}

#[derive(Debug)]
pub enum Event {
    /// Compare this code; answer with `Handle::confirm`.
    Code { session: u64, device_id: String, name: String, code: String },
    Features { session: u64, device_id: String, features: FeatureMap },
    Clipboard { session: u64, device_id: String, text: String, html: Option<String> },
    /// `clipboard.ack` (delivered) or `clipboard.rejected` for a message this end sent.
    ClipboardResult { device_id: String, message_id: String, delivered: bool },
    Ping { device_id: String },
    PingAck { device_id: String, message_id: String },
    /// A file is coming in; it is saved in the receive folder once its hash checks out.
    FileIncoming { transfer: u64, device_id: String, name: String, size: u64, mime: String },
    FileProgress { transfer: u64, device_id: String, incoming: bool, bytes: u64, total: u64 },
    /// Saved here (`path`), or confirmed by the other device.
    FileDone { transfer: u64, device_id: String, incoming: bool, name: String, path: Option<String>, size: u64 },
    FileFailed { transfer: u64, device_id: String, incoming: bool, name: String, reason: String },
    /// A link from the other device, queued for the person to open (never opened here).
    Link { device_id: String, url: String },
    /// `quick.result` for a request this end sent.
    QuickResult { device_id: String, request_id: String, accepted: bool, opened: bool },
    Battery { device_id: String, level: u8, charging: bool },
    /// The other device asks this one to ring (`find.start`) or stop (`find.stop`); the session has answered.
    Find { device_id: String, ring: bool },
    /// The other device says it is ringing (`find.started`) or not (`find.stopped`).
    FindAck { device_id: String, ringing: bool },
    /// An encrypted message the client decodes itself (notifications, codes, quick results), already opened.
    Payload { device_id: String, kind: &'static str, plain: Vec<u8> },
    /// A `quick.request` (a link, or a media command) that passed its checks and the session's sequence.
    Quick { device_id: String, request: crate::quick::Request },
    Closed { session: u64, device_id: Option<String>, reason: String, authenticated: bool, paired: bool, answered: bool },
}

/// What the client decides for a session. Called from the session's task; must not block.
pub trait Host: Send + Sync + 'static {
    fn local(&self) -> &Local;
    /// The pinned identity key of a trusted device.
    fn pin(&self, device_id: &str) -> Option<String>;
    /// A committed first pairing from another device: answer it, or refuse.
    fn admit(&self, offer: &Offer) -> Admission;
    /// This device's switches for that device, sent in `features.update`.
    fn policy(&self, device_id: &str) -> FeatureMap;
    /// Both confirmations verified. False when another session to the device wins; this one then closes.
    fn authenticated(&self, auth: Authenticated) -> bool;
    fn event(&self, event: Event);
    /// A new ID for a transfer that came in.
    fn next_id(&self) -> u64;
    /// Where received files go; None refuses them.
    fn receive_dir(&self) -> Option<PathBuf>;
    /// Kept partials (files_resume_draft1): the one holding this content from this device, in `dir`, claimed for one
    /// transfer. Partials it can no longer serve (the device's same name with other content: its source changed) go.
    fn resume_claim(&self, _peer: &str, _size: u64, _sha256: &str, _name: &str, _dir: &Path) -> Option<resume::Record> {
        None
    }
    /// Saves a partial's record, new or updated. Its bytes are on stable storage first.
    fn resume_save(&self, _record: resume::Record) {}
    /// A transfer using a partial ended: its record stays for a later attempt (`keep`) or goes. Never deletes the file.
    fn resume_release(&self, _part: &Path, _keep: bool) {}
    /// Tests only: a sender stops sending a file after this many bytes (0: never), so a test can cut it at a known place.
    fn send_limit(&self) -> u64 {
        0
    }
    /// files_resume_draft1 timing: how long a sender waits for the answer to a resumable offer, how often a receiver
    /// re-reading a partial says it is still reading, and (tests only) how long that re-read is held back.
    fn resume_timing(&self) -> (Duration, Duration, Duration) {
        (RESUME_ANSWER_TIMEOUT, RESUME_WAIT_EVERY, Duration::ZERO)
    }
    /// A phone feature's kind this end takes (phone.rs), with its feature key and size limit.
    fn phone_kind(&self, kind: &str) -> Option<crate::phone::Incoming> {
        crate::phone::incoming(kind)
    }
    /// The size of the chunks this end sends: 24 KiB as JSON, 256 KiB as binary frames (tests use smaller ones).
    fn chunk_size(&self, fast: bool) -> usize {
        if fast {
            fast::CHUNK
        } else {
            FILE_CHUNK
        }
    }
}

/// A file to offer, hashed already (hashing a large file must not hold up the session).
#[derive(Clone, Debug)]
pub struct OutgoingFile {
    pub transfer: u64,
    pub path: PathBuf,
    pub name: String,
    pub mime: String,
    pub size: u64,
    pub sha256: String,
    /// The SHA-256 at every 1 MiB, from the same pass (files_resume_draft1 checks a receiver's prefix against them).
    pub blocks: resume::Blocks,
}

/// A kept partial re-read off the session's task: its running hash and SHA-256, or None when it could not be read.
pub struct Checked {
    id: String,
    prefix: Option<(ring::digest::Context, [u8; 32])>,
}

pub enum Command {
    Confirm(bool),
    Clipboard { text: String, message_id: String },
    Features,
    Ping { message_id: String },
    SendFile(OutgoingFile),
    CancelFile(u64),
    Link { url: String, request_id: String, open: bool },
    /// Any other encrypted message (battery, find, ...): `plaintext` becomes the AES-GCM payload.
    Encrypted { kind: &'static str, plaintext: Vec<u8>, message_id: String },
    /// An outer-only answer that echoes the request's message ID (`calls.started` and its siblings).
    Plain { kind: &'static str, message_id: String },
    Close(&'static str),
    /// The session's own: a kept partial has been re-read.
    #[doc(hidden)]
    Checked(Box<Checked>),
    /// The session's own: a kept partial is still being re-read (`files.resume.wait` for this transfer).
    #[doc(hidden)]
    Checking(String),
}

#[derive(Clone, Debug)]
pub struct Handle {
    pub session: u64,
    tx: mpsc::Sender<Command>,
    /// When the session last read a frame, in `clock_ms` time.
    heard: Arc<AtomicU64>,
}

/// Milliseconds on a monotonic clock shared by every session.
pub fn clock_ms() -> u64 {
    static BASE: OnceLock<std::time::Instant> = OnceLock::new();
    BASE.get_or_init(std::time::Instant::now).elapsed().as_millis() as u64
}

impl Handle {
    pub fn last_heard(&self) -> Arc<AtomicU64> {
        self.heard.clone()
    }
    /// How long since the session last heard from the other end.
    pub fn silent_for(&self) -> Duration {
        Duration::from_millis(clock_ms().saturating_sub(self.heard.load(Ordering::Relaxed)))
    }
    pub fn confirm(&self, accept: bool) -> bool {
        self.tx.try_send(Command::Confirm(accept)).is_ok()
    }
    pub fn send_clipboard(&self, text: String, message_id: String) -> bool {
        self.tx.try_send(Command::Clipboard { text, message_id }).is_ok()
    }
    pub fn send_features(&self) -> bool {
        self.tx.try_send(Command::Features).is_ok()
    }
    pub fn ping(&self, message_id: String) -> bool {
        self.tx.try_send(Command::Ping { message_id }).is_ok()
    }
    /// Queues a file; files go one at a time, in order.
    pub fn send_file(&self, file: OutgoingFile) -> bool {
        self.tx.try_send(Command::SendFile(file)).is_ok()
    }
    pub fn cancel_file(&self, transfer: u64) -> bool {
        self.tx.try_send(Command::CancelFile(transfer)).is_ok()
    }
    pub fn send_link(&self, url: String, request_id: String, open: bool) -> bool {
        self.tx.try_send(Command::Link { url, request_id, open }).is_ok()
    }
    /// Queues an encrypted message, or false when the queue is full or the session ended.
    pub fn send_encrypted(&self, kind: &'static str, plaintext: Vec<u8>, message_id: String) -> bool {
        self.tx.try_send(Command::Encrypted { kind, plaintext, message_id }).is_ok()
    }
    /// Queues an outer-only answer echoing a request's message ID, or false when the session ended.
    pub fn send_plain(&self, kind: &'static str, message_id: String) -> bool {
        self.tx.try_send(Command::Plain { kind, message_id }).is_ok()
    }
    pub fn close(&self, why: &'static str) {
        let _ = self.tx.try_send(Command::Close(why));
    }
    pub fn is_open(&self) -> bool {
        !self.tx.is_closed()
    }
}

struct State {
    id: String,
    eph: Ephemeral,
    remote_eph: String,
    remote_id: String,
    remote_name: String,
    remote_commitment: Option<String>,
    key: Option<[u8; 32]>,
    envelope: Option<[u8; 32]>,
    /// The binary frame key (files_fast_draft1), from the session key.
    fast_key: Option<[u8; 32]>,
    fast_replay: fast::ReplayGuard,
    /// The other device shows files_fast_draft1 (its latest `features.update`).
    remote_fast: bool,
    /// The other device shows files_resume_draft1.
    remote_resume: bool,
    local_confirmed: bool,
    remote_confirmed: bool,
    remote_identity: Option<String>,
    authenticated: bool,
    /// A first pairing with a code (not a reconnect).
    paired: bool,
    answered: bool,
    awaiting_code: bool,
    offers_seen: u32,
    bad_frames: u32,
    seen: HashSet<String>,
    order: VecDeque<String>,
}

enum Step {
    Continue,
    AwaitCode,
    Close(String),
}

/// A file coming in: written to a hidden partial file and hashed as it arrives.
struct Incoming {
    transfer: u64,
    name: String,
    size: u64,
    sha256: Vec<u8>,
    received: u64,
    next_sequence: i64,
    dir: PathBuf,
    part: PathBuf,
    file: std::fs::File,
    hasher: Running,
    reported: Option<Instant>,
    /// files_resume_draft1: an interruption keeps the partial, with its record in the host's private storage.
    resumable: bool,
    phase: Phase,
    /// `received` when the record was last written.
    checkpoint: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    /// Re-reading a kept partial, whose record says this many verified bytes with this SHA-256.
    Checking { length: u64, prefix: [u8; 32] },
    /// `files.resume` sent for this offset; waiting for `files.resume.ack`.
    Proposed(u64),
    Receiving,
}

/// A kept partial's record for an incoming file: `verified` bytes with their SHA-256.
fn record_of(peer: &str, i: &Incoming, verified: (u64, [u8; 32])) -> Option<resume::Record> {
    let part = i.part.file_name()?.to_str()?.to_string();
    Some(resume::Record {
        peer: peer.to_string(),
        size: i.size,
        sha256: crypto::b64(&i.sha256),
        length: verified.0,
        prefix: crypto::b64(&verified.1),
        dir: i.dir.clone(),
        part,
        name: i.name.clone(),
        updated: 0,
    })
}

#[derive(Debug, PartialEq, Eq)]
enum Stage {
    /// `files.offer` sent; waiting for `files.accept`.
    Offered,
    Sending,
    /// `files.complete` sent; waiting for `files.complete.ack`.
    Completing,
}

/// The file this end is sending now. Others wait in `queue`.
struct Outgoing {
    file: OutgoingFile,
    id: String,
    stage: Stage,
    reader: std::fs::File,
    sequence: i64,
    /// The highest chunk the receiver acknowledged; only receivers that acknowledge (Android) hold back sending.
    acked: i64,
    acks: bool,
    sent: u64,
    deadline: Option<Instant>,
    reported: Option<Instant>,
    /// Binary frames of up to 256 KiB, paced by the acknowledgements' round trip (files_fast_draft1 at both ends).
    fast: bool,
    pacer: Pacer,
    /// Offered `resumable` (files_resume_draft1 at both ends): the receiver may answer `files.resume`.
    resumable: bool,
}

/// A Connect anywhere tunnel the session runs on (the core's loopback bridge): its ID and TLS exporter.
#[derive(Clone, Debug)]
pub struct Tunnel {
    pub id: String,
    /// Base64 TLS exporter, signed into the `bridgey-auth-v2` transcript.
    pub exporter: String,
}

/// Starts a session on a connected socket. Returns its handle at once; events go to the host.
pub fn spawn(session: u64, stream: TcpStream, role: Role, host: Arc<dyn Host>) -> Handle {
    spawn_on(session, stream, role, host, None)
}

/// A session on a socket, or on a Connect anywhere tunnel: trusted devices only, as a protocol 2 reconnect, with the
/// tunnel's exporter in the signed transcript (docs/protocol.md "Connect anywhere").
pub fn spawn_on(session: u64, stream: TcpStream, role: Role, host: Arc<dyn Host>, tunnel: Option<Tunnel>) -> Handle {
    let (tx, rx) = mpsc::channel(COMMANDS);
    let handle = Handle { session, tx, heard: Arc::new(AtomicU64::new(clock_ms())) };
    let own = handle.clone();
    tokio::spawn(async move {
        let peer = stream.peer_addr().unwrap_or_else(|_| SocketAddr::from(([0, 0, 0, 0], 0)));
        let mut s = Session::new(session, stream, role, host.clone(), own, peer);
        s.tunnel = tunnel;
        let reason = s.run(rx).await;
        s.end_transfers(&reason);
        let st = &s.st;
        host.event(Event::Closed {
            session,
            device_id: Some(st.remote_id.clone()).filter(|d| !d.is_empty()),
            reason,
            authenticated: st.authenticated,
            paired: st.paired,
            answered: st.answered,
        });
    });
    handle
}

struct Session {
    session: u64,
    role: Role,
    host: Arc<dyn Host>,
    handle: Handle,
    peer: SocketAddr,
    reader: Option<BufReader<OwnedReadHalf>>,
    write: mpsc::UnboundedSender<(Vec<u8>, bool)>,
    /// Chunks queued for the socket, and a wake when one has gone.
    in_flight: Arc<AtomicUsize>,
    room: Arc<Notify>,
    st: State,
    incoming: HashMap<String, Incoming>,
    active: Option<Outgoing>,
    queue: VecDeque<OutgoingFile>,
    /// Transfers that ended here; late chunks for them are dropped quietly.
    ended: VecDeque<String>,
    quick_sequence: i64,
    quick_seen: HashMap<String, i64>,
    tunnel: Option<Tunnel>,
}

/// Writes queued frames in order; reading carries on meanwhile. Ends when the session drops its sender or the socket fails.
async fn write_frames(mut write: tokio::net::tcp::OwnedWriteHalf, mut rx: mpsc::UnboundedReceiver<(Vec<u8>, bool)>, in_flight: Arc<AtomicUsize>, room: Arc<Notify>) {
    while let Some((frame, chunk)) = rx.recv().await {
        if write.write_all(&frame).await.is_err() {
            return;
        }
        if chunk {
            in_flight.fetch_sub(1, Ordering::Relaxed);
            room.notify_one();
        }
    }
    let _ = write.shutdown().await;
}

impl Session {
    fn new(session: u64, stream: TcpStream, role: Role, host: Arc<dyn Host>, handle: Handle, peer: SocketAddr) -> Session {
        let _ = stream.set_nodelay(true);
        let (read, write) = stream.into_split();
        let (frames, rx) = mpsc::unbounded_channel();
        let in_flight = Arc::new(AtomicUsize::new(0));
        let room = Arc::new(Notify::new());
        tokio::spawn(write_frames(write, rx, in_flight.clone(), room.clone()));
        let dials = role != Role::Accept;
        Session {
            session,
            role,
            host,
            handle,
            peer,
            reader: Some(BufReader::with_capacity(MAX_FRAME + 2, read)),
            write: frames,
            in_flight,
            room,
            incoming: HashMap::new(),
            active: None,
            queue: VecDeque::new(),
            ended: VecDeque::new(),
            quick_sequence: 0,
            quick_seen: HashMap::new(),
            tunnel: None,
            st: State {
                id: if dials { crypto::uuid4() } else { String::new() },
                eph: Ephemeral::generate(),
                remote_eph: String::new(),
                remote_id: String::new(),
                remote_name: String::new(),
                remote_commitment: None,
                key: None,
                envelope: None,
                fast_key: None,
                fast_replay: fast::ReplayGuard::default(),
                remote_fast: false,
                remote_resume: false,
                local_confirmed: false,
                remote_confirmed: false,
                remote_identity: None,
                authenticated: false,
                paired: false,
                answered: false,
                awaiting_code: false,
                offers_seen: 0,
                bad_frames: 0,
                seen: HashSet::new(),
                order: VecDeque::new(),
            },
        }
    }

    fn initiated(&self) -> bool {
        self.role != Role::Accept
    }

    async fn run(&mut self, mut rx: mpsc::Receiver<Command>) -> String {
        let host = self.host.clone();
        let local = host.local();
        match self.role.clone() {
            Role::Pair => {
                let mut offer = Message::new("pairing.offer", &self.st.id);
                offer.device_id = Some(local.device_id.clone());
                offer.device_name = Some(local.name());
                offer.commitment = Some(crypto::commitment(&self.st.id, &self.st.eph.public));
                offer.protocol_version = Some(crypto::PROTOCOL_VERSION);
                self.st.paired = true;
                if self.send(offer).await.is_err() {
                    return "send_failed".into();
                }
            }
            Role::Reconnect { device_id } => {
                let mut offer = Message::new("pairing.offer", &self.st.id);
                offer.device_id = Some(local.device_id.clone());
                offer.device_name = Some(local.name());
                offer.public_key = Some(self.st.eph.public.clone());
                offer.target_device_id = Some(device_id);
                offer.protocol_version = Some(crypto::PROTOCOL_VERSION);
                if self.send(offer).await.is_err() {
                    return "send_failed".into();
                }
            }
            Role::Accept => {}
        }
        let reader = self.reader.take().expect("reader");
        let (frames_tx, mut frames) = mpsc::channel::<(ReadFrame, Option<tokio::sync::OwnedSemaphorePermit>)>(READ_QUEUE);
        // Reads run in their own task, so a frame split across several reads is never lost when another branch of
        // the loop below wins (a select! branch must be cancel-safe; reading a frame is not).
        let _reading = AbortOnDrop(tokio::spawn(read_frames(reader, frames_tx, Arc::new(tokio::sync::Semaphore::new(READ_BUDGET)))));
        let handshake = tokio::time::sleep(HANDSHAKE_TIMEOUT);
        tokio::pin!(handshake);
        let mut code_deadline: Option<tokio::time::Instant> = None;
        let mut heartbeat = tokio::time::interval(HEARTBEAT);
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        heartbeat.tick().await;
        let mut last_heard = tokio::time::Instant::now();
        loop {
            let code_wait = async {
                match code_deadline {
                    Some(d) => tokio::time::sleep_until(d).await,
                    None => std::future::pending().await,
                }
            };
            let transfer_deadline = self.active.as_ref().and_then(|a| a.deadline);
            let transfer_wait = async move {
                match transfer_deadline {
                    Some(d) => tokio::time::sleep_until(d).await,
                    None => std::future::pending().await,
                }
            };
            let chunk_ready = self.chunk_ready();
            let room = self.in_flight.load(Ordering::Relaxed) < CHUNKS_IN_FLIGHT;
            let wake = self.room.clone();
            tokio::select! {
                // The next file chunk while few are queued; incoming frames are read in between.
                _ = std::future::ready(()), if chunk_ready && room => {
                    if let Step::Close(reason) = self.next_chunk() {
                        return reason;
                    }
                }
                _ = wake.notified(), if chunk_ready && !room => {}
                _ = transfer_wait => {
                    if let Step::Close(reason) = self.transfer_timeout().await {
                        return reason;
                    }
                }
                read = frames.recv() => {
                    // The permit goes back to the reader's budget once this frame is handled.
                    let (read, _permit) = match read {
                        Some((r, p)) => (r, p),
                        None => return "read_failed".into(),
                    };
                    let step = match read {
                        ReadFrame::End => return if self.st.authenticated { "closed_by_peer".into() } else { "closed_before_pairing".into() },
                        ReadFrame::Failed(reason) => return reason.into(),
                        ReadFrame::Line(line) => {
                            last_heard = tokio::time::Instant::now();
                            self.handle.heard.store(clock_ms(), Ordering::Relaxed);
                            // A malformed frame closes the session before dispatch (protocol/messages.json transport).
                            match Message::decode(&line) {
                                Ok(m) => self.receive(m).await,
                                Err(_) => return "bad_frame".into(),
                            }
                        }
                        ReadFrame::Binary { kind, body } => {
                            // Before authentication the marker is just an invalid JSON frame, as it always was.
                            if !self.st.authenticated {
                                return "bad_frame".into();
                            }
                            last_heard = tokio::time::Instant::now();
                            self.handle.heard.store(clock_ms(), Ordering::Relaxed);
                            self.binary(kind, &body).await
                        }
                    };
                    match step {
                        Step::Continue => if self.st.authenticated { code_deadline = None },
                        Step::AwaitCode => { self.st.awaiting_code = true; code_deadline = Some(tokio::time::Instant::now() + CODE_TIMEOUT) }
                        Step::Close(reason) => return reason,
                    }
                }
                command = rx.recv() => {
                    let Some(command) = command else { continue };
                    match self.command(command).await {
                        Step::Continue => if self.st.authenticated { code_deadline = None },
                        Step::AwaitCode => {}
                        Step::Close(reason) => return reason,
                    }
                }
                _ = code_wait => {
                    self.cancel("timeout").await;
                    return "code_timeout".into();
                }
                _ = &mut handshake, if !self.st.authenticated && code_deadline.is_none() => {
                    return "handshake_timeout".into();
                }
                _ = heartbeat.tick(), if self.st.authenticated => {
                    if last_heard.elapsed() > HEARTBEAT_TIMEOUT {
                        return "heartbeat_timeout".into();
                    }
                    let mut ping = Message::new("heartbeat.ping", &self.st.id);
                    ping.message_id = Some(crypto::uuid4());
                    if self.send(ping).await.is_err() {
                        return "send_failed".into();
                    }
                }
            }
        }
    }

    async fn command(&mut self, command: Command) -> Step {
        match command {
            Command::Close(why) => {
                if !self.st.authenticated && why == "cancelled" {
                    self.cancel("cancelled").await;
                }
                Step::Close(why.into())
            }
            Command::Confirm(accept) => {
                if !self.st.awaiting_code || self.st.local_confirmed {
                    return Step::Continue;
                }
                if !accept {
                    self.cancel("mismatch").await;
                    return Step::Close("code_rejected".into());
                }
                if let Err(e) = self.confirm().await {
                    return Step::Close(e);
                }
                self.complete()
            }
            Command::Features => {
                if self.st.authenticated {
                    self.send_features().await
                } else {
                    Step::Continue
                }
            }
            Command::Clipboard { text, message_id } => {
                if !self.st.authenticated {
                    return Step::Continue;
                }
                self.encrypted("clipboard.update", text.as_bytes(), message_id).await
            }
            Command::Ping { message_id } => {
                if !self.st.authenticated {
                    return Step::Continue;
                }
                self.encrypted("ping.request", br#"{"version":1}"#, message_id).await
            }
            Command::SendFile(file) => {
                if !self.st.authenticated {
                    self.file_failed(file.transfer, false, &file.name, "not_connected");
                    return Step::Continue;
                }
                self.queue.push_back(file);
                self.start_next().await
            }
            Command::CancelFile(transfer) => self.cancel_file(transfer).await,
            Command::Checked(c) => self.checked(*c).await,
            Command::Checking(id) => {
                // Still re-reading: the sender's wait for the answer starts again (files_resume_draft1).
                if self.incoming.get(&id).is_some_and(|i| matches!(i.phase, Phase::Checking { .. })) {
                    return self.outer("files.resume.wait", &id, None).await;
                }
                Step::Continue
            }
            Command::Encrypted { kind, plaintext, message_id } => {
                if !self.st.authenticated {
                    return Step::Continue;
                }
                self.encrypted(kind, &plaintext, message_id).await
            }
            Command::Plain { kind, message_id } => {
                if !self.st.authenticated {
                    return Step::Continue;
                }
                self.plain(kind, Some(message_id)).await
            }
            Command::Link { url, request_id, open } => {
                if !self.st.authenticated {
                    return Step::Continue;
                }
                self.quick_sequence += 1;
                let request = json!({
                    "version": 1,
                    "requestId": request_id,
                    "feature": "links",
                    "action": if open { "open" } else { "offer" },
                    "value": url,
                    "sequence": self.quick_sequence,
                });
                self.encrypted("quick.request", request.to_string().as_bytes(), crypto::uuid4()).await
            }
        }
    }

    async fn encrypted(&mut self, kind: &str, plaintext: &[u8], message_id: String) -> Step {
        self.encrypted_for(kind, plaintext, message_id, None).await
    }

    /// An encrypted message; file messages repeat their transfer ID outside, so a receiver can refuse without decrypting.
    async fn encrypted_for(&mut self, kind: &str, plaintext: &[u8], message_id: String, transfer_id: Option<&str>) -> Step {
        let Some(key) = self.st.key else { return Step::Continue };
        let (nonce, ciphertext) = crypto::encrypt(&key, plaintext);
        let mut m = Message::new(kind, &self.st.id);
        m.message_id = Some(message_id);
        m.nonce = Some(nonce);
        m.ciphertext = Some(ciphertext);
        m.transfer_id = transfer_id.map(str::to_string);
        match self.send(m).await {
            Ok(()) => Step::Continue,
            Err(_) => Step::Close("send_failed".into()),
        }
    }

    async fn send_features(&mut self) -> Step {
        let policy = self.host.policy(&self.st.remote_id);
        self.encrypted("features.update", &policy.encode(), crypto::uuid4()).await
    }

    /// One frame's bytes, tagged once there is an envelope key (pairing frames other than pairing.cancel never are).
    fn frame(&self, mut m: Message) -> Vec<u8> {
        if let Some(key) = self.st.envelope {
            if !m.kind.starts_with("pairing.") || m.kind == "pairing.cancel" {
                m.tag = Some(m.compute_tag(&key, &self.host.local().device_id));
            }
        }
        let mut text = m.encode();
        text.push('\n');
        text.into_bytes()
    }

    /// Queues one frame for the socket, in order. Never waits.
    async fn send(&mut self, m: Message) -> Result<(), ()> {
        let frame = self.frame(m);
        self.write.send((frame, false)).map_err(|_| ())
    }

    fn send_chunk(&self, m: Message) -> Result<(), ()> {
        let frame = self.frame(m);
        self.send_chunk_bytes(frame)
    }

    /// A chunk's bytes as they go on the wire (a JSON frame or a binary frame).
    fn send_chunk_bytes(&self, frame: Vec<u8>) -> Result<(), ()> {
        self.in_flight.fetch_add(1, Ordering::Relaxed);
        self.write.send((frame, true)).map_err(|_| ())
    }

    /// A transfer control message with nothing encrypted (`files.accept`, `files.chunk.ack`, `files.cancel`, ...).
    async fn outer(&mut self, kind: &str, transfer_id: &str, sequence: Option<i64>) -> Step {
        let mut m = Message::new(kind, &self.st.id);
        m.transfer_id = Some(transfer_id.to_string());
        m.sequence = sequence;
        match self.send(m).await {
            Ok(()) => Step::Continue,
            Err(_) => Step::Close("send_failed".into()),
        }
    }

    async fn cancel(&mut self, reason: &str) {
        let mut cancel = Message::new("pairing.cancel", &self.st.id);
        cancel.reason = Some(reason.into());
        let _ = self.send(cancel).await;
    }

    fn transcript(&self) -> Vec<u8> {
        let local = self.host.local();
        let (init_id, resp_id, init_eph, resp_eph) = if self.initiated() {
            (local.device_id.as_str(), self.st.remote_id.as_str(), self.st.eph.public.as_str(), self.st.remote_eph.as_str())
        } else {
            (self.st.remote_id.as_str(), local.device_id.as_str(), self.st.remote_eph.as_str(), self.st.eph.public.as_str())
        };
        match &self.tunnel {
            // On a tunnel the exporter binds the signatures to this TLS session: a relay or a man in the middle that
            // ends QUIC on both sides sees two different exporters.
            Some(t) => transcript_v2(&self.st.id, init_id, resp_id, init_eph, resp_eph, &t.exporter),
            None => transcript_v1(&self.st.id, init_id, resp_id, init_eph, resp_eph),
        }
    }

    async fn confirm(&mut self) -> Result<(), String> {
        if self.st.local_confirmed {
            return Ok(());
        }
        let key = self.st.key.ok_or("no key")?;
        self.st.local_confirmed = true;
        let host = self.host.clone();
        let local = host.local();
        let mut m = Message::new("pairing.confirm", &self.st.id);
        m.device_id = Some(local.device_id.clone());
        m.identity_key = Some(local.identity_public.clone());
        m.proof = Some(crypto::confirmation_proof(&key, &self.st.id, &local.device_id, &local.identity_public));
        m.signature = Some(crypto::b64(&local.identity.sign(&self.transcript())));
        self.send(m).await.map_err(|_| "send_failed".to_string())
    }

    fn complete(&mut self) -> Step {
        if !self.st.local_confirmed || !self.st.remote_confirmed || self.st.authenticated {
            return Step::Continue;
        }
        self.st.authenticated = true;
        self.st.awaiting_code = false;
        let auth = Authenticated {
            session: self.session,
            device_id: self.st.remote_id.clone(),
            name: self.st.remote_name.clone(),
            identity_key: self.st.remote_identity.clone().unwrap_or_default(),
            paired: self.st.paired,
            dialled: self.initiated(),
            peer: self.peer,
            handle: self.handle.clone(),
        };
        if !self.host.authenticated(auth) {
            return Step::Close("replaced".into());
        }
        // The first message after pairing: this end's switches for that device.
        let _ = self.handle.send_features();
        Step::Continue
    }

    fn set_key(&mut self, prk: [u8; 32], key: [u8; 32]) -> [u8; 32] {
        #[cfg(test)]
        KEYLOG.lock().unwrap().push((self.st.id.clone(), prk, key));
        self.st.key = Some(key);
        // Both ends sent protocol 2 (checked before every agreement here), so frames carry tags from now on.
        self.st.envelope = Some(crypto::envelope_key(&key));
        self.st.fast_key = Some(fast::frame_key(&key));
        prk
    }

    fn bad(&mut self) -> Step {
        self.st.bad_frames += 1;
        if self.st.bad_frames >= MAX_BAD_FRAMES {
            Step::Close("bad_frames".into())
        } else {
            Step::Continue
        }
    }

    fn code_event(&self, code: String) {
        self.host.event(Event::Code { session: self.session, device_id: self.st.remote_id.clone(), name: self.st.remote_name.clone(), code });
    }

    async fn receive(&mut self, m: Message) -> Step {
        let pairing = m.kind.starts_with("pairing.");
        // Admission (PairingRules.admitFrame): pairing frames before authentication, everything else after, tagged.
        if pairing {
            if self.st.authenticated && m.kind != "pairing.cancel" {
                return self.bad();
            }
            if m.kind == "pairing.cancel" {
                if let Some(key) = self.st.envelope {
                    if (self.st.authenticated || m.tag.is_some()) && !m.tag_matches(&key, &self.st.remote_id) {
                        return self.bad();
                    }
                }
            }
        } else {
            if !self.st.authenticated || m.session_id != self.st.id {
                return self.bad();
            }
            let Some(key) = self.st.envelope else { return self.bad() };
            if !m.tag_matches(&key, &self.st.remote_id) {
                return self.bad();
            }
        }
        match m.kind.as_str() {
            "pairing.offer" => self.offer(m).await,
            "pairing.answer" => self.answer(m).await,
            "pairing.reveal" => self.reveal(m),
            "pairing.confirm" => self.remote_confirm(m),
            "pairing.cancel" => {
                let reason: String = m.reason.as_deref().unwrap_or("cancelled").chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '_').take(32).collect();
                Step::Close(format!("cancelled_remote:{reason}"))
            }
            _ => self.application(m).await,
        }
    }

    async fn offer(&mut self, m: Message) -> Step {
        if self.initiated() || self.st.key.is_some() || self.st.remote_commitment.is_some() {
            return Step::Continue;
        }
        self.st.offers_seen += 1;
        if self.st.offers_seen > 1 {
            return Step::Close("second_offer".into());
        }
        let local_id = self.host.local().device_id.clone();
        // A reconnect meant for another device: close quietly, no prompt.
        if m.target_device_id.as_deref().is_some_and(|t| !t.eq_ignore_ascii_case(&local_id)) {
            return Step::Close("not_for_this_device".into());
        }
        let Some(remote_id) = m.device_id.clone().filter(|d| crypto::is_uuid(d)).map(|d| d.to_ascii_lowercase()) else {
            return Step::Close("malformed_offer".into());
        };
        if !crypto::is_uuid(&m.session_id) || remote_id == local_id {
            return Step::Close("malformed_offer".into());
        }
        self.st.id = m.session_id.clone();
        self.st.remote_id = remote_id.clone();
        self.st.remote_name = sanitized_name(m.device_name.as_deref());
        if m.protocol_version.unwrap_or(1) < crypto::PROTOCOL_VERSION {
            self.cancel("needs_protocol_2").await;
            return Step::Close("needs_protocol_2".into());
        }
        let trusted = self.host.pin(&remote_id).is_some();
        match (m.public_key.clone(), m.commitment.clone()) {
            // Tunnels carry trusted devices only: a first pairing stays on the local network, where the code is compared.
            (None, Some(_)) if self.tunnel.is_some() => {
                self.cancel("not_trusted").await;
                Step::Close("tunnel_untrusted".into())
            }
            // A first pairing (or a pairing again, with a code): the host decides.
            (None, Some(commitment)) => {
                let offer = Offer { session: self.session, device_id: &remote_id, name: &self.st.remote_name, peer: self.peer };
                if let Admission::Refuse(reason) = self.host.admit(&offer) {
                    self.cancel(reason).await;
                    return Step::Close(format!("refused:{reason}"));
                }
                self.st.paired = true;
                self.st.remote_commitment = Some(commitment);
                if self.answer_offer().await.is_err() {
                    return Step::Close("send_failed".into());
                }
                Step::Continue
            }
            // A reconnect: only from a trusted device; its pinned identity is checked at the confirm.
            (Some(revealed), None) if trusted => {
                self.st.remote_eph = revealed;
                let remote = self.st.remote_eph.clone();
                let Some((prk, key)) = self.st.eph.agree(&remote, &self.st.id) else { return Step::Close("bad_key".into()) };
                self.set_key(prk, key);
                if self.answer_offer().await.is_err() {
                    return Step::Close("send_failed".into());
                }
                match self.confirm().await {
                    Ok(()) => Step::Continue,
                    Err(e) => Step::Close(e),
                }
            }
            (Some(_), None) => {
                // Protocol 2 never takes an uncommitted offer from a device it does not trust.
                self.cancel("not_trusted").await;
                Step::Close("not_trusted".into())
            }
            _ => Step::Close("malformed_offer".into()),
        }
    }

    async fn answer_offer(&mut self) -> Result<(), ()> {
        let host = self.host.clone();
        let local = host.local();
        let mut answer = Message::new("pairing.answer", &self.st.id);
        answer.device_id = Some(local.device_id.clone());
        answer.device_name = Some(local.name());
        answer.public_key = Some(self.st.eph.public.clone());
        answer.protocol_version = Some(crypto::PROTOCOL_VERSION);
        self.st.answered = true;
        self.send(answer).await
    }

    async fn answer(&mut self, m: Message) -> Step {
        if !self.initiated() || self.st.key.is_some() || m.session_id != self.st.id {
            return Step::Continue;
        }
        let (Some(remote_id), Some(remote_eph)) = (m.device_id.clone().filter(|d| crypto::is_uuid(d)).map(|d| d.to_ascii_lowercase()), m.public_key.clone()) else {
            return Step::Close("malformed_answer".into());
        };
        if remote_id == self.host.local().device_id {
            return Step::Close("malformed_answer".into());
        }
        if let Role::Reconnect { device_id } = &self.role {
            // A dialler whose answer names another device closes.
            if !remote_id.eq_ignore_ascii_case(device_id) {
                return Step::Close("wrong_device".into());
            }
        }
        if m.protocol_version.unwrap_or(1) < crypto::PROTOCOL_VERSION {
            self.cancel("needs_protocol_2").await;
            return Step::Close("needs_protocol_2".into());
        }
        self.st.remote_id = remote_id;
        self.st.remote_name = sanitized_name(m.device_name.as_deref());
        self.st.remote_eph = remote_eph;
        self.st.answered = true;
        let local_eph = self.st.eph.public.clone();
        let remote = self.st.remote_eph.clone();
        let Some((prk, key)) = self.st.eph.agree(&remote, &self.st.id) else { return Step::Close("bad_key".into()) };
        let prk = self.set_key(prk, key);
        if self.role == Role::Pair {
            let mut reveal = Message::new("pairing.reveal", &self.st.id);
            reveal.public_key = Some(local_eph.clone());
            if self.send(reveal).await.is_err() {
                return Step::Close("send_failed".into());
            }
            self.code_event(crypto::sas_code(&prk, &local_eph, &self.st.remote_eph));
            return Step::AwaitCode;
        }
        match self.confirm().await {
            Ok(()) => Step::Continue,
            Err(e) => Step::Close(e),
        }
    }

    fn reveal(&mut self, m: Message) -> Step {
        if self.initiated() || self.st.key.is_some() || m.session_id != self.st.id {
            return Step::Continue;
        }
        let Some(commitment) = self.st.remote_commitment.clone() else { return Step::Continue };
        let Some(revealed) = m.public_key.clone() else { return Step::Close("commitment_mismatch".into()) };
        if !crypto::commitment_matches(&commitment, &self.st.id, &revealed) {
            return Step::Close("commitment_mismatch".into());
        }
        self.st.remote_eph = revealed;
        let remote = self.st.remote_eph.clone();
        let Some((prk, key)) = self.st.eph.agree(&remote, &self.st.id) else { return Step::Close("bad_key".into()) };
        let prk = self.set_key(prk, key);
        self.code_event(crypto::sas_code(&prk, &self.st.remote_eph, &self.st.eph.public));
        Step::AwaitCode
    }

    fn remote_confirm(&mut self, m: Message) -> Step {
        if m.session_id != self.st.id || self.st.key.is_none() || self.st.remote_confirmed {
            return Step::Continue;
        }
        let (Some(remote_id), Some(identity_key), Some(proof), Some(signature)) = (m.device_id.clone(), m.identity_key.clone(), m.proof.clone(), m.signature.clone()) else {
            return Step::Close("invalid_confirm".into());
        };
        if !remote_id.eq_ignore_ascii_case(&self.st.remote_id) {
            return Step::Close("invalid_confirm".into());
        }
        if !self.st.paired {
            // A reconnect: the pinned identity key, and nothing else, authenticates the device.
            match self.host.pin(&self.st.remote_id) {
                Some(pinned) if pinned == identity_key => {}
                Some(_) => return Step::Close("identity_changed".into()),
                None => return Step::Close("not_trusted".into()),
            }
        }
        let key = self.st.key.unwrap();
        if !crypto::proof_matches(&key, &self.st.id, &remote_id, &identity_key, &proof) || !crypto::verify_signature(&identity_key, &self.transcript(), &signature) {
            return Step::Close("authentication_failed".into());
        }
        self.st.remote_identity = Some(identity_key);
        self.st.remote_confirmed = true;
        self.complete()
    }

    /// Replay window for every message with a messageId; acknowledgements echo the sender's own ID instead.
    fn fresh(&mut self, m: &Message) -> Option<bool> {
        let id = m.message_id.as_ref()?;
        if id.len() > 128 {
            return None;
        }
        if matches!(m.kind.as_str(), "heartbeat.pong" | "ping.ack" | "clipboard.ack" | "clipboard.rejected" | "calls.started" | "calls.confirmation_required" | "calls.rejected") {
            return Some(true);
        }
        if self.st.seen.contains(id) {
            return Some(false);
        }
        self.st.seen.insert(id.clone());
        self.st.order.push_back(id.clone());
        if self.st.order.len() > REPLAY_WINDOW {
            if let Some(old) = self.st.order.pop_front() {
                self.st.seen.remove(&old);
            }
        }
        Some(true)
    }

    fn open(&self, m: &Message) -> Option<Vec<u8>> {
        crypto::decrypt(&self.st.key?, m.nonce.as_deref()?, m.ciphertext.as_deref()?)
    }

    async fn plain(&mut self, kind: &str, message_id: Option<String>) -> Step {
        let mut m = Message::new(kind, &self.st.id);
        m.message_id = message_id;
        match self.send(m).await {
            Ok(()) => Step::Continue,
            Err(_) => Step::Close("send_failed".into()),
        }
    }

    async fn application(&mut self, m: Message) -> Step {
        match self.fresh(&m) {
            None if m.message_id.is_some() => return self.bad(),
            Some(false) => return Step::Continue,
            _ => {}
        }
        let device_id = self.st.remote_id.clone();
        match m.kind.as_str() {
            "heartbeat.ping" => self.plain("heartbeat.pong", m.message_id.clone()).await,
            "heartbeat.pong" => Step::Continue,
            "features.update" => {
                if m.message_id.is_none() {
                    return Step::Continue;
                }
                // An upstream v1 message that does not open closes the session (protocol/messages.json).
                let Some(plain) = self.open(&m) else { return Step::Close("bad_features".into()) };
                match features::decode(&plain) {
                    features::Decoded::State(features) => {
                        self.st.remote_fast = features.get(fast::FEATURE);
                        self.st.remote_resume = features.get(resume::FEATURE);
                        self.host.event(Event::Features { session: self.session, device_id, features });
                        Step::Continue
                    }
                    features::Decoded::Ignored => Step::Continue,
                    features::Decoded::Invalid => Step::Close("invalid_features".into()),
                }
            }
            "clipboard.update" | "clipboard.rich" => {
                let Some(message_id) = m.message_id.clone() else { return Step::Continue };
                let Some(plain) = self.open(&m) else { return Step::Close("bad_clipboard".into()) };
                if !self.host.policy(&device_id).get("clipboard") {
                    // Clipboard is off here: say so, then resend the switches the peer should have had.
                    let step = self.plain("clipboard.rejected", Some(message_id)).await;
                    if let Step::Close(r) = step {
                        return Step::Close(r);
                    }
                    return self.send_features().await;
                }
                let decoded = if m.kind == "clipboard.update" { clipboard_text(&plain) } else { clipboard_rich(&plain) };
                // Malformed, empty or oversized: rejected without an acknowledgement.
                let Some((text, html)) = decoded else { return Step::Continue };
                self.host.event(Event::Clipboard { session: self.session, device_id, text, html });
                self.plain("clipboard.ack", Some(message_id)).await
            }
            "clipboard.ack" | "clipboard.rejected" => {
                if let Some(message_id) = m.message_id.clone() {
                    self.host.event(Event::ClipboardResult { device_id, message_id, delivered: m.kind == "clipboard.ack" });
                }
                Step::Continue
            }
            "ping.request" => {
                let Some(message_id) = m.message_id.clone() else { return Step::Continue };
                let Some(plain) = self.open(&m) else { return Step::Close("bad_ping".into()) };
                if !self.host.policy(&device_id).get("ping") || !version_one(&plain) {
                    return Step::Continue;
                }
                self.host.event(Event::Ping { device_id });
                self.plain("ping.ack", Some(message_id)).await
            }
            "ping.ack" => {
                if let Some(message_id) = m.message_id.clone() {
                    self.host.event(Event::PingAck { device_id, message_id });
                }
                Step::Continue
            }
            "files.offer" => self.file_offer(m).await,
            "files.chunk" => self.file_chunk(m).await,
            "files.complete" => self.file_complete(m).await,
            "files.resume" => self.file_resume(m).await,
            "files.resume.ack" => self.file_resume_ack(m).await,
            "files.resume.wait" => {
                // The receiver is still re-reading what it kept of this file: wait for its answer a while longer.
                let window = self.host.resume_timing().0;
                if let Some(a) = self.active.as_mut().filter(|a| Some(&a.id) == m.transfer_id.as_ref() && a.stage == Stage::Offered && a.resumable) {
                    a.deadline = Some(Instant::now() + window);
                }
                Step::Continue
            }
            "files.accept" => {
                if let Some(a) = self.active.as_mut().filter(|a| Some(&a.id) == m.transfer_id.as_ref() && a.stage == Stage::Offered) {
                    a.stage = Stage::Sending;
                    a.deadline = Some(Instant::now() + ACK_STALL);
                }
                Step::Continue
            }
            "files.chunk.ack" => {
                if let (Some(a), Some(sequence)) = (self.active.as_mut().filter(|a| Some(&a.id) == m.transfer_id.as_ref()), m.sequence) {
                    a.acks = true;
                    a.acked = a.acked.max(sequence.min(a.sequence - 1));
                    if a.fast && sequence >= 0 {
                        a.pacer.acknowledged(sequence as u64, Instant::now().into_std());
                    }
                    if a.stage == Stage::Sending {
                        a.deadline = Some(Instant::now() + ACK_STALL);
                    }
                }
                Step::Continue
            }
            "files.complete.ack" => {
                let done = self.active.take_if(|a| Some(&a.id) == m.transfer_id.as_ref() && a.stage == Stage::Completing);
                if let Some(a) = done {
                    self.ended(&a.id);
                    let f = a.file;
                    self.host.event(Event::FileDone { transfer: f.transfer, device_id, incoming: false, name: f.name, path: None, size: f.size });
                    return self.start_next().await;
                }
                Step::Continue
            }
            "files.rejected" => {
                // Files is off on the other device: this file and the ones waiting behind it would all be refused.
                let refused = self.active.take_if(|a| Some(&a.id) == m.transfer_id.as_ref());
                if let Some(a) = refused {
                    self.ended(&a.id);
                    self.file_failed(a.file.transfer, false, &a.file.name, "rejected");
                    for f in std::mem::take(&mut self.queue) {
                        self.file_failed(f.transfer, false, &f.name, "rejected");
                    }
                }
                Step::Continue
            }
            "files.cancel" => {
                let Some(id) = m.transfer_id.clone() else { return Step::Continue };
                let mut known = false;
                if let Some(a) = self.active.take_if(|a| a.id == id) {
                    known = true;
                    self.ended(&id);
                    self.file_failed(a.file.transfer, false, &a.file.name, "cancelled_remote");
                }
                if let Some(i) = self.incoming.remove(&id) {
                    known = true;
                    self.drop_incoming(&id, i, "cancelled_remote");
                }
                if !known {
                    return Step::Continue;
                }
                if let Step::Close(r) = self.outer("files.cancel.ack", &id, None).await {
                    return Step::Close(r);
                }
                self.start_next().await
            }
            "files.cancel.ack" => Step::Continue,
            "battery.update" => {
                if m.message_id.is_none() {
                    return Step::Continue;
                }
                let Some(plain) = self.open(&m) else { return Step::Close("bad_battery".into()) };
                if !self.host.policy(&device_id).get("battery") {
                    return Step::Continue;
                }
                // Out of range or malformed values are rejected; the session stays.
                if let Some((level, charging)) = battery(&plain) {
                    self.host.event(Event::Battery { device_id, level, charging });
                }
                Step::Continue
            }
            "find.start" | "find.stop" => {
                if m.message_id.is_none() {
                    return Step::Continue;
                }
                let Some(plain) = self.open(&m) else { return Step::Close("bad_find".into()) };
                if alert_id(&plain).is_none() {
                    return Step::Close("bad_find".into());
                }
                let ring = m.kind == "find.start";
                if ring && !self.host.policy(&device_id).get("find_device") {
                    return Step::Continue;
                }
                self.host.event(Event::Find { device_id, ring });
                let reply = if ring { "find.started" } else { "find.stopped" };
                self.encrypted(reply, find_payload().as_bytes(), crypto::uuid4()).await
            }
            "notifications.post" | "notifications.remove" => {
                if m.message_id.is_none() {
                    return Step::Continue;
                }
                // Upstream v1: a payload that does not open closes the session.
                let Some(plain) = self.open(&m) else { return Step::Close("bad_notification".into()) };
                if !self.host.policy(&device_id).get("notifications") {
                    return Step::Continue;
                }
                let kind = if m.kind == "notifications.post" { "notifications.post" } else { "notifications.remove" };
                self.host.event(Event::Payload { device_id, kind, plain });
                Step::Continue
            }
            "connect.setup" | "connect.setup.ack" | "connect.addresses" => {
                if m.message_id.is_none() {
                    return Step::Continue;
                }
                // Drafts: a payload that does not open is dropped and the session stays.
                let Some(plain) = self.open(&m).filter(|p| p.len() <= 8_192) else { return Step::Continue };
                let kind = match m.kind.as_str() {
                    "connect.setup" => "connect.setup",
                    "connect.setup.ack" => "connect.setup.ack",
                    _ => "connect.addresses",
                };
                self.host.event(Event::Payload { device_id, kind, plain });
                Step::Continue
            }
            "codes.status" | "codes.advertise" | "codes.advertise_stop" => {
                if m.message_id.is_none() {
                    return Step::Continue;
                }
                // Drafts: a payload that does not open is dropped and the session stays.
                let Some(plain) = self.open(&m).filter(|p| p.len() <= 1_024) else { return Step::Continue };
                if !self.host.policy(&device_id).get(crate::notifications::SMS_CODES) {
                    return Step::Continue;
                }
                let kind = match m.kind.as_str() {
                    "codes.status" => "codes.status",
                    "codes.advertise" => "codes.advertise",
                    _ => "codes.advertise_stop",
                };
                self.host.event(Event::Payload { device_id, kind, plain });
                Step::Continue
            }
            "find.started" | "find.stopped" => {
                if m.message_id.is_none() {
                    return Step::Continue;
                }
                let Some(plain) = self.open(&m) else { return Step::Close("bad_find".into()) };
                if alert_id(&plain).is_none() {
                    return Step::Close("bad_find".into());
                }
                self.host.event(Event::FindAck { device_id, ringing: m.kind == "find.started" });
                Step::Continue
            }
            "quick.request" => self.quick_request(m).await,
            "quick.result" => {
                let Some(plain) = self.open(&m).filter(|p| p.len() <= QUICK_MAX) else { return Step::Continue };
                let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(&plain) else { return Step::Continue };
                if o.get("version").and_then(Value::as_i64) != Some(1) {
                    return Step::Continue;
                }
                let (Some(request_id), Some(accepted)) = (o.get("requestId").and_then(Value::as_str), o.get("accepted").and_then(Value::as_bool)) else {
                    return Step::Continue;
                };
                let opened = o.get("opened").and_then(Value::as_bool).unwrap_or(false);
                self.host.event(Event::QuickResult { device_id, request_id: request_id.to_string(), accepted, opened });
                Step::Continue
            }
            // The phone's answers to `calls.request` (upstream calls.v1): outer only, echoing the request's message ID,
            // which is all they carry.
            "calls.started" | "calls.confirmation_required" | "calls.rejected" => {
                let Some(message_id) = m.message_id.clone() else { return Step::Continue };
                if !self.host.policy(&device_id).get("calls") {
                    return Step::Continue;
                }
                let kind = match m.kind.as_str() {
                    "calls.started" => "calls.started",
                    "calls.confirmation_required" => "calls.confirmation_required",
                    _ => "calls.rejected",
                };
                self.host.event(Event::Payload { device_id, kind, plain: message_id.into_bytes() });
                Step::Continue
            }
            // The phone's own features (phone.rs). Drafts: a payload that does not open, or is over its kind's limit, is
            // dropped and the session stays.
            kind if self.host.phone_kind(kind).is_some() => {
                let spec = self.host.phone_kind(kind).unwrap();
                let Some(message_id) = m.message_id.clone() else { return Step::Continue };
                let Some(mut plain) = self.open(&m).filter(|p| p.len() <= spec.max) else { return Step::Continue };
                if !self.host.policy(&device_id).get(spec.feature) {
                    return Step::Continue;
                }
                // A request answered with its own message ID (a simulated phone's calls.request) carries it along.
                if spec.with_message_id {
                    plain = json!({"messageId": message_id, "plaintext": String::from_utf8_lossy(&plain)}).to_string().into_bytes();
                }
                self.host.event(Event::Payload { device_id, kind: spec.kind, plain });
                Step::Continue
            }
            // Unknown kinds and features this client does not offer: ignored, the session stays.
            _ => Step::Continue,
        }
    }

    // MARK: files (docs/protocol.md "Files (`files.v1`)", JSON chunks)

    fn file_failed(&self, transfer: u64, incoming: bool, name: &str, reason: &str) {
        self.host.event(Event::FileFailed { transfer, device_id: self.st.remote_id.clone(), incoming, name: name.to_string(), reason: reason.to_string() });
    }

    /// Remembers a transfer that ended so its late chunks are dropped without a fuss.
    fn ended(&mut self, id: &str) {
        self.ended.push_back(id.to_string());
        if self.ended.len() > 64 {
            self.ended.pop_front();
        }
    }

    fn drop_incoming(&mut self, id: &str, i: Incoming, reason: &str) {
        drop(i.file);
        let _ = std::fs::remove_file(&i.part);
        if i.resumable {
            self.host.resume_release(&i.part, false);
        }
        self.ended(id);
        self.file_failed(i.transfer, true, &i.name, reason);
    }

    /// An interrupted file that can be resumed: its verified bytes are synced and recorded, and the partial stays for
    /// a later attempt (files_resume_draft1). Nothing verified, or a write that fails, and it goes as before.
    fn keep_incoming(&mut self, id: &str, mut i: Incoming, reason: &str) {
        let kept = match i.phase {
            // The partial is as its record says: not touched yet, or cut back to the offset proposed.
            Phase::Checking { .. } | Phase::Proposed(_) => true,
            Phase::Receiving => {
                let verified = i.hasher.checkpoint(i.size);
                let record = (verified.0 > 0).then(|| record_of(&self.st.remote_id, &i, verified)).flatten();
                match record {
                    Some(r) if i.file.flush().and_then(|_| i.file.sync_data()).is_ok() => {
                        self.host.resume_save(r);
                        true
                    }
                    _ => false,
                }
            }
        };
        if !kept {
            return self.drop_incoming(id, i, reason);
        }
        drop(i.file);
        self.host.resume_release(&i.part, true);
        self.ended(id);
        self.file_failed(i.transfer, true, &i.name, reason);
    }

    /// Resuming is on with this device: both show files_resume_draft1, on a protocol 2 session.
    fn resume_on(&self) -> bool {
        self.st.remote_resume && self.st.envelope.is_some() && self.host.policy(&self.st.remote_id).get(resume::FEATURE)
    }

    /// The next waiting file is offered when nothing is being sent.
    async fn start_next(&mut self) -> Step {
        while self.active.is_none() {
            let Some(file) = self.queue.pop_front() else { return Step::Continue };
            let reader = match std::fs::File::open(&file.path) {
                Ok(r) => r,
                Err(_) => {
                    self.file_failed(file.transfer, false, &file.name, "unreadable");
                    continue;
                }
            };
            let id = crypto::uuid4();
            let mut offer = json!({"transferId": id, "name": file.name, "mimeType": file.mime, "size": file.size, "sha256": file.sha256});
            // Files over one block may resume from what the receiver kept of an earlier attempt (files_resume_draft1).
            let resumable = file.size > resume::BLOCK && self.resume_on();
            if resumable {
                offer["resumable"] = Value::Bool(true);
            }
            // Binary frames when both ends show files_fast_draft1 (this end's switch is in its policy for the device).
            let fast = self.st.remote_fast && self.st.fast_key.is_some() && self.host.policy(&self.st.remote_id).get(fast::FEATURE);
            self.active = Some(Outgoing {
                file,
                id: id.clone(),
                stage: Stage::Offered,
                reader,
                sequence: 0,
                acked: -1,
                acks: false,
                sent: 0,
                deadline: Some(Instant::now() + if resumable { self.host.resume_timing().0 } else { ACCEPT_TIMEOUT }),
                reported: None,
                fast,
                pacer: Pacer::new(fast, self.host.chunk_size(fast), None),
                resumable,
            });
            if let Some(a) = &self.active {
                self.host.event(Event::FileProgress { transfer: a.file.transfer, device_id: self.st.remote_id.clone(), incoming: false, bytes: 0, total: a.file.size });
            }
            return self.encrypted_for("files.offer", offer.to_string().as_bytes(), crypto::uuid4(), Some(&id)).await;
        }
        Step::Continue
    }

    /// A chunk may go when a file is being sent and, for receivers that acknowledge, the window has room. Fast
    /// transfers keep their unacknowledged bytes within the pacer's window.
    fn chunk_ready(&mut self) -> bool {
        if !self.st.authenticated {
            return false;
        }
        let limit = self.host.send_limit();
        let Some(a) = self.active.as_mut().filter(|a| a.stage == Stage::Sending) else { return false };
        if limit > 0 && a.sent >= limit {
            return false;
        }
        if a.fast {
            let chunk = a.pacer.chunk;
            return a.pacer.room(chunk);
        }
        !a.acks || a.sequence - a.acked <= CHUNK_WINDOW
    }

    /// Queues the next chunk, or `files.complete` after the last one.
    fn next_chunk(&mut self) -> Step {
        let Some(key) = self.st.key else { return Step::Continue };
        let device_id = self.st.remote_id.clone();
        let fast_key = self.st.fast_key;
        let local = self.host.local().device_id.clone();
        let Some(a) = self.active.as_mut() else { return Step::Continue };
        // The host's chunk size: 24 KiB as JSON, 256 KiB as binary frames (smaller in tests).
        let mut buf = vec![0u8; a.pacer.chunk];
        let n = match read_full(&mut a.reader, &mut buf) {
            Ok(n) => n,
            Err(_) => usize::MAX,
        };
        let id = a.id.clone();
        if n == usize::MAX || (n == 0 && a.sent != a.file.size) || a.sent + n as u64 > a.file.size {
            // The file could not be read, or changed since it was hashed: tell the other device to let go.
            let a = self.active.take().unwrap();
            let mut m = Message::new("files.cancel", &self.st.id);
            m.transfer_id = Some(id.clone());
            if self.send_chunk(m).is_err() {
                return Step::Close("send_failed".into());
            }
            self.ended(&id);
            self.file_failed(a.file.transfer, false, &a.file.name, "changed");
            return Step::Continue;
        }
        if n > 0 && a.fast {
            let Some(frame) = fast_key.and_then(|k| fast::seal(fast::KIND_CHUNK, &id, a.sequence as u64, &buf[..n], &k, &local, None)) else {
                return Step::Close("send_failed".into());
            };
            a.pacer.sent(a.sequence as u64, n, Instant::now().into_std());
            a.sequence += 1;
            a.sent += n as u64;
            let now = Instant::now();
            if a.reported.is_none_or(|t| now.duration_since(t) >= PROGRESS_EVERY) {
                a.reported = Some(now);
                self.host.event(Event::FileProgress { transfer: a.file.transfer, device_id, incoming: false, bytes: a.sent, total: a.file.size });
            }
            return match self.send_chunk_bytes(frame) {
                Ok(()) => Step::Continue,
                Err(()) => Step::Close("send_failed".into()),
            };
        }
        let m = if n == 0 {
            let plain = json!({"transferId": id, "sha256": a.file.sha256}).to_string();
            let (nonce, ciphertext) = crypto::encrypt(&key, plain.as_bytes());
            a.stage = Stage::Completing;
            a.deadline = Some(Instant::now() + COMPLETE_TIMEOUT);
            let mut m = Message::new("files.complete", &self.st.id);
            m.message_id = Some(crypto::uuid4());
            m.transfer_id = Some(id);
            m.nonce = Some(nonce);
            m.ciphertext = Some(ciphertext);
            m
        } else {
            let (nonce, ciphertext) = crypto::encrypt(&key, &buf[..n]);
            let mut m = Message::new("files.chunk", &self.st.id);
            // The apps take a chunk only with its own messageId (into the replay window).
            m.message_id = Some(crypto::uuid4());
            m.transfer_id = Some(id);
            m.sequence = Some(a.sequence);
            m.nonce = Some(nonce);
            m.ciphertext = Some(ciphertext);
            a.sequence += 1;
            a.sent += n as u64;
            let now = Instant::now();
            if a.reported.is_none_or(|t| now.duration_since(t) >= PROGRESS_EVERY) {
                a.reported = Some(now);
                self.host.event(Event::FileProgress { transfer: a.file.transfer, device_id, incoming: false, bytes: a.sent, total: a.file.size });
            }
            m
        };
        match self.send_chunk(m) {
            Ok(()) => Step::Continue,
            Err(()) => Step::Close("send_failed".into()),
        }
    }

    async fn transfer_timeout(&mut self) -> Step {
        let now = Instant::now();
        let Some(a) = self.active.as_mut() else { return Step::Continue };
        if a.deadline.is_none_or(|d| d > now) {
            return Step::Continue;
        }
        let reason = match a.stage {
            Stage::Offered => "not_accepted",
            Stage::Completing => "not_confirmed",
            // Only a receiver that acknowledges can stall a transfer; for others the wait just goes on.
            Stage::Sending if a.fast && a.pacer.unacknowledged() > 0 => "stalled",
            Stage::Sending if a.acks && a.sequence - a.acked > CHUNK_WINDOW => "stalled",
            Stage::Sending => {
                a.deadline = Some(now + ACK_STALL);
                return Step::Continue;
            }
        };
        let a = self.active.take().unwrap();
        self.ended(&a.id);
        // A resumable file that stopped moving ends as interrupted without files.cancel, as the apps do, so the
        // receiver keeps its partial and the next attempt resumes (files_resume_draft1).
        if reason == "stalled" && a.resumable {
            self.file_failed(a.file.transfer, false, &a.file.name, "interrupted");
            return self.start_next().await;
        }
        self.file_failed(a.file.transfer, false, &a.file.name, reason);
        if let Step::Close(r) = self.outer("files.cancel", &a.id, None).await {
            return Step::Close(r);
        }
        self.start_next().await
    }

    async fn cancel_file(&mut self, transfer: u64) -> Step {
        if let Some(i) = self.queue.iter().position(|f| f.transfer == transfer) {
            let f = self.queue.remove(i).unwrap();
            self.file_failed(f.transfer, false, &f.name, "cancelled");
            return Step::Continue;
        }
        if let Some(a) = self.active.take_if(|a| a.file.transfer == transfer) {
            self.ended(&a.id);
            self.file_failed(a.file.transfer, false, &a.file.name, "cancelled");
            if let Step::Close(r) = self.outer("files.cancel", &a.id, None).await {
                return Step::Close(r);
            }
            return self.start_next().await;
        }
        let id = self.incoming.iter().find(|(_, i)| i.transfer == transfer).map(|(id, _)| id.clone());
        if let Some(id) = id {
            let i = self.incoming.remove(&id).unwrap();
            self.drop_incoming(&id, i, "cancelled");
            return self.outer("files.cancel", &id, None).await;
        }
        Step::Continue
    }

    async fn file_offer(&mut self, m: Message) -> Step {
        let device_id = self.st.remote_id.clone();
        let Some(outer_id) = m.transfer_id.clone() else { return Step::Continue };
        let dir = self.host.receive_dir();
        if !self.host.policy(&device_id).get("files") || dir.is_none() {
            // Files is off here: refused without decrypting, then the switches the other device should have had.
            if let Step::Close(r) = self.outer("files.rejected", &outer_id, None).await {
                return Step::Close(r);
            }
            return self.send_features().await;
        }
        let Some(plain) = self.open(&m) else { return Step::Close("bad_files".into()) };
        let offer = serde_json::from_slice::<Value>(&plain).ok();
        let o = offer.as_ref().and_then(Value::as_object);
        let field = |k: &str| o.and_then(|o| o.get(k));
        let transfer_id = field("transferId").and_then(Value::as_str).unwrap_or("");
        let name = field("name").and_then(Value::as_str).unwrap_or("");
        let size = field("size").and_then(Value::as_u64);
        let sha256 = field("sha256").and_then(Value::as_str).and_then(crypto::unb64).filter(|h| h.len() == 32);
        let mime = field("mimeType").and_then(Value::as_str).unwrap_or("application/octet-stream").chars().take(128).collect::<String>();
        // Clipboard files and folders are drafts this client does not advertise.
        let other_purpose = field("purpose").is_some_and(|p| !p.is_null()) || field("folderTransferId").is_some_and(|p| !p.is_null());
        let (Some(size), Some(sha256)) = (size, sha256) else { return self.outer("files.cancel", &outer_id, None).await };
        if other_purpose || transfer_id != outer_id || !crypto::is_uuid(transfer_id) || name.is_empty() || size > MAX_FILE {
            return self.outer("files.cancel", &outer_id, None).await;
        }
        let taken = self.incoming.contains_key(transfer_id) || self.active.as_ref().is_some_and(|a| a.id == transfer_id) || self.ended.iter().any(|e| e == transfer_id);
        if taken || self.incoming.len() >= MAX_INCOMING {
            return self.outer("files.cancel", &outer_id, None).await;
        }
        let dir = dir.unwrap();
        let name = transfer::safe_name(name);
        // files_resume_draft1: the sender marked it, both show the key, and it is more than one block.
        let resumable = field("resumable") == Some(&Value::Bool(true)) && size > resume::BLOCK && self.resume_on();
        let new = |part: PathBuf, file: std::fs::File, transfer: u64, phase: Phase, checkpoint: u64| Incoming {
            transfer,
            name: name.clone(),
            size,
            sha256: sha256.clone(),
            received: 0,
            next_sequence: 0,
            dir: dir.clone(),
            part,
            file,
            hasher: Running::new(false),
            reported: None,
            resumable,
            phase,
            checkpoint,
        };
        if resumable {
            // Only this device's partial of this very content, in the folder files land in now; never a path or ID from
            // the sender. Its bytes are read again and checked against the record before anything is offered.
            if let Some(r) = self.host.resume_claim(&device_id, size, &crypto::b64(&sha256), &name, &dir) {
                let part = r.part_path();
                let prefix: Option<[u8; 32]> = crypto::unb64(&r.prefix).and_then(|b| b.try_into().ok());
                let opened = transfer::open_partial(&part).and_then(|file| Ok((file.try_clone()?, file)));
                match (opened, prefix) {
                    (Ok((reader, file)), Some(prefix)) => {
                        let transfer = self.host.next_id();
                        let i = new(part.clone(), file, transfer, Phase::Checking { length: r.length, prefix }, r.length);
                        self.incoming.insert(transfer_id.to_string(), i);
                        self.host.event(Event::FileIncoming { transfer, device_id, name: name.clone(), size, mime });
                        self.check_partial(transfer_id.to_string(), reader, r.length);
                        return Step::Continue;
                    }
                    _ => {
                        let _ = std::fs::remove_file(&part);
                        self.host.resume_release(&part, false);
                    }
                }
            }
        }
        // Room for this file and the ones already arriving, plus a margin (0.10 M6, as on the Mac); a resumed file needs
        // only what is left of it.
        let arriving: u64 = self.incoming.values().map(|i| i.size.saturating_sub(i.received)).sum();
        if transfer::free_space(&dir).is_some_and(|free| free < size.saturating_add(arriving).saturating_add(transfer::FREE_SPACE_MARGIN)) {
            self.host.event(Event::FileFailed { transfer: 0, device_id, incoming: true, name, reason: "storage".into() });
            return self.outer("files.cancel", &outer_id, None).await;
        }
        let part = transfer::part_path(&dir, transfer_id);
        let file = match std::fs::create_dir_all(&dir).and_then(|_| std::fs::OpenOptions::new().read(true).write(true).create_new(true).open(&part)) {
            Ok(f) => f,
            Err(_) => {
                self.host.event(Event::FileFailed { transfer: 0, device_id, incoming: true, name, reason: "storage".into() });
                return self.outer("files.cancel", &outer_id, None).await;
            }
        };
        let transfer = self.host.next_id();
        let i = new(part, file, transfer, Phase::Receiving, 0);
        if resumable {
            // A record from the start, so a crash before the first checkpoint leaves no partial behind: the next start
            // sweeps records with nothing verified, and their files.
            if let Some(r) = record_of(&device_id, &i, i.hasher.checkpoint(size)) {
                self.host.resume_save(r);
            }
        }
        self.incoming.insert(transfer_id.to_string(), i);
        self.host.event(Event::FileIncoming { transfer, device_id, name, size, mime });
        self.outer("files.accept", &outer_id, None).await
    }

    /// Re-reads a kept partial's verified bytes off the session's task (up to 10 GiB); the result comes back as
    /// `Command::Checked`. Meanwhile `Command::Checking` every 30 seconds sends `files.resume.wait`, so a sender
    /// whose 120-second wait would run out first keeps waiting instead of cancelling, which would cost the partial.
    fn check_partial(&self, id: String, mut part: std::fs::File, length: u64) {
        let tx = self.handle.tx.clone();
        let (_, every, held) = self.host.resume_timing();
        tokio::spawn(async move {
            let mut read = tokio::task::spawn_blocking(move || {
                if !held.is_zero() {
                    std::thread::sleep(held);
                }
                resume::hash_prefix_of(&mut part, length).ok()
            });
            let mut tick = tokio::time::interval_at(tokio::time::Instant::now() + every, every);
            let prefix = loop {
                tokio::select! {
                    done = &mut read => break done.ok().flatten(),
                    _ = tick.tick() => {
                        if tx.send(Command::Checking(id.clone())).await.is_err() {
                            return;
                        }
                    }
                }
            };
            let _ = tx.send(Command::Checked(Box::new(Checked { id, prefix }))).await;
        });
    }

    /// A kept partial was read again. Its bytes match its record: propose resuming after them (`files.resume`). They do
    /// not (changed, damaged or unreadable): the file comes from byte zero, as without the key (`files.accept`).
    async fn checked(&mut self, c: Checked) -> Step {
        let peer = self.st.remote_id.clone();
        let Some(i) = self.incoming.get_mut(&c.id) else { return Step::Continue };
        let Phase::Checking { length, prefix } = i.phase else { return Step::Continue };
        let good = c.prefix.filter(|(_, d)| crypto::ct_eq(d, &prefix));
        let proposed = match good {
            Some((ctx, digest)) if i.file.set_len(length).is_ok() && i.file.seek(SeekFrom::End(0)).is_ok() => {
                i.hasher = Running::resumed(ctx, length, digest);
                i.received = length;
                i.checkpoint = length;
                i.phase = Phase::Proposed(length);
                i.reported = Some(Instant::now());
                self.host.event(Event::FileProgress { transfer: i.transfer, device_id: peer, incoming: true, bytes: length, total: i.size });
                Some(resume::resume_payload(&c.id, length, &digest))
            }
            _ => None,
        };
        if let Some(plain) = proposed {
            return self.encrypted_for("files.resume", &plain, crypto::uuid4(), Some(&c.id)).await;
        }
        if !self.restart_incoming(&c.id) {
            return self.outer("files.cancel", &c.id, None).await;
        }
        self.outer("files.accept", &c.id, None).await
    }

    /// The partial of an incoming file starts again from byte zero; its record now says nothing is verified. False
    /// when the file could not be cut back (it has gone, failed with `storage`).
    fn restart_incoming(&mut self, id: &str) -> bool {
        let peer = self.st.remote_id.clone();
        let Some(i) = self.incoming.get_mut(id) else { return false };
        if i.file.set_len(0).is_ok() && i.file.seek(SeekFrom::Start(0)).is_ok() {
            i.hasher = Running::new(false);
            i.received = 0;
            i.checkpoint = 0;
            i.phase = Phase::Receiving;
            if let Some(r) = record_of(&peer, i, i.hasher.checkpoint(i.size)) {
                self.host.resume_save(r);
            }
            return true;
        }
        let i = self.incoming.remove(id).unwrap();
        self.drop_incoming(id, i, "storage");
        false
    }

    /// `files.resume` for the file this end offered: continue after the receiver's bytes when their SHA-256 is this
    /// file's own over the same length, else from byte zero. Either way `files.resume.ack` says which.
    async fn file_resume(&mut self, m: Message) -> Step {
        let Some(id) = m.transfer_id.clone() else { return Step::Continue };
        let Some(plain) = self.open(&m) else { return Step::Close("bad_files".into()) };
        let device_id = self.st.remote_id.clone();
        let Some(a) = self.active.as_mut().filter(|a| a.id == id && a.stage == Stage::Offered) else { return Step::Continue };
        if !a.resumable {
            // Never offered resumable: the receiver broke the rules, so the file ends here.
            let a = self.active.take().unwrap();
            self.ended(&a.id);
            self.file_failed(a.file.transfer, false, &a.file.name, "invalid");
            if let Step::Close(r) = self.outer("files.cancel", &id, None).await {
                return Step::Close(r);
            }
            return self.start_next().await;
        }
        let sha256 = crypto::unb64(&a.file.sha256).unwrap_or_default();
        let (mut offset, mut reason) = resume::sender_answer(&plain, &id, a.file.size, &sha256, &a.file.blocks);
        if offset > 0 && a.reader.seek(SeekFrom::Start(offset)).is_err() {
            (offset, reason) = (0, Some("unreadable"));
            let _ = a.reader.seek(SeekFrom::Start(0));
        }
        a.stage = Stage::Sending;
        a.sent = offset;
        a.deadline = Some(Instant::now() + ACK_STALL);
        a.reported = Some(Instant::now());
        self.host.event(Event::FileProgress { transfer: a.file.transfer, device_id, incoming: false, bytes: offset, total: a.file.size });
        let plain = resume::ack_payload(&id, offset, reason);
        self.encrypted_for("files.resume.ack", &plain, crypto::uuid4(), Some(&id)).await
    }

    /// `files.resume.ack` for a file this end proposed to resume: chunks follow from the offset proposed, or from byte
    /// zero. Anything else cancels the file.
    async fn file_resume_ack(&mut self, m: Message) -> Step {
        let Some(id) = m.transfer_id.clone() else { return Step::Continue };
        let Some(plain) = self.open(&m) else { return Step::Close("bad_files".into()) };
        let Some(i) = self.incoming.get_mut(&id) else { return Step::Continue };
        let answer = match i.phase {
            Phase::Proposed(proposed) => resume::parse_ack(&plain, &id, proposed).map(|n| (n, proposed)),
            _ => None,
        };
        match answer {
            Some((n, proposed)) if n == proposed => {
                i.phase = Phase::Receiving;
                Step::Continue
            }
            Some(_) => {
                if !self.restart_incoming(&id) {
                    return self.outer("files.cancel", &id, None).await;
                }
                Step::Continue
            }
            None => {
                let i = self.incoming.remove(&id).unwrap();
                self.drop_incoming(&id, i, "invalid");
                self.outer("files.cancel", &id, None).await
            }
        }
    }

    async fn file_chunk(&mut self, m: Message) -> Step {
        let Some(id) = m.transfer_id.clone() else { return Step::Continue };
        if !self.incoming.contains_key(&id) {
            // A chunk for a transfer that ended here (cancelled, failed) is dropped quietly; any other is not ours.
            return if self.ended.contains(&id) { Step::Continue } else { self.bad() };
        }
        let Some(data) = self.open(&m) else { return Step::Close("bad_files".into()) };
        self.accept_chunk(id, m.sequence, &data, MAX_CHUNK_IN).await
    }

    /// A binary frame from an authenticated session (files_fast_draft1). A frame that fails its tag, is malformed or
    /// replays counts as a bad frame; an unknown kind whose tag verifies is skipped, and so are speed test bytes (this
    /// client never starts or accepts a test).
    async fn binary(&mut self, kind: u8, body: &[u8]) -> Step {
        let Some(key) = self.st.fast_key else { return self.bad() };
        let frame = match fast::open_body(kind, body, &key, &self.st.remote_id) {
            Ok(f) => f,
            Err(_) => return self.bad(),
        };
        if frame.kind != fast::KIND_CHUNK {
            return Step::Continue;
        }
        if !self.st.fast_replay.accept(frame.kind, &frame.id, frame.sequence) {
            return self.bad();
        }
        if !self.incoming.contains_key(&frame.id) {
            return if self.ended.contains(&frame.id) { Step::Continue } else { self.bad() };
        }
        let sequence = i64::try_from(frame.sequence).ok();
        self.accept_chunk(frame.id, sequence, &frame.plaintext, fast::MAX_PLAINTEXT).await
    }

    /// One chunk of an incoming file, JSON or binary: in order, within the offered size, written and hashed, then
    /// acknowledged. Anything else cancels the file.
    async fn accept_chunk(&mut self, id: String, sequence: Option<i64>, data: &[u8], max: usize) -> Step {
        let device_id = self.st.remote_id.clone();
        let Some(i) = self.incoming.get_mut(&id) else { return Step::Continue };
        let fits = i.phase == Phase::Receiving && sequence == Some(i.next_sequence) && !data.is_empty() && data.len() <= max && i.received + data.len() as u64 <= i.size;
        if !fits || i.file.write_all(data).is_err() {
            let reason = if fits { "storage" } else { "invalid" };
            let i = self.incoming.remove(&id).unwrap();
            self.drop_incoming(&id, i, reason);
            return self.outer("files.cancel", &id, None).await;
        }
        i.hasher.update(data);
        i.received += data.len() as u64;
        i.next_sequence += 1;
        // A resumable file's record follows it every 64 MiB, after its bytes are on stable storage, so a crash loses at
        // most that much (files_resume_draft1).
        if i.resumable && i.received - i.checkpoint >= resume::CHECKPOINT_EVERY && i.file.sync_data().is_ok() {
            i.checkpoint = i.received;
            if let Some(r) = record_of(&device_id, i, i.hasher.checkpoint(i.size)) {
                self.host.resume_save(r);
            }
        }
        let now = Instant::now();
        if i.reported.is_none_or(|t| now.duration_since(t) >= PROGRESS_EVERY) {
            i.reported = Some(now);
            self.host.event(Event::FileProgress { transfer: i.transfer, device_id, incoming: true, bytes: i.received, total: i.size });
        }
        // Every chunk is acknowledged, as Android does; a Mac keeps at most 64 unacknowledged, and a fast sender paces
        // itself by the acknowledgements' round trip.
        self.outer("files.chunk.ack", &id, sequence).await
    }

    async fn file_complete(&mut self, m: Message) -> Step {
        let Some(plain) = self.open(&m) else { return Step::Close("bad_files".into()) };
        let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(&plain) else { return Step::Continue };
        // Android repeats the transfer ID only inside.
        let Some(id) = o.get("transferId").and_then(Value::as_str).map(str::to_string) else { return Step::Continue };
        let hash = o.get("sha256").and_then(Value::as_str).and_then(crypto::unb64);
        let Some(i) = self.incoming.remove(&id) else { return Step::Continue };
        let device_id = self.st.remote_id.clone();
        let Incoming { transfer, name, size, sha256, received, dir, part, mut file, hasher, resumable, phase, .. } = i;
        let digest = hasher.finish();
        let verified = phase == Phase::Receiving && received == size && crypto::ct_eq(digest.as_ref(), &sha256) && hash.as_deref().is_some_and(|h| crypto::ct_eq(h, &sha256));
        let flushed = file.flush().and_then(|_| file.sync_all()).is_ok();
        drop(file);
        self.ended(&id);
        if resumable {
            // Saved or failed, this partial is never resumed again.
            self.host.resume_release(&part, false);
        }
        if !verified || !flushed {
            let _ = std::fs::remove_file(&part);
            self.file_failed(transfer, true, &name, if verified { "storage" } else { "verification_failed" });
            return self.outer("files.cancel", &id, None).await;
        }
        transfer::mark_from_elsewhere(&part);
        match transfer::place(&part, &dir, &name) {
            Ok(path) => {
                let saved = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(name);
                self.host.event(Event::FileDone { transfer, device_id, incoming: true, name: saved, path: Some(path.to_string_lossy().into_owned()), size });
                self.outer("files.complete.ack", &id, None).await
            }
            Err(_) => {
                let _ = std::fs::remove_file(&part);
                self.file_failed(transfer, true, &name, "storage");
                self.outer("files.cancel", &id, None).await
            }
        }
    }

    /// The session ended: partial files are deleted and every transfer still running or waiting fails.
    fn end_transfers(&mut self, reason: &str) {
        let why = if reason == "stopped" { "stopped" } else { "interrupted" };
        for (id, i) in std::mem::take(&mut self.incoming) {
            // A device that was forgotten takes its partials with it.
            if i.resumable && reason != "forgotten" {
                self.keep_incoming(&id, i, why);
            } else {
                self.drop_incoming(&id, i, why);
            }
        }
        if let Some(a) = self.active.take() {
            self.file_failed(a.file.transfer, false, &a.file.name, why);
        }
        for f in std::mem::take(&mut self.queue) {
            self.file_failed(f.transfer, false, &f.name, why);
        }
    }

    // MARK: links (`quick.request` with feature `links`)

    async fn quick_request(&mut self, m: Message) -> Step {
        let Some(plain) = self.open(&m).filter(|p| p.len() <= QUICK_MAX) else { return Step::Continue };
        let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(&plain) else { return Step::Continue };
        let (Some(1), Some(request_id), Some(feature), Some(action), Some(value), Some(sequence)) = (
            o.get("version").and_then(Value::as_i64),
            o.get("requestId").and_then(Value::as_str).filter(|r| crypto::is_uuid(r)),
            o.get("feature").and_then(Value::as_str),
            o.get("action").and_then(Value::as_str),
            o.get("value").and_then(Value::as_str),
            o.get("sequence").and_then(Value::as_i64).filter(|s| (1..=9_007_199_254_740_991).contains(s)),
        ) else {
            return Step::Continue;
        };
        // Each feature's sequence only rises within a session, so an old request never runs again.
        let seen = self.quick_seen.entry(feature.chars().take(32).collect()).or_insert(0);
        if sequence <= *seen {
            return Step::Continue;
        }
        *seen = sequence;
        let device_id = self.st.remote_id.clone();
        // The phone's media controls, and links it asks to open at once while this end shows links_open_draft1: the
        // client decides (and answers once the host has acted).
        let policy = self.host.policy(&device_id);
        let delegated = (feature == "media" && policy.get("media")) || (feature == "links" && action == "open" && policy.get("links") && policy.get(crate::quick::LINKS_OPEN) && transfer::valid_link(value));
        if delegated {
            let request = crate::quick::Request { request_id: request_id.to_ascii_lowercase(), feature: feature.to_string(), action: action.to_string(), value: value.to_string(), sequence: sequence as u64 };
            self.host.event(Event::Quick { device_id, request });
            return Step::Continue;
        }
        let (accepted, reason) = if feature != "links" || !matches!(action, "offer" | "open") {
            (false, None)
        } else if !self.host.policy(&device_id).get("links") {
            (false, Some("links_disabled"))
        } else if !transfer::valid_link(value) {
            (false, None)
        } else {
            self.host.event(Event::Link { device_id, url: value.to_string() });
            (true, None)
        };
        let mut result = json!({"version": 1, "requestId": request_id, "feature": feature.chars().take(32).collect::<String>(), "accepted": accepted, "opened": false});
        if let Some(r) = reason {
            result["reason"] = Value::from(r);
        }
        self.encrypted("quick.result", result.to_string().as_bytes(), crypto::uuid4()).await
    }
}

/// Reads until `buf` is full or the file ends.
fn read_full(file: &mut std::fs::File, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match file.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// Test builds only: each session's pairing material, so recorded sessions can be checked by other implementations.
#[cfg(test)]
pub(crate) type KeyLogEntry = (String, [u8; 32], [u8; 32]);
#[cfg(test)]
pub(crate) static KEYLOG: std::sync::Mutex<Vec<KeyLogEntry>> = std::sync::Mutex::new(Vec::new());

/// `bridgey-auth-v2`: the v1 fields and the tunnel's base64 TLS exporter (rust/cli/src/session.rs, the apps' tunnels).
pub fn transcript_v2(session: &str, init_id: &str, resp_id: &str, init_eph: &str, resp_eph: &str, exporter: &str) -> Vec<u8> {
    ["bridgey-auth-v2", session, init_id, resp_id, init_eph, resp_eph, exporter].join("\0").into_bytes()
}

/// `bridgey-auth-v1` \0 sessionId \0 initiator \0 responder \0 initiator key \0 responder key (PairingCoordinator.kt).
pub fn transcript_v1(session: &str, init_id: &str, resp_id: &str, init_eph: &str, resp_eph: &str) -> Vec<u8> {
    ["bridgey-auth-v1", session, init_id, resp_id, init_eph, resp_eph].join("\0").into_bytes()
}

fn version_one(plain: &[u8]) -> bool {
    matches!(serde_json::from_slice::<Value>(plain), Ok(Value::Object(o)) if o.get("version").and_then(Value::as_i64) == Some(1))
}

/// `clipboard.update`: raw UTF-8 text, 1 to 32,768 bytes.
pub fn clipboard_text(plain: &[u8]) -> Option<(String, Option<String>)> {
    if plain.is_empty() || plain.len() > CLIPBOARD_MAX {
        return None;
    }
    String::from_utf8(plain.to_vec()).ok().map(|t| (t, None))
}

/// `clipboard.rich`: `{"version":1,"text":...,"html":...}`, text required, text and HTML together at most 32 KiB.
pub fn clipboard_rich(plain: &[u8]) -> Option<(String, Option<String>)> {
    if plain.len() > CLIPBOARD_MAX + 4096 {
        return None;
    }
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return None };
    if o.get("version").and_then(Value::as_i64) != Some(1) {
        return None;
    }
    let text = o.get("text")?.as_str()?.to_string();
    let html = match o.get("html") {
        None | Some(Value::Null) => None,
        Some(Value::String(h)) => Some(h.clone()),
        Some(_) => return None,
    };
    if text.is_empty() || text.len() + html.as_ref().map_or(0, String::len) > CLIPBOARD_MAX {
        return None;
    }
    Some((text, html))
}

/// What the reader task hands the session loop.
/// `battery.update`: `level` an integer 0 to 100 and `isCharging` a boolean, or nothing.
pub fn battery(plain: &[u8]) -> Option<(u8, bool)> {
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return None };
    let level = o.get("level")?.as_u64().filter(|l| *l <= 100)?;
    let charging = o.get("isCharging")?.as_bool()?;
    Some((level as u8, charging))
}

pub fn battery_payload(level: u8, charging: bool) -> String {
    json!({"level": level.min(100), "isCharging": charging}).to_string()
}

fn alert_id(plain: &[u8]) -> Option<String> {
    let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return None };
    o.get("alertId")?.as_str().filter(|a| !a.is_empty() && a.len() <= 128).map(str::to_string)
}

pub fn find_payload() -> String {
    json!({"alertId": FIND_ALERT}).to_string()
}

/// Control, format (bidi, zero-width, tags), separator and private-use characters cannot be shown safely.
pub fn invisible(c: char) -> bool {
    c.is_control()
        || matches!(c,
            '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{200B}'..='\u{200F}' | '\u{2028}'..='\u{202E}' | '\u{2060}'..='\u{206F}'
            | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}' | '\u{E000}'..='\u{F8FF}' | '\u{E0000}'..='\u{E007F}' | '\u{F0000}'..='\u{10FFFF}')
}

/// A peer's name as the apps show it: visible characters, trimmed, at most 64, never empty.
pub fn sanitized_name(name: Option<&str>) -> String {
    let cleaned: String = name.unwrap_or("").chars().filter(|c| !invisible(*c)).collect();
    let t: String = cleaned.trim().chars().take(64).collect();
    if t.is_empty() {
        "Bridgey device".into()
    } else {
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipboard_limits() {
        assert!(clipboard_text(b"").is_none());
        assert_eq!(clipboard_text("héllo".as_bytes()).unwrap().0, "héllo");
        assert!(clipboard_text(&vec![b'a'; CLIPBOARD_MAX]).is_some());
        assert!(clipboard_text(&vec![b'a'; CLIPBOARD_MAX + 1]).is_none());
        assert!(clipboard_text(b"\xff\xfe").is_none());
        let (t, h) = clipboard_rich(br#"{"version":1,"text":"a","html":"<b>a</b>"}"#).unwrap();
        assert_eq!((t.as_str(), h.as_deref()), ("a", Some("<b>a</b>")));
        assert!(clipboard_rich(br#"{"version":1,"text":""}"#).is_none());
        assert!(clipboard_rich(br#"{"version":2,"text":"a"}"#).is_none());
        assert!(clipboard_rich(br#"{"version":1,"text":"a","html":3}"#).is_none());
    }

    #[test]
    fn names_are_cleaned() {
        assert_eq!(sanitized_name(Some("  Pixel\u{202E} 9 ")), "Pixel 9");
        assert_eq!(sanitized_name(Some("\u{200B}")), "Bridgey device");
        assert_eq!(sanitized_name(Some(&"x".repeat(100))).chars().count(), 64);
    }

    /// Every kind this client sends or handles (session.rs and client.rs) is listed for `client` in
    /// protocol/messages.json, and nothing else.
    #[test]
    fn contract_lists_the_kinds_this_client_uses() {
        let session = include_str!("session.rs");
        let client = include_str!("client.rs");
        // The phone's own features (phone.rs), each in its own module.
        let areas = [include_str!("sms.rs"), include_str!("calls.rs")];
        let mut code = format!("{}{}", &session[..session.find("#[cfg(test)]\nmod tests").unwrap()], client.split("#[cfg(test)]\nmod tests").next().unwrap());
        for area in areas {
            code.push_str(area.split("#[cfg(test)]\nmod tests").next().unwrap());
        }
        let is_kind = |s: &str| {
            let mut parts = s.split('.');
            let first = parts.next().unwrap_or("");
            let rest: Vec<&str> = parts.collect();
            !first.is_empty()
                && first.starts_with(|c: char| c.is_ascii_lowercase())
                && first.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
                && !rest.is_empty()
                && rest.iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'))
        };
        let used: std::collections::BTreeSet<String> = code.split('"').skip(1).step_by(2).filter(|s| is_kind(s)).map(str::to_string).collect();
        let contract: Value = serde_json::from_str(include_str!("../../../protocol/messages.json")).unwrap();
        let listed: std::collections::BTreeSet<String> = contract["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| m["implemented"].as_array().unwrap().iter().any(|p| p == "client"))
            .map(|m| m["kind"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(used, listed);
    }

    #[test]
    fn v1_transcript() {
        assert_eq!(transcript_v1("s", "i", "r", "I", "R"), b"bridgey-auth-v1\0s\0i\0r\0I\0R".to_vec());
    }
}
