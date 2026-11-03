//! What each command does inside the daemon. A client sends `{"cmd": ..., "args": {...}}`; each op streams
//! events and returns its result, which `serve` writes and records in the audit log.

use crate::daemon::{not_granted, relay_name, Ask, Daemon, InviteEvent, Reply, TransferInfo, GRANTS};
use crate::errors::CliError;
use crate::ipc::Conn;
use crate::store::Peer;
use crate::time::now_ms;
use serde_json::{json, Value};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::mpsc;

pub struct Out {
    writer: OwnedWriteHalf,
}

impl Out {
    pub async fn event(&mut self, v: Value) {
        let mut line = v.to_string();
        line.push('\n');
        let _ = self.writer.write_all(line.as_bytes()).await;
    }
}

async fn read_line(reader: &mut BufReader<OwnedReadHalf>) -> Option<Value> {
    let mut line = String::new();
    let mut limited = reader.take(64 * 1024);
    match limited.read_line(&mut line).await {
        Ok(0) | Err(_) => None,
        Ok(_) => serde_json::from_str(line.trim_end()).ok(),
    }
}

fn arg_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args[key].as_str().filter(|s| !s.is_empty())
}

fn arg_ms(args: &Value, key: &str, default: u64) -> u64 {
    args[key].as_u64().unwrap_or(default)
}

fn device_json(p: &Peer) -> Value {
    json!({"id": p.device_id, "name": p.name})
}

/// A reply, or timeout. Refusals (agent.request_result) become errors.
async fn next_reply(rx: &mut mpsc::UnboundedReceiver<Reply>, timeout: Duration, peer: &Peer, me: &str) -> Result<Reply, CliError> {
    match tokio::time::timeout(timeout, rx.recv()).await {
        Ok(Some(r)) if r.kind == "agent.request_result" => {
            let p = r.payload.clone().unwrap_or(Value::Null);
            match p["status"].as_str().unwrap_or("") {
                "ok" => Ok(r),
                "not_granted" => Err(not_granted(&peer.name, p["grant"].as_str().unwrap_or("that"), me)),
                "rate_limited" => Err(CliError::new("rate_limited", format!("{} is limiting requests from this device; try again later", peer.name)).with("retryAfterMs", p["retryAfterMs"].as_u64().unwrap_or(0))),
                "busy" => Err(CliError::new("rate_limited", format!("{} already has too many open requests from this device", peer.name)).with("retryAfterMs", 0)),
                "invalid" => Err(CliError::new("usage", format!("{} refused the request as invalid (a field over its limit?)", peer.name))),
                "unknown" => Err(CliError::new("failed", format!("{} does not know that request", peer.name))),
                other => Err(CliError::new("incompatible", format!("{} cannot do this ({other})", peer.name))),
            }
        }
        Ok(Some(r)) => Ok(r),
        Ok(None) => Err(CliError::new("unreachable", "the session ended")),
        Err(_) => Err(CliError::new("timeout", format!("{} did not answer in time", peer.name))),
    }
}

impl Daemon {
    pub async fn serve(self: Arc<Self>, conn: Conn) {
        self.clients.fetch_add(1, Ordering::Relaxed);
        self.used();
        let (mut reader, writer) = conn.split();
        let mut out = Out { writer };
        if let Some(req) = read_line(&mut reader).await {
            let cmd = req["cmd"].as_str().unwrap_or("").to_string();
            let args = req["args"].clone();
            let result = self.clone().dispatch(&cmd, &args, &req, &mut reader, &mut out).await;
            let (outcome, device) = match &result {
                Ok(v) => ("ok".to_string(), v["device"]["name"].as_str().map(str::to_string)),
                Err(e) => (e.code.clone(), self.resolve(arg_str(&args, "device")).ok().map(|p| p.name)),
            };
            if !matches!(cmd.as_str(), "status" | "devices" | "transfers" | "ping-daemon") {
                crate::audit::record(
                    &self.paths,
                    json!({"at": now_ms(), "command": cmd, "device": device.or_else(|| args["device"].as_str().map(str::to_string)), "outcome": outcome, "argsHash": crate::audit::args_hash(&self.paths, &args), "caller": req["caller"]}),
                );
            }
            match result {
                Ok(v) => out.event(json!({"result": v})).await,
                Err(e) => out.event(json!({"error": e.to_json()})).await,
            }
        }
        self.used();
        self.clients.fetch_sub(1, Ordering::Relaxed);
    }

    fn connect_timeout(&self, args: &Value) -> Duration {
        args["connectTimeoutMs"].as_u64().map(Duration::from_millis).unwrap_or_else(|| self.config.duration("timeouts.connect", Duration::from_secs(10)))
    }

    async fn dispatch(self: Arc<Self>, cmd: &str, args: &Value, _req: &Value, reader: &mut BufReader<OwnedReadHalf>, out: &mut Out) -> Result<Value, CliError> {
        match cmd {
            "shutdown" => {
                let d = self.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    d.stop.notify_one();
                });
                Ok(json!({"stopping": true}))
            }
            "ping-daemon" => Ok(json!({"version": crate::daemon::VERSION, "pid": std::process::id(), "service": self.service})),
            "status" => Ok(self.status_json()),
            "devices" => Ok(self.op_devices()),
            "device-status" => self.op_device_status(args).await,
            "grants" => self.op_grants(args).await,
            "grants-request" => self.op_grants_request(args).await,
            "pair" => self.op_pair(args, reader, out).await,
            "forget" => {
                let peer = self.resolve(arg_str(args, "device"))?;
                self.forget(&peer.device_id);
                Ok(json!({"device": device_json(&peer), "forgotten": true}))
            }
            "notify" => self.op_notify(args).await,
            "ask" => self.op_ask(args, out).await,
            "wait" => self.op_wait(args, out).await,
            "ring" => self.op_ring(args).await,
            "battery" => self.op_battery(args).await,
            "ping" => self.op_ping(args).await,
            "clip-set" => self.op_clip_set(args).await,
            "clip-get" => self.op_clip_get(args).await,
            "send" => self.op_send(args, out).await,
            "transfers" => Ok(json!({"transfers": self.transfers()})),
            "codes" => self.op_codes(args, out).await,
            _ => Err(CliError::new("usage", format!("unknown command {cmd}"))),
        }
    }

    fn op_devices(&self) -> Value {
        let trust = self.trust();
        let status = self.status_json();
        let devices: Vec<Value> = trust
            .peers
            .values()
            .map(|p| {
                let s = status["sessions"].as_array().and_then(|a| a.iter().find(|s| s["device"] == p.device_id.as_str())).cloned();
                let map = self.features(&p.device_id);
                let granted: Vec<&str> = GRANTS.iter().filter(|g| map.get(g.1) == Some(&Value::Bool(true))).map(|g| g.0).collect();
                let granted_cached: Vec<String> = p.grants.as_ref().and_then(|g| g.as_array()).map(|a| a.iter().filter(|g| g["state"] == "on").filter_map(|g| g["key"].as_str().map(str::to_string)).collect()).unwrap_or_default();
                json!({
                    "id": p.device_id, "name": p.name, "platform": p.platform, "pairedAt": p.paired_at, "lastSeenAt": p.last_seen_at,
                    "online": s.is_some(), "route": s.as_ref().map(|s| s["route"].clone()), "relay": s.as_ref().map(|s| s["relay"].clone()), "rttMs": s.as_ref().map(|s| s["rttMs"].clone()),
                    "granted": if s.is_some() { json!(granted) } else { json!(granted_cached) },
                    "connectAnywhere": p.pair_secret.is_some(),
                })
            })
            .collect();
        json!({"devices": devices})
    }

    async fn op_device_status(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let started = std::time::Instant::now();
        self.ensure(&peer, self.connect_timeout(args)).await?;
        let connect_ms = started.elapsed().as_millis() as u64;
        let status = self.status_json();
        let s = status["sessions"].as_array().and_then(|a| a.iter().find(|s| s["device"] == peer.device_id.as_str())).cloned().unwrap_or(Value::Null);
        let battery = self.battery(&peer.device_id).map(|(l, c, at)| json!({"level": l, "charging": c, "at": at}));
        let map = self.features(&peer.device_id);
        Ok(json!({
            "device": device_json(&peer), "route": s["route"], "relay": s["relay"], "relayName": s["relay"].as_str().map(relay_name), "rttMs": s["rttMs"],
            "connectMs": connect_ms, "since": s["since"], "battery": battery, "control": status["control"],
            "granted": GRANTS.iter().filter(|g| map.get(g.1) == Some(&Value::Bool(true))).map(|g| g.0).collect::<Vec<_>>(),
        }))
    }

    async fn op_grants(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let live = match self.ensure(&peer, self.connect_timeout(args)).await {
            Ok(_) => {
                // The phone sends agent.grants right after features.update; give it a moment on a fresh session.
                for _ in 0..20 {
                    if self.trust().peers.get(&peer.device_id).is_some_and(|p| p.grants_at >= p.last_seen_at.saturating_sub(1000)) {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                true
            }
            Err(e) if e.code == "unreachable" => false,
            Err(e) => return Err(e),
        };
        let rec = self.trust().peers.get(&peer.device_id).cloned().unwrap_or(peer.clone());
        let map = self.features(&peer.device_id);
        let listed = rec.grants.clone().unwrap_or(Value::Array(vec![]));
        let grants: Vec<Value> = GRANTS
            .iter()
            .map(|(name, wire, title, detail)| {
                let from_phone = listed.as_array().and_then(|a| a.iter().find(|g| g["key"] == *name)).cloned().unwrap_or(Value::Null);
                let state = match from_phone["state"].as_str() {
                    Some(s) => s.to_string(),
                    None if live && map.get(*wire) == Some(&Value::Bool(true)) => "on".into(),
                    None => "off".into(),
                };
                let detail = detail.replace("<this device>", &self.local.name());
                json!({"key": name, "title": title, "detail": from_phone["scope"].as_str().map(|s| format!("To {s}")).unwrap_or(detail), "state": state,
                       "window": from_phone["window"], "grantedAt": from_phone["grantedAt"], "expiresAt": from_phone["expiresAt"], "scope": from_phone["scope"]})
            })
            .collect();
        Ok(json!({"device": device_json(&peer), "live": live, "asOf": if rec.grants_at > 0 { json!(rec.grants_at) } else { Value::Null }, "grants": grants}))
    }

    async fn op_grants_request(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let keys: Vec<String> = args["keys"].as_array().map(|a| a.iter().filter_map(|k| k.as_str().map(str::to_string)).collect()).unwrap_or_default();
        if keys.is_empty() || keys.len() > 9 || keys.iter().any(|k| !GRANTS.iter().any(|g| g.0 == k)) {
            return Err(CliError::new("usage", format!("name 1 to 9 grants from: {}", GRANTS.iter().map(|g| g.0).collect::<Vec<_>>().join(", "))));
        }
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        if self.features(&peer.device_id).get("agent_draft1") != Some(&Value::Bool(true)) {
            return Err(CliError::new("incompatible", format!("{} runs a Bridgey without agent devices; update the app", peer.name)));
        }
        let mid = crate::crypto::uuid4();
        let (_g, mut rx) = self.wait_for(vec![format!("msg:{mid}")]);
        let mut payload = json!({"version": 1, "requestId": crate::crypto::uuid4(), "keys": keys});
        if let Some(n) = arg_str(args, "note") {
            payload["note"] = json!(n.chars().take(120).collect::<String>());
        }
        h.send_json_id("agent.grant_request", &payload, &mid, None);
        next_reply(&mut rx, Duration::from_secs(10), &peer, &self.local.name()).await?;
        Ok(json!({"device": device_json(&peer), "requested": keys, "status": "waiting"}))
    }

    async fn op_pair(self: Arc<Self>, args: &Value, reader: &mut BufReader<OwnedReadHalf>, out: &mut Out) -> Result<Value, CliError> {
        if let Some(name) = arg_str(args, "name") {
            self.rename(name);
        }
        let join = match arg_str(args, "join") {
            Some(link) => Some(crate::invite::Invite::parse(link, now_ms()).map_err(|e| CliError::new("usage", format!("that invite cannot be used: {e}")))?),
            None => None,
        };
        let (invite, mut rx) = self.start_invite(join);
        let label = invite.label();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(crate::invite::LIFETIME_S);
        out.event(json!({"event": "invite", "link": invite.link(), "expiresAt": invite.expires_s * 1000, "name": invite.name, "qr": if args["linkOnly"] == true { Value::Null } else { json!(crate::invite::qr(&invite.link())) }})).await;
        let result = loop {
            tokio::select! {
                _ = tokio::time::sleep_until(deadline) => break Err(CliError::new("timeout", "The invite expired (10 minutes). Run bridgey pair again.")),
                line = read_line(reader) => {
                    if line.is_none() {
                        break Err(CliError::new("interrupted", "pairing cancelled"));
                    }
                }
                ev = rx.recv() => match ev {
                    Some(InviteEvent::Code { code, peer_name, confirm }) => {
                        out.event(json!({"event": "code", "code": code, "peer": peer_name})).await;
                        // The answer comes from the person at the terminal; there is no flag that skips it.
                        let answer = tokio::time::timeout(Duration::from_secs(120), read_line(reader)).await;
                        match answer {
                            Ok(Some(v)) if v["confirm"] == true => { let _ = confirm.send(true); out.event(json!({"event": "confirmed"})).await; }
                            Ok(Some(_)) => { let _ = confirm.send(false); break Err(CliError::new("declined", "The codes did not match; nothing was paired.")); }
                            Ok(None) => { let _ = confirm.send(false); break Err(CliError::new("interrupted", "pairing cancelled")); }
                            Err(_) => { let _ = confirm.send(false); break Err(CliError::new("timeout", "No answer to the code within 2 minutes.")); }
                        }
                    }
                    Some(InviteEvent::Paired { peer }) => break Ok(peer),
                    Some(InviteEvent::Failed(reason)) => {
                        // The phone hung up or the code was refused there; a new tunnel may still come within the invite's time.
                        out.event(json!({"event": "attempt_failed", "reason": reason})).await;
                        if reason.starts_with("cancelled_remote") || reason == "code_rejected" || reason == "authentication_failed" {
                            break Err(CliError::new("declined", format!("Pairing did not finish ({reason}).")));
                        }
                    }
                    None => break Err(CliError::new("failed", "pairing ended")),
                }
            }
        };
        self.end_invite(&label);
        let peer = result?;
        // The pair secret (connect.setup) lets the two reconnect anywhere; it follows within moments.
        out.event(json!({"event": "paired", "device": {"id": peer.device_id, "name": peer.name}})).await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        while self.trust().peers.get(&peer.device_id).is_some_and(|p| p.pair_secret.is_none()) {
            if tokio::time::timeout_at(deadline, self.changed.notified()).await.is_err() {
                break;
            }
        }
        let secret = self.trust().peers.get(&peer.device_id).is_some_and(|p| p.pair_secret.is_some());
        Ok(json!({"device": {"id": peer.device_id, "name": peer.name}, "connectAnywhere": secret, "thisDevice": {"id": self.local.device_id, "name": self.local.name()}}))
    }

    async fn op_notify(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "notify")?;
        let id = crate::crypto::uuid4();
        let mid = crate::crypto::uuid4();
        let mut payload = json!({"version": 1, "notifyId": id, "title": args["title"], "priority": arg_str(args, "priority").unwrap_or("normal")});
        for k in ["body", "tag", "from"] {
            if let Some(v) = arg_str(args, k) {
                payload[k] = json!(v);
            }
        }
        let (_g, mut rx) = self.wait_for(vec![format!("notify:{id}"), format!("msg:{mid}")]);
        h.send_json_id("notify.post", &payload, &mid, None);
        next_reply(&mut rx, Duration::from_secs(10), &peer, &self.local.name()).await?;
        Ok(json!({"device": device_json(&peer), "notifyId": id, "status": "posted"}))
    }

    async fn op_ask(&self, args: &Value, out: &mut Out) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "ask")?;
        let id = crate::crypto::uuid7();
        let timeout = arg_ms(args, "timeoutMs", 30 * 60_000).min(86_400_000);
        let expires = now_ms() + timeout;
        let mut payload = json!({"version": 1, "askId": id, "title": args["title"], "options": args["options"], "allowText": args["allowText"] == true,
                                  "requireUnlock": args["requireUnlock"] == true, "expiresAt": expires});
        for k in ["body", "textHint", "from"] {
            if let Some(v) = arg_str(args, k) {
                payload[k] = json!(v);
            }
        }
        let mid = crate::crypto::uuid4();
        let (_g, mut rx) = self.wait_for(vec![format!("ask:{id}"), format!("msg:{mid}")]);
        self.add_ask(&id, Ask { device: peer.device_id.clone(), expires_at: expires, state: "sent".into(), answer: None });
        h.send_json_id("ask.request", &payload, &mid, None);
        let posted = next_reply(&mut rx, Duration::from_secs(15), &peer, &self.local.name()).await;
        if let Err(e) = posted {
            self.update_ask_state(&id, "failed");
            return Err(e);
        }
        out.event(json!({"event": "posted", "askId": id})).await;
        if args["noWait"] == true {
            return Ok(json!({"device": device_json(&peer), "askId": id, "status": "posted"}));
        }
        drop(_g);
        self.wait_answer(&peer, &id, Duration::from_millis(timeout), args, out).await
    }

    fn update_ask_state(&self, id: &str, state: &str) {
        if let Some(mut a) = self.ask(id) {
            a.state = state.into();
            self.add_ask(id, a);
        }
    }

    /// Waits for the ask's end. A timeout cancels it on the phone unless `keepOnTimeout`.
    async fn wait_answer(&self, peer: &Peer, id: &str, timeout: Duration, args: &Value, out: &mut Out) -> Result<Value, CliError> {
        let (_g, mut rx) = self.wait_for(vec![format!("ask:{id}")]);
        let deadline = tokio::time::Instant::now() + timeout;
        let mut asked_status = false;
        loop {
            if let Some(a) = self.ask(id) {
                match a.state.as_str() {
                    "answered" => {
                        let answer = a.answer.clone().unwrap_or(Value::Null);
                        let option = answer["option"].as_str().map(str::to_string);
                        let mut result = json!({"device": device_json(peer), "askId": id, "answer": answer});
                        if let Some(label) = option.as_ref().and_then(|o| args["options"].as_array().and_then(|opts| opts.iter().find(|x| x["id"] == o.as_str()))).map(|x| x["label"].clone()) {
                            result["answer"]["label"] = label;
                        }
                        if let Some(want) = arg_str(args, "failUnless") {
                            if option.as_deref() != Some(want) {
                                return Err(CliError::new("declined", format!("The answer was {}, not {want}", option.as_deref().unwrap_or("text"))).with("answer", result["answer"].clone()).with("askId", id));
                            }
                        }
                        return Ok(result);
                    }
                    "dismissed" => return Err(CliError::new("dismissed", "The question was dismissed on the phone").with("askId", id)),
                    "expired" => return Err(CliError::new("timeout", "The question expired").with("askId", id)),
                    "cancelled" => return Err(CliError::new("declined", "The question was cancelled").with("askId", id)),
                    _ => {}
                }
            }
            // A daemon that restarted, or a session that came back: ask the phone where the question stands.
            if !asked_status {
                if let Some(h) = self.handle_for(&peer.device_id) {
                    if self.ask(id).is_none() {
                        self.add_ask(id, Ask { device: peer.device_id.clone(), expires_at: now_ms() + timeout.as_millis() as u64, state: "sent".into(), answer: None });
                    }
                    h.send_json("ask.status", &json!({"version": 1, "askId": id}));
                    asked_status = true;
                }
            }
            match tokio::time::timeout_at(deadline, rx.recv()).await {
                Ok(Some(_)) => continue,
                Ok(None) => {}
                Err(_) => {
                    if args["keepOnTimeout"] != true {
                        if let Some(h) = self.handle_for(&peer.device_id) {
                            h.send_json("ask.cancel", &json!({"version": 1, "askId": id}));
                        }
                    }
                    out.event(json!({"event": "timeout", "askId": id})).await;
                    return Err(CliError::new("timeout", "No answer in time").with("askId", id));
                }
            }
            if self.handle_for(&peer.device_id).is_none() {
                // Keep waiting; reconnect in the background and ask again when the session is back.
                asked_status = false;
                let _ = self.ensure(peer, Duration::from_secs(10)).await;
            }
        }
    }

    async fn op_wait(&self, args: &Value, out: &mut Out) -> Result<Value, CliError> {
        let id = arg_str(args, "askId").filter(|i| crate::crypto::is_uuid(i)).ok_or_else(|| CliError::new("usage", "bridgey wait ASK_ID (the askId that ask --no-wait printed)"))?.to_string();
        let peer = match self.ask(&id) {
            Some(a) => self.trust().peers.get(&a.device).cloned().ok_or_else(|| CliError::new("unknown_device", "that ask's device is no longer paired"))?,
            None => self.resolve(arg_str(args, "device"))?,
        };
        let _ = self.ensure(&peer, self.connect_timeout(args)).await;
        let timeout = Duration::from_millis(arg_ms(args, "timeoutMs", 30 * 60_000).min(86_400_000));
        self.wait_answer(&peer, &id, timeout, args, out).await
    }

    async fn op_ring(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "ring")?;
        if args["stop"] == true {
            let alert = self.ring_alert(&peer.device_id).unwrap_or_else(crate::crypto::uuid4);
            let (_g, mut rx) = self.wait_for(vec![format!("find:{alert}")]);
            h.send_json("find.stop", &json!({"alertId": alert}));
            let _ = next_reply(&mut rx, Duration::from_secs(5), &peer, &self.local.name()).await;
            self.set_ring(&peer.device_id, None);
            return Ok(json!({"device": device_json(&peer), "ringing": false}));
        }
        let duration = arg_ms(args, "durationMs", 30_000).clamp(1000, 60_000);
        let alert = crate::crypto::uuid4();
        let mid = crate::crypto::uuid4();
        let (_g, mut rx) = self.wait_for(vec![format!("find:{alert}"), format!("msg:{mid}")]);
        h.send_json_id("find.start", &json!({"alertId": alert}), &mid, None);
        let r = next_reply(&mut rx, Duration::from_secs(8), &peer, &self.local.name()).await?;
        if r.kind != "find.started" {
            return Err(CliError::new("failed", format!("{} did not start ringing", peer.name)));
        }
        self.set_ring(&peer.device_id, Some(alert.clone()));
        let h2 = h.clone();
        let stop_alert = alert.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(duration)).await;
            h2.send_json("find.stop", &json!({"alertId": stop_alert}));
        });
        Ok(json!({"device": device_json(&peer), "ringing": true, "alertId": alert, "durationMs": duration}))
    }

    async fn op_battery(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "battery")?;
        for _ in 0..50 {
            if let Some((level, charging, at)) = self.battery(&peer.device_id) {
                return Ok(json!({"device": device_json(&peer), "level": level, "charging": charging, "at": at}));
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        Err(CliError::new("timeout", format!("{} has not sent its battery state yet", peer.name)))
    }

    async fn op_ping(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "ring")?;
        let mid = crate::crypto::uuid4();
        let (_g, mut rx) = self.wait_for(vec![format!("msg:{mid}")]);
        let started = std::time::Instant::now();
        h.send_json_id("ping.request", &json!({"version": 1}), &mid, None);
        next_reply(&mut rx, Duration::from_secs(5), &peer, &self.local.name()).await?;
        Ok(json!({"device": device_json(&peer), "delivered": true, "rttMs": started.elapsed().as_millis() as u64}))
    }

    async fn op_clip_set(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "clipboard")?;
        let text = args["text"].as_str().unwrap_or("");
        let html = arg_str(args, "html");
        if text.is_empty() {
            return Err(CliError::new("usage", "nothing to copy"));
        }
        if text.len() + html.map(str::len).unwrap_or(0) > 32 * 1024 {
            return Err(CliError::new("usage", "text and HTML together are at most 32 KiB"));
        }
        let mid = crate::crypto::uuid4();
        let (_g, mut rx) = self.wait_for(vec![format!("msg:{mid}")]);
        match html {
            Some(html) => h.send_json_id("clipboard.rich", &json!({"version": 1, "text": text, "html": html}), &mid, None),
            None => h.send_raw_id("clipboard.update", text.as_bytes().to_vec(), &mid),
        };
        let r = next_reply(&mut rx, Duration::from_secs(10), &peer, &self.local.name()).await?;
        if r.kind == "clipboard.rejected" {
            return Err(not_granted(&peer.name, "clipboard", &self.local.name()));
        }
        Ok(json!({"device": device_json(&peer), "delivered": true, "bytes": text.len()}))
    }

    async fn op_clip_get(&self, args: &Value) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "clipboard_request")?;
        let timeout = arg_ms(args, "timeoutMs", 120_000).min(600_000);
        let id = crate::crypto::uuid4();
        let mid = crate::crypto::uuid4();
        let (_g, mut rx) = self.wait_for(vec![format!("cliprq:{id}"), format!("msg:{mid}")]);
        h.send_json_id("clipboard.request", &json!({"version": 1, "requestId": id, "expiresAt": now_ms() + timeout}), &mid, None);
        let r = next_reply(&mut rx, Duration::from_millis(timeout + 5000), &peer, &self.local.name()).await?;
        let p = r.payload.unwrap_or(Value::Null);
        match p["status"].as_str().unwrap_or("") {
            "sent" => Ok(json!({"device": device_json(&peer), "text": p["text"], "html": p["html"]})),
            "declined" => Err(CliError::new("declined", "Declined on the phone")),
            _ => Err(CliError::new("timeout", "Nobody tapped Send in time")),
        }
    }

    async fn op_codes(&self, args: &Value, out: &mut Out) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "codes")?;
        let wait_ms = arg_ms(args, "waitMs", 0);
        let since = arg_ms(args, "sinceMs", 600_000).min(3_600_000);
        let newer_than = if wait_ms > 0 { Some(arg_ms(args, "newerThan", now_ms())) } else { None };
        let deadline = now_ms() + wait_ms;
        let mut first = true;
        loop {
            let id = crate::crypto::uuid4();
            let mid = crate::crypto::uuid4();
            let this_wait = deadline.saturating_sub(now_ms()).min(600_000);
            let mut payload = json!({"version": 1, "queryId": id, "sinceMs": since, "waitMs": this_wait, "latestOnly": args["latest"] == true});
            if let Some(s) = arg_str(args, "service") {
                payload["service"] = json!(s);
            }
            if let Some(n) = newer_than {
                payload["newerThan"] = json!(n);
            }
            let (_g, mut rx) = self.wait_for(vec![format!("codes:{id}"), format!("msg:{mid}")]);
            h.send_json_id("codes.query", &payload, &mid, None);
            let r = next_reply(&mut rx, Duration::from_millis(this_wait + 10_000), &peer, &self.local.name()).await;
            let r = match r {
                Err(e) if e.code == "timeout" || e.code == "unreachable" => {
                    if let Some(h) = self.handle_for(&peer.device_id) {
                        h.send_json("codes.cancel", &json!({"version": 1, "queryId": id}));
                    }
                    return Err(e);
                }
                other => other?,
            };
            let p = r.payload.unwrap_or(Value::Null);
            let readers = p["readers"].as_u64().unwrap_or(0);
            if first && readers == 0 {
                out.event(json!({"event": "warning", "message": format!("No Mac is reading codes for {} right now (asleep, away or Codes from messages off). New codes will not show until one is back.", peer.name)})).await;
            }
            first = false;
            let codes = p["codes"].as_array().cloned().unwrap_or_default();
            if !codes.is_empty() || wait_ms == 0 || now_ms() >= deadline {
                if wait_ms > 0 && codes.is_empty() {
                    return Err(CliError::new("timeout", "No new code arrived in time").with("readers", readers));
                }
                return Ok(json!({"device": device_json(&peer), "codes": codes, "readers": readers}));
            }
        }
    }

    async fn op_send(&self, args: &Value, out: &mut Out) -> Result<Value, CliError> {
        let peer = self.resolve(arg_str(args, "device"))?;
        let paths: Vec<String> = args["paths"].as_array().map(|a| a.iter().filter_map(|p| p.as_str().map(str::to_string)).collect()).unwrap_or_default();
        if paths.is_empty() {
            return Err(CliError::new("usage", "bridgey send PATH..."));
        }
        let mut files = Vec::new();
        for p in &paths {
            let meta = std::fs::metadata(p).map_err(|e| CliError::new("usage", format!("{p}: {e}")))?;
            if meta.is_dir() {
                return Err(CliError::new("usage", format!("{p} is a folder: this version sends files only (folders come with the transfer engine)")));
            }
            files.push((p.clone(), meta.len()));
        }
        let h = self.ensure(&peer, self.connect_timeout(args)).await?;
        self.require(&peer, "files")?;
        let mut sent = Vec::new();
        let mut total = 0u64;
        for (path, size) in files {
            let r = self.send_one(&peer, &h, &path, size, out).await;
            match r {
                Ok(v) => {
                    total += size;
                    sent.push(v);
                }
                Err(e) => return Err(e.with("sent", Value::Array(sent))),
            }
        }
        if args["noWait"] == true {
            // Files are offered one at a time and the phone acknowledges each; nothing is left running here.
        }
        Ok(json!({"device": device_json(&peer), "files": sent.len(), "bytes": total, "transfers": sent}))
    }

    async fn send_one(&self, peer: &Peer, h: &crate::session::Handle, path: &str, size: u64, out: &mut Out) -> Result<Value, CliError> {
        use tokio::io::AsyncReadExt as _;
        const CHUNK: usize = 24 * 1024;
        const WINDOW: i64 = 64;
        let name = std::path::Path::new(path).file_name().and_then(|n| n.to_str()).unwrap_or("file").to_string();
        let hash = {
            let owned = path.to_string();
            tokio::task::spawn_blocking(move || -> std::io::Result<String> {
                use std::io::Read;
                let mut f = std::fs::File::open(&owned)?;
                let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
                let mut buf = vec![0u8; 256 * 1024];
                loop {
                    let n = f.read(&mut buf)?;
                    if n == 0 {
                        break;
                    }
                    ctx.update(&buf[..n]);
                }
                Ok(crate::crypto::b64(ctx.finish().as_ref()))
            })
            .await
            .map_err(|_| CliError::new("failed", "hash"))?
            .map_err(|e| CliError::new("usage", format!("{path}: {e}")))?
        };
        let id = crate::crypto::uuid4();
        let mid = crate::crypto::uuid4();
        let mime = mime_for(&name);
        let mut info = TransferInfo { transfer_id: id.clone(), device: peer.device_id.clone(), name: name.clone(), bytes: 0, total: size, state: "offered".into(), started_at: now_ms(), ended_at: None };
        self.transfer_update(info.clone());
        let (_g, mut rx) = self.wait_for(vec![format!("xfer:{id}"), format!("msg:{mid}")]);
        h.send_json_id("files.offer", &json!({"transferId": id, "name": name, "mimeType": mime, "size": size, "sha256": hash}), &mid, Some(id.clone()));
        let fail = |info: &mut TransferInfo, state: &str| {
            info.state = state.into();
            info.ended_at = Some(now_ms());
            self.transfer_update(info.clone());
        };
        let accept = next_reply(&mut rx, Duration::from_secs(60), peer, &self.local.name()).await;
        match accept {
            Ok(r) if r.kind == "files.accept" => {}
            Ok(r) if r.kind == "files.rejected" => {
                fail(&mut info, "rejected");
                return Err(not_granted(&peer.name, "files", &self.local.name()));
            }
            Ok(r) => {
                fail(&mut info, "failed");
                return Err(CliError::new("transfer_failed", format!("{} answered {}", peer.name, r.kind)));
            }
            Err(e) => {
                fail(&mut info, "failed");
                return Err(e);
            }
        }
        info.state = "sending".into();
        self.transfer_update(info.clone());
        let mut file = tokio::fs::File::open(path).await.map_err(|e| CliError::new("transfer_failed", e.to_string()))?;
        let mut seq: i64 = 0;
        let mut acked: i64 = -1;
        let mut buf = vec![0u8; CHUNK];
        let mut sent_bytes = 0u64;
        let mut last_event = std::time::Instant::now();
        let started = std::time::Instant::now();
        loop {
            while seq - acked > WINDOW {
                match tokio::time::timeout(Duration::from_secs(30), rx.recv()).await {
                    Ok(Some(r)) if r.kind == "files.chunk.ack" => acked = acked.max(r.message.sequence.unwrap_or(-1)),
                    Ok(Some(r)) if r.kind == "files.cancel" => {
                        fail(&mut info, "cancelled");
                        return Err(CliError::new("transfer_failed", "cancelled on the phone"));
                    }
                    Ok(Some(_)) => {}
                    _ => {
                        fail(&mut info, "interrupted");
                        return Err(CliError::new("transfer_failed", "the transfer stalled"));
                    }
                }
            }
            let n = file.read(&mut buf).await.map_err(|e| CliError::new("transfer_failed", e.to_string()))?;
            if n == 0 {
                break;
            }
            if !h.send_chunk(&id, seq, buf[..n].to_vec()) {
                fail(&mut info, "interrupted");
                return Err(CliError::new("transfer_failed", "the session ended"));
            }
            seq += 1;
            sent_bytes += n as u64;
            if last_event.elapsed() > Duration::from_millis(500) {
                last_event = std::time::Instant::now();
                info.bytes = sent_bytes;
                self.transfer_update(info.clone());
                let rate = (sent_bytes as f64 / started.elapsed().as_secs_f64().max(0.001)) as u64;
                out.event(json!({"event": "progress", "transferId": id, "bytes": sent_bytes, "total": size, "rate": rate})).await;
            }
        }
        let done_mid = crate::crypto::uuid4();
        h.send_json_id("files.complete", &json!({"transferId": id, "sha256": hash}), &done_mid, Some(id.clone()));
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        loop {
            match tokio::time::timeout_at(deadline, rx.recv()).await {
                Ok(Some(r)) if r.kind == "files.complete.ack" => break,
                Ok(Some(r)) if r.kind == "files.cancel" => {
                    fail(&mut info, "failed");
                    return Err(CliError::new("transfer_failed", "the phone could not verify the file"));
                }
                Ok(Some(_)) => {}
                _ => {
                    fail(&mut info, "failed");
                    return Err(CliError::new("transfer_failed", "no confirmation from the phone"));
                }
            }
        }
        info.state = "done".into();
        info.bytes = size;
        info.ended_at = Some(now_ms());
        self.transfer_update(info);
        Ok(json!({"transferId": id, "name": name, "bytes": size, "sha256": hash}))
    }
}

fn mime_for(name: &str) -> &'static str {
    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "txt" | "log" | "md" => "text/plain",
        "json" => "application/json",
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "zip" => "application/zip",
        "gz" | "tgz" => "application/gzip",
        "apk" => "application/vnd.android.package-archive",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        _ => "application/octet-stream",
    }
}
