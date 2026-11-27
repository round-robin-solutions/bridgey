//! Files over this command's sessions (docs/protocol.md "Files", "Fast transfers" and "Resuming files"): what
//! `bridgey send` runs, and the inbox, where files paired devices send here land.
//!
//! The binary frames, the sender's byte window, the resume records and the rules for names and partial files are the
//! session client's (`bridgey_core::fast`, `resume` and `transfer`, checked against the shared vectors); this module
//! runs them over the CLI's sessions (session.rs), whose daemon routes the replies.

use crate::crypto;
use crate::daemon::{refusal, Reply};
use crate::errors::CliError;
use crate::session::Handle;
use crate::time::now_ms;
use crate::wire::Message;
use bridgey_core::fast::{self, Pacer};
use bridgey_core::resume::{self, Blocks, Running};
use bridgey_core::transfer;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, VecDeque};
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;

// region Sending

/// How long a device has to accept a file, and to confirm it after the last chunk.
const ACCEPT_TIMEOUT: Duration = Duration::from_secs(60);
/// A resumable offer: the receiver may first read up to 10 GiB again; each `files.resume.wait` starts this again.
const RESUME_ANSWER_TIMEOUT: Duration = Duration::from_secs(120);
const COMPLETE_TIMEOUT: Duration = Duration::from_secs(60);
/// A transfer whose acknowledgements stop for this long has stalled.
const ACK_STALL: Duration = Duration::from_secs(30);
/// JSON chunks unacknowledged at most, as this command always kept (the apps' 64).
const JSON_WINDOW: i64 = 64;

/// This install's file switches (`transfers.fast` and `transfers.resume` in config.toml): on unless turned off, for a test.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Switches {
    pub fast: bool,
    pub resume: bool,
}

impl Default for Switches {
    fn default() -> Switches {
        Switches { fast: true, resume: true }
    }
}

/// How one file goes to one device, decided once as it starts: a sender keeps that form for the whole transfer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Plan {
    /// Binary frames of 256 KiB paced by a byte window; else JSON chunks of 24 KiB, 64 unacknowledged at most.
    pub fast: bool,
    /// Offered `resumable`: the receiver may continue after what it kept of an earlier attempt.
    pub resumable: bool,
}

impl Plan {
    /// From the device's latest map (`true` only for JSON true) and this install's switches.
    pub fn new(peer: &Map<String, Value>, size: u64, switches: Switches) -> Plan {
        let shows = |key: &str| peer.get(key) == Some(&Value::Bool(true));
        Plan { fast: switches.fast && shows(fast::FEATURE), resumable: switches.resume && shows(resume::FEATURE) && size > resume::BLOCK }
    }

    pub fn chunk(&self) -> usize {
        if self.fast {
            fast::CHUNK
        } else {
            transfer::FILE_CHUNK
        }
    }
}

/// A file hashed for its offer: its SHA-256, size and the prefix hash at every 1 MiB, which answers a `files.resume`
/// without reading the file again.
pub struct Prepared {
    pub sha256: String,
    pub size: u64,
    pub blocks: Blocks,
}

pub async fn prepare(path: &Path) -> io::Result<Prepared> {
    let path = path.to_path_buf();
    let (sha256, size, blocks) = tokio::task::spawn_blocking(move || resume::hash_file(&path)).await.map_err(io::Error::other)??;
    Ok(Prepared { sha256, size, blocks })
}

pub struct Outgoing<'a> {
    pub transfer_id: &'a str,
    /// The offer's messageId: a refusal (`agent.request_result`) names it.
    pub offer_id: &'a str,
    pub path: &'a Path,
    pub name: &'a str,
    pub mime: &'a str,
    pub file: &'a Prepared,
    pub plan: Plan,
    /// For messages: the device's name and this install's.
    pub peer_name: &'a str,
    pub me: &'a str,
}

/// What the sender reports while it runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Progress {
    /// Accepted; chunks start after `from` bytes (0, or what the receiver kept).
    Accepted { from: u64 },
    Sent(u64),
}

/// A send that did not finish: the transfer's last state (`rejected`, `cancelled`, `interrupted`, `failed`) and the
/// command's error.
#[derive(Debug)]
pub struct Failed {
    pub state: &'static str,
    pub error: CliError,
}

fn failed(state: &'static str, code: &str, message: impl Into<String>) -> Failed {
    Failed { state, error: CliError::new(code, message) }
}

enum Next {
    Reply(Box<Reply>),
    Timeout,
    Ended,
}

/// The next reply before `deadline`; `Ended` as soon as the session is gone.
async fn next(rx: &mut mpsc::UnboundedReceiver<Reply>, h: &Handle, deadline: Instant) -> Next {
    loop {
        let tick = (Instant::now() + Duration::from_secs(1)).min(deadline);
        match tokio::time::timeout_at(tick, rx.recv()).await {
            Ok(Some(r)) => return Next::Reply(Box::new(r)),
            Ok(None) => return Next::Ended,
            Err(_) if !h.is_open() => return Next::Ended,
            Err(_) if Instant::now() >= deadline => return Next::Timeout,
            Err(_) => {}
        }
    }
}

/// Reads until `buf` is full or the file ends.
fn read_full(file: &mut File, buf: &mut [u8]) -> io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match file.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// Sends one file after `files.offer`: `rx` gets the replies for its transfer ID and offer messageId (the daemon's
/// waiters). JSON chunks or binary frames as the plan says; a resumable offer may continue after what the receiver
/// kept, once the prefix hashes agree. Progress goes to `progress`.
pub async fn send(h: &Handle, rx: &mut mpsc::UnboundedReceiver<Reply>, o: &Outgoing<'_>, progress: &mpsc::UnboundedSender<Progress>) -> Result<u64, Failed> {
    let (id, size, peer) = (o.transfer_id, o.file.size, o.peer_name);
    // A resumable file that stops moving keeps what the receiver has: it ends without files.cancel (as the apps do),
    // and sending it again continues from there.
    let interrupted = |what: &str| {
        if o.plan.resumable {
            Failed { state: "interrupted", error: CliError::new("interrupted_resumable", format!("{what}; send the same file again to continue from what {peer} kept")).with("transferId", id) }
        } else {
            failed("interrupted", "transfer_failed", what)
        }
    };
    // Opened before the offer, so a file that can no longer be read is never offered.
    let mut reader = File::open(o.path).map_err(|e| failed("failed", "transfer_failed", format!("{}: {e}", o.path.display())))?;
    let mut offer = json!({"transferId": id, "name": o.name, "mimeType": o.mime, "size": size, "sha256": o.file.sha256});
    if o.plan.resumable {
        offer["resumable"] = Value::Bool(true);
    }
    h.send_json_id("files.offer", &offer, o.offer_id, Some(id.to_string()));
    let mut deadline = Instant::now() + if o.plan.resumable { RESUME_ANSWER_TIMEOUT } else { ACCEPT_TIMEOUT };
    let offset = loop {
        let r = match next(rx, h, deadline).await {
            Next::Reply(r) => r,
            Next::Ended => return Err(interrupted("the session ended")),
            Next::Timeout => {
                h.send_outer("files.cancel", id, None);
                return Err(failed("failed", "timeout", format!("{peer} did not accept the file in time")));
            }
        };
        match r.kind.as_str() {
            "files.accept" => break 0,
            "files.rejected" => return Err(Failed { state: "rejected", error: crate::daemon::not_granted(peer, "files", o.me) }),
            "agent.request_result" => {
                if let Some(e) = refusal(r.payload.as_ref().unwrap_or(&Value::Null), peer, o.me) {
                    return Err(Failed { state: "rejected", error: e });
                }
            }
            "files.resume" if o.plan.resumable => {
                // Continue after the receiver's bytes only when their SHA-256 is this file's own over the same length.
                let sha256 = crypto::unb64(&o.file.sha256).unwrap_or_default();
                let plain = r.plaintext.as_deref().unwrap_or_default();
                let (mut at, mut reason) = resume::sender_answer(plain, id, size, &sha256, &o.file.blocks);
                if at > 0 && reader.seek(SeekFrom::Start(at)).is_err() {
                    (at, reason) = (0, Some("unreadable"));
                    let _ = reader.seek(SeekFrom::Start(0));
                }
                h.send_encrypted("files.resume.ack", resume::ack_payload(id, at, reason), Some(id.to_string()));
                break at;
            }
            "files.resume" => {
                // Never offered resumable: the receiver broke the rules, so the file ends here.
                h.send_outer("files.cancel", id, None);
                return Err(failed("failed", "transfer_failed", format!("{peer} answered with a resume this file was not offered for")));
            }
            // The receiver is still reading what it kept of this file: wait for its answer a while longer.
            "files.resume.wait" if o.plan.resumable => deadline = Instant::now() + RESUME_ANSWER_TIMEOUT,
            "files.cancel" => return Err(failed("cancelled", "transfer_failed", format!("cancelled on {peer}"))),
            _ => {}
        }
    };
    let _ = progress.send(Progress::Accepted { from: offset });
    let chunk = o.plan.chunk();
    let mut pacer = Pacer::new(o.plan.fast, chunk, None);
    let (mut sequence, mut acked, mut sent) = (0u64, -1i64, offset);
    let mut stall = Instant::now() + ACK_STALL;
    let mut buf = vec![0u8; chunk];
    loop {
        // Acknowledgements that are here already, then a wait while the window is full.
        loop {
            let full = if o.plan.fast { !pacer.room(chunk) } else { sequence as i64 - acked > JSON_WINDOW };
            let r = if full {
                match next(rx, h, stall).await {
                    Next::Reply(r) => r,
                    Next::Ended => return Err(interrupted("the session ended")),
                    Next::Timeout => {
                        if !o.plan.resumable {
                            h.send_outer("files.cancel", id, None);
                        }
                        return Err(interrupted("the transfer stalled"));
                    }
                }
            } else {
                match rx.try_recv() {
                    Ok(r) => Box::new(r),
                    Err(mpsc::error::TryRecvError::Empty) => break,
                    Err(mpsc::error::TryRecvError::Disconnected) => return Err(interrupted("the session ended")),
                }
            };
            match r.kind.as_str() {
                "files.chunk.ack" => {
                    if let Some(s) = r.message.sequence {
                        acked = acked.max(s.min(sequence as i64 - 1));
                        if o.plan.fast && s >= 0 {
                            pacer.acknowledged(s as u64, std::time::Instant::now());
                        }
                        stall = Instant::now() + ACK_STALL;
                    }
                }
                "files.cancel" => return Err(failed("cancelled", "transfer_failed", format!("cancelled on {peer}"))),
                _ => {}
            }
        }
        let n = read_full(&mut reader, &mut buf).map_err(|e| failed("failed", "transfer_failed", e.to_string()))?;
        if (n == 0 && sent != size) || sent + n as u64 > size {
            // The file changed since it was hashed: tell the other device to let go.
            h.send_outer("files.cancel", id, None);
            return Err(failed("failed", "transfer_failed", "the file changed while it was being sent"));
        }
        if n == 0 {
            break;
        }
        let ok = if o.plan.fast {
            pacer.sent(sequence, n, std::time::Instant::now());
            h.send_fast_chunk(id, sequence, buf[..n].to_vec())
        } else {
            h.send_chunk(id, sequence as i64, buf[..n].to_vec())
        };
        if !ok {
            return Err(interrupted("the session ended"));
        }
        sequence += 1;
        sent += n as u64;
        let _ = progress.send(Progress::Sent(sent));
    }
    h.send_json_id("files.complete", &json!({"transferId": id, "sha256": o.file.sha256}), &crypto::uuid4(), Some(id.to_string()));
    let deadline = Instant::now() + COMPLETE_TIMEOUT;
    loop {
        match next(rx, h, deadline).await {
            Next::Reply(r) if r.kind == "files.complete.ack" => return Ok(offset),
            Next::Reply(r) if r.kind == "files.cancel" => return Err(failed("failed", "transfer_failed", format!("{peer} could not verify the file"))),
            Next::Reply(_) => {}
            // Every byte went: a resumable file's receiver kept them all, and sending it again finishes at once.
            Next::Ended => return Err(interrupted("the session ended before the file was confirmed")),
            Next::Timeout => return Err(failed("failed", "transfer_failed", format!("no confirmation from {peer}"))),
        }
    }
}

// endregion

// region Receiving

/// Files coming in at once from one device (the session client's limit).
const MAX_INCOMING: usize = 4;
/// Progress for a file coming in is reported at most this often.
const PROGRESS_EVERY: Duration = Duration::from_millis(500);
/// How often a receiver reading a kept partial again sends `files.resume.wait`, well inside the sender's 120 s.
const RESUME_WAIT_EVERY: Duration = Duration::from_secs(30);

/// Where files land and what the inbox takes (config.toml `inbox.*`, `transfers.resume`).
#[derive(Clone, Debug)]
pub struct InboxConfig {
    /// `inbox.dir`, `~/bridgey-inbox` by default.
    pub dir: PathBuf,
    /// `inbox.receive`: off answers every offer `files.rejected`.
    pub receive: bool,
    /// `transfers.resume`: keep what came of an interrupted file and continue it on the next attempt.
    pub resume: bool,
    /// The kept partials' records (`state/file-resume.json`, 0600); None keeps them in memory.
    pub records: Option<PathBuf>,
}

/// What the inbox tells the daemon, for `bridgey transfers`, the log and the audit log. Never file contents.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Report {
    Incoming { transfer_id: String, device: String, name: String, size: u64 },
    Progress { transfer_id: String, bytes: u64 },
    Saved { transfer_id: String, device: String, name: String, path: PathBuf, size: u64, resumed_from: u64 },
    Failed { transfer_id: String, device: String, name: String, reason: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    /// Reading a kept partial again, whose record says this many verified bytes with this SHA-256.
    Checking { length: u64, prefix: [u8; 32] },
    /// `files.resume` sent for this offset; waiting for `files.resume.ack`.
    Proposed(u64),
    Receiving,
}

/// A file coming in: written to a hidden partial in the inbox through one handle, and hashed as it arrives.
struct Incoming {
    local_id: u64,
    peer: String,
    handle: Handle,
    name: String,
    size: u64,
    sha256: Vec<u8>,
    received: u64,
    next_sequence: u64,
    dir: PathBuf,
    part: PathBuf,
    file: File,
    hasher: Running,
    resumable: bool,
    phase: Phase,
    /// `received` when the record was last written.
    checkpoint: u64,
    resumed_from: u64,
    reported: Instant,
}

impl Incoming {
    /// The record of this partial with `verified` bytes and their SHA-256.
    fn record(&self, verified: (u64, [u8; 32])) -> Option<resume::Record> {
        Some(resume::Record {
            peer: self.peer.clone(),
            size: self.size,
            sha256: crypto::b64(&self.sha256),
            length: verified.0,
            prefix: crypto::b64(&verified.1),
            dir: self.dir.clone(),
            part: self.part.file_name()?.to_str()?.to_string(),
            name: self.name.clone(),
            updated: 0,
        })
    }
}

struct InboxState {
    config: InboxConfig,
    incoming: HashMap<String, Incoming>,
    /// Transfers that ended here, so an offer cannot reuse one.
    ended: VecDeque<String>,
    store: resume::Store,
}

/// The files paired devices send here. One per daemon; cheap to clone.
#[derive(Clone)]
pub struct Inbox {
    state: Arc<Mutex<InboxState>>,
    report: mpsc::UnboundedSender<Report>,
}

/// A new partial: `O_CREAT | O_EXCL | O_NOFOLLOW`, 0600. A name that exists, a dangling link included, is never
/// opened, so a new part is this user's own file with one name and needs no owner or link check (security review
/// 1.0, F1 and its follow-up).
fn create_partial(path: &Path) -> io::Result<File> {
    fs::OpenOptions::new().read(true).write(true).create_new(true).mode(0o600).custom_flags(libc::O_NOFOLLOW).open(path)
}

/// Moves a verified partial to the first free name, only while its name still names the very file written through
/// `file`, and checks the saved name the same way afterwards: a link or another file put in the partial's place, even
/// between the check and the move, is never published (security review 1.0, F1).
fn publish(file: &File, part: &Path, dir: &Path, name: &str) -> io::Result<PathBuf> {
    let ours = file.metadata()?;
    let same = |m: &fs::Metadata| m.file_type().is_file() && m.dev() == ours.dev() && m.ino() == ours.ino();
    if !same(&fs::symlink_metadata(part)?) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "the partial was replaced"));
    }
    let target = transfer::place(part, dir, name)?;
    if !fs::symlink_metadata(&target).is_ok_and(|m| same(&m)) {
        let _ = fs::remove_file(&target);
        return Err(io::Error::new(io::ErrorKind::InvalidData, "the partial was replaced"));
    }
    Ok(target)
}

/// The inbox folder, made 0700 when this creates it (an existing folder keeps its mode).
fn ensure_dir(dir: &Path) -> io::Result<()> {
    if !dir.exists() {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    }
    if fs::metadata(dir)?.is_dir() {
        Ok(())
    } else {
        Err(io::Error::new(io::ErrorKind::InvalidInput, "not a folder"))
    }
}

impl InboxState {
    /// Deletes the partials whose records went and saves the records.
    fn partials_changed(&self, gone: Vec<PathBuf>) {
        for part in gone {
            // Only names this command gives partials (`resume::valid_part`); records with any other name never load.
            let _ = fs::remove_file(part);
        }
        if let Some(path) = &self.config.records {
            let _ = crate::paths::write_private(path, &self.store.encode());
        }
    }

    fn save_record(&mut self, record: resume::Record) {
        let gone = self.store.save(record, now_ms());
        self.partials_changed(gone);
    }

    fn release(&mut self, part: &Path, keep: bool) {
        if self.store.release(part, keep) {
            self.partials_changed(Vec::new());
        }
    }

    fn ended(&mut self, id: &str) {
        self.ended.push_back(id.to_string());
        if self.ended.len() > 64 {
            self.ended.pop_front();
        }
    }
}

impl Inbox {
    /// The inbox, with the records of partials kept from an earlier run, less those that can no longer be resumed
    /// (expired, nothing verified, gone or shorter than recorded), whose files are deleted.
    pub fn new(config: InboxConfig, report: mpsc::UnboundedSender<Report>) -> Inbox {
        let mut store = config.records.as_ref().and_then(|p| fs::read(p).ok()).map(|b| resume::Store::decode(&b)).unwrap_or_default();
        // symlink_metadata: a link where a partial was is not the partial.
        let gone = store.sweep(now_ms(), |p| fs::symlink_metadata(p).ok().filter(|m| m.is_file()).map(|m| m.len()));
        let state = InboxState { config, incoming: HashMap::new(), ended: VecDeque::new(), store };
        if !gone.is_empty() {
            state.partials_changed(gone);
        }
        Inbox { state: Arc::new(Mutex::new(state)), report }
    }

    fn lock(&self) -> MutexGuard<'_, InboxState> {
        self.state.lock().unwrap()
    }

    fn tell(&self, r: Report) {
        let _ = self.report.send(r);
    }

    fn failed(&self, id: &str, i: &Incoming, reason: &str) {
        self.tell(Report::Failed { transfer_id: id.into(), device: i.peer.clone(), name: i.name.clone(), reason: reason.into() });
    }

    /// Ends an incoming file and deletes its partial (a cancel always does).
    fn drop_incoming(&self, st: &mut InboxState, id: &str, i: Incoming, reason: &str) {
        let _ = fs::remove_file(&i.part);
        if i.resumable {
            st.release(&i.part, false);
        }
        st.ended(id);
        self.failed(id, &i, reason);
    }

    /// An interrupted resumable file: its verified bytes are synced and recorded, and the partial stays for the next
    /// attempt. Nothing verified, or a write that fails, and it goes as any other.
    fn keep_incoming(&self, st: &mut InboxState, id: &str, mut i: Incoming, reason: &str) {
        let kept = match i.phase {
            // The partial is as its record says: not touched yet, or cut back to the offset proposed.
            Phase::Checking { .. } | Phase::Proposed(_) => true,
            Phase::Receiving => {
                let verified = i.hasher.checkpoint(i.size);
                match (verified.0 > 0).then(|| i.record(verified)).flatten() {
                    Some(r) if i.file.flush().and_then(|_| i.file.sync_data()).is_ok() => {
                        st.save_record(r);
                        true
                    }
                    _ => false,
                }
            }
        };
        if !kept {
            return self.drop_incoming(st, id, i, reason);
        }
        st.release(&i.part, true);
        st.ended(id);
        self.failed(id, &i, reason);
    }

    /// `files.offer` from `peer` on session `local_id`. Accepted into a new partial, resumed from a kept one (after it
    /// is read again), rejected while the inbox is off, or cancelled when it breaks a rule.
    pub fn offer(&self, h: &Handle, local_id: u64, peer: &str, peer_resume: bool, m: &Message, plain: Option<&[u8]>) {
        let Some(outer) = m.transfer_id.clone() else { return };
        let mut st = self.lock();
        if !st.config.receive {
            h.send_outer("files.rejected", &outer, None);
            return;
        }
        let cancel = || {
            h.send_outer("files.cancel", &outer, None);
        };
        let offer = plain.and_then(|p| serde_json::from_slice::<Value>(p).ok());
        let o = offer.as_ref().and_then(Value::as_object);
        let field = |k: &str| o.and_then(|o| o.get(k));
        let transfer_id = field("transferId").and_then(Value::as_str).unwrap_or("");
        let name = field("name").and_then(Value::as_str).unwrap_or("");
        let size = field("size").and_then(Value::as_u64);
        let sha256 = field("sha256").and_then(Value::as_str).and_then(crypto::unb64).filter(|h| h.len() == 32);
        // Clipboard files and folders are drafts this command does not advertise.
        let other_purpose = field("purpose").is_some_and(|p| !p.is_null()) || field("folderTransferId").is_some_and(|p| !p.is_null());
        let (Some(size), Some(sha256)) = (size, sha256) else { return cancel() };
        if other_purpose || transfer_id != outer || !crypto::is_uuid(transfer_id) || name.is_empty() || size > transfer::MAX_FILE {
            return cancel();
        }
        let taken = st.incoming.contains_key(transfer_id) || st.ended.iter().any(|e| e == transfer_id);
        if taken || st.incoming.values().filter(|i| i.peer == peer).count() >= MAX_INCOMING {
            return cancel();
        }
        let name = transfer::safe_name(name);
        let dir = st.config.dir.clone();
        let refuse = |reason: &str| {
            self.tell(Report::Failed { transfer_id: transfer_id.into(), device: peer.into(), name: name.clone(), reason: reason.into() });
            cancel();
        };
        if ensure_dir(&dir).is_err() {
            return refuse("storage");
        }
        // files_resume_draft1: the sender marked it, both show the key, and it is more than one block.
        let resumable = field("resumable") == Some(&Value::Bool(true)) && size > resume::BLOCK && st.config.resume && peer_resume;
        let new = |part: PathBuf, file: File, phase: Phase, verified: u64| Incoming {
            local_id,
            peer: peer.to_ascii_lowercase(),
            handle: h.clone(),
            name: name.clone(),
            size,
            sha256: sha256.clone(),
            received: 0,
            next_sequence: 0,
            dir: dir.clone(),
            part,
            file,
            hasher: Running::new(false),
            resumable,
            phase,
            checkpoint: verified,
            resumed_from: 0,
            reported: Instant::now(),
        };
        if resumable {
            // Only this device's partial of this very content, in the folder files land in now; never a path or ID from
            // the sender. Its bytes are read again, through the handle that will write it, before anything is offered.
            let (found, gone) = st.store.claim(peer, size, &crypto::b64(&sha256), &name, &dir, now_ms());
            if !gone.is_empty() {
                st.partials_changed(gone);
            }
            if let Some(r) = found {
                let part = r.part_path();
                let prefix: Option<[u8; 32]> = crypto::unb64(&r.prefix).and_then(|b| b.try_into().ok());
                // Not through a link, and only a plain file of this user with one name (security review 1.0, F1).
                let opened = transfer::open_partial(&part).and_then(|file| Ok((file.try_clone()?, file)));
                match (opened, prefix) {
                    (Ok((reader, file)), Some(prefix)) => {
                        st.incoming.insert(transfer_id.to_string(), new(part, file, Phase::Checking { length: r.length, prefix }, r.length));
                        self.tell(Report::Incoming { transfer_id: transfer_id.into(), device: peer.into(), name: name.clone(), size });
                        self.check_partial(h.clone(), transfer_id.to_string(), reader, r.length);
                        return;
                    }
                    _ => {
                        let _ = fs::remove_file(&part);
                        st.release(&part, false);
                    }
                }
            }
        }
        // Room for this file and the ones already arriving, plus a margin (the apps' rule, 0.10 M6).
        let arriving: u64 = st.incoming.values().map(|i| i.size.saturating_sub(i.received)).sum();
        if transfer::free_space(&dir).is_some_and(|free| free < size.saturating_add(arriving).saturating_add(transfer::FREE_SPACE_MARGIN)) {
            return refuse("storage");
        }
        let part = transfer::part_path(&dir, transfer_id);
        let Ok(file) = create_partial(&part) else { return refuse("storage") };
        let i = new(part, file, Phase::Receiving, 0);
        if resumable {
            // A record from the start, so a crash before the first checkpoint leaves nothing behind: the next start
            // sweeps records with nothing verified, and their files.
            if let Some(r) = i.record(i.hasher.checkpoint(size)) {
                st.save_record(r);
            }
        }
        st.incoming.insert(transfer_id.to_string(), i);
        drop(st);
        self.tell(Report::Incoming { transfer_id: transfer_id.into(), device: peer.into(), name, size });
        h.send_outer("files.accept", &outer, None);
    }

    /// Reads a kept partial's verified bytes again off the async threads, through the handle the transfer writes with;
    /// meanwhile `files.resume.wait` every 30 seconds keeps the sender waiting instead of cancelling.
    fn check_partial(&self, h: Handle, id: String, mut part: File, length: u64) {
        let inbox = self.clone();
        tokio::spawn(async move {
            let mut read = tokio::task::spawn_blocking(move || resume::hash_prefix_of(&mut part, length).ok());
            let mut tick = tokio::time::interval_at(Instant::now() + RESUME_WAIT_EVERY, RESUME_WAIT_EVERY);
            let prefix = loop {
                tokio::select! {
                    done = &mut read => break done.ok().flatten(),
                    _ = tick.tick() => {
                        if !h.send_outer("files.resume.wait", &id, None) {
                            return;
                        }
                    }
                }
            };
            inbox.checked(&id, prefix);
        });
    }

    /// A kept partial was read again. Its bytes match its record: propose resuming after them (`files.resume`). They do
    /// not (changed, damaged, unreadable): the file comes from byte zero (`files.accept`).
    fn checked(&self, id: &str, prefix: Option<(ring::digest::Context, [u8; 32])>) {
        let mut st = self.lock();
        let Some(i) = st.incoming.get_mut(id) else { return };
        let Phase::Checking { length, prefix: recorded } = i.phase else { return };
        let good = prefix.filter(|(_, d)| crypto::ct_eq(d, &recorded));
        match good {
            Some((ctx, digest)) if i.file.set_len(length).is_ok() && i.file.seek(SeekFrom::End(0)).is_ok() => {
                i.hasher = Running::resumed(ctx, length, digest);
                i.received = length;
                i.checkpoint = length;
                i.resumed_from = length;
                i.phase = Phase::Proposed(length);
                i.handle.send_encrypted("files.resume", resume::resume_payload(id, length, &digest), Some(id.to_string()));
            }
            _ => {
                let h = i.handle.clone();
                if self.restart(&mut st, id) {
                    h.send_outer("files.accept", id, None);
                } else {
                    h.send_outer("files.cancel", id, None);
                }
            }
        }
    }

    /// The partial of an incoming file starts again from byte zero, its record saying nothing is verified. False when
    /// it could not be cut back (it has gone, failed with `storage`).
    fn restart(&self, st: &mut InboxState, id: &str) -> bool {
        let Some(i) = st.incoming.get_mut(id) else { return false };
        if i.file.set_len(0).is_ok() && i.file.seek(SeekFrom::Start(0)).is_ok() {
            i.hasher = Running::new(false);
            i.received = 0;
            i.checkpoint = 0;
            i.resumed_from = 0;
            i.phase = Phase::Receiving;
            let record = i.record(i.hasher.checkpoint(i.size));
            if let Some(r) = record {
                st.save_record(r);
            }
            return true;
        }
        let i = st.incoming.remove(id).unwrap();
        self.drop_incoming(st, id, i, "storage");
        false
    }

    /// The incoming file `id`, only on the session and from the device it came with.
    fn take_if_ours(st: &mut InboxState, local_id: u64, peer: &str, id: &str) -> Option<Incoming> {
        st.incoming.get(id).filter(|i| i.local_id == local_id && i.peer.eq_ignore_ascii_case(peer))?;
        st.incoming.remove(id)
    }

    /// `files.resume.ack` for a file this end proposed to resume: chunks follow from the offset proposed, or from byte
    /// zero. Anything else cancels the file.
    pub fn resume_ack(&self, local_id: u64, peer: &str, id: &str, plain: Option<&[u8]>) {
        let mut st = self.lock();
        let Some(i) = st.incoming.get_mut(id).filter(|i| i.local_id == local_id && i.peer.eq_ignore_ascii_case(peer)) else { return };
        let answer = match (i.phase, plain) {
            (Phase::Proposed(proposed), Some(plain)) => resume::parse_ack(plain, id, proposed).map(|n| (n, proposed)),
            _ => None,
        };
        let h = i.handle.clone();
        match answer {
            Some((n, proposed)) if n == proposed => i.phase = Phase::Receiving,
            Some(_) => {
                if !self.restart(&mut st, id) {
                    h.send_outer("files.cancel", id, None);
                }
            }
            None => {
                let i = st.incoming.remove(id).unwrap();
                self.drop_incoming(&mut st, id, i, "invalid");
                h.send_outer("files.cancel", id, None);
            }
        }
    }

    /// One chunk of an incoming file, JSON (`max` 48 KiB) or a binary frame (`max` 1 MiB): in order, within the offered
    /// size, written and hashed, then acknowledged. Anything else cancels the file; a chunk for a file that is not
    /// coming in (ended here, or never offered) is dropped.
    pub fn chunk(&self, local_id: u64, peer: &str, id: &str, sequence: Option<u64>, data: &[u8], max: usize) {
        let mut st = self.lock();
        let Some(i) = st.incoming.get_mut(id).filter(|i| i.local_id == local_id && i.peer.eq_ignore_ascii_case(peer)) else { return };
        let fits = i.phase == Phase::Receiving && sequence == Some(i.next_sequence) && !data.is_empty() && data.len() <= max && i.received + data.len() as u64 <= i.size;
        if !fits || i.file.write_all(data).is_err() {
            let reason = if fits { "storage" } else { "invalid" };
            let i = st.incoming.remove(id).unwrap();
            let h = i.handle.clone();
            self.drop_incoming(&mut st, id, i, reason);
            h.send_outer("files.cancel", id, None);
            return;
        }
        i.hasher.update(data);
        i.received += data.len() as u64;
        i.next_sequence += 1;
        let h = i.handle.clone();
        let (received, sequence) = (i.received, i.next_sequence - 1);
        let report = i.reported.elapsed() >= PROGRESS_EVERY;
        if report {
            i.reported = Instant::now();
        }
        // A resumable file's record follows it every 64 MiB, once its bytes are on stable storage, so a crash loses at
        // most that much.
        let record = (i.resumable && i.received - i.checkpoint >= resume::CHECKPOINT_EVERY && i.file.sync_data().is_ok()).then(|| {
            i.checkpoint = i.received;
            i.record(i.hasher.checkpoint(i.size))
        });
        if let Some(Some(r)) = record {
            st.save_record(r);
        }
        drop(st);
        if report {
            self.tell(Report::Progress { transfer_id: id.into(), bytes: received });
        }
        // Every chunk is acknowledged: a fast sender paces itself by the acknowledgements' round trip.
        h.send_outer("files.chunk.ack", id, Some(sequence as i64));
    }

    /// `files.complete`: saved under the first free name in the inbox once every byte is here and the whole file's
    /// SHA-256 is the offer's, then confirmed with `files.complete.ack`.
    pub fn complete(&self, local_id: u64, peer: &str, plain: Option<&[u8]>) {
        let Some(Value::Object(o)) = plain.and_then(|p| serde_json::from_slice::<Value>(p).ok()) else { return };
        // Android repeats the transfer ID only inside.
        let Some(id) = o.get("transferId").and_then(Value::as_str).map(str::to_string) else { return };
        let hash = o.get("sha256").and_then(Value::as_str).and_then(crypto::unb64);
        let mut st = self.lock();
        let Some(mut i) = Self::take_if_ours(&mut st, local_id, peer, &id) else { return };
        let h = i.handle.clone();
        let digest = std::mem::replace(&mut i.hasher, Running::new(false)).finish();
        let verified = i.phase == Phase::Receiving && i.received == i.size && crypto::ct_eq(&digest, &i.sha256) && hash.as_deref().is_some_and(|x| crypto::ct_eq(x, &i.sha256));
        let flushed = i.file.flush().and_then(|_| i.file.sync_all()).is_ok();
        st.ended(&id);
        if i.resumable {
            // Saved or failed, this partial is never resumed again.
            st.release(&i.part, false);
        }
        drop(st);
        if !verified || !flushed {
            let _ = fs::remove_file(&i.part);
            self.failed(&id, &i, if verified { "storage" } else { "verification_failed" });
            h.send_outer("files.cancel", &id, None);
            return;
        }
        match publish(&i.file, &i.part, &i.dir, &i.name) {
            Ok(path) => {
                let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| i.name.clone());
                self.tell(Report::Saved { transfer_id: id.clone(), device: i.peer.clone(), name, path, size: i.size, resumed_from: i.resumed_from });
                h.send_outer("files.complete.ack", &id, None);
            }
            Err(_) => {
                // The partial goes only while its name is still the file written; a link or another file that took
                // its place stays as it is.
                let ours = i.file.metadata().ok();
                if fs::symlink_metadata(&i.part).is_ok_and(|m| m.is_file() && ours.as_ref().is_some_and(|o| o.dev() == m.dev() && o.ino() == m.ino())) {
                    let _ = fs::remove_file(&i.part);
                }
                self.failed(&id, &i, "storage");
                h.send_outer("files.cancel", &id, None);
            }
        }
    }

    /// `files.cancel` from the sender: the partial goes. True when the file was coming in here.
    pub fn cancel(&self, local_id: u64, peer: &str, id: &str) -> bool {
        let mut st = self.lock();
        let Some(i) = Self::take_if_ours(&mut st, local_id, peer, id) else { return false };
        let h = i.handle.clone();
        self.drop_incoming(&mut st, id, i, "cancelled_remote");
        h.send_outer("files.cancel.ack", id, None);
        true
    }

    /// A session ended: its resumable files keep their verified bytes for the next attempt, the rest go. A device that
    /// was forgotten takes its partials with it.
    pub fn closed(&self, local_id: u64, reason: &str) {
        let mut st = self.lock();
        let ids: Vec<String> = st.incoming.iter().filter(|(_, i)| i.local_id == local_id).map(|(id, _)| id.clone()).collect();
        for id in ids {
            let i = st.incoming.remove(&id).unwrap();
            if i.resumable && reason != "forgotten" {
                self.keep_incoming(&mut st, &id, i, "interrupted");
            } else {
                self.drop_incoming(&mut st, &id, i, "interrupted");
            }
        }
    }

    /// The device was unpaired: its kept partials go.
    pub fn forget(&self, peer: &str) {
        let mut st = self.lock();
        let gone = st.store.forget(peer);
        st.partials_changed(gone);
    }

    #[cfg(test)]
    fn kept(&self) -> Vec<resume::Record> {
        self.lock().store.records().to_vec()
    }
}

/// A `files.*` frame from `peer`: the inbox takes the kinds of a file coming in, and a cancel for one. False for the
/// rest (answers to this install's own sends), which the daemon gives to their waiters.
pub fn route(inbox: &Inbox, h: &Handle, local_id: u64, peer: &str, peer_resume: impl FnOnce() -> bool, m: &Message, plaintext: Option<&[u8]>) -> bool {
    match m.kind.as_str() {
        "files.offer" => inbox.offer(h, local_id, peer, peer_resume(), m, plaintext),
        "files.chunk" => {
            if let Some(id) = &m.transfer_id {
                inbox.chunk(local_id, peer, id, m.sequence.and_then(|s| u64::try_from(s).ok()), plaintext.unwrap_or_default(), transfer::MAX_CHUNK_IN);
            }
        }
        "files.complete" => inbox.complete(local_id, peer, plaintext),
        "files.resume.ack" => {
            if let Some(id) = &m.transfer_id {
                inbox.resume_ack(local_id, peer, id, plaintext);
            }
        }
        "files.cancel" if m.transfer_id.as_ref().is_some_and(|id| inbox.cancel(local_id, peer, id)) => {}
        _ => return false,
    }
    true
}

// endregion

#[cfg(test)]
mod tests;
