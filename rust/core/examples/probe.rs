//! A headless test node: what an app does, without an app. Used by `server/local/live-test.sh`.
//!
//! It joins the control service with a software node key, keeps one peer, and on every tunnel
//! connects to the loopback bridge. The QUIC client sends numbered lines and times the echoes;
//! the other side echoes them. Output is one JSON line per event or measurement.
//!
//! cargo run --example probe -- --id A --peer B --side 0 --secret <base64 32 bytes> \
//!     --control ws://127.0.0.1:18450/v1/ws [--relay-only] [--address 10.0.0.2:42459] [--port 42459] [--state file] [--key file]

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
    // --key <file>: the same node key every run, as an app keeps it (a fresh one otherwise).
    let saved = arg("--key").and_then(|p| std::fs::read(p).ok());
    let pkcs8 = match saved {
        Some(bytes) => bytes,
        None => {
            let fresh = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng).expect("key").as_ref().to_vec();
            if let Some(path) = arg("--key") {
                let _ = std::fs::write(path, &fresh);
            }
            fresh
        }
    };
    let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &pkcs8, &rng).expect("key");
    let port: u16 = arg("--port").and_then(|p| p.parse().ok()).unwrap_or(0);
    let config = json!({
        "port": port,
        "controlUrl": arg("--control"),
        "app": "bridgey-probe/0.1",
        "nodeKey": b64::url_encode(key.public_key().as_ref()),
        "relayOnly": flag("--relay-only"),
        "state": arg("--state").and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| serde_json::from_str::<Value>(&t).ok()),
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
            // What an app keeps between runs (--state <file>): the next start reuses it.
            "state" => {
                if let Some(path) = arg("--state") {
                    let _ = std::fs::write(path, event["state"].to_string());
                }
                println!("{}", json!({"probe": "event", "atMs": started.elapsed().as_millis() as u64, "event": {"e": "log", "msg": "state saved"}}));
            }
            "tunnel" => {
                println!("{}", json!({"probe": "tunnel", "atMs": started.elapsed().as_millis() as u64, "event": event}));
                let port = event["port"].as_u64().unwrap() as u16;
                let token = event["token"].as_str().unwrap().to_string();
                let client = event["quicClient"].as_bool().unwrap();
                let tunnel = event["tunnel"].as_str().unwrap().to_string();
                let lines = lines.clone();
                std::thread::spawn(move || run_bridge(handle, port, &token, client, &tunnel, started, lines));
            }
            _ => println!("{}", json!({"probe": "event", "atMs": started.elapsed().as_millis() as u64, "event": event})),
        }
    }
    let status: Value = serde_json::from_str(&ffi::command(handle, r#"{"c":"status"}"#)).unwrap();
    println!("{}", json!({"probe": "status", "status": status, "echoes": lines.load(std::sync::atomic::Ordering::Relaxed)}));
    ffi::stop(handle);
}

/// Like the apps, the probe tells the core when a session works (its first echo): a tunnel that closes after
/// that is redialled at once, one that never worked backs off.
fn authenticated(handle: u64, tunnel: &str) {
    ffi::command(handle, &json!({"c": "authenticated", "tunnel": tunnel}).to_string());
}

fn run_bridge(handle: u64, port: u16, token: &str, client: bool, tunnel: &str, started: Instant, lines: std::sync::Arc<std::sync::atomic::AtomicU64>) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).expect("bridge");
    stream.set_nodelay(true).ok();
    stream.write_all(format!("{token}\n").as_bytes()).unwrap();
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
                authenticated(handle, tunnel);
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
                    if lines.fetch_add(1, std::sync::atomic::Ordering::Relaxed) == 0 {
                        authenticated(handle, tunnel);
                    }
                }
            }
        }
    }
    println!("{}", json!({"probe": "bridge_closed", "tunnel": tunnel, "atMs": started.elapsed().as_millis() as u64}));
}
