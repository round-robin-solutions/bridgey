//! A headless test node: what an app does, without an app. Used by `server/local/live-test.sh`.
//!
//! It joins the control service with a software node key, keeps one peer, and on every tunnel
//! connects to the loopback bridge. The QUIC client sends numbered lines and times the echoes;
//! the other side echoes them. Output is one JSON line per event or measurement.
//!
//! cargo run --example probe -- --id A --peer B --side 0 --secret <base64 32 bytes> \
//!     --control ws://127.0.0.1:18450/v1/ws [--relay-only] [--address 10.0.0.2:42459] [--port 42459]
//!     [--binary-mb 64]   both sides exchange 64 MiB of binary frames (as fast transfers send) instead of text lines

use bridgey_connect::ffi;
use bridgey_connect_proto::b64;
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpStream;
use std::time::{Duration, Instant};

fn arg(name: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

fn flag(name: &str) -> bool {
    std::env::args().any(|a| a == name)
}

fn main() {
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng).expect("key");
    let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng).expect("key");
    let port: u16 = arg("--port").and_then(|p| p.parse().ok()).unwrap_or(0);
    let config = json!({
        "port": port,
        "controlUrl": arg("--control"),
        "app": "bridgey-probe/0.1",
        "nodeKey": b64::url_encode(key.public_key().as_ref()),
        "relayOnly": flag("--relay-only"),
    });
    let started = Instant::now();
    let reply: Value = serde_json::from_str(&ffi::start(&config.to_string())).unwrap();
    let handle = reply["handle"].as_u64().unwrap_or_else(|| panic!("start failed: {reply}"));
    let addresses: Vec<Value> = std::env::args()
        .collect::<Vec<_>>()
        .windows(2)
        .filter(|w| w[0] == "--address")
        .map(|w| {
            let (a, p) = w[1].rsplit_once(':').unwrap();
            json!({"a": a.trim_matches(|c| c == '[' || c == ']'), "p": p.parse::<u16>().unwrap(), "kind": "lan"})
        })
        .collect();
    let peer = json!({"id": arg("--peer").unwrap(), "side": arg("--side").unwrap().parse::<u8>().unwrap(), "pairSecret": arg("--secret").unwrap(), "addresses": addresses, "connected": false});
    let set = ffi::command(handle, &json!({"c": "peers", "peers": [peer]}).to_string());
    println!("{}", json!({"probe": "peers", "reply": serde_json::from_str::<Value>(&set).unwrap()}));
    let relay_only_after: Option<u64> = arg("--relay-only-after").and_then(|s| s.parse().ok());
    let run_for: u64 = arg("--seconds").and_then(|s| s.parse().ok()).unwrap_or(40);
    let mut flipped = false;
    let lines = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    while started.elapsed() < Duration::from_secs(run_for) {
        if let Some(after) = relay_only_after {
            if !flipped && started.elapsed() >= Duration::from_secs(after) {
                flipped = true;
                println!("{}", json!({"probe": "relay_only_on", "atMs": started.elapsed().as_millis() as u64}));
                ffi::command(handle, &json!({"c": "debug", "relayOnly": true}).to_string());
            }
        }
        let Some(event) = ffi::next_event(handle, 200) else { continue };
        let event: Value = serde_json::from_str(&event).unwrap();
        match event["e"].as_str().unwrap_or_default() {
            "sign" => {
                let data = b64::std_decode(event["data"].as_str().unwrap()).unwrap();
                let sig = key.sign(&rng, &data).unwrap();
                ffi::command(handle, &json!({"c": "sign.result", "id": event["id"], "sig": b64::std_encode(sig.as_ref())}).to_string());
            }
            "tunnel" => {
                println!("{}", json!({"probe": "tunnel", "atMs": started.elapsed().as_millis() as u64, "event": event}));
                let port = event["port"].as_u64().unwrap() as u16;
                let token = event["token"].as_str().unwrap().to_string();
                let client = event["quicClient"].as_bool().unwrap();
                let tunnel = event["tunnel"].as_str().unwrap().to_string();
                let lines = lines.clone();
                std::thread::spawn(move || run_bridge(port, &token, client, &tunnel, started, lines));
            }
            _ => println!("{}", json!({"probe": "event", "atMs": started.elapsed().as_millis() as u64, "event": event})),
        }
    }
    let status: Value = serde_json::from_str(&ffi::command(handle, r#"{"c":"status"}"#)).unwrap();
    println!("{}", json!({"probe": "status", "status": status, "echoes": lines.load(std::sync::atomic::Ordering::Relaxed)}));
    ffi::stop(handle);
}

fn run_bridge(port: u16, token: &str, client: bool, tunnel: &str, started: Instant, lines: std::sync::Arc<std::sync::atomic::AtomicU64>) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("bridge");
    stream.set_nodelay(true).ok();
    stream.write_all(format!("{token}\n").as_bytes()).unwrap();
    if let Some(mb) = arg("--binary-mb").and_then(|m| m.parse::<usize>().ok()) {
        return run_binary(stream, mb, client, tunnel, started);
    }
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    if client {
        // Like the apps' probe after a network change: no answer in 3 s means the path is gone.
        stream.set_read_timeout(Some(Duration::from_secs(3))).ok();
        let mut rtts = Vec::new();
        for n in 0.. {
            let sent = Instant::now();
            // A recognisable plaintext marker, so a capture can prove the relay never sees it.
            if stream.write_all(format!("{{\"kind\":\"probe.ping\",\"secret\":\"PLAINTEXT-MARKER-{n}\"}}\n").as_bytes()).is_err() {
                break;
            }
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            rtts.push(sent.elapsed().as_micros() as u64);
            lines.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if n == 0 {
                println!("{}", json!({"probe": "first_echo", "tunnel": tunnel, "atMs": started.elapsed().as_millis() as u64, "rttUs": rtts[0]}));
            }
            if rtts.len() == 20 {
                rtts.sort();
                println!("{}", json!({"probe": "echo_rtt", "tunnel": tunnel, "medianUs": rtts[10], "maxUs": rtts[19]}));
                rtts.clear();
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    } else {
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {
                    if stream.write_all(line.as_bytes()).is_err() {
                        break;
                    }
                    lines.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
        }
    }
    println!("{}", json!({"probe": "bridge_closed", "tunnel": tunnel, "atMs": started.elapsed().as_millis() as u64}));
}

/// `--binary-mb N`: the session's bytes are not all text. Fast transfers (files_fast_draft1) put binary frames on the
/// same stream: a 0xB1 marker, then up to 1 MiB of ciphertext that holds every byte value, newlines included. The QUIC
/// client sends N MiB shaped like 256 KiB frames; the other side echoes every byte; the client checks that the echo is
/// identical (SHA-256) and times it.
fn run_binary(mut stream: TcpStream, mb: usize, client: bool, tunnel: &str, started: Instant) {
    use ring::digest::{Context, SHA256};
    use std::io::Read;
    if !client {
        let mut buf = vec![0u8; 1 << 20];
        loop {
            match stream.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if stream.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
        println!("{}", json!({"probe": "binary_echo_closed", "tunnel": tunnel}));
        return;
    }
    let total = mb << 20;
    let mut frame = vec![0u8; 6 + 256 * 1024];
    let mut writer = stream.try_clone().unwrap();
    let sender = std::thread::spawn(move || {
        let mut digest = Context::new(&SHA256);
        let mut seed: u32 = 0x9E37_79B9;
        let mut sent = 0;
        while sent < total {
            frame[0] = 0xB1;
            frame[1] = 1;
            let body = (frame.len() - 6) as u32;
            frame[2..6].copy_from_slice(&body.to_be_bytes());
            for byte in frame[6..].iter_mut() {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                *byte = seed as u8;
            }
            let take = frame.len().min(total - sent);
            digest.update(&frame[..take]);
            if writer.write_all(&frame[..take]).is_err() {
                break;
            }
            sent += take;
        }
        digest.finish()
    });
    let begun = Instant::now();
    let mut digest = Context::new(&SHA256);
    let mut buf = vec![0u8; 1 << 20];
    let mut received = 0;
    while received < total {
        match stream.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                digest.update(&buf[..n]);
                received += n;
            }
        }
    }
    let seconds = begun.elapsed().as_secs_f64();
    let sent = sender.join().unwrap();
    let identical = received == total && digest.finish().as_ref() == sent.as_ref();
    println!("{}", json!({"probe": "binary_echo", "tunnel": tunnel, "atMs": started.elapsed().as_millis() as u64, "bytes": received,
        "identical": identical, "mbPerSecondEachWay": (received as f64 / 1e6 / seconds * 10.0).round() / 10.0}));
}
