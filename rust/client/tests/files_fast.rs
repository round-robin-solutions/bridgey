//! What the Windows client adds to files between two session clients: binary frames (files_fast_draft1) both ways
//! next to JSON chunks, Windows-safe names, cancels from either end and a dropped connection, two devices sending
//! large files to each other at once, and battery and find device. tests/files.rs covers the rest of the files wire.

mod common;

use bridgey_core::{ClientError, Event};
use common::{pair, Peer};
use std::path::{Path, PathBuf};
use std::time::Duration;

fn temp(tag: &str) -> PathBuf {
    // A UUID: Windows refuses characters that other names can contain.
    let dir = std::env::temp_dir().join(format!("bridgey-fast-{tag}-{}", bridgey_core::crypto::uuid4()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Bytes that are not all alike, so a chunk out of place would show.
fn pattern(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i * 31 % 251) as u8).collect()
}

/// Two paired clients with Files, Battery and Find device on, each receiving into its own folder.
fn setup(tag: &str) -> (Peer, Peer, PathBuf, PathBuf) {
    let (a, b) = (Peer::new("Windows PC"), Peer::new("Test phone"));
    for p in [&a, &b] {
        for key in ["files", "battery", "find_device"] {
            p.client.set_feature(None, key, true).unwrap();
        }
    }
    let (da, db) = (temp(&format!("{tag}-a")), temp(&format!("{tag}-b")));
    a.client.set_receive_dir(Some(&da));
    b.client.set_receive_dir(Some(&db));
    pair(&a, &b);
    a.wait("B shows files", |e| matches!(e, Event::Features { remote, .. } if remote.get("files") && remote.get("files_fast_draft1")).then_some(()));
    b.wait("A shows files", |e| matches!(e, Event::Features { remote, .. } if remote.get("files") && remote.get("files_fast_draft1")).then_some(()));
    (a, b, da, db)
}

/// How a transfer ended at one end: Ok(saved name and path) or Err(reason).
fn ended(peer: &Peer, what: &str, transfer: Option<u64>, incoming: bool) -> Result<(String, Option<String>), String> {
    peer.wait(what, |e| match e {
        Event::FileDone { transfer: t, incoming: i, name, path, .. } if *i == incoming && transfer.is_none_or(|x| x == *t) => Some(Ok((name.clone(), path.clone()))),
        Event::FileFailed { transfer: t, incoming: i, reason, .. } if *i == incoming && transfer.is_none_or(|x| x == *t) => Some(Err(reason.clone())),
        _ => None,
    })
}

fn write(dir: &Path, name: &str, data: &[u8]) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, data).unwrap();
    path
}

fn no_partial_files(dir: &Path) -> bool {
    std::fs::read_dir(dir).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().ends_with(".part"))
}

#[test]
fn files_go_both_ways_in_binary_frames_and_json_chunks() {
    let (a, b, da, db) = setup("both");
    let source = temp("both-src");
    let data = pattern(300_000);
    let file = write(&source, "photo.jpg", &data);

    // A to B in binary frames of 4 KiB: dozens of chunks, every one acknowledged and paced.
    a.client.set_chunk_size_for_tests(4096);
    let transfer = a.client.send_file(&b.id(), &file, None, None).unwrap();
    assert!(ended(&a, "A sent", Some(transfer), false).is_ok());
    let (name, path) = ended(&b, "B received", None, true).unwrap();
    assert_eq!(name, "photo.jpg");
    assert_eq!(path.as_deref(), Some(db.join("photo.jpg").to_str().unwrap()));
    assert_eq!(std::fs::read(db.join("photo.jpg")).unwrap(), data);

    // The same name again is numbered, never overwritten ("photo (1).jpg" on Windows, "photo 2.jpg" elsewhere).
    b.clear();
    let again = a.client.send_file(&b.id(), &file, None, None).unwrap();
    assert!(ended(&a, "A sent again", Some(again), false).is_ok());
    let (second, _) = ended(&b, "B received again", None, true).unwrap();
    assert_eq!(second, if cfg!(windows) { "photo (1).jpg" } else { "photo 2.jpg" });
    assert_eq!(std::fs::read(db.join(&second)).unwrap(), data);

    // A name Windows reserves is made safe before it lands.
    b.clear();
    let device = write(&source, "CON.txt", b"not a device");
    let t = a.client.send_file(&b.id(), &device, None, None).unwrap();
    assert!(ended(&a, "A sent CON", Some(t), false).is_ok());
    assert_eq!(ended(&b, "B received CON", None, true).unwrap().0, "_CON.txt");

    // B to A as JSON chunks (fast transfers off), several files queued at once, in order.
    b.client.set_fast_transfers(false);
    a.wait("B turned fast transfers off", |e| matches!(e, Event::Features { remote, .. } if !remote.get("files_fast_draft1")).then_some(()));
    let names = ["one.txt", "two.txt", "three.txt"];
    let transfers: Vec<u64> = names.iter().map(|n| b.client.send_file(&a.id(), &write(&source, n, &pattern(60_000 + n.len())), None, None).unwrap()).collect();
    for (n, t) in names.iter().zip(&transfers) {
        assert!(ended(&b, n, Some(*t), false).is_ok(), "{n}");
        assert_eq!(std::fs::read(da.join(n)).unwrap(), pattern(60_000 + n.len()));
    }
    assert!(no_partial_files(&da) && no_partial_files(&db));
    a.stop();
    b.stop();
}

#[test]
fn cancels_from_either_end_and_a_dropped_connection_leave_no_partial_files() {
    let (a, b, _da, db) = setup("cancel");
    let source = temp("cancel-src");

    // Files off for A on B: A cannot send at all.
    b.client.set_feature(Some(&a.id()), "files", false).unwrap();
    a.wait("B turned files off", |e| matches!(e, Event::Features { remote, .. } if !remote.get("files")).then_some(()));
    let small = write(&source, "small.txt", b"hi");
    assert_eq!(a.client.send_file(&b.id(), &small, None, None), Err(ClientError::FeatureOff));
    b.client.set_feature(Some(&a.id()), "files", true).unwrap();
    a.wait("B turned files on", |e| matches!(e, Event::Features { remote, .. } if remote.get("files")).then_some(()));

    // B cancels while receiving binary frames; A hears it and stops.
    a.client.set_chunk_size_for_tests(1024);
    let big = write(&source, "big.bin", &pattern(8_000_000));
    let transfer = a.client.send_file(&b.id(), &big, None, None).unwrap();
    let receiving = b.wait("B receiving", |e| match e {
        Event::FileProgress { transfer, incoming: true, bytes, .. } if *bytes > 0 => Some(*transfer),
        _ => None,
    });
    b.client.cancel_file(receiving).unwrap();
    assert_eq!(ended(&a, "A told", Some(transfer), false), Err("cancelled_remote".into()));
    assert!(no_partial_files(&db));

    // A cancels while sending.
    b.clear();
    let transfer = a.client.send_file(&b.id(), &big, None, None).unwrap();
    b.wait("B receiving again", |e| matches!(e, Event::FileProgress { incoming: true, bytes, .. } if *bytes > 0).then_some(()));
    a.client.cancel_file(transfer).unwrap();
    assert_eq!(ended(&a, "A cancelled", Some(transfer), false), Err("cancelled".into()));
    assert_eq!(ended(&b, "B told", None, true), Err("cancelled_remote".into()));

    // The connection drops mid-file: A calls it interrupted, and B's partial file goes. (With files_resume_draft1 at both
    // ends B would keep it for a later attempt, tests/files_resume.rs; B turns it off, as a peer without the key.)
    b.client.set_file_resume(false);
    a.wait("B turned resume off", |e| matches!(e, Event::Features { remote, .. } if !remote.get("files_resume_draft1")).then_some(()));
    b.clear();
    let transfer = a.client.send_file(&b.id(), &big, None, None).unwrap();
    b.wait("B receiving a third time", |e| matches!(e, Event::FileProgress { incoming: true, bytes, .. } if *bytes > 0).then_some(()));
    b.stop();
    assert_eq!(ended(&a, "A interrupted", Some(transfer), false), Err("interrupted".into()));
    std::thread::sleep(Duration::from_millis(300));
    assert!(no_partial_files(&db), "no partial file after a drop");
    a.stop();
}

#[test]
fn battery_and_find_device_both_ways() {
    let (a, b, _, _) = setup("battery");
    a.client.set_battery(Some((55, true)));
    let (level, charging) = b.wait("battery at B", |e| match e {
        Event::Battery { level, charging, .. } => Some((*level, *charging)),
        _ => None,
    });
    assert_eq!((level, charging), (55, true));
    assert_eq!(b.client.snapshot()["devices"][0]["battery"]["level"], 55);
    b.client.set_battery(Some((7, false)));
    a.wait("battery at A", |e| matches!(e, Event::Battery { level: 7, charging: false, .. }).then_some(()));

    // A rings B; B says it is ringing; B's person stops it, and A hears that.
    a.client.find(&b.id(), true).unwrap();
    b.wait("B asked to ring", |e| matches!(e, Event::FindRequested { ring: true, .. }).then_some(()));
    a.wait("A sees B ringing", |e| matches!(e, Event::FindState { ringing: true, .. }).then_some(()));
    assert_eq!(a.client.snapshot()["devices"][0]["ringing"], true);
    a.clear();
    b.client.find_stopped(&a.id()).unwrap();
    a.wait("A sees B stopped", |e| matches!(e, Event::FindState { ringing: false, .. }).then_some(()));

    // B rings A, then stops it from B.
    b.client.find(&a.id(), true).unwrap();
    a.wait("A asked to ring", |e| matches!(e, Event::FindRequested { ring: true, .. }).then_some(()));
    b.client.find(&a.id(), false).unwrap();
    a.wait("A asked to stop", |e| matches!(e, Event::FindRequested { ring: false, .. }).then_some(()));
    b.wait("B sees A stopped", |e| matches!(e, Event::FindState { ringing: false, .. }).then_some(()));

    // Find device off on A for B: B cannot ring A.
    a.client.set_feature(Some(&b.id()), "find_device", false).unwrap();
    b.wait("A turned find off", |e| matches!(e, Event::Features { remote, .. } if !remote.get("find_device")).then_some(()));
    assert_eq!(b.client.find(&a.id(), true), Err(ClientError::FeatureOff));
    a.stop();
    b.stop();
}

#[test]
fn both_devices_send_large_files_to_each_other_at_once() {
    let (a, b, da, db) = setup("crossed");
    let source = temp("crossed-src");
    let (to_b, to_a) = (pattern(24_000_000), pattern(24_000_001));
    let fb = write(&source, "to-b.bin", &to_b);
    let fa = write(&source, "to-a.bin", &to_a);
    let ta = a.client.send_file(&b.id(), &fb, None, None).unwrap();
    let tb = b.client.send_file(&a.id(), &fa, None, None).unwrap();
    assert!(ended(&a, "A sent", Some(ta), false).is_ok());
    assert!(ended(&b, "B sent", Some(tb), false).is_ok());
    assert_eq!(std::fs::read(db.join("to-b.bin")).unwrap(), to_b);
    assert_eq!(std::fs::read(da.join("to-a.bin")).unwrap(), to_a);
    a.stop();
    b.stop();
}
