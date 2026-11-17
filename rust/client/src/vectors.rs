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
    enum Wire {
        Line(String),
        Binary(Vec<u8>),
    }

    type Recording = Arc<Mutex<Vec<(String, Wire)>>>;

    /// Forwards one connection, splitting each direction into JSON lines and binary frames as it goes.
    fn proxy(target: u16) -> (u16, Recording) {
        use std::io::Read;
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let frames: Recording = Arc::default();
        let log = frames.clone();
        std::thread::spawn(move || {
            let (inbound, _) = listener.accept().unwrap();
            let outbound = TcpStream::connect(("127.0.0.1", target)).unwrap();
            let pipe = |from: TcpStream, mut to: TcpStream, side: &'static str, log: Recording| {
                std::thread::spawn(move || {
                    let mut r = BufReader::new(from);
                    loop {
                        let first = match r.fill_buf() {
                            Ok([]) | Err(_) => return,
                            Ok(b) => b[0],
                        };
                        let wire = if first == fast::MARKER {
                            let mut header = [0u8; fast::HEADER];
                            if r.read_exact(&mut header).is_err() {
                                return;
                            }
                            let len = fast::body_length(&header).expect("a valid binary frame");
                            let mut frame = header.to_vec();
                            frame.resize(fast::HEADER + len, 0);
                            if r.read_exact(&mut frame[fast::HEADER..]).is_err() {
                                return;
                            }
                            Wire::Binary(frame)
                        } else {
                            let mut line = String::new();
                            if r.read_line(&mut line).unwrap_or(0) == 0 {
                                return;
                            }
                            Wire::Line(line.trim_end_matches('\n').to_string())
                        };
                        let bytes = match &wire {
                            Wire::Line(l) => format!("{l}\n").into_bytes(),
                            Wire::Binary(b) => b.clone(),
                        };
                        log.lock().unwrap().push((side.to_string(), wire));
                        if to.write_all(&bytes).is_err() {
                            return;
                        }
                    }
                })
            };
            pipe(inbound.try_clone().unwrap(), outbound.try_clone().unwrap(), "initiator", log.clone());
            pipe(outbound, inbound, "responder", log);
        });
        (port, frames)
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
