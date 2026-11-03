//! One Bridgey session on a Connect anywhere tunnel (the core's loopback bridge), the way the apps run it
//! (PairingCoordinator.kt, SessionSecurity.kt): protocol 2 only, so every frame after pairing carries its
//! envelope tag and passes the replay window.
//!
//! - **Reconnect** to a paired device: the QUIC client offers its key (no commitment), the other side answers,
//!   both confirm without a prompt, signatures bind the tunnel's exporter and the pinned identity key.
//! - **Invite** (remote pairing, docs/protocol.md "agent devices"): this end is the responder of exactly one
//!   committed first pairing from a device it does not trust. The code is shown to the person at the terminal,
//!   who must confirm it; the transcript also binds the invite secret.

use crate::crypto::{self, Ephemeral, SigningKey};
use crate::wire::{Message, MAX_FRAME};
use std::collections::{HashSet, VecDeque};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};

const HEARTBEAT: Duration = Duration::from_secs(25);
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(75);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
const CODE_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_BAD_FRAMES: u32 = 16;
const REPLAY_WINDOW: usize = 256;

#[derive(Clone, Debug)]
pub enum Mode {
    /// A paired device; `expected` is the device the core reached (the tunnel's peer).
    Reconnect { expected: Option<String> },
    /// One first pairing from an invite; the value is base64(SHA-256(invite secret)).
    Invite { invite_hash: String },
    /// The joining end of an invite (test hook `bridgey pair --join`): this end commits, reveals and is the
    /// initiator, as the phone is.
    Join { invite_hash: String },
}

pub struct Local {
    pub device_id: String,
    pub device_name: std::sync::RwLock<String>,
    pub identity: Arc<SigningKey>,
    pub identity_public: String,
}

impl Local {
    pub fn name(&self) -> String {
        self.device_name.read().unwrap().clone()
    }
}

/// A trusted device's pinned identity key, looked up when its confirm arrives.
pub type PinLookup = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

#[derive(Clone, Debug)]
pub struct AuthPeer {
    pub device_id: String,
    pub name: String,
    pub identity_key: String,
}

pub enum Outgoing {
    /// An encrypted payload: kind, the plaintext, the messageId, and an optional outer transferId / sequence.
    Encrypted { kind: String, plaintext: Vec<u8>, message_id: String, transfer_id: Option<String>, sequence: Option<i64> },
    /// A files.chunk: outer transferId and sequence, an encrypted chunk, no messageId (it stays out of the window).
    Chunk { transfer_id: String, sequence: i64, plaintext: Vec<u8> },
    /// An outer-only message (acks, files.accept, ...); sessionId is filled in.
    Plain(Box<Message>),
    Close(&'static str),
}

#[derive(Clone)]
pub struct Handle {
    pub local_id: u64,
    tx: mpsc::UnboundedSender<Outgoing>,
}

impl Handle {
    pub fn send_encrypted(&self, kind: &str, plaintext: Vec<u8>, transfer_id: Option<String>) -> String {
        let message_id = crypto::uuid4();
        let _ = self.tx.send(Outgoing::Encrypted { kind: kind.into(), plaintext, message_id: message_id.clone(), transfer_id, sequence: None });
        message_id
    }

    /// Sends with a messageId chosen by the caller (it registered its reply keys first).
    pub fn send_json_id(&self, kind: &str, payload: &serde_json::Value, message_id: &str, transfer_id: Option<String>) -> bool {
        self.tx.send(Outgoing::Encrypted { kind: kind.into(), plaintext: payload.to_string().into_bytes(), message_id: message_id.into(), transfer_id, sequence: None }).is_ok()
    }

    pub fn send_raw_id(&self, kind: &str, plaintext: Vec<u8>, message_id: &str) -> bool {
        self.tx.send(Outgoing::Encrypted { kind: kind.into(), plaintext, message_id: message_id.into(), transfer_id: None, sequence: None }).is_ok()
    }

    pub fn send_json(&self, kind: &str, payload: &serde_json::Value) -> String {
        self.send_encrypted(kind, payload.to_string().into_bytes(), None)
    }


    pub fn send_chunk(&self, transfer_id: &str, sequence: i64, plaintext: Vec<u8>) -> bool {
        self.tx.send(Outgoing::Chunk { transfer_id: transfer_id.into(), sequence, plaintext }).is_ok()
    }


    pub fn close(&self, why: &'static str) {
        let _ = self.tx.send(Outgoing::Close(why));
    }

    pub fn is_open(&self) -> bool {
        !self.tx.is_closed()
    }
}

pub enum Event {
    /// Invite pairing: compare this code; answer through `confirm` (true to confirm).
    Code { local_id: u64, code: String, peer_name: String, confirm: oneshot::Sender<bool> },
    Authenticated { local_id: u64, peer: AuthPeer, handle: Handle, invite: bool, tunnel: String },
    /// A frame that passed the tag and replay checks; `plaintext` when it had an encrypted payload that opened.
    Frame { local_id: u64, peer_id: String, message: Box<Message>, plaintext: Option<Vec<u8>> },
    Closed { local_id: u64, peer_id: Option<String>, reason: String, authenticated: bool },
}

struct State {
    id: String,
    initiated: bool,
    eph: Ephemeral,
    remote_eph: String,
    remote_id: String,
    remote_name: String,
    remote_protocol: i64,
    remote_commitment: Option<String>,
    prk: Option<[u8; 32]>,
    key: Option<[u8; 32]>,
    envelope: Option<[u8; 32]>,
    local_confirmed: bool,
    remote_confirmed: bool,
    remote_identity: Option<String>,
    authenticated: bool,
    answered: bool,
    offers_seen: u32,
    bad_frames: u32,
    seen: HashSet<String>,
    order: VecDeque<String>,
}

pub struct Spec {
    pub local_id: u64,
    pub port: u16,
    pub token: String,
    pub exporter: String,
    pub tunnel: String,
    pub quic_client: bool,
    pub mode: Mode,
}

pub fn spawn(spec: Spec, local: Arc<Local>, pins: PinLookup, events: mpsc::UnboundedSender<Event>) {
    tokio::spawn(async move {
        let local_id = spec.local_id;
        let (reason, peer, authenticated) = match run(spec, local, pins, events.clone()).await {
            Ok((reason, peer, auth)) => (reason, peer, auth),
            Err((reason, peer, auth)) => (reason, peer, auth),
        };
        let _ = events.send(Event::Closed { local_id, peer_id: peer, reason, authenticated });
    });
}

type Outcome = (String, Option<String>, bool);

async fn run(spec: Spec, local: Arc<Local>, pins: PinLookup, events: mpsc::UnboundedSender<Event>) -> Result<Outcome, Outcome> {
    let fail = |r: &str| -> Outcome { (r.to_string(), None, false) };
    let mut stream = TcpStream::connect(("127.0.0.1", spec.port)).await.map_err(|_| fail("bridge"))?;
    let _ = stream.set_nodelay(true);
    stream.write_all(format!("{}\n", spec.token).as_bytes()).await.map_err(|_| fail("bridge"))?;
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::with_capacity(MAX_FRAME + 2, read);
    let (tx, mut rx) = mpsc::unbounded_channel::<Outgoing>();
    let mut st = State {
        id: if spec.quic_client { crypto::uuid4() } else { String::new() },
        initiated: spec.quic_client,
        eph: Ephemeral::generate(),
        remote_eph: String::new(),
        remote_id: String::new(),
        remote_name: String::new(),
        remote_protocol: 1,
        remote_commitment: None,
        prk: None,
        key: None,
        envelope: None,
        local_confirmed: false,
        remote_confirmed: false,
        remote_identity: None,
        authenticated: false,
        answered: false,
        offers_seen: 0,
        bad_frames: 0,
        seen: HashSet::new(),
        order: VecDeque::new(),
    };
    let invite_hash = match &spec.mode {
        Mode::Invite { invite_hash } | Mode::Join { invite_hash } => Some(invite_hash.clone()),
        Mode::Reconnect { .. } => None,
    };
    if spec.quic_client && matches!(spec.mode, Mode::Join { .. }) {
        let mut offer = Message::new("pairing.offer", &st.id);
        offer.device_id = Some(local.device_id.clone());
        offer.device_name = Some(local.name());
        offer.commitment = Some(crypto::commitment(&st.id, &st.eph.public));
        offer.protocol_version = Some(crypto::PROTOCOL_VERSION);
        write_frame(&mut write, &offer).await.map_err(|_| fail("send"))?;
    } else if spec.quic_client {
        // Reconnects dial; an invite tunnel's QUIC client is the joining end.
        let Mode::Reconnect { expected: Some(expected) } = &spec.mode else { return Err(fail("no_peer_to_dial")) };
        let mut offer = Message::new("pairing.offer", &st.id);
        offer.device_id = Some(local.device_id.clone());
        offer.device_name = Some(local.name());
        offer.public_key = Some(st.eph.public.clone());
        offer.target_device_id = Some(expected.clone());
        offer.protocol_version = Some(crypto::PROTOCOL_VERSION);
        write_frame(&mut write, &offer).await.map_err(|_| fail("send"))?;
    }
    let (code_tx, mut code_rx) = mpsc::unbounded_channel::<bool>();
    let handshake_deadline = tokio::time::sleep(HANDSHAKE_TIMEOUT);
    tokio::pin!(handshake_deadline);
    let mut code_deadline: Option<tokio::time::Instant> = None;
    let mut heartbeat = tokio::time::interval(HEARTBEAT);
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
                    Ok(false) => return Err((if st.authenticated { "closed_by_peer".into() } else { "closed_before_pairing".into() }, peer_of(&st), st.authenticated)),
                    Err(reason) => return Err((reason.into(), peer_of(&st), st.authenticated)),
                }
                last_heard = tokio::time::Instant::now();
                let message = match Message::decode(&line) {
                    Ok(m) => m,
                    Err(_) => return Err(("bad_frame".into(), peer_of(&st), st.authenticated)),
                };
                let step = receive(&mut st, &spec, &local, &pins, &invite_hash, message, &mut write, &events, &tx, &code_tx).await;
                match step {
                    Step::Continue => if st.authenticated { code_deadline = None },
                    Step::AwaitCode => code_deadline = Some(tokio::time::Instant::now() + CODE_TIMEOUT),
                    Step::Close(reason) => {
                        return Err((reason, peer_of(&st), st.authenticated));
                    }
                }
            }
            Some(confirmed) = code_rx.recv() => {
                if !confirmed {
                    let mut cancel = Message::new("pairing.cancel", &st.id);
                    cancel.reason = Some("mismatch".into());
                    let _ = write_frame(&mut write, &cancel).await;
                    return Err(("code_rejected".into(), peer_of(&st), false));
                }
                if let Err(reason) = confirm(&mut st, &local, &invite_hash, &spec, &mut write).await {
                    return Err((reason, peer_of(&st), false));
                }
                if let Some(o) = complete(&mut st, &spec, &events, &tx) { return Err(o) }
                // Still waiting for the person at the phone: the same two minutes keep running.
                if st.authenticated { code_deadline = None }
            }
            _ = code_wait => {
                let mut cancel = Message::new("pairing.cancel", &st.id);
                cancel.reason = Some("timeout".into());
                let _ = write_frame(&mut write, &cancel).await;
                return Err(("code_timeout".into(), peer_of(&st), false));
            }
            _ = &mut handshake_deadline, if !st.authenticated && code_deadline.is_none() => {
                return Err(("handshake_timeout".into(), peer_of(&st), false));
            }
            out = rx.recv() => {
                let Some(out) = out else { continue };
                let m = match out {
                    Outgoing::Close(why) => return Ok((why.into(), peer_of(&st), st.authenticated)),
                    Outgoing::Plain(m) => { let mut m = *m; m.session_id = st.id.clone(); m }
                    Outgoing::Chunk { transfer_id, sequence, plaintext } => {
                        let Some(key) = st.key else { continue };
                        let (nonce, ciphertext) = crypto::encrypt(&key, &plaintext);
                        let mut m = Message::new("files.chunk", &st.id);
                        m.transfer_id = Some(transfer_id);
                        m.sequence = Some(sequence);
                        m.nonce = Some(nonce);
                        m.ciphertext = Some(ciphertext);
                        m
                    }
                    Outgoing::Encrypted { kind, plaintext, message_id, transfer_id, sequence } => {
                        let Some(key) = st.key else { continue };
                        let (nonce, ciphertext) = crypto::encrypt(&key, &plaintext);
                        let mut m = Message::new(&kind, &st.id);
                        m.message_id = Some(message_id);
                        m.nonce = Some(nonce);
                        m.ciphertext = Some(ciphertext);
                        m.transfer_id = transfer_id;
                        m.sequence = sequence;
                        m
                    }
                };
                let m = tagged(&st, &local, m);
                if write_frame(&mut write, &m).await.is_err() {
                    return Err(("send_failed".into(), peer_of(&st), st.authenticated));
                }
            }
            _ = heartbeat.tick(), if st.authenticated => {
                if last_heard.elapsed() > HEARTBEAT_TIMEOUT {
                    return Err(("heartbeat_timeout".into(), peer_of(&st), true));
                }
                let mut ping = Message::new("heartbeat.ping", &st.id);
                ping.message_id = Some(crypto::uuid4());
                let ping = tagged(&st, &local, ping);
                if write_frame(&mut write, &ping).await.is_err() {
                    return Err(("send_failed".into(), peer_of(&st), true));
                }
            }
        }
    }
}

fn peer_of(st: &State) -> Option<String> {
    Some(st.remote_id.clone()).filter(|s| !s.is_empty())
}

/// Tags every frame once there is an envelope key, except pairing frames other than pairing.cancel.
fn tagged(st: &State, local: &Local, mut m: Message) -> Message {
    if let Some(key) = st.envelope {
        if !m.kind.starts_with("pairing.") || m.kind == "pairing.cancel" {
            m.tag = Some(m.compute_tag(&key, &local.device_id));
        }
    }
    m
}

async fn write_frame(write: &mut tokio::net::tcp::OwnedWriteHalf, m: &Message) -> std::io::Result<()> {
    let mut text = m.encode();
    text.push('\n');
    write.write_all(text.as_bytes()).await
}

/// Reads one line of at most 65,536 bytes into `line` (without the LF). Ok(false) at the end of the stream.
async fn read_line(reader: &mut BufReader<tokio::net::tcp::OwnedReadHalf>, line: &mut Vec<u8>) -> Result<bool, &'static str> {
    line.clear();
    loop {
        let buf = reader.fill_buf().await.map_err(|_| "read_failed")?;
        if buf.is_empty() {
            return if line.is_empty() { Ok(false) } else { Err("truncated") };
        }
        if line.is_empty() && buf[0] == 0xB1 {
            // A binary frame: this command never advertises files_fast_draft1, so the peer must not send one.
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

enum Step {
    Continue,
    AwaitCode,
    Close(String),
}

fn transcript(st: &State, local: &Local, exporter: &str, invite_hash: &Option<String>) -> Vec<u8> {
    let (init_id, resp_id, init_eph, resp_eph) = if st.initiated {
        (local.device_id.as_str(), st.remote_id.as_str(), st.eph.public.as_str(), st.remote_eph.as_str())
    } else {
        (st.remote_id.as_str(), local.device_id.as_str(), st.remote_eph.as_str(), st.eph.public.as_str())
    };
    let mut fields = vec!["bridgey-auth-v2", &st.id, init_id, resp_id, init_eph, resp_eph, exporter];
    if let Some(h) = invite_hash {
        fields.push(h);
    }
    fields.join("\0").into_bytes()
}

async fn confirm(st: &mut State, local: &Local, invite_hash: &Option<String>, spec: &Spec, write: &mut tokio::net::tcp::OwnedWriteHalf) -> Result<(), String> {
    if st.local_confirmed {
        return Ok(());
    }
    let key = st.key.ok_or("no key")?;
    st.local_confirmed = true;
    let mut m = Message::new("pairing.confirm", &st.id);
    m.device_id = Some(local.device_id.clone());
    m.identity_key = Some(local.identity_public.clone());
    m.proof = Some(crypto::confirmation_proof(&key, &st.id, &local.device_id, &local.identity_public));
    m.signature = Some(crypto::b64(&local.identity.sign(&transcript(st, local, &spec.exporter, invite_hash))));
    write_frame(write, &m).await.map_err(|_| "send_failed".to_string())
}

fn complete(st: &mut State, spec: &Spec, events: &mpsc::UnboundedSender<Event>, tx: &mpsc::UnboundedSender<Outgoing>) -> Option<Outcome> {
    if !st.local_confirmed || !st.remote_confirmed || st.authenticated {
        return None;
    }
    st.authenticated = true;
    let handle = Handle { local_id: spec.local_id, tx: tx.clone() };
    let peer = AuthPeer { device_id: st.remote_id.clone(), name: st.remote_name.clone(), identity_key: st.remote_identity.clone().unwrap_or_default() };
    let _ = events.send(Event::Authenticated { local_id: spec.local_id, peer, handle, invite: matches!(spec.mode, Mode::Invite { .. } | Mode::Join { .. }), tunnel: spec.tunnel.clone() });
    None
}

/// Control, format (bidi, zero-width, tags), separator and private-use characters cannot be shown safely.
pub fn invisible(c: char) -> bool {
    c.is_control()
        || matches!(c,
            '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{200B}'..='\u{200F}' | '\u{2028}'..='\u{202E}' | '\u{2060}'..='\u{206F}'
            | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}' | '\u{E000}'..='\u{F8FF}' | '\u{E0000}'..='\u{E007F}' | '\u{F0000}'..='\u{10FFFF}')
}

/// Text from a peer, safe for a terminal or a log line.
pub fn printable(text: &str, max: usize) -> String {
    text.chars().filter(|c| !invisible(*c)).take(max).collect()
}

fn sanitized_name(name: Option<&str>) -> String {
    let cleaned: String = name.unwrap_or("").chars().filter(|c| !invisible(*c)).collect();
    let t: String = cleaned.trim().chars().take(64).collect();
    if t.is_empty() { "Bridgey device".into() } else { t }
}

#[allow(clippy::too_many_arguments)]
async fn receive(
    st: &mut State,
    spec: &Spec,
    local: &Local,
    pins: &PinLookup,
    invite_hash: &Option<String>,
    m: Message,
    write: &mut tokio::net::tcp::OwnedWriteHalf,
    events: &mpsc::UnboundedSender<Event>,
    tx: &mpsc::UnboundedSender<Outgoing>,
    code_tx: &mpsc::UnboundedSender<bool>,
) -> Step {
    let pairing = m.kind.starts_with("pairing.");
    // Admission (PairingRules.admitFrame): pairing frames before authentication, everything else after, tagged.
    if pairing {
        if st.authenticated && m.kind != "pairing.cancel" {
            return bad(st);
        }
        if m.kind == "pairing.cancel" && st.envelope.is_some() && m.tag.is_some() && !m.tag_matches(st.envelope.as_ref().unwrap(), &st.remote_id) {
            return bad(st);
        }
        if st.authenticated && m.kind == "pairing.cancel" && (m.session_id != st.id || !m.tag_matches(st.envelope.as_ref().unwrap(), &st.remote_id)) {
            return bad(st);
        }
    } else {
        if !st.authenticated || m.session_id != st.id {
            return bad(st);
        }
        let Some(key) = st.envelope else { return bad(st) };
        if !m.tag_matches(&key, &st.remote_id) {
            return bad(st);
        }
    }
    match m.kind.as_str() {
        "pairing.offer" => {
            if st.initiated || st.key.is_some() || st.remote_commitment.is_some() {
                return Step::Continue;
            }
            st.offers_seen += 1;
            if st.offers_seen > 1 {
                return Step::Close("second_offer".into());
            }
            if m.target_device_id.as_deref().is_some_and(|t| !t.eq_ignore_ascii_case(&local.device_id)) {
                return Step::Close("not_for_this_device".into());
            }
            let Some(remote_id) = m.device_id.clone().filter(|d| crypto::is_uuid(d)) else { return Step::Close("malformed_offer".into()) };
            if !crypto::is_uuid(&m.session_id) || remote_id.eq_ignore_ascii_case(&local.device_id) {
                return Step::Close("malformed_offer".into());
            }
            let protocol = m.protocol_version.unwrap_or(1);
            if protocol < crypto::PROTOCOL_VERSION {
                return Step::Close("needs_protocol_2".into());
            }
            let trusted = pins(&remote_id).is_some();
            match (&spec.mode, m.public_key.is_none(), m.commitment.is_some()) {
                (Mode::Invite { .. }, true, true) if !trusted => {}
                (Mode::Invite { .. } | Mode::Join { .. }, _, _) => return Step::Close("invite_untrusted_offer".into()),
                (Mode::Reconnect { expected }, false, false) if trusted && expected.as_ref().is_none_or(|e| remote_id.eq_ignore_ascii_case(e)) => {}
                (Mode::Reconnect { .. }, _, _) => return Step::Close("tunnel_untrusted".into()),
            }
            st.id = m.session_id.clone();
            st.remote_id = remote_id;
            st.remote_name = sanitized_name(m.device_name.as_deref());
            st.remote_protocol = protocol;
            let mut answer = Message::new("pairing.answer", &st.id);
            answer.device_id = Some(local.device_id.clone());
            answer.device_name = Some(local.name());
            answer.public_key = Some(st.eph.public.clone());
            answer.protocol_version = Some(crypto::PROTOCOL_VERSION);
            st.answered = true;
            if let Some(revealed) = m.public_key.clone() {
                st.remote_eph = revealed;
                let Some((prk, key)) = st.eph.agree(&st.remote_eph.clone(), &st.id) else { return Step::Close("bad_key".into()) };
                set_key(st, prk, key);
                if write_frame(write, &answer).await.is_err() {
                    return Step::Close("send_failed".into());
                }
                // A plain reconnect to a trusted device: confirm without a prompt.
                if let Err(e) = confirm(st, local, invite_hash, spec, write).await {
                    return Step::Close(e);
                }
                return Step::Continue;
            }
            st.remote_commitment = m.commitment.clone();
            if write_frame(write, &answer).await.is_err() {
                return Step::Close("send_failed".into());
            }
            Step::Continue
        }
        "pairing.reveal" => {
            if st.initiated || st.key.is_some() || m.session_id != st.id {
                return Step::Continue;
            }
            let Some(commitment) = st.remote_commitment.clone() else { return Step::Continue };
            let Some(revealed) = m.public_key.clone() else { return Step::Close("commitment_mismatch".into()) };
            if !crypto::commitment_matches(&commitment, &st.id, &revealed) {
                return Step::Close("commitment_mismatch".into());
            }
            st.remote_eph = revealed;
            let Some((prk, key)) = st.eph.agree(&st.remote_eph.clone(), &st.id) else { return Step::Close("bad_key".into()) };
            set_key(st, prk, key);
            let code = crypto::sas_code(&prk, &st.remote_eph, &st.eph.public);
            let (confirm_tx, confirm_rx) = oneshot::channel();
            let forward = code_tx.clone();
            tokio::spawn(async move {
                let answer = confirm_rx.await.unwrap_or(false);
                let _ = forward.send(answer);
            });
            let _ = events.send(Event::Code { local_id: spec.local_id, code, peer_name: st.remote_name.clone(), confirm: confirm_tx });
            Step::AwaitCode
        }
        "pairing.answer" => {
            if !st.initiated || st.key.is_some() || m.session_id != st.id {
                return Step::Continue;
            }
            let joining = matches!(spec.mode, Mode::Join { .. });
            let (Some(remote_id), Some(remote_eph)) = (m.device_id.clone().filter(|d| crypto::is_uuid(d)), m.public_key.clone()) else { return Step::Close("malformed_answer".into()) };
            match &spec.mode {
                Mode::Reconnect { expected: Some(expected) } if remote_id.eq_ignore_ascii_case(expected) => {}
                Mode::Join { .. } if pins(&remote_id).is_none() => {}
                _ => return Step::Close("wrong_device".into()),
            }
            if m.protocol_version.unwrap_or(1) < crypto::PROTOCOL_VERSION {
                return Step::Close("needs_protocol_2".into());
            }
            st.remote_id = remote_id;
            st.remote_name = sanitized_name(m.device_name.as_deref());
            st.remote_eph = remote_eph;
            st.remote_protocol = m.protocol_version.unwrap_or(1);
            st.answered = true;
            let local_eph = st.eph.public.clone();
            let Some((prk, key)) = st.eph.agree(&st.remote_eph.clone(), &st.id) else { return Step::Close("bad_key".into()) };
            set_key(st, prk, key);
            if joining {
                let mut reveal = Message::new("pairing.reveal", &st.id);
                reveal.public_key = Some(local_eph.clone());
                if write_frame(write, &reveal).await.is_err() {
                    return Step::Close("send_failed".into());
                }
                let code = crypto::sas_code(&prk, &local_eph, &st.remote_eph);
                let (confirm_tx, confirm_rx) = oneshot::channel();
                let forward = code_tx.clone();
                tokio::spawn(async move {
                    let answer = confirm_rx.await.unwrap_or(false);
                    let _ = forward.send(answer);
                });
                let _ = events.send(Event::Code { local_id: spec.local_id, code, peer_name: st.remote_name.clone(), confirm: confirm_tx });
                return Step::AwaitCode;
            }
            if let Err(e) = confirm(st, local, invite_hash, spec, write).await {
                return Step::Close(e);
            }
            Step::Continue
        }
        "pairing.confirm" => {
            if m.session_id != st.id || st.key.is_none() || st.remote_confirmed {
                return Step::Continue;
            }
            let (Some(remote_id), Some(identity_key), Some(proof), Some(signature)) = (m.device_id.clone(), m.identity_key.clone(), m.proof.clone(), m.signature.clone()) else {
                return Step::Close("invalid_confirm".into());
            };
            if remote_id != st.remote_id {
                return Step::Close("invalid_confirm".into());
            }
            if let Some(pinned) = pins(&remote_id) {
                if pinned != identity_key {
                    return Step::Close("identity_changed".into());
                }
            } else if !matches!(spec.mode, Mode::Invite { .. } | Mode::Join { .. }) {
                return Step::Close("not_trusted".into());
            }
            let key = st.key.unwrap();
            if !crypto::proof_matches(&key, &st.id, &remote_id, &identity_key, &proof) || !crypto::verify_signature(&identity_key, &transcript(st, local, &spec.exporter, invite_hash), &signature) {
                return Step::Close("authentication_failed".into());
            }
            st.remote_identity = Some(identity_key);
            st.remote_confirmed = true;
            match complete(st, spec, events, tx) {
                Some((r, _, _)) => Step::Close(r),
                None => Step::Continue,
            }
        }
        "pairing.cancel" => {
            let reason: String = m.reason.as_deref().unwrap_or("cancelled").chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '_').take(32).collect();
            Step::Close(format!("cancelled_remote:{reason}"))
        }
        _ => {
            // Replay window for every message with a messageId (heartbeats and acks included).
            if m.message_id.as_ref().is_some_and(|i| i.len() > 128) {
                return bad(st);
            }
            if let Some(id) = m.message_id.clone() {
                let replayable = !matches!(m.kind.as_str(), "heartbeat.pong" | "ping.ack" | "clipboard.ack");
                if replayable {
                    if st.seen.contains(&id) {
                        return Step::Continue;
                    }
                    st.seen.insert(id.clone());
                    st.order.push_back(id);
                    if st.order.len() > REPLAY_WINDOW {
                        if let Some(old) = st.order.pop_front() {
                            st.seen.remove(&old);
                        }
                    }
                }
            }
            if m.kind == "heartbeat.ping" {
                let mut pong = Message::new("heartbeat.pong", &st.id);
                pong.message_id = m.message_id.clone();
                let _ = tx.send(Outgoing::Plain(Box::new(pong)));
                return Step::Continue;
            }
            if m.kind == "heartbeat.pong" {
                return Step::Continue;
            }
            let plaintext = match (&m.nonce, &m.ciphertext, st.key) {
                (Some(n), Some(c), Some(k)) => match crypto::decrypt(&k, n, c) {
                    Some(p) => Some(p),
                    None => return bad(st),
                },
                _ => None,
            };
            let _ = events.send(Event::Frame { local_id: spec.local_id, peer_id: st.remote_id.clone(), message: Box::new(m), plaintext });
            Step::Continue
        }
    }
}

fn set_key(st: &mut State, prk: [u8; 32], key: [u8; 32]) {
    st.prk = Some(prk);
    st.key = Some(key);
    if st.remote_protocol >= crypto::PROTOCOL_VERSION {
        st.envelope = Some(crypto::envelope_key(&key));
    }
}

fn bad(st: &mut State) -> Step {
    st.bad_frames += 1;
    if st.bad_frames >= MAX_BAD_FRAMES {
        Step::Close("bad_frames".into())
    } else {
        Step::Continue
    }
}
