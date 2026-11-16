//! A scripted Bridgey device for tests of apps built on the session client (the Windows UI tests pair with it on
//! the CI runner). It confirms every code, writes one JSON line per event to stdout, and can send clipboard text
//! once connected.
//!
//!   peer --name "Test phone" --port 42470 --allow [--send "text"] [--pair 127.0.0.1:42458] [--discover] [--seconds 300]
//!
//! It never touches a real device's settings: identity and trust live in memory and end with the process.

use bridgey_core::{Client, Config, Event, MemoryStorage, Next};
use serde_json::json;
use std::io::Write;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn main() {
    let mut name = "Bridgey test peer".to_string();
    let mut port = 0u16;
    let mut allow = false;
    let mut send: Option<String> = None;
    let mut pair: Option<String> = None;
    let mut seconds = 300u64;
    let mut discover = false;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().unwrap_or_else(|| panic!("{arg} needs a value"));
        match arg.as_str() {
            "--name" => name = value(),
            "--port" => port = value().parse().expect("port"),
            "--allow" => allow = true,
            "--send" => send = Some(value()),
            "--pair" => pair = Some(value()),
            "--seconds" => seconds = value().parse().expect("seconds"),
            "--discover" => discover = true,
            other => panic!("unknown argument {other}"),
        }
    }
    let mut config = Config::new(&name, "android");
    config.port = port;
    config.discovery = discover;
    let client = Client::start(config, Arc::new(MemoryStorage::default())).expect("peer starts");
    let out = |v: serde_json::Value| {
        let mut stdout = std::io::stdout().lock();
        let _ = writeln!(stdout, "{v}");
        let _ = stdout.flush();
    };
    out(json!({"event": "ready", "deviceId": client.device_id(), "port": client.port()}));
    if allow {
        client.allow_pairing(Duration::from_secs(600));
    }
    if let Some(target) = pair {
        let (host, port) = target.rsplit_once(':').map(|(h, p)| (h.to_string(), p.parse().expect("port"))).unwrap_or((target, 0));
        client.pair(None, Some(&host), port).expect("pair");
    }
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut sent = false;
    while Instant::now() < deadline {
        let Next::Event(e) = client.next_event(Duration::from_millis(200)) else { continue };
        match e {
            Event::PairingCode { pairing, code, name, .. } => {
                out(json!({"event": "code", "code": code, "name": name}));
                let _ = client.confirm_pairing(pairing, true);
            }
            Event::PairingFinished { ok, reason, .. } => out(json!({"event": "paired", "ok": ok, "reason": reason})),
            Event::Connected { device_id, name } => out(json!({"event": "connected", "deviceId": device_id, "name": name})),
            Event::Disconnected { device_id, reason } => out(json!({"event": "disconnected", "deviceId": device_id, "reason": reason})),
            Event::Features { device_id, remote, .. } => {
                out(json!({"event": "features", "deviceId": device_id, "remote": remote.to_json()}));
                if let (Some(text), false, true) = (&send, sent, remote.get("clipboard")) {
                    // Give the app a moment to show the device before the text arrives.
                    std::thread::sleep(Duration::from_millis(1500));
                    let r = client.send_clipboard(&device_id, text);
                    out(json!({"event": "sending", "ok": r.is_ok()}));
                    sent = true;
                }
            }
            Event::Clipboard { device_id, text, .. } => out(json!({"event": "clipboard", "deviceId": device_id, "text": text})),
            Event::ClipboardSent { status, .. } => out(json!({"event": "sent", "status": format!("{status:?}")})),
            Event::Ping { device_id } => out(json!({"event": "ping", "deviceId": device_id})),
            _ => {}
        }
    }
    client.stop();
}
