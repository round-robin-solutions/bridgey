//! Resuming a file from its last verified chunk (draft `files_resume_draft1`, docs/protocol.md "Resuming files" and
//! docs/file-resume.md): the receiver's record of each partial it keeps, the rules for keeping and finding one, the
//! prefix hash both ends compare, and the two messages. The session (session.rs) runs the exchange; this module has no
//! network code. Checked against protocol/test-vectors/files-resume-v1.json.

use crate::crypto::{self, b64, unb64};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

/// The feature key: a capability, advertised whenever this client supports it.
pub const FEATURE: &str = "files_resume_draft1";
/// A resume offset is a whole number of these (or the whole file), so a sender can check it against the hashes it kept
/// while hashing the file for the offer, without reading the file again. Only larger files are offered resumable.
pub const BLOCK: u64 = 1024 * 1024;
/// A kept partial lives until 24 hours after it last grew (the folders journal's window).
pub const LIFETIME_MS: u64 = 24 * 60 * 60 * 1000;
/// Kept partials per device and in all; a new one pushes out the oldest.
pub const PER_PEER: usize = 4;
pub const TOTAL: usize = 16;
/// Verified bytes kept in all; above it the oldest partials not in use go. Two of the largest files fit.
pub const MAX_KEPT_BYTES: u64 = 20 * 1024 * 1024 * 1024;
/// The receiver writes its record at least this often while a resumable file comes in, so a crash loses at most this.
pub const CHECKPOINT_EVERY: u64 = 64 * 1024 * 1024;
/// `files.resume` and `files.resume.ack` plaintexts.
pub const MAX_MESSAGE: usize = 1024;
/// The storage key of the records (the host's private storage).
pub const STORAGE_KEY: &str = "file-resume";

/// One kept partial: whose file it is, how much of it is verified, and where it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    /// The device that sent it (authenticated), lowercase.
    pub peer: String,
    /// The offer's size and base64 SHA-256: the file's content identity.
    pub size: u64,
    pub sha256: String,
    /// Verified bytes: on stable storage before this record named them.
    pub length: u64,
    /// Base64 SHA-256 of those bytes.
    pub prefix: String,
    /// The receive folder the partial is in, and its hidden file name there.
    pub dir: PathBuf,
    pub part: String,
    /// The offered name (made safe), only to notice a changed source.
    pub name: String,
    /// When it last grew or was kept (Unix ms).
    pub updated: u64,
}

impl Record {
    pub fn part_path(&self) -> PathBuf {
        self.dir.join(&self.part)
    }

    fn expired(&self, now: u64) -> bool {
        // A stamp far in the future means the clock went back: it counts as expired too.
        now >= self.updated.saturating_add(LIFETIME_MS) || self.updated > now.saturating_add(LIFETIME_MS)
    }

    fn to_json(&self) -> Value {
        json!({
            "peer": self.peer, "size": self.size, "sha256": self.sha256, "length": self.length, "prefix": self.prefix,
            "dir": self.dir.to_string_lossy(), "part": self.part, "name": self.name, "updated": self.updated,
        })
    }

    fn from_json(v: &Value) -> Option<Record> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        let n = |k: &str| v.get(k).and_then(Value::as_u64);
        let r = Record {
            peer: s("peer")?.to_ascii_lowercase(),
            size: n("size")?,
            sha256: s("sha256")?,
            length: n("length")?,
            prefix: s("prefix")?,
            dir: PathBuf::from(s("dir")?),
            part: s("part")?,
            name: s("name").unwrap_or_default(),
            updated: n("updated")?,
        };
        let hash = |h: &str| unb64(h).is_some_and(|b| b.len() == 32);
        (crypto::is_uuid(&r.peer) && hash(&r.sha256) && hash(&r.prefix) && r.length <= r.size && valid_part(&r.part)).then_some(r)
    }
}

/// Only names this client gives partials: `.bridgey-<uuid>.part`, never a path, so a damaged record cannot point a
/// deletion anywhere else.
pub fn valid_part(name: &str) -> bool {
    name.strip_prefix(".bridgey-").and_then(|r| r.strip_suffix(".part")).is_some_and(crypto::is_uuid)
}

/// The receiver's kept partials. Pure bookkeeping: the caller deletes the part files it returns and persists `encode`.
#[derive(Default)]
pub struct Store {
    records: Vec<Record>,
    /// Part files a transfer is using now; never swept, evicted or claimed twice.
    claimed: HashSet<PathBuf>,
}

impl Store {
    pub fn decode(bytes: &[u8]) -> Store {
        let records = serde_json::from_slice::<Value>(bytes)
            .ok()
            .filter(|v| v.get("version").and_then(Value::as_u64) == Some(1))
            .and_then(|v| v.get("records").and_then(Value::as_array).map(|a| a.iter().filter_map(Record::from_json).take(TOTAL * 2).collect()))
            .unwrap_or_default();
        Store { records, claimed: HashSet::new() }
    }

    pub fn encode(&self) -> Vec<u8> {
        json!({"version": 1, "records": self.records.iter().map(Record::to_json).collect::<Vec<_>>()}).to_string().into_bytes()
    }

    pub fn records(&self) -> &[Record] {
        &self.records
    }

    fn take(&mut self, keep: impl Fn(&Record) -> bool) -> Vec<PathBuf> {
        let mut gone = Vec::new();
        self.records.retain(|r| {
            let k = keep(r);
            if !k {
                gone.push(r.part_path());
            }
            k
        });
        gone
    }

    /// At start: drops what can no longer be resumed (expired, nothing verified, the part file missing or shorter
    /// than its record). Returns the part files to delete.
    pub fn sweep(&mut self, now: u64, part_length: impl Fn(&Path) -> Option<u64>) -> Vec<PathBuf> {
        self.take(|r| !r.expired(now) && r.length > 0 && part_length(&r.part_path()).is_some_and(|l| l >= r.length))
    }

    fn expire(&mut self, now: u64) -> Vec<PathBuf> {
        let claimed = std::mem::take(&mut self.claimed);
        let gone = self.take(|r| claimed.contains(&r.part_path()) || !r.expired(now));
        self.claimed = claimed;
        gone
    }

    /// A resumable offer from `peer`: the partial to resume, claimed until released, and the part files to delete.
    /// Only a record from the same device with the same size and SHA-256 matches, in the folder files land in now.
    /// Unclaimed records from that device with the same name but other content are dropped: its source changed.
    pub fn claim(&mut self, peer: &str, size: u64, sha256: &str, name: &str, dir: &Path, now: u64) -> (Option<Record>, Vec<PathBuf>) {
        let peer = peer.to_ascii_lowercase();
        let mut gone = self.expire(now);
        let claimed = std::mem::take(&mut self.claimed);
        let same = |r: &Record| r.peer == peer && r.size == size && r.sha256 == sha256;
        let found = self.records.iter().find(|r| !claimed.contains(&r.part_path()) && same(r) && r.length > 0 && r.dir == dir).cloned();
        let keep_part = found.as_ref().map(Record::part_path);
        gone.extend(self.take(|r| {
            let free = !claimed.contains(&r.part_path()) && keep_part.as_ref() != Some(&r.part_path());
            let stale = r.peer == peer && (same(r) || (!name.is_empty() && r.name == name));
            !(free && stale)
        }));
        self.claimed = claimed;
        if let Some(p) = keep_part {
            self.claimed.insert(p);
        }
        (found, gone)
    }

    /// Saves a record, new or updated (matched by its part file), stamped `now` and claimed. Over the limits the oldest
    /// unclaimed records go. Returns the part files to delete.
    pub fn save(&mut self, mut record: Record, now: u64) -> Vec<PathBuf> {
        record.peer = record.peer.to_ascii_lowercase();
        record.updated = now;
        let part = record.part_path();
        self.claimed.insert(part.clone());
        match self.records.iter_mut().find(|r| r.part_path() == part) {
            Some(r) => *r = record.clone(),
            None => self.records.push(record.clone()),
        }
        let mut gone = self.expire(now);
        loop {
            let of_peer = self.records.iter().filter(|r| r.peer == record.peer).count();
            let over_peer = of_peer > PER_PEER;
            let bytes: u64 = self.records.iter().map(|r| r.length).sum();
            if !over_peer && self.records.len() <= TOTAL && bytes <= MAX_KEPT_BYTES {
                break;
            }
            let oldest = self
                .records
                .iter()
                .enumerate()
                .filter(|(_, r)| !self.claimed.contains(&r.part_path()) && (!over_peer || r.peer == record.peer))
                .min_by_key(|(_, r)| r.updated)
                .map(|(i, _)| i);
            match oldest {
                Some(i) => gone.push(self.records.remove(i).part_path()),
                // Everything left is in use: over the limit until a transfer ends.
                None => break,
            }
        }
        gone
    }

    /// The transfer using this partial ended: its record stays for a later attempt (`keep`) or goes. True when a
    /// record went.
    pub fn release(&mut self, part: &Path, keep: bool) -> bool {
        self.claimed.remove(part);
        let before = self.records.len();
        if !keep {
            self.records.retain(|r| r.part_path() != part);
        }
        self.records.len() != before
    }

    /// The device was unpaired: its partials go. Returns the part files to delete.
    pub fn forget(&mut self, peer: &str) -> Vec<PathBuf> {
        let peer = peer.to_ascii_lowercase();
        let claimed = self.claimed.clone();
        self.take(|r| r.peer != peer || claimed.contains(&r.part_path()))
    }
}

/// A running SHA-256 that remembers the prefix hash at every `BLOCK` boundary it passes: the last one (a receiver's
/// checkpoint) or all of them (a sender's, to check a `files.resume` without reading the file again).
#[derive(Clone)]
pub struct Running {
    ctx: ring::digest::Context,
    length: u64,
    last: (u64, [u8; 32]),
    all: Option<Vec<[u8; 32]>>,
}

fn finish(ctx: &ring::digest::Context) -> [u8; 32] {
    ctx.clone().finish().as_ref().try_into().expect("SHA-256")
}

impl Running {
    pub fn new(keep_all: bool) -> Running {
        let ctx = ring::digest::Context::new(&ring::digest::SHA256);
        let empty = finish(&ctx);
        Running { ctx, length: 0, last: (0, empty), all: keep_all.then(Vec::new) }
    }

    /// Continues from a verified prefix of `length` bytes (a block boundary or the whole file).
    pub fn resumed(ctx: ring::digest::Context, length: u64, digest: [u8; 32]) -> Running {
        Running { ctx, length, last: (length, digest), all: None }
    }

    pub fn update(&mut self, mut data: &[u8]) {
        while !data.is_empty() {
            let to_boundary = BLOCK - self.length % BLOCK;
            let n = usize::try_from(to_boundary).unwrap_or(usize::MAX).min(data.len());
            self.ctx.update(&data[..n]);
            self.length += n as u64;
            data = &data[n..];
            if self.length.is_multiple_of(BLOCK) {
                let digest = finish(&self.ctx);
                self.last = (self.length, digest);
                if let Some(all) = self.all.as_mut() {
                    all.push(digest);
                }
            }
        }
    }

    pub fn length(&self) -> u64 {
        self.length
    }

    /// What a receiver may record of a file of `size` bytes: the whole file once it is all here, else the last block
    /// boundary, with the SHA-256 of the bytes before it.
    pub fn checkpoint(&self, size: u64) -> (u64, [u8; 32]) {
        if self.length == size {
            (size, finish(&self.ctx))
        } else {
            self.last
        }
    }

    pub fn finish(self) -> [u8; 32] {
        finish(&self.ctx)
    }

    /// The prefix hashes at every block boundary, for `Blocks`.
    pub fn blocks(&self) -> Blocks {
        Blocks(self.all.clone().unwrap_or_default())
    }
}

/// A sender's prefix hashes at every 1 MiB boundary of a file, from the pass that hashed it for the offer.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Blocks(pub Vec<[u8; 32]>);

impl std::fmt::Debug for Blocks {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "Blocks({})", self.0.len())
    }
}

impl Blocks {
    /// The SHA-256 of the first `offset` bytes, when `offset` is a block boundary inside the file.
    pub fn prefix(&self, offset: u64) -> Option<&[u8; 32]> {
        let i = usize::try_from(offset / BLOCK).ok()?.checked_sub(1)?;
        offset.is_multiple_of(BLOCK).then(|| self.0.get(i)).flatten()
    }
}

/// The base64 SHA-256 of a file, its size and its block hashes, read in 256 KiB pieces.
pub fn hash_file(path: &Path) -> io::Result<(String, u64, Blocks)> {
    let mut file = File::open(path)?;
    let mut running = Running::new(true);
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = match file.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        running.update(&buf[..n]);
    }
    let (size, blocks) = (running.length(), running.blocks());
    Ok((b64(&running.finish()), size, blocks))
}

/// What a sender answers to a `files.resume` for its file of `size` bytes with SHA-256 `sha256`: the offset to go on
/// from (the receiver's, or 0) and, for 0, why (`invalid` or `mismatch`).
pub fn sender_answer(plain: &[u8], transfer_id: &str, size: u64, sha256: &[u8], blocks: &Blocks) -> (u64, Option<&'static str>) {
    let Some((offset, prefix)) = parse_resume(plain, transfer_id, size) else { return (0, Some("invalid")) };
    let ours: Option<&[u8]> = if offset == size { Some(sha256) } else { blocks.prefix(offset).map(|p| p.as_slice()) };
    match ours {
        Some(h) if crypto::ct_eq(h, &prefix) => (offset, None),
        _ => (0, Some("mismatch")),
    }
}

/// SHA-256 of a file's first `length` bytes, read in 256 KiB pieces, and the running hash to continue from there.
/// Fails when the file is shorter.
pub fn hash_prefix(path: &Path, length: u64) -> io::Result<(ring::digest::Context, [u8; 32])> {
    hash_prefix_of(&mut File::open(path)?, length)
}

/// [hash_prefix] through an open handle, from byte zero: the receiver re-reads the very file it will write to, never
/// whatever the path names by then.
pub fn hash_prefix_of(file: &mut File, length: u64) -> io::Result<(ring::digest::Context, [u8; 32])> {
    use std::io::Seek;
    file.seek(io::SeekFrom::Start(0))?;
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buf = vec![0u8; 256 * 1024];
    let mut left = length;
    while left > 0 {
        let want = buf.len().min(usize::try_from(left).unwrap_or(usize::MAX));
        let n = match file.read(&mut buf[..want]) {
            Ok(0) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "shorter than its record")),
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        ctx.update(&buf[..n]);
        left -= n as u64;
    }
    let digest: [u8; 32] = ctx.clone().finish().as_ref().try_into().expect("SHA-256");
    Ok((ctx, digest))
}

/// An integral JSON number (both apps accept 1 and 1.0), never negative.
fn integer(v: Option<&Value>) -> Option<u64> {
    let n = v?.as_number()?;
    n.as_u64().or_else(|| n.as_f64().filter(|f| f.fract() == 0.0 && *f >= 0.0 && *f < 9.007e15).map(|f| f as u64))
}

fn object<'a>(plain: &'a [u8], transfer_id: &str, holder: &'a mut Option<Value>) -> Option<&'a serde_json::Map<String, Value>> {
    if plain.len() > MAX_MESSAGE {
        return None;
    }
    *holder = serde_json::from_slice::<Value>(plain).ok();
    let o = holder.as_ref()?.as_object()?;
    (integer(o.get("version")) == Some(1) && o.get("transferId").and_then(Value::as_str) == Some(transfer_id)).then_some(o)
}

/// `files.resume`: the receiver has the first `offset` bytes and this is their SHA-256.
pub fn resume_payload(transfer_id: &str, offset: u64, prefix: &[u8]) -> Vec<u8> {
    json!({"version": 1, "transferId": transfer_id, "offset": offset, "prefixSha256": b64(prefix)}).to_string().into_bytes()
}

/// A `files.resume` for this transfer of `size` bytes: the offset (a positive whole number of blocks not above `size`,
/// or `size` itself) and the prefix hash, or None.
pub fn parse_resume(plain: &[u8], transfer_id: &str, size: u64) -> Option<(u64, [u8; 32])> {
    let mut holder = None;
    let o = object(plain, transfer_id, &mut holder)?;
    let offset = integer(o.get("offset")).filter(|n| (1..=size).contains(n) && (n.is_multiple_of(BLOCK) || *n == size))?;
    let prefix: [u8; 32] = o.get("prefixSha256").and_then(Value::as_str).and_then(unb64)?.try_into().ok()?;
    Some((offset, prefix))
}

/// `files.resume.ack`: the sender continues from `offset` (the receiver's) or from byte zero, saying why.
pub fn ack_payload(transfer_id: &str, offset: u64, reason: Option<&str>) -> Vec<u8> {
    let mut v = json!({"version": 1, "transferId": transfer_id, "offset": offset});
    if let Some(r) = reason {
        v["reason"] = Value::from(r);
    }
    v.to_string().into_bytes()
}

/// A `files.resume.ack` answering an offer of `proposed` bytes: `proposed` or 0, or None for anything else.
pub fn parse_ack(plain: &[u8], transfer_id: &str, proposed: u64) -> Option<u64> {
    let mut holder = None;
    let o = object(plain, transfer_id, &mut holder)?;
    integer(o.get("offset")).filter(|n| *n == proposed || *n == 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PEER: &str = "7e57d00d-0000-4000-8000-0000000000aa";
    const OTHER: &str = "7e57d00d-0000-4000-8000-0000000000bb";

    fn vectors() -> Value {
        serde_json::from_str(&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/files-resume-v1.json")).unwrap()).unwrap()
    }

    fn pattern(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i * 31 % 251) as u8).collect()
    }

    fn sha(data: &[u8]) -> String {
        b64(ring::digest::digest(&ring::digest::SHA256, data).as_ref())
    }

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("bridgey-resume-{tag}-{}", crypto::uuid4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn record(peer: &str, n: u64, updated: u64, dir: &Path) -> Record {
        Record {
            peer: peer.into(),
            size: 1000 + n,
            sha256: sha(&n.to_be_bytes()),
            length: 10,
            prefix: sha(b"x"),
            dir: dir.to_path_buf(),
            part: format!(".bridgey-{}.part", crypto::uuid4()),
            name: format!("file{n}.bin"),
            updated,
        }
    }

    /// The source both platforms build: `pattern` bytes of `size`.
    fn source(v: &Value) -> Vec<u8> {
        assert_eq!(v["source"]["pattern"], "byte i is (i * 31) mod 251");
        pattern(v["source"]["size"].as_u64().unwrap() as usize)
    }

    #[test]
    fn prefix_hashes_match_the_vectors() {
        let v = vectors();
        let data = source(&v);
        assert_eq!(sha(&data), v["source"]["sha256"].as_str().unwrap());
        let dir = temp("prefix");
        let path = dir.join("source.bin");
        std::fs::write(&path, &data).unwrap();
        for p in v["prefixes"].as_array().unwrap() {
            let n = p["offset"].as_u64().unwrap();
            let (ctx, digest) = hash_prefix(&path, n).unwrap();
            assert_eq!(b64(&digest), p["prefixSha256"].as_str().unwrap(), "prefix {n}");
            // The running hash continues to the whole file's SHA-256.
            let mut ctx = ctx;
            ctx.update(&data[n as usize..]);
            assert_eq!(b64(ctx.finish().as_ref()), v["source"]["sha256"].as_str().unwrap(), "continued from {n}");
        }
        assert!(hash_prefix(&path, data.len() as u64 + 1).is_err(), "a file shorter than the record fails");
        // The sender's pass keeps the same hashes at every block, and the receiver's running hash checkpoints at them.
        let (whole, size, blocks) = hash_file(&path).unwrap();
        assert_eq!((whole.as_str(), size), (v["source"]["sha256"].as_str().unwrap(), data.len() as u64));
        assert_eq!(blocks.0.len() as u64, size / BLOCK);
        let mut running = Running::new(false);
        for (i, piece) in data.chunks(24 * 1024 + 7).enumerate() {
            running.update(piece);
            let (at, digest) = running.checkpoint(size);
            assert!(at == size || at.is_multiple_of(BLOCK), "piece {i}: a checkpoint is a block boundary or the whole file");
            assert_eq!(digest, hash_prefix(&path, at).unwrap().1);
        }
        for p in v["prefixes"].as_array().unwrap() {
            let n = p["offset"].as_u64().unwrap();
            let expected = p["prefixSha256"].as_str().unwrap();
            let kept = if n == size { unb64(&whole) } else { blocks.prefix(n).map(|b| b.to_vec()) };
            assert_eq!(kept.map(|b| b64(&b)).as_deref(), Some(expected), "block hash at {n}");
        }
        assert!(blocks.prefix(BLOCK + 1).is_none() && blocks.prefix(0).is_none() && blocks.prefix(4 * BLOCK).is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn resume_payloads_decode_as_the_vectors_say() {
        let v = vectors();
        let mut checked = 0;
        for c in v["resumePayload"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            let plain = match (&c["plaintext"], c["plaintextString"].as_str()) {
                (_, Some(s)) => s.as_bytes().to_vec(),
                (p, None) => p.to_string().into_bytes(),
            };
            let got = parse_resume(&plain, c["transferId"].as_str().unwrap(), c["size"].as_u64().unwrap());
            match &c["expect"] {
                Value::String(s) if s == "invalid" => assert!(got.is_none(), "{name} is invalid"),
                exp => {
                    let (offset, prefix) = got.unwrap_or_else(|| panic!("{name} decodes"));
                    assert_eq!(offset, exp["offset"].as_u64().unwrap(), "{name}");
                    assert_eq!(b64(&prefix), exp["prefixSha256"].as_str().unwrap(), "{name}");
                    if c["write"] == Value::Bool(true) {
                        let written: Value = serde_json::from_slice(&resume_payload(c["transferId"].as_str().unwrap(), offset, &prefix)).unwrap();
                        assert_eq!(written, c["plaintext"], "{name} writes the same fields");
                    }
                }
            }
            checked += 1;
        }
        assert!(checked >= 10);
    }

    #[test]
    fn acks_decode_as_the_vectors_say() {
        let v = vectors();
        for c in v["ackPayload"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            let plain = match c["plaintextString"].as_str() {
                Some(s) => s.as_bytes().to_vec(),
                None => c["plaintext"].to_string().into_bytes(),
            };
            let got = parse_ack(&plain, c["transferId"].as_str().unwrap(), c["proposed"].as_u64().unwrap());
            match c["expect"].as_str().unwrap() {
                "invalid" => assert_eq!(got, None, "{name}"),
                "resume" => assert_eq!(got, c["proposed"].as_u64(), "{name}"),
                "restart" => assert_eq!(got, Some(0), "{name}"),
                other => panic!("{name}: {other}"),
            }
            if c["write"] == Value::Bool(true) {
                let p = &c["plaintext"];
                let written: Value = serde_json::from_slice(&ack_payload(p["transferId"].as_str().unwrap(), p["offset"].as_u64().unwrap(), p["reason"].as_str())).unwrap();
                assert_eq!(&written, p, "{name} writes the same fields");
            }
        }
    }

    /// The receiver's decision for an offer, from its record and what is on disk: resume at an offset or start at zero.
    #[test]
    fn receiver_decisions_follow_the_vectors() {
        let v = vectors();
        let data = source(&v);
        for c in v["receiverDecision"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            let dir = temp("decide");
            let r = &c["record"];
            let part = format!(".bridgey-{}.part", crypto::uuid4());
            let mut on_disk = data[..r["partLength"].as_u64().unwrap() as usize].to_vec();
            if let Some(i) = r["flipByte"].as_u64() {
                on_disk[i as usize] ^= 0xFF;
            }
            if r["partExists"] != Value::Bool(false) {
                std::fs::write(dir.join(&part), &on_disk).unwrap();
            }
            let rec = Record {
                peer: r["peer"].as_str().unwrap().into(),
                size: r["size"].as_u64().unwrap(),
                sha256: r["sha256"].as_str().unwrap().into(),
                length: r["length"].as_u64().unwrap(),
                prefix: r["prefixSha256"].as_str().unwrap().into(),
                dir: dir.clone(),
                part: part.clone(),
                name: r["name"].as_str().unwrap().into(),
                updated: 0,
            };
            let mut store = Store::default();
            store.save(rec.clone(), r["updatedMs"].as_u64().unwrap());
            store.release(&rec.part_path(), true);
            let now = c["nowMs"].as_u64().unwrap();
            let o = &c["offer"];
            let restarted = c["afterRestart"] == Value::Bool(true);
            if restarted {
                let reloaded = Store::decode(&store.encode());
                store = reloaded;
                let gone = store.sweep(now, |p| std::fs::metadata(p).ok().map(|m| m.len()));
                for p in gone {
                    let _ = std::fs::remove_file(p);
                }
            }
            let (found, _) = store.claim(o["peer"].as_str().unwrap(), o["size"].as_u64().unwrap(), o["sha256"].as_str().unwrap(), o["name"].as_str().unwrap(), &dir, now);
            // What the session does with a claimed record: re-read its prefix and compare.
            let verified = found.and_then(|f| hash_prefix(&f.part_path(), f.length).ok().filter(|(_, d)| b64(d) == f.prefix).map(|_| f.length));
            let exp = &c["expect"];
            assert_eq!(verified, exp["resumeAt"].as_u64(), "{name}: resume offset");
            if let Some(dropped) = exp["dropsRecord"].as_bool() {
                assert_eq!(!store.records().iter().any(|x| x.part == part), dropped, "{name}: the record is dropped");
            }
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    /// The sender's answer to a files.resume, from its own file.
    #[test]
    fn sender_decisions_follow_the_vectors() {
        let v = vectors();
        let data = source(&v);
        let dir = temp("sender");
        for c in v["senderDecision"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            let mut file = data.clone();
            if let Some(i) = c["senderFlipByte"].as_u64() {
                file[i as usize] ^= 0xFF;
            }
            if let Some(n) = c["senderLength"].as_u64() {
                file.truncate(n as usize);
            }
            let path = dir.join("source.bin");
            std::fs::write(&path, &file).unwrap();
            let t = c["transferId"].as_str().unwrap();
            let plain = c["resume"].to_string().into_bytes();
            // From the hashes kept while hashing the file for the offer: no second read.
            let (whole, size, blocks) = hash_file(&path).unwrap();
            let (offset, reason) = sender_answer(&plain, t, size, &unb64(&whole).unwrap(), &blocks);
            assert_eq!(offset, c["expect"]["offset"].as_u64().unwrap(), "{name}");
            assert_eq!(reason, c["expect"]["reason"].as_str(), "{name}");
            // Reading the prefix again gives the same answer.
            let reread = match parse_resume(&plain, t, size) {
                None => (0, Some("invalid")),
                Some((n, prefix)) => match hash_prefix(&path, n) {
                    Ok((_, d)) if crypto::ct_eq(&d, &prefix) => (n, None),
                    _ => (0, Some("mismatch")),
                },
            };
            assert_eq!(reread, (offset, reason), "{name}: read again");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn retention_follows_the_vectors() {
        let v = vectors();
        for c in v["retention"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            let dir = PathBuf::from("/nonexistent");
            let mut store = Store::default();
            let mut parts = std::collections::HashMap::new();
            for k in c["kept"].as_array().unwrap() {
                let mut r = record(k["peer"].as_str().unwrap(), k["n"].as_u64().unwrap(), 0, &dir);
                r.part = format!(".bridgey-{}.part", crypto::uuid4());
                r.length = k["length"].as_u64().unwrap_or(r.length);
                r.size = r.size.max(r.length);
                parts.insert(r.part_path(), k["label"].as_str().unwrap().to_string());
                store.save(r.clone(), k["updatedMs"].as_u64().unwrap());
                if k["inUse"] != Value::Bool(true) {
                    store.release(&r.part_path(), true);
                }
            }
            let n = &c["new"];
            let mut r = record(n["peer"].as_str().unwrap(), 9999, 0, &dir);
            r.part = format!(".bridgey-{}.part", crypto::uuid4());
            r.length = n["length"].as_u64().unwrap_or(r.length);
            r.size = r.size.max(r.length);
            let gone: Vec<String> = store.save(r, n["updatedMs"].as_u64().unwrap()).iter().map(|p| parts[p].clone()).collect();
            let expected: Vec<String> = c["evicted"].as_array().unwrap().iter().map(|e| e.as_str().unwrap().to_string()).collect();
            assert_eq!(gone, expected, "{name}");
        }
    }

    /// Folders are designed, not built here: these rules restate docs/protocol.md so the vectors are checked once
    /// before the apps use them.
    #[test]
    fn folder_vectors_follow_the_designed_rules() {
        let v = vectors();
        for c in v["folderAccept"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            let p = &c["partial"];
            let decoded = if p.is_null() {
                Some(None)
            } else {
                (|| {
                    let entry = p["entry"].as_u64()?;
                    let size = c["entrySizes"][entry.to_string()].as_u64()?;
                    let offset = p["offset"].as_u64().filter(|n| (1..=size).contains(n) && (n.is_multiple_of(BLOCK) || *n == size))?;
                    let prefix = p["prefixSha256"].as_str().and_then(unb64).filter(|b| b.len() == 32)?;
                    Some(Some(json!({"entry": entry, "offset": offset, "prefixSha256": b64(&prefix)})))
                })()
            };
            match (&c["expect"], decoded) {
                (Value::String(s), Some(None)) if s == "none" => {}
                (Value::String(s), None) if s == "invalid" => {}
                (exp, Some(Some(got))) if exp.is_object() => assert_eq!(&got, exp, "{name}"),
                (exp, got) => panic!("{name}: expected {exp}, got {got:?}"),
            }
        }
        for c in v["entryOffer"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            let (p, o, exp) = (&c["receiverPartial"], &c["entryOffer"], &c["expect"]);
            let same_entry = !p.is_null() && p["entry"] == o["entry"];
            match o["offset"].as_u64() {
                None => {
                    assert_eq!(exp["startAt"].as_u64(), Some(0), "{name}");
                    assert_eq!(exp["discardsPartial"].as_bool().unwrap_or(false), same_entry, "{name}");
                }
                Some(n) if same_entry && p["offset"].as_u64() == Some(n) && n <= o["size"].as_u64().unwrap() => assert_eq!(exp["startAt"].as_u64(), Some(n), "{name}"),
                Some(_) => assert_eq!(exp["entryFailed"], "invalid_message", "{name}"),
            }
        }
    }

    #[test]
    fn records_survive_encoding_and_bad_ones_are_dropped() {
        let dir = PathBuf::from("/tmp/received");
        let mut store = Store::default();
        let r = record(PEER, 1, 5, &dir);
        store.save(r.clone(), 5);
        let back = Store::decode(&store.encode());
        assert_eq!(back.records(), store.records());
        let mut bad = r.to_json();
        bad["part"] = Value::from("../../etc/passwd");
        let mut short = r.to_json();
        short["prefix"] = Value::from("AAAA");
        let mut long = r.to_json();
        long["length"] = Value::from(r.size + 1);
        let doc = json!({"version": 1, "records": [bad, short, long, r.to_json()]});
        assert_eq!(Store::decode(doc.to_string().as_bytes()).records().len(), 1, "only the valid record is kept");
        assert!(Store::decode(b"{\"version\":2,\"records\":[]}").records().is_empty());
        assert!(Store::decode(b"not json").records().is_empty());
    }

    #[test]
    fn claims_are_per_device_and_one_at_a_time() {
        let dir = PathBuf::from("/tmp/received");
        let mut store = Store::default();
        let r = record(PEER, 1, 0, &dir);
        store.save(r.clone(), 100);
        store.release(&r.part_path(), true);
        let (found, _) = store.claim(OTHER, r.size, &r.sha256, &r.name, &dir, 200);
        assert!(found.is_none(), "another device never gets this partial");
        assert_eq!(store.records().len(), 1, "nor does it disturb it");
        let (found, _) = store.claim(PEER, r.size, &r.sha256, &r.name, &dir, 200);
        assert_eq!(found.as_ref().map(|f| f.part.clone()), Some(r.part.clone()));
        let (again, gone) = store.claim(PEER, r.size, &r.sha256, &r.name, &dir, 200);
        assert!(again.is_none() && gone.is_empty(), "a partial in use serves one transfer");
        store.release(&r.part_path(), false);
        assert!(store.records().is_empty());
        let (found, _) = store.claim(PEER, r.size, &r.sha256, &r.name, Path::new("/elsewhere"), 200);
        assert!(found.is_none(), "only in the folder files land in now");
    }

    #[test]
    fn forgetting_a_device_drops_its_partials() {
        let dir = PathBuf::from("/tmp/received");
        let mut store = Store::default();
        for (i, p) in [PEER, OTHER, PEER].iter().enumerate() {
            let r = record(p, i as u64, 0, &dir);
            store.save(r.clone(), 10);
            store.release(&r.part_path(), true);
        }
        assert_eq!(store.forget(PEER).len(), 2);
        assert_eq!(store.records().len(), 1);
        assert_eq!(store.records()[0].peer, OTHER);
    }

    #[test]
    fn part_names_are_only_ours() {
        assert!(valid_part(".bridgey-6d1f2c3b-4a59-4687-9a1b-2c3d4e5f6a7b.part"));
        for bad in ["bridgey-6d1f2c3b-4a59-4687-9a1b-2c3d4e5f6a7b.part", ".bridgey-x.part", ".bridgey-6d1f2c3b-4a59-4687-9a1b-2c3d4e5f6a7b.part/..", "../.bridgey-6d1f2c3b-4a59-4687-9a1b-2c3d4e5f6a7b.part"] {
            assert!(!valid_part(bad), "{bad}");
        }
    }
}
