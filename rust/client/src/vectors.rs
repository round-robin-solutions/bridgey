//! `protocol/test-vectors/session-client-v1.json`: a real session between two session clients, recorded on the
//! wire (a first pairing with its code, both features maps, clipboard text and its acknowledgement), with the
//! pairing material from the test key log. The Android and Mac test suites check every frame with their own
//! code; this test checks the committed file with this crate's. `BRIDGEY_WRITE_VECTORS=session` records a new one.
//! `session-client-files-v1.json` (files, battery, find device) is below; `BRIDGEY_WRITE_VECTORS=files` records it.

use crate::client::{Client, Config};
use crate::events::{Event, Next, SendStatus};
use crate::session::{transcript_v1, KEYLOG};
use crate::trust::MemoryStorage;
use crate::wire::Message;
use crate::{crypto, features};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/session-client-v1.json");
const TEXT: &str = "Bridgey vector: clipboard text ✓";

/// Lines seen on the wire, with the side that sent each.
type Recording = Arc<Mutex<Vec<(String, String)>>>;

/// Forwards one connection to `target`, recording every line with the side that sent it.
fn proxy(target: u16) -> (u16, Recording) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let lines: Recording = Arc::default();
    let log = lines.clone();
    std::thread::spawn(move || {
        let (inbound, _) = listener.accept().unwrap();
        let outbound = TcpStream::connect(("127.0.0.1", target)).unwrap();
        let pipe = |from: TcpStream, mut to: TcpStream, side: &'static str, log: Recording| {
            std::thread::spawn(move || {
                for line in BufReader::new(from).lines() {
                    let Ok(line) = line else { return };
                    log.lock().unwrap().push((side.to_string(), line.clone()));
                    if to.write_all(format!("{line}\n").as_bytes()).is_err() {
                        return;
                    }
                }
            })
        };
        pipe(inbound.try_clone().unwrap(), outbound.try_clone().unwrap(), "initiator", log.clone());
        pipe(outbound, inbound, "responder", log);
    });
    (port, lines)
}

fn wait(client: &Client, until: impl Fn(&Event) -> bool, seen: &mut Vec<Event>) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Next::Event(e) = client.next_event(Duration::from_millis(100)) {
            if let Event::PairingCode { pairing, .. } = &e {
                let _ = client.confirm_pairing(*pairing, true);
            }
            let done = until(&e);
            seen.push(e);
            if done {
                return;
            }
        }
    }
    panic!("timed out: {seen:?}");
}

fn record() -> Value {
    let start = |name: &str| {
        let mut c = Config::new(name, "windows");
        c.port = 0;
        c.discovery = false;
        Client::start(c, Arc::new(MemoryStorage::default())).unwrap()
    };
    let (a, b) = (start("Vector initiator"), start("Vector responder"));
    b.allow_pairing(Duration::from_secs(60));
    let (port, lines) = proxy(b.port());
    a.pair(None, Some("127.0.0.1"), port).unwrap();
    let b_thread = {
        std::thread::spawn(move || {
            let mut seen = Vec::new();
            wait(&b, |e| matches!(e, Event::Features { .. }), &mut seen);
            wait(&b, |e| matches!(e, Event::Clipboard { .. }), &mut seen);
            (b, seen)
        })
    };
    let mut seen = Vec::new();
    wait(&a, |e| matches!(e, Event::Features { .. }), &mut seen);
    let peer = seen.iter().find_map(|e| if let Event::Connected { device_id, .. } = e { Some(device_id.clone()) } else { None }).unwrap();
    a.send_clipboard(&peer, TEXT).unwrap();
    wait(&a, |e| matches!(e, Event::ClipboardSent { status: SendStatus::Delivered, .. }), &mut seen);
    let (b, _) = b_thread.join().unwrap();
    std::thread::sleep(Duration::from_millis(200));
    a.stop();
    b.stop();
    let code = seen.iter().find_map(|e| if let Event::PairingCode { code, .. } = e { Some(code.clone()) } else { None }).unwrap();
    let frames: Vec<(String, String)> = lines.lock().unwrap().iter().filter(|(_, l)| !l.contains("\"heartbeat.")).cloned().collect();
    let offer = Message::decode(frames[0].1.as_bytes()).unwrap();
    let (_, prk, key) = KEYLOG.lock().unwrap().iter().find(|(s, ..)| *s == offer.session_id).cloned().unwrap();
    json!({
        "version": 1,
        "description": "A protocol 2 session between two Bridgey session clients (rust/client), recorded on the wire: the first pairing (offer with commitment, answer, reveal, both confirms), each side's features.update, a clipboard.update from the initiator and its clipboard.ack. Heartbeats are left out. prk and sessionKey come from the test key log; everything else is what crossed the wire. Generated by rust/client/src/vectors.rs.",
        "transcript": "bridgey-auth-v1",
        "prk": crypto::b64(&prk),
        "sessionKey": crypto::b64(&key),
        "code": code,
        "clipboardText": TEXT,
        "frames": frames.iter().map(|(from, line)| json!({"from": from, "line": line})).collect::<Vec<_>>(),
    })
}

/// Checks a recorded session the way a receiver would, with this crate's own code.
fn check(v: &Value) {
    let frames: Vec<(String, Message)> = v["frames"].as_array().unwrap().iter().map(|f| (f["from"].as_str().unwrap().to_string(), Message::decode(f["line"].as_str().unwrap().as_bytes()).expect("every frame decodes"))).collect();
    let find = |kind: &str| frames.iter().find(|(_, m)| m.kind == kind).map(|(_, m)| m.clone()).unwrap();
    let (offer, answer, reveal) = (find("pairing.offer"), find("pairing.answer"), find("pairing.reveal"));
    let session = offer.session_id.clone();
    let (init_id, resp_id) = (offer.device_id.clone().unwrap(), answer.device_id.clone().unwrap());
    let (init_eph, resp_eph) = (reveal.public_key.clone().unwrap(), answer.public_key.clone().unwrap());
    assert!(offer.public_key.is_none() && offer.protocol_version == Some(2) && answer.protocol_version == Some(2));
    assert!(crypto::commitment_matches(offer.commitment.as_deref().unwrap(), &session, &init_eph));
    let prk: [u8; 32] = crypto::unb64(v["prk"].as_str().unwrap()).unwrap().try_into().unwrap();
    let key: [u8; 32] = crypto::unb64(v["sessionKey"].as_str().unwrap()).unwrap().try_into().unwrap();
    assert_eq!(crypto::hmac_key(&prk), key);
    assert_eq!(crypto::sas_code(&prk, &init_eph, &resp_eph), v["code"].as_str().unwrap());
    let transcript = transcript_v1(&session, &init_id, &resp_id, &init_eph, &resp_eph);
    let mut identities = std::collections::HashMap::new();
    for (_, m) in frames.iter().filter(|(_, m)| m.kind == "pairing.confirm") {
        let (id, identity) = (m.device_id.clone().unwrap(), m.identity_key.clone().unwrap());
        assert!(crypto::proof_matches(&key, &session, &id, &identity, m.proof.as_deref().unwrap()));
        assert!(crypto::verify_signature(&identity, &transcript, m.signature.as_deref().unwrap()));
        identities.insert(id, identity);
    }
    assert_eq!(identities.len(), 2);
    let envelope = crypto::envelope_key(&key);
    let mut features_seen = 0;
    for (from, m) in frames.iter().filter(|(_, m)| !m.kind.starts_with("pairing.")) {
        let sender = if from == "initiator" { &init_id } else { &resp_id };
        assert!(m.tag_matches(&envelope, sender), "{} is tagged by its sender", m.kind);
        match m.kind.as_str() {
            "features.update" => {
                let plain = crypto::decrypt(&key, m.nonce.as_deref().unwrap(), m.ciphertext.as_deref().unwrap()).unwrap();
                let features::Decoded::State(map) = features::decode(&plain) else { panic!("features decode") };
                assert!(map.get("clipboard"));
                features_seen += 1;
            }
            "clipboard.update" => {
                let plain = crypto::decrypt(&key, m.nonce.as_deref().unwrap(), m.ciphertext.as_deref().unwrap()).unwrap();
                assert_eq!(String::from_utf8(plain).unwrap(), v["clipboardText"].as_str().unwrap());
                let ack = find("clipboard.ack");
                assert_eq!(ack.message_id, m.message_id);
            }
            _ => {}
        }
    }
    assert_eq!(features_seen, 2);
}

/// `BRIDGEY_WRITE_VECTORS=1` records every vector again; `=session` or `=files` only that one.
fn writes(which: &str) -> bool {
    std::env::var("BRIDGEY_WRITE_VECTORS").is_ok_and(|v| v == "1" || v == which)
}

#[test]
fn recorded_session_vector() {
    if writes("session") {
        let v = record();
        check(&v);
        std::fs::write(PATH, serde_json::to_string_pretty(&v).unwrap() + "\n").unwrap();
    }
    let v: Value = serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap();
    check(&v);
}

#[test]
fn a_fresh_recording_checks() {
    check(&record());
}

/// `protocol/test-vectors/session-client-files-v1.json`: a recorded session with battery both ways, find device, one
/// file in binary frames (files_fast_draft1) and one in JSON chunks, every frame as it crossed the wire. The Android
/// and Mac suites open every frame with their own code and reassemble both files.
mod files {
    use super::*;
    use crate::fast;

    const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/session-client-files-v1.json");
    const FAST_FILE: &str = "Bridgey vector: this file travels in binary frames of forty bytes each. ✓";
    const JSON_FILE: &str = "Bridgey vector: and this one in JSON chunks, as upstream peers send them.";
    const CHUNK: usize = 40;

    /// One frame on the wire: a JSON line, or a whole binary frame.
    #[derive(Clone)]
    pub(super) enum Wire {
        Line(String),
        Binary(Vec<u8>),
    }

    pub(super) type Recording = Arc<Mutex<Vec<(String, Wire)>>>;

    /// Forwards one connection, splitting each direction into JSON lines and binary frames as it goes.
    pub(super) fn proxy(target: u16) -> (u16, Recording) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let frames: Recording = Arc::default();
        let log = frames.clone();
        std::thread::spawn(move || {
            let (inbound, _) = listener.accept().unwrap();
            relay(inbound, target, log);
        });
        (port, frames)
    }

    /// Forwards every connection it takes, each recorded on its own, in the order they came.
    pub(super) fn proxy_each(target: u16) -> (u16, Arc<Mutex<Vec<Recording>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let all: Arc<Mutex<Vec<Recording>>> = Arc::default();
        let list = all.clone();
        std::thread::spawn(move || {
            for inbound in listener.incoming() {
                let Ok(inbound) = inbound else { return };
                let log: Recording = Arc::default();
                list.lock().unwrap().push(log.clone());
                relay(inbound, target, log);
            }
        });
        (port, all)
    }

    fn relay(inbound: TcpStream, target: u16, log: Recording) {
        use std::io::Read;
        let Ok(outbound) = TcpStream::connect(("127.0.0.1", target)) else { return };
        // Each frame goes on at once: with Nagle's algorithm and Windows' delayed acknowledgements, a run of small
        // frames (a thousand 1 KB chunks) would wait up to 200 ms each.
        let _ = inbound.set_nodelay(true);
        let _ = outbound.set_nodelay(true);
        let pipe = |from: TcpStream, mut to: TcpStream, side: &'static str, log: Recording| {
            std::thread::spawn(move || {
                let mut r = BufReader::new(from);
                loop {
                    let first = match r.fill_buf() {
                        Ok([]) | Err(_) => break,
                        Ok(b) => b[0],
                    };
                    let wire = if first == fast::MARKER {
                        let mut header = [0u8; fast::HEADER];
                        if r.read_exact(&mut header).is_err() {
                            break;
                        }
                        let len = fast::body_length(&header).expect("a valid binary frame");
                        let mut frame = header.to_vec();
                        frame.resize(fast::HEADER + len, 0);
                        if r.read_exact(&mut frame[fast::HEADER..]).is_err() {
                            break;
                        }
                        Wire::Binary(frame)
                    } else {
                        let mut line = String::new();
                        if r.read_line(&mut line).unwrap_or(0) == 0 {
                            break;
                        }
                        Wire::Line(line.trim_end_matches('\n').to_string())
                    };
                    let bytes = match &wire {
                        Wire::Line(l) => format!("{l}\n").into_bytes(),
                        Wire::Binary(b) => b.clone(),
                    };
                    log.lock().unwrap().push((side.to_string(), wire));
                    if to.write_all(&bytes).is_err() {
                        break;
                    }
                }
                // One side ended: the other goes too, as a dropped connection would.
                let _ = to.shutdown(std::net::Shutdown::Both);
            })
        };
        pipe(inbound.try_clone().unwrap(), outbound.try_clone().unwrap(), "initiator", log.clone());
        pipe(outbound, inbound, "responder", log);
    }

    fn temp(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("bridgey-vector-{tag}-{}", crypto::uuid4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn done(e: &Event, incoming: bool) -> bool {
        matches!(e, Event::FileDone { incoming: i, .. } if *i == incoming)
    }

    fn record() -> Value {
        let start = |name: &str| {
            let mut c = Config::new(name, "windows");
            c.port = 0;
            c.discovery = false;
            for key in ["files", "battery", "find_device"] {
                c.defaults.set(key, true);
            }
            Client::start(c, Arc::new(MemoryStorage::default())).unwrap()
        };
        let (a, b) = (start("Vector initiator"), start("Vector responder"));
        let (send_dir, receive_dir) = (temp("send"), temp("receive"));
        b.set_receive_dir(Some(&receive_dir));
        b.allow_pairing(Duration::from_secs(60));
        a.set_chunk_size_for_tests(CHUNK);
        let (port, frames) = proxy(b.port());
        a.pair(None, Some("127.0.0.1"), port).unwrap();
        let b_thread = std::thread::spawn(move || {
            let mut seen = Vec::new();
            wait(&b, |e| matches!(e, Event::Features { remote, .. } if remote.get("files")), &mut seen);
            b.set_battery(Some((81, false)));
            wait(&b, |e| matches!(e, Event::Battery { .. }), &mut seen);
            wait(&b, |e| matches!(e, Event::FindRequested { ring: true, .. }), &mut seen);
            let a_id = seen.iter().find_map(|e| if let Event::Connected { device_id, .. } = e { Some(device_id.clone()) } else { None }).unwrap();
            b.find_stopped(&a_id).unwrap();
            wait(&b, |e| done(e, true), &mut seen);
            seen.clear();
            wait(&b, |e| done(e, true), &mut seen);
            b
        });
        let mut seen = Vec::new();
        wait(&a, |e| matches!(e, Event::Features { remote, .. } if remote.get("files") && remote.get(fast::FEATURE)), &mut seen);
        let peer = seen.iter().find_map(|e| if let Event::Connected { device_id, .. } = e { Some(device_id.clone()) } else { None }).unwrap();
        a.set_battery(Some((64, true)));
        wait(&a, |e| matches!(e, Event::Battery { .. }), &mut seen);
        a.find(&peer, true).unwrap();
        wait(&a, |e| matches!(e, Event::FindState { ringing: false, .. }), &mut seen);
        let fast_path = send_dir.join("fast.txt");
        std::fs::write(&fast_path, FAST_FILE).unwrap();
        a.send_file(&peer, &fast_path, None, None).unwrap();
        wait(&a, |e| done(e, false), &mut seen);
        a.set_fast_transfers(false);
        let json_path = send_dir.join("json.txt");
        std::fs::write(&json_path, JSON_FILE).unwrap();
        seen.clear();
        a.send_file(&peer, &json_path, None, None).unwrap();
        wait(&a, |e| done(e, false), &mut seen);
        let b = b_thread.join().unwrap();
        std::thread::sleep(Duration::from_millis(200));
        a.stop();
        b.stop();
        assert_eq!(std::fs::read_to_string(receive_dir.join("fast.txt")).unwrap(), FAST_FILE);
        assert_eq!(std::fs::read_to_string(receive_dir.join("json.txt")).unwrap(), JSON_FILE);
        let _ = std::fs::remove_dir_all(send_dir);
        let _ = std::fs::remove_dir_all(receive_dir);
        let frames: Vec<(String, Wire)> = frames.lock().unwrap().iter().filter(|(_, w)| !matches!(w, Wire::Line(l) if l.contains("\"heartbeat."))).cloned().collect();
        let Wire::Line(first) = &frames[0].1 else { panic!("the offer comes first") };
        let offer = Message::decode(first.as_bytes()).unwrap();
        let (_, prk, key) = KEYLOG.lock().unwrap().iter().find(|(s, ..)| *s == offer.session_id).cloned().unwrap();
        json!({
            "version": 1,
            "description": "A protocol 2 session between two Bridgey session clients (rust/client), recorded on the wire after the first pairing: battery.update both ways, find.start, find.started and find.stopped, one file in binary frames (files_fast_draft1, 40-byte chunks, every one acknowledged) and, after the initiator turned fast transfers off and sent features.update again, one file in JSON files.chunk messages. Each frame is a JSON line ('line') or a whole binary frame, header included ('binaryBase64'). Heartbeats are left out. prk and sessionKey come from the test key log. Generated by rust/client/src/vectors.rs.",
            "transcript": "bridgey-auth-v1",
            "prk": crypto::b64(&prk),
            "sessionKey": crypto::b64(&key),
            "files": [
                {"name": "fast.txt", "text": FAST_FILE, "binary": true},
                {"name": "json.txt", "text": JSON_FILE, "binary": false},
            ],
            "battery": {"initiator": {"level": 64, "isCharging": true}, "responder": {"level": 81, "isCharging": false}},
            "frames": frames.iter().map(|(from, w)| match w {
                Wire::Line(l) => json!({"from": from, "line": l}),
                Wire::Binary(b) => json!({"from": from, "binaryBase64": crypto::b64(b)}),
            }).collect::<Vec<_>>(),
        })
    }

    /// Checks a recorded session the way a receiver would: every JSON frame's tag, every binary frame's AES-GCM tag
    /// under the frame key and its sender, the offers, both files reassembled and hashed, battery and find payloads.
    fn check(v: &Value) {
        let key: [u8; 32] = crypto::unb64(v["sessionKey"].as_str().unwrap()).unwrap().try_into().unwrap();
        let prk: [u8; 32] = crypto::unb64(v["prk"].as_str().unwrap()).unwrap().try_into().unwrap();
        assert_eq!(crypto::hmac_key(&prk), key);
        let envelope = crypto::envelope_key(&key);
        let frame_key = fast::frame_key(&key);
        let mut ids = std::collections::HashMap::new();
        let mut offers: std::collections::HashMap<String, (String, u64, String)> = Default::default();
        let mut chunks: std::collections::HashMap<String, Vec<(u64, Vec<u8>, bool)>> = Default::default();
        let mut acks = 0;
        let mut seen = std::collections::BTreeSet::new();
        let mut completes = std::collections::HashMap::new();
        for f in v["frames"].as_array().unwrap() {
            let from = f["from"].as_str().unwrap().to_string();
            if let Some(line) = f["line"].as_str() {
                let m = Message::decode(line.as_bytes()).expect("every JSON frame decodes");
                if m.kind == "pairing.offer" || m.kind == "pairing.answer" {
                    ids.insert(from.clone(), m.device_id.clone().unwrap());
                }
                if m.kind.starts_with("pairing.") {
                    continue;
                }
                let sender = ids[&from].clone();
                assert!(m.tag_matches(&envelope, &sender), "{} is tagged by its sender", m.kind);
                seen.insert(m.kind.clone());
                let open = || crypto::decrypt(&key, m.nonce.as_deref().unwrap(), m.ciphertext.as_deref().unwrap()).unwrap();
                match m.kind.as_str() {
                    "battery.update" => {
                        let (level, charging) = crate::session::battery(&open()).unwrap();
                        let exp = &v["battery"][from.as_str()];
                        assert_eq!((u64::from(level), charging), (exp["level"].as_u64().unwrap(), exp["isCharging"].as_bool().unwrap()));
                    }
                    "find.start" | "find.started" | "find.stopped" => {
                        let p: Value = serde_json::from_slice(&open()).unwrap();
                        assert_eq!(p["alertId"], "active", "Android takes no other alert ID");
                    }
                    "files.offer" => {
                        let p: Value = serde_json::from_slice(&open()).unwrap();
                        assert_eq!(p["transferId"].as_str(), m.transfer_id.as_deref(), "the outer transferId repeats the offer's");
                        assert!(m.message_id.is_some());
                        offers.insert(m.transfer_id.clone().unwrap(), (p["name"].as_str().unwrap().into(), p["size"].as_u64().unwrap(), p["sha256"].as_str().unwrap().into()));
                    }
                    "files.chunk" => {
                        assert!(m.message_id.is_some(), "the apps take a JSON chunk only with its own messageId");
                        chunks.entry(m.transfer_id.clone().unwrap()).or_default().push((m.sequence.unwrap() as u64, open(), false));
                    }
                    "files.chunk.ack" => acks += 1,
                    "files.complete" => {
                        let p: Value = serde_json::from_slice(&open()).unwrap();
                        completes.insert(p["transferId"].as_str().unwrap().to_string(), p["sha256"].as_str().unwrap().to_string());
                    }
                    _ => {}
                }
            } else {
                let bytes = crypto::unb64(f["binaryBase64"].as_str().unwrap()).unwrap();
                let header: [u8; fast::HEADER] = bytes[..fast::HEADER].try_into().unwrap();
                assert_eq!(fast::body_length(&header), Some(bytes.len() - fast::HEADER));
                let frame = fast::open_body(header[1], &bytes[fast::HEADER..], &frame_key, &ids[&from]).expect("the binary frame opens under its sender");
                assert_eq!(frame.kind, fast::KIND_CHUNK);
                chunks.entry(frame.id).or_default().push((frame.sequence, frame.plaintext, true));
            }
        }
        for kind in ["battery.update", "find.start", "find.started", "find.stopped", "files.offer", "files.accept", "files.chunk", "files.chunk.ack", "files.complete", "files.complete.ack"] {
            assert!(seen.contains(kind), "{kind} was recorded");
        }
        let mut found = 0;
        for file in v["files"].as_array().unwrap() {
            let (id, (_, size, sha)) = offers.iter().find(|(_, (n, ..))| n == file["name"].as_str().unwrap()).expect("offered");
            let mut parts = chunks[id].clone();
            assert!(parts.iter().all(|p| p.2 == file["binary"].as_bool().unwrap()), "{} goes the way the vector says", file["name"]);
            parts.sort_by_key(|p| p.0);
            assert!(parts.iter().enumerate().all(|(i, p)| p.0 == i as u64), "sequences follow on from 0");
            let data: Vec<u8> = parts.into_iter().flat_map(|p| p.1).collect();
            assert_eq!(data, file["text"].as_str().unwrap().as_bytes());
            assert_eq!(data.len() as u64, *size);
            assert_eq!(crypto::b64(ring::digest::digest(&ring::digest::SHA256, &data).as_ref()), *sha);
            assert_eq!(&completes[id], sha);
            found += 1;
        }
        assert_eq!(found, 2);
        assert!(acks >= 4, "the receiver acknowledges chunks");
    }

    #[test]
    fn recorded_files_vector() {
        if writes("files") {
            let v = record();
            check(&v);
            std::fs::write(PATH, serde_json::to_string_pretty(&v).unwrap() + "\n").unwrap();
        }
        let v: Value = serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap();
        check(&v);
    }

    #[test]
    fn a_fresh_files_recording_checks() {
        check(&record());
    }
}

/// `protocol/test-vectors/session-client-notifications-v1.json`: after pairing, a phone (a session client sending what
/// the phone sends) posts notifications and codes messages, and the Windows side answers with an action and reply, a
/// dismiss, a link request, an advertising result and presence. The Android suite reads every message the Windows
/// side sent with the phone's own checks. `BRIDGEY_WRITE_VECTORS=notifications` records it.
mod notifications {
    use super::files::{proxy, Wire};
    use super::*;
    use crate::notifications::Presence;

    const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/session-client-notifications-v1.json");
    pub(super) const TOKEN_REPLY: &str = "4f1c0b9a2e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a3928170f6e5d4c";
    const TOKEN_READ: &str = "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9";
    const UUID: &str = "7e57d00d-0000-4000-8000-0000000000cc";

    fn record() -> Value {
        let start = |name: &str| {
            let mut c = Config::new(name, "windows");
            c.port = 0;
            c.discovery = false;
            for key in ["notifications", "notification_routing_draft1", "device_presence_draft1", "sms_codes_draft1"] {
                c.defaults.set(key, true);
            }
            Client::start(c, Arc::new(MemoryStorage::default())).unwrap()
        };
        let (pc, phone) = (start("Vector PC"), start("Vector phone"));
        pc.set_codes(true, false);
        phone.allow_pairing(Duration::from_secs(60));
        let (port, frames) = proxy(phone.port());
        pc.pair(None, Some("127.0.0.1"), port).unwrap();
        let phone_thread = std::thread::spawn(move || {
            let mut phone_seen = Vec::new();
            wait(&phone, |e| matches!(e, Event::Features { remote, .. } if remote.get("device_presence_draft1")), &mut phone_seen);
            let pc_id = phone_seen.iter().find_map(|e| if let Event::Connected { device_id, .. } = e { Some(device_id.clone()) } else { None }).unwrap();
            (phone, pc_id)
        });
        let mut seen = Vec::new();
        wait(&pc, |e| matches!(e, Event::Features { remote, .. } if remote.get("notifications")), &mut seen);
        let phone_id = seen.iter().find_map(|e| if let Event::Connected { device_id, .. } = e { Some(device_id.clone()) } else { None }).unwrap();
        let (phone, pc_id) = phone_thread.join().unwrap();
        let sms = json!({
            "packageName": "com.google.android.apps.messaging", "applicationName": "Messages", "notificationId": "0|com.google.android.apps.messaging|42|null|10234",
            "title": "VM-HDFCBK", "text": "OTP is 482913 for txn of INR 2,499.00 at AMAZON PAY. Do not share OTP.", "timestamp": 1794000000000i64,
            "actions": [{"actionToken": TOKEN_REPLY, "title": "Reply", "allowsReply": true}, {"actionToken": TOKEN_READ, "title": "Mark as read", "allowsReply": false}],
            "smsDefaultApp": true, "redacted": false, "presentation": "alert",
        });
        phone.send_as_phone_for_tests(&pc_id, "notifications.post", &sms.to_string()).unwrap();
        wait(&pc, |e| matches!(e, Event::Notification { notification, .. } if notification.code.is_some()), &mut seen);
        let quiet = json!({"packageName": "com.whatsapp", "applicationName": "WhatsApp", "notificationId": "0|com.whatsapp|7|null|10301", "title": "Ravi", "text": "On my way", "timestamp": 1794000005000i64, "actions": [], "smsDefaultApp": false, "presentation": "quiet"});
        phone.send_as_phone_for_tests(&pc_id, "notifications.post", &quiet.to_string()).unwrap();
        wait(&pc, |e| matches!(e, Event::Notification { notification, .. } if notification.quiet), &mut seen);
        phone.send_as_phone_for_tests(&pc_id, "codes.status", &json!({"version": 1, "status": "hidden"}).to_string()).unwrap();
        wait(&pc, |e| matches!(e, Event::CodesStatus { .. }), &mut seen);
        pc.notification_action(&phone_id, "0|com.google.android.apps.messaging|42|null|10234", TOKEN_REPLY, Some("Thanks, done ✓")).unwrap();
        pc.dismiss_notification(&phone_id, "0|com.whatsapp|7|null|10301").unwrap();
        pc.codes_link_request(&phone_id).unwrap();
        phone.send_as_phone_for_tests(&pc_id, "codes.advertise", &json!({"version": 1, "serviceUuid": UUID}).to_string()).unwrap();
        wait(&pc, |e| matches!(e, Event::CodesAdvertise { start: true, .. }), &mut seen);
        pc.codes_advertise_result(&phone_id, UUID, false, Some("unsupported")).unwrap();
        pc.set_presence(Presence::Locked);
        phone.send_as_phone_for_tests(&pc_id, "notifications.remove", &json!({"notificationId": "0|com.google.android.apps.messaging|42|null|10234"}).to_string()).unwrap();
        wait(&pc, |e| matches!(e, Event::NotificationRemoved { .. }), &mut seen);
        std::thread::sleep(Duration::from_millis(300));
        pc.stop();
        phone.stop();
        let frames: Vec<(String, String)> = frames
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(from, w)| match w {
                Wire::Line(l) if !l.contains("\"heartbeat.") => Some((from.clone(), l.clone())),
                _ => None,
            })
            .collect();
        let offer = Message::decode(frames[0].1.as_bytes()).unwrap();
        let (_, prk, key) = KEYLOG.lock().unwrap().iter().find(|(s, ..)| *s == offer.session_id).cloned().unwrap();
        json!({
            "version": 1,
            "description": "A protocol 2 session between two Bridgey session clients (rust/client), recorded on the wire after the first pairing. The responder sends what the phone sends: two notifications.post (an SMS with a code and two actions, alert; a WhatsApp message, quiet), codes.status, codes.advertise and notifications.remove. The initiator (the Windows side) answers with notifications.action with a reply, notifications.dismiss, codes.link_request, codes.advertise_result and presence.state. Heartbeats are left out. prk and sessionKey come from the test key log. Generated by rust/client/src/vectors.rs.",
            "transcript": "bridgey-auth-v1",
            "prk": crypto::b64(&prk),
            "sessionKey": crypto::b64(&key),
            "replyToken": TOKEN_REPLY,
            "replyText": "Thanks, done ✓",
            "serviceUuid": UUID,
            "frames": frames.iter().map(|(from, line)| json!({"from": from, "line": line})).collect::<Vec<_>>(),
        })
    }

    fn check(v: &Value) {
        let key: [u8; 32] = crypto::unb64(v["sessionKey"].as_str().unwrap()).unwrap().try_into().unwrap();
        let envelope = crypto::envelope_key(&key);
        let mut ids = std::collections::HashMap::new();
        let mut kinds = std::collections::BTreeMap::new();
        for f in v["frames"].as_array().unwrap() {
            let from = f["from"].as_str().unwrap().to_string();
            let m = Message::decode(f["line"].as_str().unwrap().as_bytes()).unwrap();
            if m.kind == "pairing.offer" || m.kind == "pairing.answer" {
                ids.insert(from.clone(), m.device_id.clone().unwrap());
            }
            if m.kind.starts_with("pairing.") {
                continue;
            }
            assert!(m.tag_matches(&envelope, &ids[&from]), "{} is tagged by its sender", m.kind);
            let plain = m.ciphertext.as_deref().map(|c| crypto::decrypt(&key, m.nonce.as_deref().unwrap(), c).unwrap());
            *kinds.entry((from.clone(), m.kind.clone())).or_insert(0) += 1;
            match m.kind.as_str() {
                "notifications.post" => assert!(crate::notifications::decode_post(&plain.unwrap(), true).is_some()),
                "notifications.action" => {
                    let p: Value = serde_json::from_slice(&plain.unwrap()).unwrap();
                    assert_eq!(p["actionToken"], v["replyToken"]);
                    assert_eq!(p["replyText"], v["replyText"]);
                }
                "presence.state" => {
                    let p: Value = serde_json::from_slice(&plain.unwrap()).unwrap();
                    assert_eq!(p["version"], 1);
                    assert!(p["sequence"].as_u64().unwrap() >= 1);
                }
                _ => {}
            }
        }
        for (from, kind) in [("responder", "notifications.post"), ("responder", "codes.status"), ("responder", "codes.advertise"), ("responder", "notifications.remove"), ("initiator", "notifications.action"), ("initiator", "notifications.dismiss"), ("initiator", "codes.link_request"), ("initiator", "codes.advertise_result"), ("initiator", "presence.state")] {
            assert!(kinds.contains_key(&(from.to_string(), kind.to_string())), "{from} sent {kind}");
        }
    }

    #[test]
    fn recorded_notifications_vector() {
        if writes("notifications") {
            let v = record();
            check(&v);
            std::fs::write(PATH, serde_json::to_string_pretty(&v).unwrap() + "\n").unwrap();
        }
        let v: Value = serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap();
        check(&v);
    }

    #[test]
    fn a_fresh_notifications_recording_checks() {
        check(&record());
    }
}

/// `protocol/test-vectors/session-client-quick-v1.json`: a phone's link and media requests and the Windows side's
/// answers, its media.state and a link it sends. `BRIDGEY_WRITE_VECTORS=quick` records it.
mod quick {
    use super::files::{proxy, Wire};
    use super::*;

    const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/session-client-quick-v1.json");
    const LINK_TO_PHONE: &str = "https://roundrobin.in/bridgey";

    fn record() -> Value {
        let start = |name: &str| {
            let mut c = Config::new(name, "windows");
            c.port = 0;
            c.discovery = false;
            for key in ["links", "media", "links_open_draft1"] {
                c.defaults.set(key, true);
            }
            Client::start(c, Arc::new(MemoryStorage::default())).unwrap()
        };
        let (pc, phone) = (start("Vector PC"), start("Vector phone"));
        // Phones don't show links_open_draft1 (Macs do), so the PC offers its link.
        phone.set_feature(None, "links_open_draft1", false).unwrap();
        phone.allow_pairing(Duration::from_secs(60));
        let (port, frames) = proxy(phone.port());
        pc.pair(None, Some("127.0.0.1"), port).unwrap();
        let phone_thread = std::thread::spawn(move || {
            let mut seen = Vec::new();
            wait(&phone, |e| matches!(e, Event::Features { remote, .. } if remote.get("media")), &mut seen);
            let pc_id = seen.iter().find_map(|e| if let Event::Connected { device_id, .. } = e { Some(device_id.clone()) } else { None }).unwrap();
            (phone, pc_id)
        });
        let mut seen = Vec::new();
        wait(&pc, |e| matches!(e, Event::Features { remote, .. } if remote.get("media")), &mut seen);
        let phone_id = seen.iter().find_map(|e| if let Event::Connected { device_id, .. } = e { Some(device_id.clone()) } else { None }).unwrap();
        let (phone, pc_id) = phone_thread.join().unwrap();
        pc.set_media_state(Some(&json!({"player": "Spotify", "title": "Clair de lune", "artist": "Debussy", "playing": true, "position": 95, "duration": 300, "volume": 0, "controls": ["toggle", "pause", "next", "previous", "seek"]}).to_string())).unwrap();
        let open = json!({"version": 1, "requestId": crypto::uuid4(), "feature": "links", "action": "open", "value": "https://example.com/article", "sequence": 1});
        phone.send_as_phone_for_tests(&pc_id, "quick.request", &open.to_string()).unwrap();
        wait(&pc, |e| matches!(e, Event::Link { open: true, .. }), &mut seen);
        let seek = json!({"version": 1, "requestId": crypto::uuid4(), "feature": "media", "action": "seek", "value": "120", "sequence": 1});
        phone.send_as_phone_for_tests(&pc_id, "quick.request", &seek.to_string()).unwrap();
        let request_id = loop {
            if let Next::Event(Event::MediaCommand { request_id, .. }) = pc.next_event(Duration::from_secs(5)) {
                break request_id;
            }
        };
        pc.media_result(&phone_id, &request_id, true).unwrap();
        pc.send_link(&phone_id, LINK_TO_PHONE).unwrap();
        wait(&pc, |e| matches!(e, Event::LinkSent { .. }), &mut seen);
        std::thread::sleep(Duration::from_millis(300));
        pc.stop();
        phone.stop();
        let frames: Vec<(String, String)> = frames
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(from, w)| match w {
                Wire::Line(l) if !l.contains("\"heartbeat.") => Some((from.clone(), l.clone())),
                _ => None,
            })
            .collect();
        let offer = Message::decode(frames[0].1.as_bytes()).unwrap();
        let (_, prk, key) = KEYLOG.lock().unwrap().iter().find(|(s, ..)| *s == offer.session_id).cloned().unwrap();
        json!({
            "version": 1,
            "description": "A protocol 2 session between two Bridgey session clients (rust/client), recorded on the wire after the first pairing. The responder sends what a phone sends: quick.request with links action open and with media action seek. The initiator (the Windows side) answers with quick.result (opened right away; the seek done), sends media.state and a quick.request with links action offer, which the responder answers. Heartbeats are left out. prk and sessionKey come from the test key log. Generated by rust/client/src/vectors.rs.",
            "transcript": "bridgey-auth-v1",
            "prk": crypto::b64(&prk),
            "sessionKey": crypto::b64(&key),
            "linkToPhone": LINK_TO_PHONE,
            "frames": frames.iter().map(|(from, line)| json!({"from": from, "line": line})).collect::<Vec<_>>(),
        })
    }

    fn check(v: &Value) {
        let key: [u8; 32] = crypto::unb64(v["sessionKey"].as_str().unwrap()).unwrap().try_into().unwrap();
        let envelope = crypto::envelope_key(&key);
        let mut ids = std::collections::HashMap::new();
        let mut kinds = std::collections::BTreeSet::new();
        for f in v["frames"].as_array().unwrap() {
            let from = f["from"].as_str().unwrap().to_string();
            let m = Message::decode(f["line"].as_str().unwrap().as_bytes()).unwrap();
            if m.kind == "pairing.offer" || m.kind == "pairing.answer" {
                ids.insert(from.clone(), m.device_id.clone().unwrap());
            }
            if m.kind.starts_with("pairing.") {
                continue;
            }
            assert!(m.tag_matches(&envelope, &ids[&from]), "{} is tagged by its sender", m.kind);
            kinds.insert((from.clone(), m.kind.clone()));
            let Some(c) = m.ciphertext.as_deref() else { continue };
            let plain = crypto::decrypt(&key, m.nonce.as_deref().unwrap(), c).unwrap();
            if from == "initiator" && m.kind == "quick.request" {
                let r = crate::quick::decode_request(&plain).unwrap();
                assert_eq!((r.feature.as_str(), r.action.as_str(), r.value.as_str()), ("links", "offer", v["linkToPhone"].as_str().unwrap()));
            }
        }
        for (from, kind) in [("responder", "quick.request"), ("initiator", "quick.result"), ("initiator", "media.state"), ("initiator", "quick.request"), ("responder", "quick.result")] {
            assert!(kinds.contains(&(from.to_string(), kind.to_string())), "{from} sent {kind}");
        }
    }

    #[test]
    fn recorded_quick_vector() {
        if writes("quick") {
            let v = record();
            check(&v);
            std::fs::write(PATH, serde_json::to_string_pretty(&v).unwrap() + "\n").unwrap();
        }
        let v: Value = serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap();
        check(&v);
    }

    #[test]
    fn a_fresh_quick_recording_checks() {
        check(&record());
    }
}

/// `protocol/test-vectors/session-client-resume-v1.json`: resuming a file (files_resume_draft1) between two session
/// clients. A first session (not recorded) cuts a file after its first 1 MiB block and drops; the recorded session is
/// the reconnect, where the same file is offered again `resumable`, the receiver says it is still re-reading its
/// partial (`files.resume.wait`), answers `files.resume` with 1 MiB and its SHA-256, the sender agrees
/// (`files.resume.ack`) and only the rest travels, in binary frames numbered from 0. The Android and Mac suites open
/// every frame with their own code and check the resume messages with their own decoders. `BRIDGEY_WRITE_VECTORS=resume`
/// records it.
mod resume {
    use super::files::{proxy_each, Wire};
    use super::*;
    use crate::{fast, resume};

    const PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/session-client-resume-v1.json");
    const NAME: &str = "resume.bin";
    /// One block and a short tail: the recorded session carries only the tail.
    const SIZE: usize = 1024 * 1024 + 5000;
    const CHUNK: usize = 1000;

    fn pattern() -> Vec<u8> {
        (0..SIZE).map(|i| (i * 31 % 251) as u8).collect()
    }

    fn connected(e: &Event) -> bool {
        matches!(e, Event::Features { remote, .. } if remote.get("files") && remote.get(resume::FEATURE))
    }

    fn record() -> Value {
        let start = |name: &str, manual: bool| {
            let mut c = Config::new(name, "windows");
            c.port = 0;
            c.discovery = false;
            // The receiver never dials, so the reconnect goes through the recording proxy.
            c.manual_connect = manual;
            c.defaults.set("files", true);
            Client::start(c, Arc::new(MemoryStorage::default())).unwrap()
        };
        let (a, b) = (start("Vector sender", false), start("Vector receiver", true));
        let dir = std::env::temp_dir().join(format!("bridgey-vector-resume-{}", crypto::uuid4()));
        let (send_dir, receive_dir) = (dir.join("send"), dir.join("receive"));
        std::fs::create_dir_all(&send_dir).unwrap();
        b.set_receive_dir(Some(&receive_dir));
        b.allow_pairing(Duration::from_secs(60));
        a.set_chunk_size_for_tests(CHUNK);
        let source = send_dir.join(NAME);
        std::fs::write(&source, pattern()).unwrap();
        let (port, connections) = proxy_each(b.port());
        a.pair(None, Some("127.0.0.1"), port).unwrap();
        let b_thread = std::thread::spawn(move || {
            let mut seen = Vec::new();
            wait(&b, connected, &mut seen);
            b
        });
        let mut seen = Vec::new();
        wait(&a, connected, &mut seen);
        let b = b_thread.join().unwrap();
        let peer = seen.iter().find_map(|e| if let Event::Connected { device_id, .. } = e { Some(device_id.clone()) } else { None }).unwrap();
        // First attempt: stops two chunks past the first block, so the receiver keeps 1 MiB.
        a.set_send_limit_for_tests(1024 * 1024 + 2 * CHUNK as u64);
        a.send_file(&peer, &source, None, None).unwrap();
        let deadline = Instant::now() + Duration::from_secs(60);
        let has_part = |len: u64| {
            std::fs::read_dir(&receive_dir).into_iter().flatten().flatten().any(|e| e.path().to_string_lossy().ends_with(".part") && e.metadata().is_ok_and(|m| m.len() >= len))
        };
        while !has_part(1024 * 1024 + 2 * CHUNK as u64) {
            assert!(Instant::now() < deadline, "the first attempt never reached the cut");
            std::thread::sleep(Duration::from_millis(20));
        }
        b.set_lan_for_tests(false);
        seen.clear();
        wait(&a, |e| matches!(e, Event::FileFailed { incoming: false, .. }), &mut seen);
        // The recorded session: the receiver re-reads slowly enough to send files.resume.wait, then resumes.
        a.set_send_limit_for_tests(0);
        a.set_resume_timing_for_tests(Duration::from_millis(800), Duration::ZERO);
        b.set_resume_timing_for_tests(Duration::from_millis(800), Duration::from_millis(500));
        b.set_lan_for_tests(true);
        let b_thread = std::thread::spawn(move || {
            let mut seen = Vec::new();
            wait(&b, |e| matches!(e, Event::FileDone { incoming: true, .. }), &mut seen);
            b
        });
        a.network_changed();
        seen.clear();
        wait(&a, connected, &mut seen);
        a.send_file(&peer, &source, None, None).unwrap();
        wait(&a, |e| matches!(e, Event::FileDone { incoming: false, .. }), &mut seen);
        let b = b_thread.join().unwrap();
        std::thread::sleep(Duration::from_millis(200));
        a.stop();
        b.stop();
        assert_eq!(std::fs::read(receive_dir.join(NAME)).unwrap(), pattern());
        let _ = std::fs::remove_dir_all(dir);
        let recorded = connections.lock().unwrap().last().cloned().expect("a reconnect");
        let frames: Vec<(String, Wire)> = recorded.lock().unwrap().iter().filter(|(_, w)| !matches!(w, Wire::Line(l) if l.contains("\"heartbeat."))).cloned().collect();
        let Wire::Line(first) = &frames[0].1 else { panic!("the offer comes first") };
        let offer = Message::decode(first.as_bytes()).unwrap();
        let (_, prk, key) = KEYLOG.lock().unwrap().iter().find(|(s, ..)| *s == offer.session_id).cloned().unwrap();
        let data = pattern();
        json!({
            "version": 1,
            "description": "Resuming a file (files_resume_draft1) between two Bridgey session clients (rust/client), recorded on the wire. A first session, not recorded, sent the file's first 1 MiB and a little more and dropped; the receiver kept its first 1 MiB block. This is the reconnect: features.update both ways with files_resume_draft1, the same file offered again with resumable: true under a new transferId, files.resume.wait from the receiver while it re-reads its partial (held back on purpose), files.resume with offset 1048576 and the SHA-256 of those bytes, files.resume.ack with the same offset, then only the file's last 5000 bytes as binary frames of 1000 bytes numbered from 0 (each acknowledged), files.complete and files.complete.ack. The file is 'size' bytes, byte i is (i * 31) mod 251. Each frame is a JSON line ('line') or a whole binary frame ('binaryBase64'). Heartbeats are left out. prk and sessionKey come from the test key log. Generated by rust/client/src/vectors.rs.",
            "prk": crypto::b64(&prk),
            "sessionKey": crypto::b64(&key),
            "file": {"name": NAME, "size": SIZE, "pattern": "byte i is (i * 31) mod 251", "sha256": crypto::b64(ring::digest::digest(&ring::digest::SHA256, &data).as_ref())},
            "resumeAt": resume::BLOCK,
            "frames": frames.iter().map(|(from, w)| match w {
                Wire::Line(l) => json!({"from": from, "line": l}),
                Wire::Binary(b) => json!({"from": from, "binaryBase64": crypto::b64(b)}),
            }).collect::<Vec<_>>(),
        })
    }

    /// Checks the recorded resume as each end would: tags, the resumable offer, files.resume.wait before the answer,
    /// files.resume and its prefix hash against the file, the agreed files.resume.ack, chunks from 0 carrying exactly
    /// the bytes after the offset, and the whole file's SHA-256.
    fn check(v: &Value) {
        let key: [u8; 32] = crypto::unb64(v["sessionKey"].as_str().unwrap()).unwrap().try_into().unwrap();
        let prk: [u8; 32] = crypto::unb64(v["prk"].as_str().unwrap()).unwrap().try_into().unwrap();
        assert_eq!(crypto::hmac_key(&prk), key);
        let (envelope, frame_key) = (crypto::envelope_key(&key), fast::frame_key(&key));
        let size = v["file"]["size"].as_u64().unwrap();
        let data: Vec<u8> = (0..size as usize).map(|i| (i * 31 % 251) as u8).collect();
        let sha = ring::digest::digest(&ring::digest::SHA256, &data);
        assert_eq!(crypto::b64(sha.as_ref()), v["file"]["sha256"].as_str().unwrap());
        let at = v["resumeAt"].as_u64().unwrap();
        let mut ids = std::collections::HashMap::new();
        let mut order = Vec::new();
        let (mut transfer, mut chunks, mut resume_maps) = (None::<String>, Vec::new(), 0);
        for f in v["frames"].as_array().unwrap() {
            let from = f["from"].as_str().unwrap().to_string();
            if let Some(line) = f["line"].as_str() {
                let m = Message::decode(line.as_bytes()).expect("every JSON frame decodes");
                if m.kind == "pairing.offer" || m.kind == "pairing.answer" {
                    ids.insert(from.clone(), m.device_id.clone().unwrap());
                }
                if m.kind.starts_with("pairing.") {
                    continue;
                }
                assert!(m.tag_matches(&envelope, &ids[&from]), "{} is tagged by its sender", m.kind);
                let open = || crypto::decrypt(&key, m.nonce.as_deref().unwrap(), m.ciphertext.as_deref().unwrap()).unwrap();
                order.push((from.clone(), m.kind.clone()));
                match m.kind.as_str() {
                    "features.update" => {
                        let features::Decoded::State(map) = features::decode(&open()) else { panic!("features decode") };
                        if map.get(resume::FEATURE) {
                            resume_maps += 1;
                        }
                    }
                    "files.offer" => {
                        let p: Value = serde_json::from_slice(&open()).unwrap();
                        assert_eq!(p["resumable"], Value::Bool(true), "offered resumable");
                        assert_eq!((p["size"].as_u64(), p["sha256"].as_str()), (Some(size), v["file"]["sha256"].as_str()));
                        transfer = m.transfer_id.clone();
                    }
                    "files.resume.wait" => {
                        assert_eq!(from, "responder");
                        assert!(m.ciphertext.is_none() && m.transfer_id == transfer, "outer only, for the offer");
                    }
                    "files.resume" => {
                        let t = transfer.clone().unwrap();
                        let (offset, prefix) = resume::parse_resume(&open(), &t, size).expect("a valid files.resume");
                        assert_eq!(offset, at);
                        assert_eq!(prefix.as_slice(), ring::digest::digest(&ring::digest::SHA256, &data[..at as usize]).as_ref());
                    }
                    "files.resume.ack" => {
                        assert_eq!(resume::parse_ack(&open(), transfer.as_deref().unwrap(), at), Some(at), "the sender agrees");
                    }
                    "files.complete" => {
                        let p: Value = serde_json::from_slice(&open()).unwrap();
                        assert_eq!(p["sha256"].as_str(), v["file"]["sha256"].as_str());
                    }
                    _ => {}
                }
            } else {
                let bytes = crypto::unb64(f["binaryBase64"].as_str().unwrap()).unwrap();
                let header: [u8; fast::HEADER] = bytes[..fast::HEADER].try_into().unwrap();
                let frame = fast::open_body(header[1], &bytes[fast::HEADER..], &frame_key, &ids[&from]).expect("the binary frame opens under its sender");
                assert_eq!(Some(&frame.id), transfer.as_ref());
                order.push((from, "binary".into()));
                chunks.push((frame.sequence, frame.plaintext));
            }
        }
        assert_eq!(resume_maps, 2, "both ends show files_resume_draft1");
        let position = |kind: &str| order.iter().position(|(_, k)| k == kind).unwrap_or_else(|| panic!("{kind} was recorded"));
        let (offered, waited, resumed, acked, first_chunk, completed) =
            (position("files.offer"), position("files.resume.wait"), position("files.resume"), position("files.resume.ack"), position("binary"), position("files.complete.ack"));
        assert!(offered < waited && waited < resumed && resumed < acked && acked < first_chunk && first_chunk < completed);
        assert!(!order.iter().any(|(_, k)| k == "files.accept"), "files.resume instead of files.accept");
        assert!(chunks.iter().enumerate().all(|(i, c)| c.0 == i as u64), "sequences from 0");
        let tail: Vec<u8> = chunks.into_iter().flat_map(|c| c.1).collect();
        assert_eq!(tail, data[at as usize..], "only the bytes after the offset travel");
    }

    #[test]
    fn recorded_resume_vector() {
        if writes("resume") {
            let v = record();
            check(&v);
            std::fs::write(PATH, serde_json::to_string_pretty(&v).unwrap() + "\n").unwrap();
        }
        let v: Value = serde_json::from_str(&std::fs::read_to_string(PATH).unwrap()).unwrap();
        check(&v);
    }

    #[test]
    fn a_fresh_resume_recording_checks() {
        check(&record());
    }
}
