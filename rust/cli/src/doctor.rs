//! `bridgey doctor`: what works from this host, one line per check (connect-anywhere 12.2 plus this install).
//!
//! Binary and version; config and key permissions; daemon and service; the control service (and the clock,
//! from its Date header); every relay's STUN from this host and the daemon's relay allocation; the route to
//! each paired device; and what each device granted.

use crate::client;
use crate::config::Config;
use crate::paths::{mode, Paths};
use crate::time::now_ms;
use serde_json::{json, Value};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq)]
pub enum Level {
    Ok,
    Warn,
    Fail,
}

pub struct Check {
    pub name: String,
    pub level: Level,
    pub detail: String,
    pub data: Value,
}

fn check(name: &str, level: Level, detail: impl Into<String>, data: Value) -> Check {
    Check { name: name.into(), level, detail: detail.into(), data }
}

fn perm_check(name: &str, path: &std::path::Path, want: u32) -> Check {
    match mode(path) {
        None => check(name, Level::Warn, format!("{} does not exist yet", path.display()), json!({"path": path})),
        Some(m) if m & 0o077 == 0 => check(name, Level::Ok, format!("{} ({:o})", path.display(), m), json!({"path": path, "mode": format!("{m:o}")})),
        Some(m) => check(name, Level::Fail, format!("{} is {:o}; run chmod {:o} {}", path.display(), m, want, path.display()), json!({"path": path, "mode": format!("{m:o}")})),
    }
}

/// WebSocket handshake to the control service: (milliseconds, server clock skew in ms).
async fn control(url: &str) -> Result<(u64, Option<i64>), String> {
    let started = Instant::now();
    let connect = tokio_tungstenite::connect_async(url);
    let (mut ws, response) = tokio::time::timeout(Duration::from_secs(8), connect).await.map_err(|_| "timed out after 8 s".to_string())?.map_err(|e| e.to_string())?;
    let ms = started.elapsed().as_millis() as u64;
    let skew = response.headers().get("date").and_then(|d| d.to_str().ok()).and_then(parse_http_date).map(|server| server as i64 - now_ms() as i64);
    let _ = ws.close(None).await;
    Ok((ms, skew))
}

/// `Tue, 03 Nov 2026 12:04:31 GMT` to Unix ms.
fn parse_http_date(text: &str) -> Option<u64> {
    let parts: Vec<&str> = text.split_whitespace().collect();
    if parts.len() < 5 {
        return None;
    }
    let day: i64 = parts[1].parse().ok()?;
    let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].iter().position(|m| *m == parts[2])? as i64 + 1;
    let year: i64 = parts[3].parse().ok()?;
    let hms: Vec<i64> = parts[4].split(':').filter_map(|x| x.parse().ok()).collect();
    if hms.len() != 3 {
        return None;
    }
    // Days from civil (Howard Hinnant).
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(((days * 86_400 + hms[0] * 3600 + hms[1] * 60 + hms[2]) * 1000) as u64)
}

/// One STUN binding from a fresh socket: the round trip and our public address as the relay sees it.
async fn stun(addr: &str) -> Result<(u64, String), String> {
    use bridgey_connect::stun::{Message, ATTR_XOR_MAPPED_ADDRESS, BINDING};
    let target = tokio::net::lookup_host(addr).await.map_err(|e| e.to_string())?.find(|a| a.is_ipv4()).ok_or("no IPv4 address")?;
    let sock = tokio::net::UdpSocket::bind("0.0.0.0:0").await.map_err(|e| e.to_string())?;
    let m = Message::request(BINDING);
    let packet = m.encode(None, true);
    let started = Instant::now();
    let mut buf = [0u8; 1500];
    for attempt in 0..3 {
        sock.send_to(&packet, target).await.map_err(|e| e.to_string())?;
        if let Ok(Ok((n, _))) = tokio::time::timeout(Duration::from_millis(500 * (attempt + 1)), sock.recv_from(&mut buf)).await {
            if let Some(reply) = Message::decode(&buf[..n]).filter(|r| r.txid == m.txid) {
                let mapped = reply.xor_address(ATTR_XOR_MAPPED_ADDRESS).map(|a| a.to_string()).unwrap_or_default();
                return Ok((started.elapsed().as_millis() as u64, mapped));
            }
        }
    }
    Err("no answer (UDP blocked?)".into())
}

pub async fn run(paths: &Paths, config: &Config, connect_ms: u64) -> Vec<Check> {
    let mut checks = Vec::new();
    let exe = std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default();
    checks.push(check("binary", Level::Ok, format!("bridgey {} ({} {}) at {exe}", crate::daemon::VERSION, std::env::consts::OS, std::env::consts::ARCH), json!({"version": crate::daemon::VERSION, "path": exe, "os": std::env::consts::OS, "arch": std::env::consts::ARCH})));
    // Files and permissions.
    checks.push(perm_check("config folder", &paths.root, 0o700));
    if paths.config.exists() {
        checks.push(perm_check("config.toml", &paths.config, 0o600));
    }
    checks.push(perm_check("keys folder", &paths.keys, 0o700));
    for k in ["identity.p8", "node.p8"] {
        checks.push(perm_check(&format!("key {k}"), &paths.keys.join(k), 0o600));
    }
    checks.push(perm_check("trust records", &paths.state.join("trust.json"), 0o600));
    // Daemon and service.
    let svc = crate::service::status(paths);
    let was_running = client::request(paths, "status", json!({}), false, |_| {}).await.is_ok();
    // Start one if needed (as any command would), and give a fresh one a moment to sign in for the relay list.
    let mut daemon = client::request(paths, "status", json!({}), true, |_| {}).await;
    for _ in 0..30 {
        match &daemon {
            Ok(s) if s["coreState"]["relays"].as_array().is_none_or(|r| r.is_empty()) && s["control"] != "unreachable" => {
                tokio::time::sleep(Duration::from_millis(200)).await;
                daemon = client::request(paths, "status", json!({}), false, |_| {}).await;
            }
            _ => break,
        }
    }
    match &daemon {
        Ok(s) => checks.push(check(
            "daemon",
            Level::Ok,
            format!(
                "running (pid {}, {}{})",
                s["pid"],
                if s["service"] == true { "service" } else { "started by a command, stops when idle" },
                if was_running { format!(", up {}", crate::time::relative(s["startedAt"].as_u64().unwrap_or(0), now_ms()).replace(" ago", "")) } else { ", just started".into() }
            ),
            s.clone(),
        )),
        Err(_) => checks.push(check("daemon", Level::Warn, "not running (a command starts one; bridgey service install keeps one)", Value::Null)),
    }
    let svc_level = if svc["active"] == true { Level::Ok } else if svc["installed"] == true { Level::Fail } else { Level::Warn };
    let mut svc_detail = match (svc["installed"].as_bool(), svc["active"].as_bool()) {
        (Some(true), Some(true)) => format!("{} active and enabled", svc["path"].as_str().unwrap_or("")),
        (Some(true), _) => format!("installed but not running; see journalctl --user -u {}", svc["unit"].as_str().unwrap_or("bridgey")),
        _ => "not installed (bridgey service install)".into(),
    };
    if svc["linger"] == false {
        svc_detail.push_str("; lingering is off, so it stops when you log out (loginctl enable-linger)");
    }
    checks.push(check("service", if svc["linger"] == false && svc_level == Level::Ok { Level::Warn } else { svc_level }, svc_detail, svc));
    // Control service and the clock.
    let url = config.control_url();
    match control(&url).await {
        Ok((ms, skew)) => {
            checks.push(check("control service", Level::Ok, format!("{url} reached in {ms} ms"), json!({"url": url, "ms": ms})));
            match skew {
                Some(s) if s.abs() > 60_000 => checks.push(check("clock", Level::Fail, format!("{} s off the control service (sealed signals older than 5 minutes are dropped); fix NTP", s / 1000), json!({"skewMs": s}))),
                Some(s) if s.abs() > 5_000 => checks.push(check("clock", Level::Warn, format!("{} s off the control service", s / 1000), json!({"skewMs": s}))),
                Some(s) => checks.push(check("clock", Level::Ok, format!("within {} s of the control service", (s.abs() / 1000).max(1)), json!({"skewMs": s}))),
                None => checks.push(check("clock", Level::Warn, "the control service sent no Date header", Value::Null)),
            }
        }
        Err(e) => checks.push(check("control service", Level::Fail, format!("{url}: {e}"), json!({"url": url, "error": e}))),
    }
    // Relays: the pool comes from the daemon's last sign-in.
    if let Ok(s) = &daemon {
        let relays = s["coreState"]["relays"].as_array().cloned().unwrap_or_default();
        if relays.is_empty() {
            checks.push(check("relays", Level::Warn, "the daemon has no relay list yet (no sign-in to the control service)", Value::Null));
        }
        for r in relays {
            let id = r["id"].as_str().unwrap_or("?").to_string();
            let addr = r["addr"].as_str().unwrap_or("").to_string();
            let name = format!("relay {} ({id})", crate::daemon::relay_name(&id));
            match stun(&addr).await {
                Ok((ms, mapped)) => checks.push(check(&name, Level::Ok, format!("STUN {ms} ms; this host is {mapped} from there"), json!({"id": id, "addr": addr, "ms": ms, "mapped": mapped}))),
                Err(e) => checks.push(check(&name, Level::Fail, format!("STUN to {addr}: {e}"), json!({"id": id, "addr": addr, "error": e}))),
            }
        }
        let warm = &s["coreState"]["warm"];
        if warm.is_object() {
            checks.push(check("relay allocation", Level::Ok, format!("TURN allocation held on {}", crate::daemon::relay_name(warm["relay"].as_str().unwrap_or("?"))), json!({"relay": warm["relay"]})));
        } else {
            checks.push(check("relay allocation", Level::Warn, "no TURN allocation held yet (made when needed)", Value::Null));
        }
    }
    // Detect codes: the build, the model.
    let detect = crate::detect::status(paths);
    let (level, detail) = match (crate::detect::BUILT_WITH_DETECTOR, detect["installed"].is_object()) {
        (false, _) => (Level::Ok, "this build cannot detect codes (built without the model runner)".to_string()),
        (true, false) => (Level::Ok, "no code model; bridgey codes model download --accept-terms to detect codes for the phone".to_string()),
        (true, true) => (Level::Ok, format!("ready: {} (switch Detect codes on for this install on the phone)", detect["installed"]["name"].as_str().unwrap_or("model"))),
    };
    checks.push(check("detect codes", level, detail, detect));
    // Routes and grants per device.
    let devices = client::request(paths, "devices", json!({}), true, |_| {}).await.ok().and_then(|d| d["devices"].as_array().cloned()).unwrap_or_default();
    if devices.is_empty() {
        checks.push(check("devices", Level::Warn, "nothing paired yet (bridgey pair)", Value::Null));
    }
    for d in devices {
        let name = d["name"].as_str().unwrap_or("?").to_string();
        let id = d["id"].as_str().unwrap_or("").to_string();
        let st = client::request(paths, "device-status", json!({"device": id, "connectTimeoutMs": connect_ms}), true, |_| {}).await;
        match st {
            Ok(s) => {
                let route = match s["route"].as_str() {
                    Some("relay") => format!("relay ({})", s["relayName"].as_str().unwrap_or("?")),
                    Some("vpn") => "private network".into(),
                    Some("lan") => "same network".into(),
                    Some(r) => r.to_string(),
                    None => "?".into(),
                };
                checks.push(check(&format!("route to {name}"), Level::Ok, format!("{route}, round trip {} ms", s["rttMs"]), s.clone()));
            }
            Err(e) => checks.push(check(&format!("route to {name}"), Level::Fail, e.message.clone(), e.to_json())),
        }
        if let Ok(g) = client::request(paths, "grants", json!({"device": id, "connectTimeoutMs": 2000}), true, |_| {}).await {
            let on: Vec<String> = g["grants"].as_array().map(|a| a.iter().filter(|x| x["state"] == "on").filter_map(|x| x["key"].as_str().map(str::to_string)).collect()).unwrap_or_default();
            let waiting = g["grants"].as_array().map(|a| a.iter().filter(|x| x["state"] == "waiting").count()).unwrap_or(0);
            let detail = if on.is_empty() { "nothing granted yet; turn permissions on in Bridgey on the phone".to_string() } else { format!("on: {}", on.join(", ")) };
            let detail = if waiting > 0 { format!("{detail}; {waiting} waiting for you") } else { detail };
            checks.push(check(&format!("grants from {name}"), if on.is_empty() { Level::Warn } else { Level::Ok }, detail, g));
        }
    }
    checks
}

#[cfg(test)]
mod tests {
    #[test]
    fn http_dates() {
        assert_eq!(super::parse_http_date("Sat, 25 Oct 2025 13:46:40 GMT"), Some(1_761_400_000_000));
    }
}
