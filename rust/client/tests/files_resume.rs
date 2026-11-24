//! Resuming a file from its last verified chunk (draft files_resume_draft1, docs/protocol.md "Resuming files"): after
//! the sender drops and restarts, after the receiver drops, after the receiver restarts, and when there is nothing
//! safe to resume (the source changed, the partial expired or was tampered with, a peer without the key, a cancel).
//! A sender stops at a known byte (`set_send_limit_for_tests`), so where a transfer is cut never depends on timing.

mod common;

use bridgey_core::{Event, MemoryStorage, Storage};
use common::{connected, pair, Codes, Peer};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const MIB: u64 = 1024 * 1024;
/// Not a whole number of blocks, so the last piece is short.
const SIZE: usize = 6 * 1024 * 1024 + 12_345;
const CHUNK: usize = 64 * 1024;
/// Where the first attempt stops: two chunks past 3 MiB, so the receiver's record says 3 MiB.
const CUT: u64 = 3 * MIB + 2 * CHUNK as u64;
const RESUME: &str = "files_resume_draft1";

fn temp(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("bridgey-resume-{tag}-{}", bridgey_core::crypto::uuid4()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn pattern(len: usize, salt: u8) -> Vec<u8> {
    (0..len).map(|i| ((i * 31 % 251) as u8) ^ salt).collect()
}

struct Pair {
    a: Peer,
    b: Peer,
    storage_a: Arc<dyn Storage>,
    storage_b: Arc<dyn Storage>,
    /// B's received files.
    db: PathBuf,
    source: PathBuf,
}

fn start(name: &str, storage: &Arc<dyn Storage>, port: u16) -> Peer {
    let p = Peer::start(name, storage.clone(), port, Codes::Accept);
    p.client.set_feature(None, "files", true).unwrap();
    p.client.set_chunk_size_for_tests(CHUNK);
    p
}

/// Both see each other's features with Files on and, when given, the resume key as given.
fn features_seen(a: &Peer, b: &Peer, key: &str, on: Option<bool>) {
    let check = |p: &Peer, other: String| p.wait("features", move |e| matches!(e, Event::Features { device_id, remote, .. } if *device_id == other && remote.get("files") && on.is_none_or(|on| remote.get(key) == on)).then_some(()));
    check(a, b.id());
    check(b, a.id());
}

fn setup(tag: &str) -> Pair {
    let storage_a: Arc<dyn Storage> = Arc::new(MemoryStorage::default());
    let storage_b: Arc<dyn Storage> = Arc::new(MemoryStorage::default());
    let (a, b) = (start("Sender", &storage_a, 0), start("Receiver", &storage_b, 0));
    let db = temp(&format!("{tag}-received"));
    b.client.set_receive_dir(Some(&db));
    pair(&a, &b);
    features_seen(&a, &b, RESUME, Some(true));
    let source = temp(&format!("{tag}-source")).join("video.mov");
    std::fs::write(&source, pattern(SIZE, 0)).unwrap();
    Pair { a, b, storage_a, storage_b, db, source }
}

fn part_files(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir).map(|d| d.map(|e| e.unwrap().path()).filter(|p| p.to_string_lossy().ends_with(".part")).collect()).unwrap_or_default()
}

/// Waits until the receiver's partial holds `bytes`.
fn wait_part(dir: &Path, bytes: u64) -> PathBuf {
    let deadline = Instant::now() + common::WAIT;
    loop {
        if let Some(p) = part_files(dir).into_iter().find(|p| std::fs::metadata(p).is_ok_and(|m| m.len() >= bytes)) {
            return p;
        }
        assert!(Instant::now() < deadline, "the partial never reached {bytes} bytes: {:?}", part_files(dir));
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn records(storage: &Arc<dyn Storage>) -> Vec<Value> {
    storage.load("file-resume").unwrap().map(|b| serde_json::from_slice::<Value>(&b).unwrap()["records"].as_array().unwrap().clone()).unwrap_or_default()
}

/// How a transfer ended at one end: Ok(saved path) or Err(reason).
fn ended(peer: &Peer, what: &str, transfer: Option<u64>, incoming: bool) -> Result<Option<String>, String> {
    peer.wait(what, |e| match e {
        Event::FileDone { transfer: t, incoming: i, path, .. } if *i == incoming && transfer.is_none_or(|x| x == *t) => Some(Ok(path.clone())),
        Event::FileFailed { transfer: t, incoming: i, reason, .. } if *i == incoming && transfer.is_none_or(|x| x == *t) => Some(Err(reason.clone())),
        _ => None,
    })
}

/// The first progress the receiver reported for a file since its log was cleared: the resume offset, or the first chunk.
fn first_progress(peer: &Peer) -> u64 {
    peer.wait("progress", |e| match e {
        Event::FileProgress { incoming: true, bytes, .. } => Some(*bytes),
        _ => None,
    })
}

/// Sends the source and stops after `CUT` bytes, once the receiver holds them all.
fn send_until_cut(p: &Pair) -> u64 {
    p.a.client.set_send_limit_for_tests(CUT);
    let t = p.a.client.send_file(&p.b.id(), &p.source, None, None).unwrap();
    wait_part(&p.db, CUT);
    t
}

/// Sends the source again and checks what arrived, returning where the receiver started.
fn send_again(p: &Pair) -> u64 {
    p.a.client.set_send_limit_for_tests(0);
    p.a.clear();
    p.b.clear();
    let t = p.a.client.send_file(&p.b.id(), &p.source, None, None).unwrap();
    assert_eq!(ended(&p.a, "sent", Some(t), false), Ok(None));
    let path = ended(&p.b, "received", None, true).expect("saved");
    assert_eq!(std::fs::read(path.unwrap()).unwrap(), std::fs::read(&p.source).unwrap(), "the whole file, verified");
    assert!(part_files(&p.db).is_empty(), "no partial left: {:?}", part_files(&p.db));
    assert!(records(&p.storage_b).is_empty(), "no record left");
    first_progress(&p.b)
}

/// The receiver goes off the network and comes back: both see the file interrupted, and the receiver keeps its partial.
fn receiver_drops(p: &Pair, transfer: u64) {
    p.a.clear();
    p.b.client.set_lan_for_tests(false);
    assert_eq!(ended(&p.a, "sender interrupted", Some(transfer), false), Err("interrupted".into()));
    assert_eq!(ended(&p.b, "receiver interrupted", None, true), Err("interrupted".into()));
    p.b.clear();
    p.b.client.set_lan_for_tests(true);
    p.a.client.network_changed();
    p.a.wait("reconnected", connected(&p.b.id()));
    p.b.wait("reconnected", connected(&p.a.id()));
}

fn finish(p: Pair) {
    p.a.stop();
    p.b.stop();
}

#[test]
fn resumes_after_the_sender_drops_and_restarts() {
    let mut p = setup("sender");
    let t = send_until_cut(&p);
    // The sender quits mid-file. It keeps nothing: every resume decision is the receiver's, checked by the sender.
    let port = p.a.client.port();
    p.a.stop();
    assert_eq!(ended(&p.b, "receiver interrupted", None, true), Err("interrupted".into()));
    let _ = t;
    let kept = records(&p.storage_b);
    assert_eq!(kept.len(), 1, "one partial kept");
    assert_eq!(kept[0]["length"], 3 * MIB, "verified to the last whole block");
    assert_eq!(part_files(&p.db).len(), 1);
    p.b.clear();
    p.a = start("Sender", &p.storage_a, port);
    p.a.wait("reconnected", connected(&p.b.id()));
    features_seen(&p.a, &p.b, RESUME, Some(true));
    assert_eq!(send_again(&p), 3 * MIB, "resumed after the kept 3 MiB, not from byte zero");
    finish(p);
}

#[test]
fn resumes_after_the_receiver_drops() {
    let p = setup("receiver-drop");
    let t = send_until_cut(&p);
    receiver_drops(&p, t);
    assert_eq!(part_files(&p.db).len(), 1, "the partial is kept");
    features_seen(&p.a, &p.b, RESUME, Some(true));
    assert_eq!(send_again(&p), 3 * MIB);
    finish(p);
}

#[test]
fn resumes_after_the_receiver_restarts_with_json_chunks() {
    let mut p = setup("receiver-restart");
    // JSON chunks (24 KiB) instead of binary frames: the same resume, whichever way chunks travel.
    p.a.client.set_fast_transfers(false);
    p.b.wait("A turned fast transfers off", |e| matches!(e, Event::Features { remote, .. } if !remote.get("files_fast_draft1")).then_some(()));
    p.a.client.set_send_limit_for_tests(3 * MIB + 5 * 24 * 1024);
    let t = p.a.client.send_file(&p.b.id(), &p.source, None, None).unwrap();
    wait_part(&p.db, 3 * MIB + 5 * 24 * 1024);
    let port = p.b.client.port();
    let b_id = p.b.id();
    p.b.stop();
    assert_eq!(ended(&p.a, "sender interrupted", Some(t), false), Err("interrupted".into()));
    assert_eq!(records(&p.storage_b).len(), 1, "the record is in the receiver's private storage");
    p.a.clear();
    p.b = start("Receiver", &p.storage_b, port);
    assert_eq!(p.b.id(), b_id);
    p.b.client.set_receive_dir(Some(&p.db));
    p.a.wait("reconnected", connected(&b_id));
    features_seen(&p.a, &p.b, RESUME, Some(true));
    assert_eq!(send_again(&p), 3 * MIB);
    finish(p);
}

#[test]
fn a_whole_file_kept_completes_without_a_chunk() {
    let p = setup("whole");
    // Every byte arrived, but files.complete never went.
    p.a.client.set_send_limit_for_tests(SIZE as u64);
    let t = p.a.client.send_file(&p.b.id(), &p.source, None, None).unwrap();
    wait_part(&p.db, SIZE as u64);
    receiver_drops(&p, t);
    assert_eq!(records(&p.storage_b)[0]["length"], SIZE as u64);
    features_seen(&p.a, &p.b, RESUME, Some(true));
    assert_eq!(send_again(&p), SIZE as u64);
    finish(p);
}

#[test]
fn a_changed_source_starts_from_zero_and_drops_the_old_partial() {
    let p = setup("changed");
    let t = send_until_cut(&p);
    receiver_drops(&p, t);
    let old = part_files(&p.db);
    assert_eq!(old.len(), 1);
    // Same name and size, other bytes: another SHA-256, so nothing kept can be part of it.
    std::fs::write(&p.source, pattern(SIZE, 0x5A)).unwrap();
    features_seen(&p.a, &p.b, RESUME, Some(true));
    assert_eq!(send_again(&p), CHUNK as u64, "from byte zero");
    assert!(!old[0].exists(), "the old partial went");
    finish(p);
}

#[test]
fn a_tampered_partial_starts_from_zero() {
    let p = setup("tampered");
    let t = send_until_cut(&p);
    receiver_drops(&p, t);
    let part = part_files(&p.db).pop().unwrap();
    let mut bytes = std::fs::read(&part).unwrap();
    bytes[1000] ^= 0xFF;
    std::fs::write(&part, bytes).unwrap();
    features_seen(&p.a, &p.b, RESUME, Some(true));
    assert_eq!(send_again(&p), CHUNK as u64, "the kept bytes no longer match their record");
    finish(p);
}

#[test]
fn an_expired_partial_is_swept_at_start() {
    let mut p = setup("expired");
    let t = send_until_cut(&p);
    let port = p.b.client.port();
    p.b.stop();
    assert_eq!(ended(&p.a, "sender interrupted", Some(t), false), Err("interrupted".into()));
    assert_eq!(part_files(&p.db).len(), 1);
    // A day and a minute later.
    let mut doc: Value = serde_json::from_slice(&p.storage_b.load("file-resume").unwrap().unwrap()).unwrap();
    let updated = doc["records"][0]["updated"].as_u64().unwrap();
    doc["records"][0]["updated"] = Value::from(updated - 24 * 60 * 60 * 1000 - 60_000);
    p.storage_b.store("file-resume", &serde_json::to_vec(&doc).unwrap()).unwrap();
    p.a.clear();
    p.b = start("Receiver", &p.storage_b, port);
    assert!(part_files(&p.db).is_empty(), "swept when the receiver started");
    assert!(records(&p.storage_b).is_empty());
    p.b.client.set_receive_dir(Some(&p.db));
    p.a.wait("reconnected", connected(&p.b.id()));
    features_seen(&p.a, &p.b, RESUME, Some(true));
    assert_eq!(send_again(&p), CHUNK as u64);
    finish(p);
}

#[test]
fn peers_without_the_key_keep_the_old_behaviour() {
    let p = setup("old");
    for (off, on) in [(&p.b, &p.a), (&p.a, &p.b)] {
        // One end without the key: the offer is not resumable, an interruption deletes the partial, a retry starts at zero.
        p.a.clear();
        p.b.clear();
        off.client.set_file_resume(false);
        on.wait("key off", |e| matches!(e, Event::Features { remote, .. } if !remote.get(RESUME)).then_some(()));
        p.a.clear();
        p.b.clear();
        let t = send_until_cut(&p);
        receiver_drops(&p, t);
        assert!(part_files(&p.db).is_empty(), "no partial kept");
        assert!(records(&p.storage_b).is_empty());
        features_seen(&p.a, &p.b, RESUME, None);
        assert_eq!(send_again(&p), CHUNK as u64);
        off.client.set_file_resume(true);
        features_seen(&p.a, &p.b, RESUME, Some(true));
    }
    finish(p);
}

#[test]
fn a_cancel_or_forgetting_the_device_removes_the_partial() {
    let p = setup("cancel");
    // A cancel by the sender: nothing is kept.
    let t = send_until_cut(&p);
    p.a.client.cancel_file(t).unwrap();
    assert_eq!(ended(&p.b, "receiver told", None, true), Err("cancelled_remote".into()));
    assert!(part_files(&p.db).is_empty() && records(&p.storage_b).is_empty());

    // Interrupted and kept, then resumed, then cancelled by the receiver: the partial goes with it.
    p.a.clear();
    p.b.clear();
    let t = send_until_cut(&p);
    receiver_drops(&p, t);
    features_seen(&p.a, &p.b, RESUME, Some(true));
    p.a.client.set_send_limit_for_tests(5 * MIB);
    let t = p.a.client.send_file(&p.b.id(), &p.source, None, None).unwrap();
    assert_eq!(first_progress(&p.b), 3 * MIB, "resumed");
    wait_part(&p.db, 5 * MIB);
    let receiving = p.b.wait("receiving", |e| match e {
        Event::FileIncoming { transfer, .. } => Some(*transfer),
        _ => None,
    });
    p.b.client.cancel_file(receiving).unwrap();
    assert_eq!(ended(&p.a, "sender told", Some(t), false), Err("cancelled_remote".into()));
    assert!(part_files(&p.db).is_empty() && records(&p.storage_b).is_empty(), "a cancel removes the partial");
    assert_eq!(send_again(&p), CHUNK as u64);

    // Interrupted and kept, then the receiver forgets the sender: its partials go too.
    p.a.clear();
    p.b.clear();
    let t = send_until_cut(&p);
    receiver_drops(&p, t);
    assert_eq!(part_files(&p.db).len(), 1);
    p.b.client.forget(&p.a.id()).unwrap();
    assert!(part_files(&p.db).is_empty() && records(&p.storage_b).is_empty(), "forgetting a device removes its partials");
    finish(p);
}
