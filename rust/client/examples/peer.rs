//! A scripted Bridgey device for tests of apps built on the session client (the Windows UI tests pair with it on
//! the CI runner). It confirms every code, writes one JSON line per event to stdout, can send clipboard text once
//! connected, and takes commands on stdin, one per line, for the device it is connected to:
//!
//!   clipboard <text>         send text
//!   file <path>              send a file
//!   battery <level> <0|1>    report its battery (level 0 to 100, charging)
//!   ring | stop-ring         ring the other device, or stop it
//!   stopped                  it stopped ringing itself (after the other device rang it)
//!   notify <json>            post a notification (the notifications.post payload)
//!   unnotify <id>            the notification went away on the phone
//!   codes-status <status>    allowed, hidden or not_linked
//!   link <url> | link-open <url>   send a link (kept for Open, or opened right away)
//!   media <action> [value]   a media button (toggle, pause, next, previous, seek, volume)
//!
//!   peer --name "Test phone" --port 42470 --allow [--send "text"] [--pair 127.0.0.1:42458] [--discover]
//!        [--receive-dir <folder>] [--seconds 300]
//!
//! Files, battery, find device and notifications (with routing, presence and code status) are on. It never touches a real device's settings: identity and trust live in
//! memory and end with the process.

use bridgey_core::{Client, Config, Event, MemoryStorage, Next};
use serde_json::json;
use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn out(v: serde_json::Value) {
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{v}");
    let _ = stdout.flush();
}

fn main() {
    let mut name = "Bridgey test peer".to_string();
    let mut port = 0u16;
    let mut allow = false;
    let mut send: Option<String> = None;
    let mut pair: Option<String> = None;
    let mut seconds = 300u64;
    let mut discover = false;
    let mut receive_dir: Option<String> = None;
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
            "--receive-dir" => receive_dir = Some(value()),
            other => panic!("unknown argument {other}"),
        }
    }
    let mut config = Config::new(&name, "android");
    config.port = port;
    config.discovery = discover;
    for key in ["files", "battery", "find_device", "notifications", "notification_routing_draft1", "device_presence_draft1", "sms_codes_draft1", "links", "media"] {
        config.defaults.set(key, true);
    }
    let client = Arc::new(Client::start(config, Arc::new(MemoryStorage::default())).expect("peer starts"));
    if let Some(dir) = &receive_dir {
        client.set_receive_dir(Some(std::path::Path::new(dir)));
    }
    out(json!({"event": "ready", "deviceId": client.device_id(), "port": client.port()}));
    if allow {
        client.allow_pairing(Duration::from_secs(600));
    }
    if let Some(target) = pair {
        let (host, port) = target.rsplit_once(':').map(|(h, p)| (h.to_string(), p.parse().expect("port"))).unwrap_or((target, 0));
        client.pair(None, Some(&host), port).expect("pair");
    }
    let connected: Arc<Mutex<Option<String>>> = Arc::default();
    let sequence = Arc::new(std::sync::atomic::AtomicU64::new(0));
    {
        let (client, connected, sequence) = (client.clone(), connected.clone(), sequence.clone());
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                let Ok(line) = line else { return };
                let Some(device) = connected.lock().unwrap().clone() else {
                    out(json!({"event": "command", "ok": false, "error": "not connected", "line": line}));
                    continue;
                };
                let (command, rest) = line.split_once(' ').unwrap_or((line.as_str(), ""));
                let result = match command {
                    "clipboard" => client.send_clipboard(&device, rest).map(|_| ()),
                    "file" => client.send_file(&device, std::path::Path::new(rest), None, None).map(|_| ()),
                    "battery" => {
                        let mut parts = rest.split_whitespace();
                        let level = parts.next().and_then(|l| l.parse().ok()).unwrap_or(50);
                        let charging = parts.next() == Some("1");
                        client.set_battery(Some((level, charging)));
                        Ok(())
                    }
                    "ring" => client.find(&device, true),
                    "stop-ring" => client.find(&device, false),
                    "stopped" => client.find_stopped(&device),
                    "notify" => client.send_as_phone_for_tests(&device, "notifications.post", rest),
                    "unnotify" => client.send_as_phone_for_tests(&device, "notifications.remove", &json!({"notificationId": rest}).to_string()),
                    "codes-status" => client.send_as_phone_for_tests(&device, "codes.status", &json!({"version": 1, "status": rest}).to_string()),
                    "link" | "link-open" | "media" => {
                        let (feature, action, value) = match command {
                            "link" => ("links", "offer", rest.to_string()),
                            "link-open" => ("links", "open", rest.to_string()),
                            _ => {
                                let (a, v) = rest.split_once(' ').unwrap_or((rest, ""));
                                ("media", a, v.to_string())
                            }
                        };
                        let seq = sequence.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                        let payload = json!({"version": 1, "requestId": bridgey_core::crypto::uuid4(), "feature": feature, "action": action, "value": value, "sequence": seq});
                        client.send_as_phone_for_tests(&device, "quick.request", &payload.to_string())
                    }
                    _ => {
                        out(json!({"event": "command", "ok": false, "error": "unknown command", "line": line}));
                        continue;
                    }
                };
                out(json!({"event": "command", "command": command, "ok": result.is_ok(), "error": result.err().map(|e| e.to_string())}));
            }
        });
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
            Event::Connected { device_id, name } => {
                *connected.lock().unwrap() = Some(device_id.clone());
                out(json!({"event": "connected", "deviceId": device_id, "name": name}));
            }
            Event::Disconnected { device_id, reason } => {
                *connected.lock().unwrap() = None;
                out(json!({"event": "disconnected", "deviceId": device_id, "reason": reason}));
            }
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
            // Transfers in one shape for the UI tests: direction, state (receiving, sending, done, failed), name, path.
            Event::FileIncoming { transfer, device_id, name, size, .. } => out(json!({"event": "transfer", "transfer": transfer, "deviceId": device_id, "direction": "receive", "state": "receiving", "name": name, "bytes": 0, "total": size})),
            Event::FileProgress { transfer, device_id, incoming, bytes, total } => out(json!({"event": "transfer", "transfer": transfer, "deviceId": device_id, "direction": if incoming { "receive" } else { "send" }, "state": if incoming { "receiving" } else { "sending" }, "bytes": bytes, "total": total})),
            Event::FileDone { transfer, device_id, incoming, name, path, size } => out(json!({"event": "transfer", "transfer": transfer, "deviceId": device_id, "direction": if incoming { "receive" } else { "send" }, "state": "done", "name": name, "path": path, "bytes": size, "total": size})),
            Event::FileFailed { transfer, device_id, incoming, name, reason } => out(json!({"event": "transfer", "transfer": transfer, "deviceId": device_id, "direction": if incoming { "receive" } else { "send" }, "state": "failed", "name": name, "reason": reason})),
            Event::Battery { level, charging, .. } => out(json!({"event": "battery", "level": level, "charging": charging})),
            Event::FindRequested { ring, .. } => out(json!({"event": "find", "ring": ring})),
            Event::FindState { ringing, .. } => out(json!({"event": "ringing", "ringing": ringing})),
            Event::Link { url, open, .. } => out(json!({"event": "link", "url": url, "open": open})),
            _ => {}
        }
    }
    client.stop();
}
