//! The phone's files (`files_browse_draft1`, docs/protocol.md "Draft: phone files, media and folders both ways" and
//! "Draft: folders, places and settings sync"): browsing the phone's places and folders, its photos and videos and its
//! recent documents with thumbnails, downloading files and folders, and adding files to the folder being browsed, as
//! the Mac's Phone files window does (macos/Sources/BridgeyMac/PhoneFiles*.swift, BrowseMessages.swift,
//! FolderReceiveSession.swift, FolderSendSession.swift). The pattern every area follows is in `phone.rs`.
//!
//! - Requests go in two lanes with the phone's budgets (browse: 4 in flight and 40 per 10 s; media: 4 active and 60 per
//!   10 s); more wait their turn here. Every request is answered within 8 s (the first part of a streamed one).
//! - A download is `places.download`, then a folder transfer from the phone with `into`: the entries land directly in
//!   the chosen folder (the receive folder by default), a clashing name becomes "name (1).ext", nothing is merged,
//!   replaced or overwritten. Each file is verified against the manifest's SHA-256 before it takes its name. A folder
//!   the phone sends on its own lands in the receive folder under its own name.
//! - An upload is a folder transfer to the phone with `into` and the folder being browsed as its destination; files
//!   only for now (each file's name made portable, clashes between them numbered).
//! - Folder transfers that break off are not resumed yet: the phone is told the journal is missing
//!   (`resume_unavailable`) and the files saved so far stay.
//!
//! Host commands (`bridgey_phone`, area 3), each answered at once:
//!   status | places | list {placeId, path, cursor?, sort?, descending?} | media {kind, cursor?, limit?}
//!   | thumbnails {items: [{key, ref}], size?, replaces?} | cancel {requestId}
//!   | download {items: [ref], folder?} | cancel_download {requestId}
//!   | upload {placeId, path, files: [{path, name?}]} | cancel_upload {uploadId}
//! Events (`BRIDGEY_EVENT_KIND_PHONE_FILES`): `status`, `places`, `list`, `media`, `thumbnails` (one per batch),
//! `download` and `upload` (their progress and outcome). An answer that fails carries `error` (a protocol code, or
//! `timeout` and `not_connected`).
//!
//! File names are never logged.

use crate::client::Inner;
use crate::folders::{self, Entry};
use crate::phone::{self, boolean, integer, non_negative, request_id, Area, Incoming};
use crate::session::{FolderEntryOffer, FolderFile, FolderTarget, Host as _, OutgoingFile};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

/// The phone serves browsing and takes uploads.
pub(crate) const BROWSE: &str = "files_browse_draft1";
/// This device's switch for the whole area: Files.
const FILES: &str = "files";

const SMALL: usize = 8_192;
const LARGE: usize = 32_768;
const MEDIA_PART: usize = 45_056;
const MAX_LIST: usize = 200;
const MAX_THUMB_ITEMS: usize = 64;
const MAX_THUMB_BYTES: usize = 24 * 1024;
const MAX_PART_DATA: usize = 32 * 1024;
const MAX_PREVIEW_PARTS: i64 = 1024 * 1024 / 32 / 1024 + 1;
const MAX_DOWNLOAD_ITEMS: usize = 100;

const ANSWER: Duration = Duration::from_secs(8);
/// A folder's first answer after its manifest.
const FIRST_ANSWER: Duration = Duration::from_secs(15);
/// A question the phone asks its person (destination, conflict) plus a margin.
const QUESTION: Duration = Duration::from_secs(195);
const RESULT: Duration = Duration::from_secs(30);
const LANE_ACTIVE: usize = 4;
const WINDOW: Duration = Duration::from_secs(10);
const PROGRESS_EVERY: Duration = Duration::from_millis(250);
/// Room kept free beyond a folder (the Mac's rule).
const SPACE_MARGIN: u64 = 64 * 1024 * 1024;
const MAX_FAILURES: usize = 50;

pub fn incoming(kind: &str) -> Option<Incoming> {
    let (kind, max): (&'static str, usize) = match kind {
        "places.listed" => ("places.listed", LARGE),
        "places.error" => ("places.error", SMALL),
        "places.files_page" => ("places.files_page", LARGE),
        "places.download_started" => ("places.download_started", SMALL),
        "media.page" => ("media.page", LARGE),
        "media.thumbnails_batch" => ("media.thumbnails_batch", MEDIA_PART),
        "folders.offer" => ("folders.offer", SMALL),
        "folders.manifest" => ("folders.manifest", LARGE),
        "folders.complete" => ("folders.complete", LARGE),
        "folders.waiting" => ("folders.waiting", SMALL),
        "folders.accept" => ("folders.accept", SMALL),
        "folders.rejected" => ("folders.rejected", SMALL),
        "folders.entry_failed" => ("folders.entry_failed", SMALL),
        "folders.result" => ("folders.result", LARGE),
        "folders.cancel" => ("folders.cancel", SMALL),
        _ => return None,
    };
    Some(Incoming { area: Area::PhoneFiles, kind, feature: FILES, max, with_message_id: false })
}

// MARK: - The wire

/// A place: `default` or a 22-character base64url ID.
pub fn is_place_id(id: &str) -> bool {
    id == "default" || (id.len() == 22 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'))
}

/// A lowercase UUID, as folder transfer IDs are written.
fn is_wire_id(id: &str) -> bool {
    crate::crypto::is_uuid(id) && id == id.to_ascii_lowercase()
}

/// A `ref`: `{placeId, path, name}` or `{mediaId}`, as the phone resolves it.
pub fn valid_ref(r: &Value) -> bool {
    let Some(o) = r.as_object() else { return false };
    if let Some(m) = o.get("mediaId") {
        let Some(m) = m.as_str() else { return false };
        return !o.contains_key("placeId") && !m.is_empty() && m.len() <= 20 && m.bytes().all(|b| b.is_ascii_digit()) && m.parse::<i64>().is_ok();
    }
    let (Some(place), Some(path), Some(name)) = (o.get("placeId").and_then(Value::as_str), o.get("path").and_then(Value::as_str), o.get("name").and_then(Value::as_str)) else { return false };
    is_place_id(place) && folders::is_existing_path(path) && folders::is_existing_name(name)
}

fn tint(value: Option<&Value>) -> Option<u32> {
    let t = value?.as_str()?;
    (t.len() == 7 && t.starts_with('#')).then(|| u32::from_str_radix(&t[1..], 16).ok()).flatten()
}

fn bytes_of(value: Option<&Value>) -> Option<Vec<u8>> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(value?.as_str()?).ok()
}

fn optional_int(o: &Map<String, Value>, key: &str) -> Result<Option<i64>, ()> {
    match o.get(key) {
        None | Some(Value::Null) => Ok(None),
        v => integer(v).map(Some).ok_or(()),
    }
}

fn optional_str<'a>(o: &'a Map<String, Value>, key: &str) -> Result<Option<&'a str>, ()> {
    match o.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        _ => Err(()),
    }
}

fn optional_bool(o: &Map<String, Value>, key: &str) -> Result<Option<bool>, ()> {
    match o.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        _ => Err(()),
    }
}

/// One entry of a folder listing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileEntry {
    pub name: String,
    pub dir: bool,
    pub size: Option<i64>,
    pub modified: Option<i64>,
    pub mime_type: Option<String>,
    pub thumb: bool,
}

impl FileEntry {
    pub fn to_json(&self) -> Value {
        json!({"name": self.name, "dir": self.dir, "size": self.size, "modified": self.modified, "mimeType": self.mime_type, "thumb": self.thumb})
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FilesPage {
    pub request_id: String,
    pub place_id: String,
    pub path: String,
    pub entries: Vec<FileEntry>,
    pub folder_count: i64,
    pub file_count: i64,
    pub next_cursor: Option<String>,
    pub writable: bool,
}

/// `places.files_page`: at most 200 entries; an entry this device could not ask for again (not one existing
/// component) is skipped and the counts stay as sent. A field of the wrong type refuses the page.
pub fn decode_files_page(plain: &[u8]) -> Option<FilesPage> {
    let o = phone::versioned(plain, LARGE)?;
    let request_id = request_id(o.get("requestId"))?;
    let place_id = o.get("placeId")?.as_str()?.to_string();
    let path = o.get("path")?.as_str()?.to_string();
    let list = o.get("entries")?.as_array()?;
    if list.len() > MAX_LIST {
        return None;
    }
    let mut entries = Vec::new();
    for e in list {
        let e = e.as_object()?;
        let name = e.get("name")?.as_str()?;
        let dir = e.get("dir")?.as_bool()?;
        let (size, modified, mime, thumb) = (optional_int(e, "size").ok()?, optional_int(e, "modified").ok()?, optional_str(e, "mimeType").ok()?, optional_bool(e, "thumb").ok()?);
        if !folders::is_existing_name(name) {
            continue;
        }
        entries.push(FileEntry {
            name: name.to_string(),
            dir,
            size: if dir { None } else { size.map(|s| s.max(0)) },
            modified,
            mime_type: if dir { None } else { mime.map(str::to_string) },
            thumb: !dir && thumb == Some(true),
        });
    }
    let folder_count = optional_int(&o, "folderCount").ok()?.unwrap_or(entries.iter().filter(|e| e.dir).count() as i64);
    let file_count = optional_int(&o, "fileCount").ok()?.unwrap_or(entries.iter().filter(|e| !e.dir).count() as i64);
    let next_cursor = optional_str(&o, "nextCursor").ok()?.map(str::to_string);
    let writable = optional_bool(&o, "writable").ok()?.unwrap_or(false);
    Some(FilesPage { request_id, place_id, path, entries, folder_count, file_count, next_cursor, writable })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DownloadStarted {
    pub request_id: String,
    pub folder_transfer_id: String,
    pub root_name: String,
    pub file_count: i64,
    pub folder_count: i64,
    pub total_size: i64,
}

/// `places.download_started`: the folder transfer that follows, named by a lowercase UUID.
pub fn decode_download_started(plain: &[u8]) -> Option<DownloadStarted> {
    let o = phone::versioned(plain, SMALL)?;
    let request_id = request_id(o.get("requestId"))?;
    let folder_transfer_id = o.get("folderTransferId")?.as_str().filter(|i| is_wire_id(i))?.to_string();
    let root_name = o.get("rootName")?.as_str()?.to_string();
    let (file_count, folder_count, total_size) = (integer(o.get("fileCount"))?, integer(o.get("folderCount"))?, integer(o.get("totalSize"))?);
    Some(DownloadStarted { request_id, folder_transfer_id, root_name, file_count, folder_count, total_size })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Thumb {
    pub key: String,
    pub mime_type: String,
    pub width: i64,
    pub height: i64,
    pub tint: Option<u32>,
    pub data: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThumbnailsBatch {
    pub request_id: String,
    pub thumbs: Vec<Thumb>,
    /// The thumbnails this device cannot use, in order, then the batch's own missing list.
    pub missing: Vec<String>,
    pub done: bool,
}

/// `media.thumbnails_batch`: a thumbnail without a size, that is not an image, not base64 or over 24 KiB counts as
/// missing; a tint that is not "#rrggbb" is dropped.
pub fn decode_thumbnails_batch(plain: &[u8]) -> Option<ThumbnailsBatch> {
    let o = phone::versioned(plain, MEDIA_PART)?;
    let request_id = request_id(o.get("requestId"))?;
    let list = o.get("thumbs")?.as_array()?;
    let done = o.get("done")?.as_bool()?;
    let (mut thumbs, mut missing) = (Vec::new(), Vec::new());
    for t in list {
        let t = t.as_object()?;
        let key = t.get("key")?.as_str()?.to_string();
        let mime_type = t.get("mimeType")?.as_str()?.to_string();
        let (width, height) = (integer(t.get("width"))?, integer(t.get("height"))?);
        optional_str(t, "tint").ok()?;
        let data = t.get("data")?.as_str()?;
        let bytes = bytes_of(Some(&Value::String(data.to_string())));
        match bytes {
            Some(data) if data.len() <= MAX_THUMB_BYTES && width > 0 && height > 0 && mime_type.starts_with("image/") => {
                thumbs.push(Thumb { key, mime_type, width, height, tint: tint(t.get("tint")), data })
            }
            _ => missing.push(key),
        }
    }
    match o.get("missing") {
        None | Some(Value::Null) => {}
        Some(Value::Array(keys)) => missing.extend(keys.iter().filter_map(Value::as_str).map(str::to_string)),
        Some(_) => return None,
    }
    Some(ThumbnailsBatch { request_id, thumbs, missing, done })
}

/// `media.preview_part`: one part of a preview (at most 33 parts of 32 KiB) with its bytes.
pub fn decode_preview_part(plain: &[u8]) -> Option<(Value, Vec<u8>)> {
    let o = phone::versioned(plain, MEDIA_PART)?;
    request_id(o.get("requestId"))?;
    let (index, count) = (integer(o.get("index"))?, integer(o.get("count"))?);
    let mime = o.get("mimeType")?.as_str()?;
    let (width, height) = (integer(o.get("width"))?, integer(o.get("height"))?);
    let data = bytes_of(o.get("data")).filter(|d| d.len() <= MAX_PART_DATA)?;
    if !(1..=MAX_PREVIEW_PARTS).contains(&count) {
        return None;
    }
    Some((json!({"index": index, "count": count, "mimeType": mime, "width": width, "height": height, "tint": tint(o.get("tint"))}), data))
}

/// `media.range_part`: bytes of a file (at most 32 KiB) from `offset`.
pub fn decode_range_part(plain: &[u8]) -> Option<(Value, Vec<u8>)> {
    let o = phone::versioned(plain, MEDIA_PART)?;
    request_id(o.get("requestId"))?;
    let (offset, file_size) = (integer(o.get("offset"))?, integer(o.get("fileSize"))?);
    let modified = optional_int(&o, "modified").ok()?;
    let last = o.get("last")?.as_bool()?;
    let data = bytes_of(o.get("data")).filter(|d| d.len() <= MAX_PART_DATA)?;
    Some((json!({"offset": offset, "fileSize": file_size, "modified": modified, "last": last}), data))
}

pub fn media_list_request(id: &str, kind: &str, cursor: Option<&str>, limit: i64) -> Value {
    let mut v = json!({"version": 1, "requestId": id, "kind": kind, "limit": limit.clamp(1, MAX_LIST as i64)});
    if let Some(c) = cursor {
        v["cursor"] = json!(c);
    }
    v
}

pub fn media_cancel_request(id: &str) -> Value {
    json!({"version": 1, "requestId": id})
}

/// A media item of `media.page`, as this device keeps it; None when its ref or name cannot be used.
fn media_item(v: &Value) -> Option<Value> {
    let o = v.as_object()?;
    let r = o.get("ref")?;
    let name = o.get("name")?.as_str().filter(|n| !n.is_empty())?;
    if !valid_ref(r) {
        return None;
    }
    let int = |k: &str| integer(o.get(k));
    Some(json!({
        "ref": r,
        "name": name,
        "size": int("size").map(|s| s.max(0)),
        "modified": int("modified"),
        "mimeType": o.get("mimeType").and_then(Value::as_str),
        "width": int("width"),
        "height": int("height"),
        "durationMs": int("durationMs"),
        "thumb": o.get("thumb").and_then(Value::as_bool) == Some(true),
        "location": o.get("location").and_then(Value::as_str).map(|l| l.chars().take(128).collect::<String>()),
        "taken": int("taken").filter(|t| *t > 0),
    }))
}

// MARK: - State

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LaneKind {
    Browse,
    Media,
}

/// One lane's budget: requests in flight, and when each of the last 10 s went.
#[derive(Default)]
struct Lane {
    active: usize,
    sent: VecDeque<Instant>,
    queue: VecDeque<Queued>,
    pump_scheduled: bool,
}

struct Queued {
    id: String,
    kind: &'static str,
    payload: Value,
    pending: Pending,
}

#[derive(Clone, Debug)]
enum Pending {
    Places,
    List,
    Media,
    Thumbnails { keys: Vec<String> },
    Download,
}

struct Waiting {
    lane: LaneKind,
    pending: Pending,
    /// Bumped by each part of a streamed answer, so only the latest wait times out.
    generation: u64,
}

/// A download asked for: the folder it lands in, and the folder transfer once the phone has named it.
struct Download {
    folder: PathBuf,
    folder_transfer_id: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReceivePhase {
    Manifest,
    Receiving,
}

/// A folder coming in (a download, or a folder the phone sends on its own).
struct Receive {
    id: String,
    /// The download it answers; None for a folder the phone sends on its own (or, simulated, an upload to the phone).
    request: Option<String>,
    into: bool,
    offer: folders::Offer,
    assembler: folders::Assembler,
    phase: ReceivePhase,
    folder: PathBuf,
    root: PathBuf,
    root_name: String,
    top_names: HashMap<String, String>,
    dirs: HashMap<String, PathBuf>,
    failed_dirs: HashSet<String>,
    next_dir: usize,
    done_dirs: HashSet<usize>,
    done: HashSet<usize>,
    last_entry: i64,
    transfers: HashMap<u64, (usize, u64)>,
    failures: Vec<(usize, String)>,
    created_folders: usize,
    renamed: usize,
    bytes: u64,
    saved: Vec<String>,
    reported: Option<Instant>,
}

impl Receive {
    fn entries(&self) -> &[Entry] {
        &self.assembler.entries
    }
}

/// A file to send: where it is, its MIME type and its block hashes.
type Source = (PathBuf, String, crate::resume::Blocks);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SendPhase {
    Hashing,
    Offered,
    Waiting,
    Sending,
    Finishing,
}

/// A folder going out (an upload, or, simulated, a download the phone serves).
struct Send {
    id: String,
    /// The download it answers (a simulated phone), or None for an upload.
    download_request: Option<String>,
    destination: Option<(String, String)>,
    root_name: String,
    entries: Vec<Entry>,
    sources: HashMap<usize, Source>,
    phase: SendPhase,
    /// Files still to hand to the session, in entry order.
    queue: VecDeque<usize>,
    transfers: HashMap<u64, usize>,
    sent: usize,
    failures: Vec<(usize, String)>,
    bytes: u64,
    progress: HashMap<u64, u64>,
    reported: Option<Instant>,
    generation: u64,
}

impl Send {
    fn files(&self) -> usize {
        self.entries.iter().filter(|e| !e.dir).count()
    }
    fn total(&self) -> u64 {
        self.entries.iter().map(|e| e.size).sum()
    }
}

#[derive(Default)]
struct Phone {
    browse: Lane,
    media: Lane,
    waiting: HashMap<String, Waiting>,
    downloads: HashMap<String, Download>,
    receiving: HashMap<String, Receive>,
    sending: HashMap<String, Send>,
}

impl Phone {
    fn lane(&mut self, kind: LaneKind) -> &mut Lane {
        match kind {
            LaneKind::Browse => &mut self.browse,
            LaneKind::Media => &mut self.media,
        }
    }
}

/// Every phone's requests and folder transfers, by device ID, and the file transfers that belong to them.
#[derive(Default)]
pub struct State {
    phones: HashMap<String, Phone>,
    owned: HashMap<u64, (String, String)>,
}

fn with<R>(inner: &Inner, device_id: &str, f: impl FnOnce(&mut Phone) -> R) -> R {
    let mut st = inner.phone.files.lock().unwrap();
    f(st.phones.entry(device_id.to_string()).or_default())
}

fn emit(inner: &Inner, device_id: &str, what: &str, detail: Value) {
    phone::emit(inner, Area::PhoneFiles, device_id, what, 0, detail);
}

fn simulating(inner: &Inner) -> bool {
    inner.simulating.load(Ordering::Relaxed)
}

/// Files on here and there, and (for browsing) the phone serves it.
fn files_on(inner: &Inner, device_id: &str) -> bool {
    inner.policy_for(device_id).get(FILES) && inner.remote_features(device_id).is_some_and(|r| r.get(FILES))
}

fn browsable(inner: &Inner, device_id: &str) -> bool {
    files_on(inner, device_id) && inner.remote_features(device_id).is_some_and(|r| r.get(BROWSE))
}

/// An encrypted message to the device, whatever its kind (the gates are the callers').
fn send(inner: &Inner, device_id: &str, kind: &'static str, payload: &Value) -> bool {
    inner.connected_handle(device_id).is_some_and(|h| h.send_encrypted(kind, payload.to_string().into_bytes(), crate::crypto::uuid4()))
}

/// An encrypted folder message that repeats its folder transfer ID outside.
fn send_transfer(inner: &Inner, device_id: &str, kind: &'static str, payload: &Value, transfer_id: &str) -> bool {
    inner.connected_handle(device_id).is_some_and(|h| h.send_encrypted_transfer(kind, payload.to_string().into_bytes(), transfer_id.to_string()))
}

fn now_ms(t: std::time::SystemTime) -> Option<i64> {
    t.duration_since(std::time::UNIX_EPOCH).ok().map(|d| d.as_millis() as i64)
}

// MARK: - Requests and the two lanes

fn submit(inner: &Inner, device_id: &str, lane: LaneKind, kind: &'static str, payload: Value, id: &str, pending: Pending) {
    with(inner, device_id, |p| p.lane(lane).queue.push_back(Queued { id: id.to_string(), kind, payload, pending }));
    pump(inner, device_id, lane);
}

/// Sends what the lane's budget allows; the rest waits for an answer or for the window to move.
fn pump(inner: &Inner, device_id: &str, lane: LaneKind) {
    let budget = if lane == LaneKind::Browse { 40 } else { 60 };
    loop {
        let next = with(inner, device_id, |p| {
            let l = p.lane(lane);
            while l.sent.front().is_some_and(|t| t.elapsed() >= WINDOW) {
                l.sent.pop_front();
            }
            if l.queue.is_empty() || l.active >= LANE_ACTIVE {
                return Err(None);
            }
            if l.sent.len() >= budget {
                let wait = WINDOW.saturating_sub(l.sent.front().map(|t| t.elapsed()).unwrap_or_default());
                return Err((!std::mem::replace(&mut l.pump_scheduled, true)).then_some(wait));
            }
            let q = l.queue.pop_front().unwrap();
            l.active += 1;
            l.sent.push_back(Instant::now());
            p.waiting.insert(q.id.clone(), Waiting { lane, pending: q.pending.clone(), generation: 0 });
            Ok(q)
        });
        match next {
            Ok(q) => {
                if !send(inner, device_id, q.kind, &q.payload) {
                    finish(inner, device_id, &q.id);
                    fail_request(inner, device_id, &q.id, q.pending, "not_connected");
                    continue;
                }
                arm(inner, device_id, &q.id, 0);
            }
            Err(Some(wait)) => {
                let device = device_id.to_string();
                phone::after(inner, wait, move |inner| {
                    with(inner, &device, |p| p.lane(lane).pump_scheduled = false);
                    pump(inner, &device, lane);
                });
                return;
            }
            Err(None) => return,
        }
    }
}

/// The answer's 8 seconds start (again, for each part of a streamed answer).
fn arm(inner: &Inner, device_id: &str, id: &str, generation: u64) {
    let (device, id) = (device_id.to_string(), id.to_string());
    phone::after(inner, ANSWER, move |inner| {
        let timed_out = with(inner, &device, |p| p.waiting.get(&id).is_some_and(|w| w.generation == generation));
        if timed_out {
            if let Some(w) = finish(inner, &device, &id) {
                fail_request(inner, &device, &id, w.pending, "timeout");
            }
        }
    });
}

/// An answered (or failed) request leaves its lane, and the next one may go.
fn finish(inner: &Inner, device_id: &str, id: &str) -> Option<Waiting> {
    let w = with(inner, device_id, |p| {
        let w = p.waiting.remove(id)?;
        let l = p.lane(w.lane);
        l.active = l.active.saturating_sub(1);
        Some(w)
    })?;
    pump(inner, device_id, w.lane);
    Some(w)
}

fn fail_request(inner: &Inner, device_id: &str, id: &str, pending: Pending, code: &str) {
    match pending {
        Pending::Places => emit(inner, device_id, "places", json!({"requestId": id, "error": code})),
        Pending::List => emit(inner, device_id, "list", json!({"requestId": id, "error": code})),
        Pending::Media => emit(inner, device_id, "media", json!({"requestId": id, "error": code})),
        Pending::Thumbnails { keys } => emit(inner, device_id, "thumbnails", json!({"requestId": id, "thumbs": [], "missing": keys, "done": true, "error": code})),
        Pending::Download => {
            with(inner, device_id, |p| p.downloads.remove(id));
            emit(inner, device_id, "download", json!({"requestId": id, "state": "failed", "error": code}));
        }
    }
}

// MARK: - Commands

pub(crate) fn command(inner: &Inner, device_id: &str, command: &Value) -> Value {
    let str_of = |k: &str| command.get(k).and_then(Value::as_str);
    match phone::op(command) {
        Some("status") => phone::ok(json!({"available": browsable(inner, device_id), "files": files_on(inner, device_id)})),
        Some("cancel") => {
            let Some(id) = str_of("requestId") else { return phone::error("invalid") };
            if let Some(w) = finish(inner, device_id, id) {
                if w.lane == LaneKind::Media {
                    send(inner, device_id, "media.cancel", &media_cancel_request(id));
                }
            }
            with(inner, device_id, |p| {
                p.browse.queue.retain(|q| q.id != id);
                p.media.queue.retain(|q| q.id != id);
            });
            phone::ok(json!({}))
        }
        Some("cancel_download") => {
            let Some(id) = str_of("requestId") else { return phone::error("invalid") };
            cancel_receive(inner, device_id, id);
            phone::ok(json!({}))
        }
        Some("cancel_upload") => {
            let Some(id) = str_of("uploadId") else { return phone::error("invalid") };
            cancel_send(inner, device_id, id, "user");
            phone::ok(json!({}))
        }
        Some(op) => {
            if !browsable(inner, device_id) {
                return phone::error(if inner.connected_handle(device_id).is_none() { "not_connected" } else { "feature_off" });
            }
            let id = crate::crypto::uuid4();
            match op {
                "places" => submit(inner, device_id, LaneKind::Browse, "places.list", json!({"version": 1, "requestId": id, "purpose": "browse"}), &id, Pending::Places),
                "list" => {
                    let (Some(place), Some(path)) = (str_of("placeId"), str_of("path")) else { return phone::error("invalid") };
                    if !is_place_id(place) || !folders::is_existing_path(path) {
                        return phone::error("invalid");
                    }
                    let sort = str_of("sort").filter(|s| matches!(*s, "name" | "modified" | "size" | "kind")).unwrap_or("name");
                    let payload = json!({"version": 1, "requestId": id, "placeId": place, "path": path, "cursor": str_of("cursor"), "sort": sort,
                                         "descending": command.get("descending").and_then(Value::as_bool).unwrap_or(false)});
                    submit(inner, device_id, LaneKind::Browse, "places.files", payload, &id, Pending::List);
                }
                "media" => {
                    let kind = str_of("kind").filter(|k| matches!(*k, "media" | "files" | "recent")).unwrap_or("media");
                    let limit = command.get("limit").and_then(Value::as_i64).unwrap_or(100);
                    submit(inner, device_id, LaneKind::Browse, "media.list", media_list_request(&id, kind, str_of("cursor"), limit), &id, Pending::Media);
                }
                "thumbnails" => {
                    let items: Vec<Value> = command.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
                    let ok = |i: &Value| {
                        i.get("key").and_then(Value::as_str).is_some_and(|k| (1..=64).contains(&k.len()) && k.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
                            && i.get("ref").is_some_and(valid_ref)
                    };
                    if items.is_empty() || items.len() > MAX_THUMB_ITEMS || !items.iter().all(ok) {
                        return phone::error("invalid");
                    }
                    let keys = items.iter().map(|i| i["key"].as_str().unwrap().to_string()).collect();
                    let size = command.get("size").and_then(Value::as_i64).unwrap_or(256).clamp(64, 512);
                    let mut payload = json!({"version": 1, "requestId": id, "items": items, "size": size});
                    if let Some(r) = str_of("replaces") {
                        payload["replaces"] = json!(r);
                        // The phone drops the earlier one once this is accepted; so does this device.
                        if let Some(w) = finish(inner, device_id, r) {
                            fail_request(inner, device_id, r, w.pending, "cancelled");
                        }
                    }
                    submit(inner, device_id, LaneKind::Media, "media.thumbnails", payload, &id, Pending::Thumbnails { keys });
                }
                "download" => {
                    let items: Vec<Value> = command.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
                    if items.is_empty() || items.len() > MAX_DOWNLOAD_ITEMS || !items.iter().all(valid_ref) {
                        return phone::error("invalid");
                    }
                    let folder = str_of("folder").map(PathBuf::from).or_else(|| inner.receive_dir());
                    let Some(folder) = folder else { return phone::error("no_folder") };
                    with(inner, device_id, |p| p.downloads.insert(id.clone(), Download { folder: folder.clone(), folder_transfer_id: None }));
                    submit(inner, device_id, LaneKind::Browse, "places.download", json!({"version": 1, "requestId": id, "items": items}), &id, Pending::Download);
                    return phone::ok(json!({"requestId": id}));
                }
                "upload" => return upload(inner, device_id, command),
                _ => return phone::error("invalid"),
            }
            phone::ok(json!({"requestId": id}))
        }
        None => phone::error("invalid"),
    }
}

// MARK: - Answers from the phone

pub(crate) fn receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) {
    match kind {
        "places.listed" => {
            let Some(o) = phone::versioned(plain, LARGE) else { return };
            let Some(id) = request_id(o.get("requestId")) else { return };
            if finish(inner, device_id, &id).is_none() {
                return;
            }
            let places: Vec<Value> = o
                .get("places")
                .and_then(Value::as_array)
                .map(|l| {
                    l.iter()
                        .filter(|p| p.get("placeId").and_then(Value::as_str).is_some_and(is_place_id))
                        .map(|p| json!({"placeId": p["placeId"], "label": p.get("label").and_then(Value::as_str).map(|l| l.chars().take(64).collect::<String>()), "available": p.get("available").and_then(Value::as_bool).unwrap_or(false), "freeBytes": integer(p.get("freeBytes"))}))
                        .collect()
                })
                .unwrap_or_default();
            let media = o.get("media").and_then(Value::as_str).filter(|m| matches!(*m, "full" | "partial" | "none")).unwrap_or("none");
            emit(inner, device_id, "places", json!({"requestId": id, "places": places, "writable": boolean(o.get("writable")) == Some(true), "media": media, "documents": boolean(o.get("documents")) == Some(true)}));
        }
        "places.error" => {
            let Some(o) = phone::versioned(plain, SMALL) else { return };
            let Some(id) = request_id(o.get("requestId")) else { return };
            let code = o.get("code").and_then(Value::as_str).filter(|c| c.len() <= 32).unwrap_or("io_error").to_string();
            if let Some(w) = finish(inner, device_id, &id) {
                fail_request(inner, device_id, &id, w.pending, &code);
            }
        }
        "places.files_page" => {
            let Some(page) = decode_files_page(plain) else { return };
            if finish(inner, device_id, &page.request_id).is_none() {
                return;
            }
            let entries: Vec<Value> = page.entries.iter().map(FileEntry::to_json).collect();
            emit(
                inner,
                device_id,
                "list",
                json!({"requestId": page.request_id, "placeId": page.place_id, "path": page.path, "entries": entries, "folderCount": page.folder_count,
                       "fileCount": page.file_count, "nextCursor": page.next_cursor, "writable": page.writable}),
            );
        }
        "media.page" => {
            let Some(o) = phone::versioned(plain, LARGE) else { return };
            let Some(id) = request_id(o.get("requestId")) else { return };
            let Some(list) = o.get("items").and_then(Value::as_array).filter(|l| l.len() <= MAX_LIST) else { return };
            if finish(inner, device_id, &id).is_none() {
                return;
            }
            let items: Vec<Value> = list.iter().filter_map(media_item).collect();
            let access = o.get("access").and_then(Value::as_str).filter(|a| matches!(*a, "full" | "partial" | "none")).unwrap_or("none");
            emit(
                inner,
                device_id,
                "media",
                json!({"requestId": id, "kind": o.get("kind").and_then(Value::as_str), "items": items, "nextCursor": o.get("nextCursor").and_then(Value::as_str),
                       "access": access, "indexing": boolean(o.get("indexing")) == Some(true)}),
            );
        }
        "media.thumbnails_batch" => {
            use base64::Engine;
            let Some(batch) = decode_thumbnails_batch(plain) else { return };
            let ours = with(inner, device_id, |p| match p.waiting.get_mut(&batch.request_id) {
                Some(w) if matches!(w.pending, Pending::Thumbnails { .. }) => {
                    w.generation += 1;
                    Some(w.generation)
                }
                _ => None,
            });
            let Some(generation) = ours else { return };
            if batch.done {
                finish(inner, device_id, &batch.request_id);
            } else {
                arm(inner, device_id, &batch.request_id, generation);
            }
            let thumbs: Vec<Value> = batch
                .thumbs
                .iter()
                .map(|t| json!({"key": t.key, "mimeType": t.mime_type, "width": t.width, "height": t.height, "tint": t.tint, "data": base64::engine::general_purpose::STANDARD.encode(&t.data)}))
                .collect();
            emit(inner, device_id, "thumbnails", json!({"requestId": batch.request_id, "thumbs": thumbs, "missing": batch.missing, "done": batch.done}));
        }
        "places.download_started" => {
            let Some(s) = decode_download_started(plain) else { return };
            if finish(inner, device_id, &s.request_id).is_none() {
                return;
            }
            let known = with(inner, device_id, |p| p.downloads.get_mut(&s.request_id).map(|d| d.folder_transfer_id = Some(s.folder_transfer_id.clone())).is_some());
            if known {
                emit(
                    inner,
                    device_id,
                    "download",
                    json!({"requestId": s.request_id, "state": "started", "rootName": s.root_name, "files": s.file_count, "folders": s.folder_count, "total": s.total_size}),
                );
            }
        }
        "folders.offer" => folder_offer(inner, device_id, plain),
        "folders.manifest" => folder_manifest(inner, device_id, plain),
        "folders.complete" => folder_complete(inner, device_id, plain),
        "folders.cancel" => folder_cancelled(inner, device_id, plain),
        "folders.waiting" | "folders.accept" | "folders.rejected" | "folders.entry_failed" | "folders.result" => send_answer(inner, device_id, kind, plain),
        _ => {}
    }
}

// MARK: - Receiving a folder (downloads)

fn folder_id_of(o: &Map<String, Value>) -> Option<String> {
    o.get("folderTransferId").and_then(Value::as_str).filter(|i| is_wire_id(i)).map(str::to_string)
}

/// Refuses a folder before anything is written: outer `folders.rejected` with its code.
fn reject(inner: &Inner, device_id: &str, id: &str, code: &str, entry: Option<usize>, needed: Option<u64>, free: Option<u64>) {
    let mut v = json!({"version": 1, "folderTransferId": id, "code": code});
    if let Some(e) = entry {
        v["entry"] = json!(e);
    }
    if let (Some(n), Some(f)) = (needed, free) {
        v["neededBytes"] = json!(n);
        v["freeBytes"] = json!(f);
    }
    send_transfer(inner, device_id, "folders.rejected", &v, id);
    let r = with(inner, device_id, |p| p.receiving.remove(id));
    if let Some(r) = r {
        end_receive(inner, device_id, &r, "failed", Some(code));
    }
}

fn folder_offer(inner: &Inner, device_id: &str, plain: &[u8]) {
    let Some(o) = phone::versioned(plain, SMALL) else { return };
    let Some(id) = folder_id_of(&o) else { return };
    let int = |k: &str| non_negative(o.get(k));
    let root_name = o.get("rootName").and_then(Value::as_str).unwrap_or("").to_string();
    let (Some(files), Some(dirs), Some(total), Some(pages)) = (int("fileCount"), int("folderCount"), int("totalSize"), int("pageCount")) else {
        return reject(inner, device_id, &id, "invalid_message", None, None, None);
    };
    let Some(digest) = o.get("manifestSha256").and_then(Value::as_str).map(str::to_string) else { return reject(inner, device_id, &id, "invalid_message", None, None, None) };
    if with(inner, device_id, |p| p.receiving.contains_key(&id)) {
        return;
    }
    if !files_on(inner, device_id) {
        return reject(inner, device_id, &id, "policy", None, None, None);
    }
    if !folders::is_portable(&root_name) || files as usize > folders::MAX_FILES || dirs as usize > folders::MAX_FOLDERS || total as u64 > folders::MAX_TOTAL_SIZE || pages as usize > folders::MAX_PAGES {
        return reject(inner, device_id, &id, "limit_exceeded", None, None, None);
    }
    // Nothing here keeps a journal yet: a resumed folder starts again from the phone.
    if boolean(o.get("resume")) == Some(true) {
        return reject(inner, device_id, &id, "resume_unavailable", None, None, None);
    }
    let into = boolean(o.get("into")) == Some(true);
    let request = o.get("downloadRequestId").and_then(Value::as_str).map(str::to_string);
    // Where it lands: the download's folder; a folder the phone sends on its own goes to the receive folder; a
    // simulated phone takes uploads into its receive folder.
    let folder = match (&request, into) {
        (Some(r), true) => match with(inner, device_id, |p| p.downloads.get(r).map(|d| d.folder.clone())) {
            Some(f) => f,
            None => return reject(inner, device_id, &id, "policy", None, None, None),
        },
        (None, true) if simulating(inner) && o.get("destination").is_some() => match inner.receive_dir() {
            Some(f) => f,
            None => return reject(inner, device_id, &id, "place_unavailable", None, None, None),
        },
        (None, false) => match inner.receive_dir() {
            Some(f) => f,
            None => return reject(inner, device_id, &id, "policy", None, None, None),
        },
        _ => return reject(inner, device_id, &id, "policy", None, None, None),
    };
    let offer = folders::Offer {
        folder_transfer_id: id.clone(),
        root_name: root_name.clone(),
        file_count: files as usize,
        folder_count: dirs as usize,
        total_size: total as u64,
        page_count: pages as usize,
        manifest_sha256: digest,
    };
    let mut r = Receive {
        id: id.clone(),
        request: request.filter(|_| into),
        into,
        assembler: folders::Assembler::new(offer.clone()),
        offer,
        phase: ReceivePhase::Manifest,
        root: folder.clone(),
        folder,
        root_name,
        top_names: HashMap::new(),
        dirs: HashMap::new(),
        failed_dirs: HashSet::new(),
        next_dir: 0,
        done_dirs: HashSet::new(),
        done: HashSet::new(),
        last_entry: -1,
        transfers: HashMap::new(),
        failures: vec![],
        created_folders: 0,
        renamed: 0,
        bytes: 0,
        saved: vec![],
        reported: None,
    };
    let immediate = r.assembler.without_pages();
    with(inner, device_id, |p| p.receiving.insert(id.clone(), r));
    match immediate {
        Some(Ok(())) => prepare(inner, device_id, &id),
        Some(Err((code, entry))) => reject(inner, device_id, &id, &code, entry, None, None),
        None => {
            let (device, folder) = (device_id.to_string(), id.clone());
            phone::after(inner, FIRST_ANSWER, move |inner| {
                if with(inner, &device, |p| p.receiving.get(&folder).is_some_and(|r| r.phase == ReceivePhase::Manifest)) {
                    reject(inner, &device, &folder, "timeout", None, None, None);
                }
            });
        }
    }
}

fn folder_manifest(inner: &Inner, device_id: &str, plain: &[u8]) {
    let Some(o) = phone::versioned(plain, LARGE) else { return };
    let Some(id) = folder_id_of(&o) else { return };
    let (Some(page), Some(entries)) = (integer(o.get("page")), o.get("entries").and_then(Value::as_array)) else {
        return reject(inner, device_id, &id, "invalid_manifest", None, None, None);
    };
    let result = with(inner, device_id, |p| {
        let r = p.receiving.get_mut(&id).filter(|r| r.phase == ReceivePhase::Manifest)?;
        r.assembler.add(&id, page, entries, plain.len())
    });
    match result {
        Some(Ok(())) => prepare(inner, device_id, &id),
        Some(Err((code, entry))) => reject(inner, device_id, &id, &code, entry, None, None),
        None => {}
    }
}

/// The names in a folder, by case key: what a new name may not take.
fn listing(dir: &Path) -> HashSet<String> {
    std::fs::read_dir(dir).map(|d| d.filter_map(|e| e.ok()).map(|e| folders::case_key(&e.file_name().to_string_lossy())).collect()).unwrap_or_default()
}

/// The manifest is complete: room is checked and the destination made ready, then `folders.accept`.
fn prepare(inner: &Inner, device_id: &str, id: &str) {
    let Some((folder, total, into, root_name, tops)) = with(inner, device_id, |p| {
        let r = p.receiving.get(id)?;
        let tops: Vec<(String, bool)> = r.entries().iter().filter(|e| !e.path.contains('/')).map(|e| (e.path.clone(), e.dir)).collect();
        Some((r.folder.clone(), r.offer.total_size, r.into, r.root_name.clone(), tops))
    }) else {
        return;
    };
    if std::fs::create_dir_all(&folder).is_err() || !folder.is_dir() {
        return reject(inner, device_id, id, "place_unavailable", None, None, None);
    }
    let free = crate::transfer::free_space(&folder);
    if let Some(free) = free {
        if free < total.saturating_add(SPACE_MARGIN) {
            return reject(inner, device_id, id, "insufficient_space", None, Some(total + SPACE_MARGIN), Some(free));
        }
    }
    let mut taken = listing(&folder);
    let mut top_names = HashMap::new();
    let (root, final_root, choice) = if into {
        // Downloads never merge or overwrite: a clashing top-level item becomes a copy.
        for (name, dir) in tops {
            let chosen = folders::first_free(&name, dir, |k| taken.contains(k));
            taken.insert(folders::case_key(&chosen));
            if chosen != name {
                top_names.insert(name, chosen);
            }
        }
        (folder.clone(), root_name.clone(), "none")
    } else {
        let chosen = folders::first_free(&root_name, true, |k| taken.contains(k));
        let root = folder.join(&chosen);
        if std::fs::create_dir(&root).is_err() {
            return reject(inner, device_id, id, "place_unavailable", None, None, None);
        }
        let choice = if chosen == root_name { "none" } else { "new_folder" };
        (root, chosen, choice)
    };
    let label: String = folder.to_string_lossy().chars().take(128).collect();
    let ok = with(inner, device_id, |p| {
        let Some(r) = p.receiving.get_mut(id) else { return false };
        r.phase = ReceivePhase::Receiving;
        r.root = root.clone();
        r.root_name = final_root.clone();
        r.dirs.insert(String::new(), root.clone());
        if !into {
            r.created_folders += 1;
            r.saved.push(root.to_string_lossy().into_owned());
        }
        r.top_names = top_names;
        true
    });
    if !ok {
        return;
    }
    let mut accept = json!({"version": 1, "folderTransferId": id, "rootName": final_root, "destinationLabel": label, "choice": choice});
    if let Some(f) = free {
        accept["freeBytes"] = json!(f);
    }
    send(inner, device_id, "folders.accept", &accept);
    report_receive(inner, device_id, id, true);
}

/// Before file entry `limit`, every folder entry above it exists (an existing folder of the name is used; a file of
/// the name keeps both, the folder numbered).
fn ensure_dirs(r: &mut Receive, limit: usize) {
    while r.next_dir < limit.min(r.entries().len()) {
        let index = r.next_dir;
        r.next_dir += 1;
        let e = r.entries()[index].clone();
        if !e.dir || r.done_dirs.contains(&index) {
            continue;
        }
        let parent_path = folders::parent(&e.path).to_string();
        let Some(parent) = r.dirs.get(&parent_path).cloned().filter(|_| !r.failed_dirs.contains(&parent_path)) else {
            r.failed_dirs.insert(e.path.clone());
            r.failures.push((index, "io_error".into()));
            continue;
        };
        let top = parent_path.is_empty();
        let leaf = if top { r.top_names.get(&e.path).cloned().unwrap_or(e.path.clone()) } else { folders::leaf(&e.path).to_string() };
        let existing = parent.join(&leaf);
        let path = if existing.is_dir() && !(r.into && top) && !std::fs::symlink_metadata(&existing).is_ok_and(|m| m.file_type().is_symlink()) {
            existing
        } else {
            let taken = listing(&parent);
            let name = if taken.contains(&folders::case_key(&leaf)) { folders::first_free(&leaf, true, |k| taken.contains(k)) } else { leaf };
            let path = parent.join(&name);
            if std::fs::create_dir(&path).is_err() {
                r.failed_dirs.insert(e.path.clone());
                r.failures.push((index, "io_error".into()));
                continue;
            }
            r.created_folders += 1;
            if top {
                r.saved.push(path.to_string_lossy().into_owned());
            }
            path
        };
        r.dirs.insert(e.path.clone(), path);
        r.done_dirs.insert(index);
    }
}

/// The session's question for a file of a folder: where it lands, under a name nothing has.
pub(crate) fn folder_entry(inner: &Inner, device_id: &str, offer: &FolderEntryOffer) -> Option<FolderTarget> {
    let transfer = inner.next_id();
    let answer = with(inner, device_id, |p| {
        let r = p.receiving.get_mut(&offer.folder_transfer_id)?;
        let fail = |code: &str| Some(Err(code.to_string()));
        if r.phase != ReceivePhase::Receiving {
            return fail("invalid_message");
        }
        let Ok(index) = usize::try_from(offer.entry) else { return fail("invalid_message") };
        let Some(e) = r.entries().get(index).cloned() else { return fail("invalid_message") };
        if e.dir || offer.entry <= r.last_entry || offer.path != e.path || offer.name != folders::leaf(&e.path) || offer.size != e.size || offer.sha256 != e.sha256 {
            return fail("invalid_message");
        }
        r.last_entry = offer.entry;
        ensure_dirs(r, index);
        let parent_path = folders::parent(&e.path).to_string();
        let Some(parent) = r.dirs.get(&parent_path).cloned().filter(|_| !r.failed_dirs.contains(&parent_path)) else { return fail("io_error") };
        let top = parent_path.is_empty();
        let leaf = if top { r.top_names.get(&e.path).cloned().unwrap_or(e.path.clone()) } else { folders::leaf(&e.path).to_string() };
        let taken = listing(&parent);
        let name = folders::first_free(&leaf, false, |k| taken.contains(k));
        if name != folders::leaf(&e.path) {
            r.renamed += 1;
        }
        r.transfers.insert(transfer, (index, 0));
        Some(Ok((parent, name, index)))
    });
    match answer? {
        Ok((dir, name, _)) => {
            inner.phone.files.lock().unwrap().owned.insert(transfer, (device_id.to_string(), offer.folder_transfer_id.clone()));
            Some(FolderTarget { dir, name, transfer })
        }
        Err(code) => {
            let failed = json!({"version": 1, "folderTransferId": offer.folder_transfer_id, "entry": offer.entry, "transferId": offer.transfer_id, "code": code});
            send(inner, device_id, "folders.entry_failed", &failed);
            with(inner, device_id, |p| {
                if let (Some(r), Ok(index)) = (p.receiving.get_mut(&offer.folder_transfer_id), usize::try_from(offer.entry)) {
                    r.failures.push((index, code));
                }
            });
            None
        }
    }
}

pub(crate) fn owns(inner: &Inner, transfer: u64) -> bool {
    inner.phone.files.lock().unwrap().owned.contains_key(&transfer)
}

/// A file event of a transfer that belongs to a folder here.
pub(crate) fn file_event(inner: &Inner, event: crate::session::Event) {
    use crate::session::Event as E;
    let transfer = match &event {
        E::FileIncoming { transfer, .. } | E::FileProgress { transfer, .. } | E::FileDone { transfer, .. } | E::FileFailed { transfer, .. } => *transfer,
        _ => return,
    };
    let Some((device_id, folder)) = inner.phone.files.lock().unwrap().owned.get(&transfer).cloned() else { return };
    if matches!(event, E::FileDone { .. } | E::FileFailed { .. }) {
        inner.phone.files.lock().unwrap().owned.remove(&transfer);
    }
    let receiving = with(inner, &device_id, |p| p.receiving.contains_key(&folder));
    if receiving {
        let force = with(inner, &device_id, |p| {
            let Some(r) = p.receiving.get_mut(&folder) else { return false };
            match event {
                E::FileProgress { bytes, .. } => {
                    if let Some((_, seen)) = r.transfers.get_mut(&transfer) {
                        r.bytes += bytes.saturating_sub(*seen);
                        *seen = bytes;
                    }
                    false
                }
                E::FileDone { path, size, .. } => {
                    if let Some((index, seen)) = r.transfers.remove(&transfer) {
                        r.bytes += size.saturating_sub(seen);
                        r.done.insert(index);
                        if !r.entries()[index].path.contains('/') {
                            if let Some(p) = path {
                                r.saved.push(p);
                            }
                        }
                    }
                    true
                }
                E::FileFailed { reason, .. } => {
                    if let Some((index, seen)) = r.transfers.remove(&transfer) {
                        r.bytes = r.bytes.saturating_sub(seen);
                        let code = match reason.as_str() {
                            "verification_failed" => "verification_failed",
                            "storage" => "io_error",
                            "cancelled" | "cancelled_remote" => "cancelled",
                            _ => "interrupted",
                        };
                        r.failures.push((index, code.into()));
                    }
                    true
                }
                _ => false,
            }
        });
        let too_many = with(inner, &device_id, |p| p.receiving.get(&folder).is_some_and(|r| r.failures.len() >= MAX_FAILURES));
        if too_many {
            return cancel_receive_folder(inner, &device_id, &folder, "error", Some("too_many_failures"));
        }
        return report_receive(inner, &device_id, &folder, force);
    }
    send_file_event(inner, &device_id, &folder, transfer, event);
}

/// Progress of a folder coming in, at most four times a second (or now).
fn report_receive(inner: &Inner, device_id: &str, id: &str, force: bool) {
    let detail = with(inner, device_id, |p| {
        let r = p.receiving.get_mut(id)?;
        if !force && r.reported.is_some_and(|t| t.elapsed() < PROGRESS_EVERY) {
            return None;
        }
        r.reported = Some(Instant::now());
        Some(receive_json(r, "receiving", None))
    });
    if let Some(d) = detail {
        emit(inner, device_id, "download", d);
    }
}

fn receive_json(r: &Receive, state: &str, error: Option<&str>) -> Value {
    json!({
        "requestId": r.request.clone().unwrap_or_else(|| r.id.clone()),
        "folderTransferId": r.id,
        "pushed": r.request.is_none(),
        "state": state,
        "rootName": r.root_name,
        "folder": r.folder.to_string_lossy(),
        "files": r.offer.file_count,
        "filesDone": r.done.len(),
        "failed": r.failures.len(),
        "bytes": r.bytes,
        "total": r.offer.total_size,
        "saved": r.saved,
        "renamed": r.renamed,
        "error": error,
    })
}

/// A folder coming in ended. Its files still running stay this area's until their last event (a cancel's own end), so
/// the host never hears about them as ordinary files.
fn end_receive(inner: &Inner, device_id: &str, r: &Receive, state: &str, error: Option<&str>) {
    {
        let mut st = inner.phone.files.lock().unwrap();
        if let Some(req) = &r.request {
            if let Some(p) = st.phones.get_mut(device_id) {
                p.downloads.remove(req);
            }
        }
    }
    emit(inner, device_id, "download", receive_json(r, state, error));
}

fn folder_complete(inner: &Inner, device_id: &str, plain: &[u8]) {
    let Some(o) = phone::versioned(plain, LARGE) else { return };
    let Some(id) = folder_id_of(&o) else { return };
    // The sender's own failures, as it reported them.
    let theirs: Vec<(usize, String)> = o
        .get("failed")
        .and_then(Value::as_array)
        .map(|l| l.iter().filter_map(|f| Some((non_negative(f.get("entry"))? as usize, f.get("code")?.as_str()?.to_string()))).collect())
        .unwrap_or_default();
    let their_count = non_negative(o.get("failedCount")).unwrap_or(theirs.len() as i64) as usize;
    let Some(r) = with(inner, device_id, |p| {
        let r = p.receiving.get_mut(&id).filter(|r| r.phase == ReceivePhase::Receiving)?;
        let n = r.entries().len();
        ensure_dirs(r, n);
        p.receiving.remove(&id)
    }) else {
        return;
    };
    let files: Vec<usize> = (0..r.entries().len()).filter(|i| !r.entries()[*i].dir).collect();
    let dirs: Vec<usize> = (0..r.entries().len()).filter(|i| r.entries()[*i].dir).collect();
    let complete = files.iter().all(|i| r.done.contains(i)) && dirs.iter().all(|i| r.done_dirs.contains(i));
    let saved_bytes: u64 = r.done.iter().map(|i| r.entries()[*i].size).sum();
    let failed: Vec<Value> = r.failures.iter().chain(theirs.iter()).take(folders::MAX_REPORTED_FAILURES).map(|(e, c)| json!({"entry": e, "code": c})).collect();
    let result = json!({
        "version": 1, "folderTransferId": id, "status": if complete { "complete" } else { "incomplete" }, "savedFiles": r.done.len(),
        "savedBytes": saved_bytes, "createdFolders": r.created_folders, "renamedFiles": r.renamed, "replacedFiles": 0,
        "failedCount": r.failures.len() + their_count, "failed": failed,
    });
    send(inner, device_id, "folders.result", &result);
    end_receive(inner, device_id, &r, if complete { "done" } else { "incomplete" }, None);
}

/// The phone cancelled a folder in either direction.
fn folder_cancelled(inner: &Inner, device_id: &str, plain: &[u8]) {
    let Some(o) = phone::versioned(plain, SMALL) else { return };
    let Some(id) = folder_id_of(&o) else { return };
    let code = o.get("code").and_then(Value::as_str).unwrap_or("cancelled").to_string();
    if let Some(h) = inner.connected_handle(device_id) {
        h.send_outer("folders.cancel.ack", id.clone());
    }
    if let Some(r) = with(inner, device_id, |p| p.receiving.remove(&id)) {
        for t in r.transfers.keys() {
            inner.cancel_transfer(*t);
        }
        let state = if r.done.is_empty() { "cancelled" } else { "incomplete" };
        return end_receive(inner, device_id, &r, state, Some(&code));
    }
    if let Some(s) = with(inner, device_id, |p| p.sending.remove(&id)) {
        for t in s.transfers.keys() {
            inner.cancel_transfer(*t);
        }
        end_send(inner, device_id, &s, "cancelled", Some(&code), None);
    }
}

/// Cancel here: the download asked for, or the folder coming in.
fn cancel_receive(inner: &Inner, device_id: &str, request: &str) {
    if let Some(w) = finish(inner, device_id, request) {
        fail_request(inner, device_id, request, w.pending, "cancelled");
        return;
    }
    let folder = with(inner, device_id, |p| {
        let d = p.downloads.remove(request);
        d.and_then(|d| d.folder_transfer_id).or_else(|| p.receiving.contains_key(request).then(|| request.to_string()))
    });
    match folder {
        Some(f) if with(inner, device_id, |p| p.receiving.contains_key(&f)) => cancel_receive_folder(inner, device_id, &f, "user", None),
        _ => emit(inner, device_id, "download", json!({"requestId": request, "state": "cancelled"})),
    }
}

fn cancel_receive_folder(inner: &Inner, device_id: &str, folder: &str, reason: &str, code: Option<&str>) {
    let Some(r) = with(inner, device_id, |p| p.receiving.remove(folder)) else { return };
    let mut v = json!({"version": 1, "folderTransferId": folder, "reason": reason});
    if let Some(c) = code {
        v["code"] = json!(c);
    }
    send_transfer(inner, device_id, "folders.cancel", &v, folder);
    for t in r.transfers.keys() {
        inner.cancel_transfer(*t);
    }
    let state = if code.is_some() { "incomplete" } else if r.done.is_empty() { "cancelled" } else { "incomplete" };
    end_receive(inner, device_id, &r, state, code.or(Some("cancelled")));
}

// MARK: - Sending a folder (uploads)

fn upload(inner: &Inner, device_id: &str, command: &Value) -> Value {
    let (Some(place), Some(path)) = (command.get("placeId").and_then(Value::as_str), command.get("path").and_then(Value::as_str)) else { return phone::error("invalid") };
    if !is_place_id(place) || !folders::is_existing_path(path) {
        return phone::error("invalid");
    }
    let files: Vec<(PathBuf, String)> = command
        .get("files")
        .and_then(Value::as_array)
        .map(|l| {
            l.iter()
                .filter_map(|f| {
                    let p = PathBuf::from(f.get("path")?.as_str()?);
                    let name = f.get("name").and_then(Value::as_str).map(str::to_string).or_else(|| p.file_name().map(|n| n.to_string_lossy().into_owned()))?;
                    Some((p, name))
                })
                .collect()
        })
        .unwrap_or_default();
    if files.is_empty() || files.len() > folders::MAX_FILES || files.iter().any(|(p, _)| !p.is_file()) {
        return phone::error("invalid");
    }
    let id = crate::crypto::uuid4();
    start_send(inner, device_id, &id, None, Some((place.to_string(), path.to_string())), files.into_iter().map(|(p, n)| (n, Some(p))).collect());
    phone::ok(json!({"uploadId": id}))
}

/// Names the items (portable, clashes numbered), hashes the files off the session's threads, then offers the folder.
/// Items are top-level files, or folders (`None`) and the files inside them by path (a simulated phone's downloads).
fn start_send(inner: &Inner, device_id: &str, id: &str, download_request: Option<String>, destination: Option<(String, String)>, items: Vec<(String, Option<PathBuf>)>) {
    let s = Send {
        id: id.to_string(),
        download_request: download_request.clone(),
        destination,
        root_name: String::new(),
        entries: vec![],
        sources: HashMap::new(),
        phase: SendPhase::Hashing,
        queue: VecDeque::new(),
        transfers: HashMap::new(),
        sent: 0,
        failures: vec![],
        bytes: 0,
        progress: HashMap::new(),
        reported: None,
        generation: 0,
    };
    with(inner, device_id, |p| p.sending.insert(id.to_string(), s));
    if download_request.is_none() {
        emit(inner, device_id, "upload", json!({"uploadId": id, "state": "hashing"}));
    }
    // Top-level names made portable; clashes among them numbered (the sender's rule).
    let names: Vec<(String, bool)> = items.iter().filter(|(n, _)| !n.contains('/')).map(|(n, p)| (folders::portable_name(n), p.is_none())).collect();
    let resolved: HashMap<usize, String> = folders::resolve_siblings(&names).into_iter().collect();
    let mut top_index = 0;
    let mut renamed: HashMap<String, String> = HashMap::new();
    let mut named: Vec<(String, Option<PathBuf>)> = Vec::new();
    for (name, path) in items {
        if name.contains('/') {
            named.push((name, path));
        } else {
            let final_name = resolved.get(&top_index).cloned().unwrap_or(name.clone());
            renamed.insert(name.clone(), final_name.clone());
            named.push((final_name, path));
            top_index += 1;
        }
    }
    // Paths under a renamed top-level folder follow it.
    for (name, _) in named.iter_mut().filter(|(n, _)| n.contains('/')) {
        let (top, rest) = name.split_once('/').unwrap();
        if let Some(r) = renamed.get(top) {
            *name = format!("{r}/{rest}");
        }
    }
    named.sort_by(|a, b| {
        if a.0 == b.0 {
            std::cmp::Ordering::Equal
        } else if folders::precedes(&a.0, &b.0) {
            std::cmp::Ordering::Less
        } else {
            std::cmp::Ordering::Greater
        }
    });
    let (device, id) = (device_id.to_string(), id.to_string());
    let me = std::sync::Arc::downgrade(&inner.arc());
    inner.rt.spawn(async move {
        let hashed = tokio::task::spawn_blocking(move || {
            named
                .into_iter()
                .map(|(name, path)| match path {
                    None => Ok((Entry { dir: true, path: name, size: 0, sha256: String::new(), modified: None }, None)),
                    Some(p) => {
                        let (sha256, size, blocks) = crate::resume::hash_file(&p)?;
                        let modified = std::fs::metadata(&p).and_then(|m| m.modified()).ok().and_then(now_ms);
                        let mime = crate::transfer::mime_for(&name).to_string();
                        Ok((Entry { dir: false, path: name, size, sha256, modified }, Some((p, mime, blocks))))
                    }
                })
                .collect::<std::io::Result<Vec<_>>>()
        })
        .await;
        let Some(inner) = me.upgrade() else { return };
        match hashed {
            Ok(Ok(list)) => offer_folder(&inner, &device, &id, list),
            _ => {
                if let Some(s) = with(&inner, &device, |p| p.sending.remove(&id)) {
                    end_send(&inner, &device, &s, "failed", Some("unreadable"), None);
                }
            }
        }
    });
}

fn offer_folder(inner: &Inner, device_id: &str, id: &str, list: Vec<(Entry, Option<Source>)>) {
    let entries: Vec<Entry> = list.iter().map(|(e, _)| e.clone()).collect();
    let root_name = entries.first().map(|e| e.path.split('/').next().unwrap_or("").to_string()).unwrap_or_default();
    let total: u64 = entries.iter().map(|e| e.size).sum();
    let (files, dirs) = (entries.iter().filter(|e| !e.dir).count(), entries.iter().filter(|e| e.dir).count());
    let pages = folders::pages(id, &entries);
    let ready = with(inner, device_id, |p| {
        let s = p.sending.get_mut(id)?;
        s.root_name = root_name.clone();
        s.entries = entries.clone();
        for (i, (_, source)) in list.into_iter().enumerate() {
            if let Some(src) = source {
                s.sources.insert(i, src);
            }
        }
        s.phase = SendPhase::Offered;
        s.generation += 1;
        Some((s.download_request.clone(), s.destination.clone(), s.generation))
    });
    let Some((request, destination, generation)) = ready else { return };
    let Some(pages) = pages.filter(|_| total <= folders::MAX_TOTAL_SIZE && files <= folders::MAX_FILES && dirs <= folders::MAX_FOLDERS) else {
        if let Some(s) = with(inner, device_id, |p| p.sending.remove(id)) {
            end_send(inner, device_id, &s, "failed", Some("limit_exceeded"), None);
        }
        return;
    };
    let mut offer = json!({
        "version": 1, "folderTransferId": id, "rootName": root_name, "fileCount": files, "folderCount": dirs, "totalSize": total,
        "pageCount": pages.len(), "manifestSha256": folders::manifest_digest(&root_name, &entries), "resume": false, "into": true,
    });
    if let Some((place, path)) = destination {
        offer["destination"] = json!({"placeId": place, "path": path});
    }
    if let Some(r) = request {
        offer["downloadRequestId"] = json!(r);
    }
    let mut sent = send_transfer(inner, device_id, "folders.offer", &offer, id);
    for page in &pages {
        sent &= send(inner, device_id, "folders.manifest", page);
    }
    if !sent {
        if let Some(s) = with(inner, device_id, |p| p.sending.remove(id)) {
            end_send(inner, device_id, &s, "failed", Some("not_connected"), None);
        }
        return;
    }
    report_send(inner, device_id, id, true);
    wait_send(inner, device_id, id, generation, FIRST_ANSWER);
}

/// The phone has `delay` to answer (its first answer, a question it asks, or the result).
fn wait_send(inner: &Inner, device_id: &str, id: &str, generation: u64, delay: Duration) {
    let (device, folder) = (device_id.to_string(), id.to_string());
    phone::after(inner, delay, move |inner| {
        let stale = with(inner, &device, |p| p.sending.get(&folder).is_some_and(|s| s.generation == generation && s.phase != SendPhase::Sending));
        if stale {
            let finishing = with(inner, &device, |p| p.sending.get(&folder).is_some_and(|s| s.phase == SendPhase::Finishing));
            if finishing {
                // The files went; only the phone's account of them is missing.
                if let Some(s) = with(inner, &device, |p| p.sending.remove(&folder)) {
                    let state = if s.failures.is_empty() { "done" } else { "incomplete" };
                    end_send(inner, &device, &s, state, None, None);
                }
            } else {
                cancel_send(inner, &device, &folder, "timeout");
            }
        }
    });
}

fn send_answer(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) {
    let Some(o) = phone::versioned(plain, LARGE) else { return };
    let Some(id) = folder_id_of(&o) else { return };
    if !with(inner, device_id, |p| p.sending.contains_key(&id)) {
        return;
    }
    match kind {
        "folders.waiting" => {
            let generation = with(inner, device_id, |p| {
                let s = p.sending.get_mut(&id)?;
                (s.phase == SendPhase::Offered || s.phase == SendPhase::Waiting).then(|| {
                    s.phase = SendPhase::Waiting;
                    s.generation += 1;
                    s.generation
                })
            });
            if let Some(g) = generation {
                report_send(inner, device_id, &id, true);
                wait_send(inner, device_id, &id, g, QUESTION);
            }
        }
        "folders.accept" => {
            let accepted = with(inner, device_id, |p| {
                let s = p.sending.get_mut(&id).filter(|s| s.phase == SendPhase::Offered || s.phase == SendPhase::Waiting)?;
                s.phase = SendPhase::Sending;
                s.generation += 1;
                s.queue = (0..s.entries.len()).filter(|i| !s.entries[*i].dir).collect();
                Some(())
            });
            if accepted.is_some() {
                report_send(inner, device_id, &id, true);
                send_next(inner, device_id, &id);
            }
        }
        "folders.rejected" => {
            let code = o.get("code").and_then(Value::as_str).unwrap_or("policy").to_string();
            if let Some(s) = with(inner, device_id, |p| p.sending.remove(&id)) {
                for t in s.transfers.keys() {
                    inner.cancel_transfer(*t);
                }
                end_send(inner, device_id, &s, "failed", Some(&code), None);
            }
        }
        "folders.entry_failed" => {
            let (Some(entry), Some(code)) = (non_negative(o.get("entry")), o.get("code").and_then(Value::as_str)) else { return };
            let transfer = with(inner, device_id, |p| {
                let s = p.sending.get_mut(&id)?;
                let t = s.transfers.iter().find(|(_, e)| **e == entry as usize).map(|(t, _)| *t)?;
                s.transfers.remove(&t);
                s.failures.push((entry as usize, code.to_string()));
                Some(t)
            });
            if let Some(t) = transfer {
                // The phone drops the rest of this file: it stops here too (its end is still this folder's), and the next goes.
                inner.cancel_transfer(t);
                send_next(inner, device_id, &id);
            }
        }
        "folders.result" => {
            let Some(s) = with(inner, device_id, |p| p.sending.remove(&id)) else { return };
            let complete = o.get("status").and_then(Value::as_str) == Some("complete");
            let result = json!({"savedFiles": non_negative(o.get("savedFiles")), "renamedFiles": non_negative(o.get("renamedFiles")), "failedCount": non_negative(o.get("failedCount"))});
            end_send(inner, device_id, &s, if complete { "done" } else { "incomplete" }, None, Some(result));
        }
        _ => {}
    }
}

/// Hands the folder's next file to the session (one at a time: the session sends them in order anyway, and its queue
/// stays short); when none is left and none is going, the folder is complete.
fn send_next(inner: &Inner, device_id: &str, id: &str) {
    loop {
        let next = with(inner, device_id, |p| {
            let s = p.sending.get_mut(id).filter(|s| s.phase == SendPhase::Sending)?;
            if !s.transfers.is_empty() {
                return Some(None);
            }
            let Some(index) = s.queue.pop_front() else { return Some(Some(None)) };
            let e = s.entries[index].clone();
            let source = s.sources.get(&index).map(|(p, m, b)| (p.clone(), m.clone(), crate::resume::Blocks(b.0.clone())));
            Some(Some(Some((index, e, source))))
        });
        let Some(Some(next)) = next else { return };
        let Some((index, e, source)) = next else { return all_sent(inner, device_id, id) };
        let Some((path, mime, blocks)) = source else { continue };
        let transfer = inner.next_id();
        {
            let mut st = inner.phone.files.lock().unwrap();
            st.owned.insert(transfer, (device_id.to_string(), id.to_string()));
            if let Some(s) = st.phones.get_mut(device_id).and_then(|p| p.sending.get_mut(id)) {
                s.transfers.insert(transfer, index);
            }
        }
        let file = OutgoingFile {
            transfer,
            path,
            name: folders::leaf(&e.path).to_string(),
            mime,
            size: e.size,
            sha256: e.sha256.clone(),
            blocks,
            folder: Some(FolderFile { folder_transfer_id: id.to_string(), entry: index as u64, path: e.path.clone() }),
        };
        if inner.send_hashed_file(device_id, file) {
            return;
        }
        inner.phone.files.lock().unwrap().owned.remove(&transfer);
        with(inner, device_id, |p| {
            if let Some(s) = p.sending.get_mut(id) {
                s.transfers.remove(&transfer);
                s.failures.push((index, "interrupted".into()));
            }
        });
    }
}

/// A file of a folder going out moved, finished or failed.
fn send_file_event(inner: &Inner, device_id: &str, folder: &str, transfer: u64, event: crate::session::Event) {
    use crate::session::Event as E;
    let ended = with(inner, device_id, |p| {
        let s = p.sending.get_mut(folder)?;
        match event {
            E::FileProgress { bytes, .. } => {
                let seen = s.progress.entry(transfer).or_insert(0);
                s.bytes += bytes.saturating_sub(*seen);
                *seen = bytes;
                Some(false)
            }
            E::FileDone { size, .. } => {
                s.transfers.remove(&transfer)?;
                let seen = s.progress.remove(&transfer).unwrap_or(0);
                s.bytes += size.saturating_sub(seen);
                s.sent += 1;
                Some(true)
            }
            E::FileFailed { reason, .. } => {
                let index = s.transfers.remove(&transfer)?;
                s.bytes = s.bytes.saturating_sub(s.progress.remove(&transfer).unwrap_or(0));
                s.failures.push((index, if reason == "changed" { "source_changed".into() } else { "io_error".into() }));
                Some(true)
            }
            _ => Some(false),
        }
    });
    match ended {
        Some(true) => {
            report_send(inner, device_id, folder, true);
            send_next(inner, device_id, folder);
        }
        Some(false) => report_send(inner, device_id, folder, false),
        None => {}
    }
}

/// Every file went or failed: `folders.complete`, then the phone's result within 30 s.
fn all_sent(inner: &Inner, device_id: &str, id: &str) {
    let Some((sent, failures, generation)) = with(inner, device_id, |p| {
        let s = p.sending.get_mut(id)?;
        s.phase = SendPhase::Finishing;
        s.generation += 1;
        Some((s.sent, s.failures.clone(), s.generation))
    }) else {
        return;
    };
    let failed: Vec<Value> = failures.iter().take(folders::MAX_REPORTED_FAILURES).map(|(e, c)| json!({"entry": e, "code": c})).collect();
    send(inner, device_id, "folders.complete", &json!({"version": 1, "folderTransferId": id, "sentFiles": sent, "failedCount": failures.len(), "failed": failed}));
    report_send(inner, device_id, id, true);
    wait_send(inner, device_id, id, generation, RESULT);
}

fn report_send(inner: &Inner, device_id: &str, id: &str, force: bool) {
    let detail = with(inner, device_id, |p| {
        let s = p.sending.get_mut(id)?;
        if s.download_request.is_some() || (!force && s.reported.is_some_and(|t| t.elapsed() < PROGRESS_EVERY)) {
            return None;
        }
        s.reported = Some(Instant::now());
        let state = match s.phase {
            SendPhase::Hashing => "hashing",
            SendPhase::Offered => "offered",
            SendPhase::Waiting => "waiting",
            SendPhase::Sending => "sending",
            SendPhase::Finishing => "finishing",
        };
        Some(send_json(s, state, None, None))
    });
    if let Some(d) = detail {
        emit(inner, device_id, "upload", d);
    }
}

fn send_json(s: &Send, state: &str, error: Option<&str>, result: Option<Value>) -> Value {
    json!({
        "uploadId": s.id, "state": state, "rootName": s.root_name, "files": s.files(), "filesDone": s.sent, "failed": s.failures.len(),
        "bytes": s.bytes, "total": s.total(), "error": error, "result": result,
        "destination": s.destination.as_ref().map(|(place, path)| json!({"placeId": place, "path": path})),
    })
}

fn end_send(inner: &Inner, device_id: &str, s: &Send, state: &str, error: Option<&str>, result: Option<Value>) {
    if s.download_request.is_none() {
        emit(inner, device_id, "upload", send_json(s, state, error, result));
    }
}

/// Cancel here (or a wait that ran out): `folders.cancel`, and the files still going stop.
fn cancel_send(inner: &Inner, device_id: &str, id: &str, reason: &str) {
    let Some(s) = with(inner, device_id, |p| p.sending.remove(id)) else { return };
    let code = if reason == "timeout" { "timeout" } else { "cancelled" };
    if s.phase != SendPhase::Hashing {
        send_transfer(inner, device_id, "folders.cancel", &json!({"version": 1, "folderTransferId": id, "reason": reason, "code": code}), id);
    }
    for t in s.transfers.keys() {
        inner.cancel_transfer(*t);
    }
    end_send(inner, device_id, &s, if reason == "timeout" { "failed" } else { "cancelled" }, Some(code), None);
}

// MARK: - Lifecycle

pub(crate) fn features_changed(inner: &Inner, device_id: &str) {
    if simulating(inner) {
        return;
    }
    emit(inner, device_id, "status", json!({"available": browsable(inner, device_id), "files": files_on(inner, device_id)}));
}

/// The session ended: requests in flight fail, folders stop where they are (the files saved stay).
pub(crate) fn disconnected(inner: &Inner, device_id: &str) {
    let phone = inner.phone.files.lock().unwrap().phones.remove(device_id);
    let Some(p) = phone else { return };
    for (id, w) in p.waiting {
        fail_request(inner, device_id, &id, w.pending, "not_connected");
    }
    for q in p.browse.queue.into_iter().chain(p.media.queue) {
        fail_request(inner, device_id, &q.id, q.pending, "not_connected");
    }
    for (_, r) in p.receiving {
        end_receive(inner, device_id, &r, "interrupted", Some("interrupted"));
    }
    for (_, s) in p.sending {
        end_send(inner, device_id, &s, "interrupted", Some("interrupted"), None);
    }
    for (id, d) in p.downloads {
        if d.folder_transfer_id.is_some() {
            emit(inner, device_id, "download", json!({"requestId": id, "state": "interrupted", "error": "interrupted"}));
        }
    }
    if !simulating(inner) {
        emit(inner, device_id, "status", json!({"available": false, "files": false}));
    }
}

pub(crate) fn forgotten(inner: &Inner, device_id: &str) {
    disconnected(inner, device_id);
}

// MARK: - A simulated phone (sim.rs): its part is in phone_files/sim.rs, outside the kinds this device speaks.

mod sim;
pub(crate) use sim::{sim_incoming, sim_receive};

#[cfg(test)]
mod tests;
