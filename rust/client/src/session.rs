//! One session with a Bridgey device over plain TCP, the way the apps run it on the local network or a
//! tailnet (PairingCoordinator.kt, Pairing.swift, docs/protocol.md "Pairing flow"): newline JSON frames of
//! at most 65,536 bytes, protocol 2 only, so a first pairing commits and reveals, both people compare a
//! six-digit code, and every frame after pairing carries its envelope tag and passes the replay window.
//!
//! The same state machine as the agent CLI's tunnel sessions (rust/cli/src/session.rs), with the local
//! network's `bridgey-auth-v1` transcript, the apps' 10 s heartbeat and the host deciding who may pair.

use crate::crypto::{self, Ephemeral, SigningKey};
use crate::features::{self, FeatureMap};
use crate::wire::{Message, MAX_FRAME};
use serde_json::Value;
use std::collections::{HashSet, VecDeque};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;
use tokio::sync::mpsc;

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
}

pub enum Command {
    Confirm(bool),
    Clipboard { text: String, message_id: String },
    Features,
    Ping { message_id: String },
    Close(&'static str),
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

/// Starts a session on a connected socket. Returns its handle at once; events go to the host.
pub fn spawn(session: u64, stream: TcpStream, role: Role, host: Arc<dyn Host>) -> Handle {
    let (tx, rx) = mpsc::channel(COMMANDS);
    let handle = Handle { session, tx, heard: Arc::new(AtomicU64::new(clock_ms())) };
    let own = handle.clone();
    tokio::spawn(async move {
        let peer = stream.peer_addr().unwrap_or_else(|_| SocketAddr::from(([0, 0, 0, 0], 0)));
        let mut s = Session::new(session, stream, role, host.clone(), own, peer);
        let reason = s.run(rx).await;
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
    write: OwnedWriteHalf,
    st: State,
}

impl Session {
    fn new(session: u64, stream: TcpStream, role: Role, host: Arc<dyn Host>, handle: Handle, peer: SocketAddr) -> Session {
        let _ = stream.set_nodelay(true);
        let (read, write) = stream.into_split();
        let dials = role != Role::Accept;
        Session {
            session,
            role,
            host,
            handle,
            peer,
            reader: Some(BufReader::with_capacity(MAX_FRAME + 2, read)),
            write,
            st: State {
                id: if dials { crypto::uuid4() } else { String::new() },
                eph: Ephemeral::generate(),
                remote_eph: String::new(),
                remote_id: String::new(),
                remote_name: String::new(),
                remote_commitment: None,
                key: None,
                envelope: None,
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
        let mut reader = self.reader.take().expect("reader");
        let handshake = tokio::time::sleep(HANDSHAKE_TIMEOUT);
        tokio::pin!(handshake);
        let mut code_deadline: Option<tokio::time::Instant> = None;
        let mut heartbeat = tokio::time::interval(HEARTBEAT);
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        heartbeat.tick().await;
        let mut last_heard = tokio::time::Instant::now();
        let mut line = Vec::with_capacity(4096);
        loop {
            let code_wait = async {
                match code_deadline {
                    Some(d) => tokio::time::sleep_until(d).await,
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                read = read_line(&mut reader, &mut line) => {
                    match read {
                        Ok(true) => {}
                        Ok(false) => return if self.st.authenticated { "closed_by_peer".into() } else { "closed_before_pairing".into() },
                        Err(reason) => return reason.into(),
                    }
                    last_heard = tokio::time::Instant::now();
                    self.handle.heard.store(clock_ms(), Ordering::Relaxed);
                    // A malformed frame closes the session before dispatch (protocol/messages.json transport).
                    let message = match Message::decode(&line) {
                        Ok(m) => m,
                        Err(_) => return "bad_frame".into(),
                    };
                    match self.receive(message).await {
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
        }
    }

    async fn encrypted(&mut self, kind: &str, plaintext: &[u8], message_id: String) -> Step {
        let Some(key) = self.st.key else { return Step::Continue };
        let (nonce, ciphertext) = crypto::encrypt(&key, plaintext);
        let mut m = Message::new(kind, &self.st.id);
        m.message_id = Some(message_id);
        m.nonce = Some(nonce);
        m.ciphertext = Some(ciphertext);
        match self.send(m).await {
            Ok(()) => Step::Continue,
            Err(_) => Step::Close("send_failed".into()),
        }
    }

    async fn send_features(&mut self) -> Step {
        let policy = self.host.policy(&self.st.remote_id);
        self.encrypted("features.update", &policy.encode(), crypto::uuid4()).await
    }

    /// Writes one frame, tagged once there is an envelope key (pairing frames other than pairing.cancel never are).
    async fn send(&mut self, mut m: Message) -> std::io::Result<()> {
        if let Some(key) = self.st.envelope {
            if !m.kind.starts_with("pairing.") || m.kind == "pairing.cancel" {
                m.tag = Some(m.compute_tag(&key, &self.host.local().device_id));
            }
        }
        let mut text = m.encode();
        text.push('\n');
        self.write.write_all(text.as_bytes()).await
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
        transcript_v1(&self.st.id, init_id, resp_id, init_eph, resp_eph)
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

    async fn answer_offer(&mut self) -> std::io::Result<()> {
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
        if matches!(m.kind.as_str(), "heartbeat.pong" | "ping.ack" | "clipboard.ack" | "clipboard.rejected") {
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
            // Unknown kinds and features this client does not offer: ignored, the session stays.
            _ => Step::Continue,
        }
    }
}

/// Test builds only: each session's pairing material, so recorded sessions can be checked by other implementations.
#[cfg(test)]
pub(crate) static KEYLOG: std::sync::Mutex<Vec<(String, [u8; 32], [u8; 32])>> = std::sync::Mutex::new(Vec::new());

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

/// Reads one line of at most 65,536 bytes into `line` (without the LF). Ok(false) at the end of the stream.
async fn read_line(reader: &mut BufReader<OwnedReadHalf>, line: &mut Vec<u8>) -> Result<bool, &'static str> {
    line.clear();
    loop {
        let buf = reader.fill_buf().await.map_err(|_| "read_failed")?;
        if buf.is_empty() {
            return if line.is_empty() { Ok(false) } else { Err("truncated") };
        }
        if line.is_empty() && buf[0] == 0xB1 {
            // A binary frame: this client never advertises files_fast_draft1, so the peer must not send one.
            return Err("binary_frame");
        }
        match buf.iter().position(|b| *b == b'\n') {
            Some(i) => {
                line.extend_from_slice(&buf[..i]);
                reader.consume(i + 1);
                if line.len() > MAX_FRAME {
                    return Err("frame_too_large");
                }
                return Ok(true);
            }
            None => {
                let n = buf.len();
                line.extend_from_slice(buf);
                reader.consume(n);
                if line.len() > MAX_FRAME {
                    return Err("frame_too_large");
                }
            }
        }
    }
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

    /// Every kind this client sends or handles is listed for `client` in protocol/messages.json, and nothing else.
    #[test]
    fn contract_lists_the_kinds_this_client_uses() {
        let source = include_str!("session.rs");
        let code = &source[..source.find("#[cfg(test)]").unwrap()];
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
