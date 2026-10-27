//! bridgey-rendezvous: the Connect anywhere control service (docs/connect-anywhere.md, section 6).
//!
//! Presence, sealed signal forwarding, node authentication and relay credentials. It never sees
//! device names, device IDs, identity keys, candidates or any content: signalling bodies are
//! sealed with a key only the two paired devices hold.

mod config;
mod hub;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use bridgey_connect_proto::rdv::{self, Limits, Msg};
use bridgey_connect_proto::{b64, derive};
use config::Config;
use futures_util::StreamExt;
use hub::{Hub, Outcome};
use ring::rand::SecureRandom;
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

struct App {
    hub: Mutex<Hub>,
    per_ip: Mutex<HashMap<IpAddr, usize>>,
    trust_proxy: bool,
    limits: config::Limits,
    environment: String,
}

const DEFAULT_CONFIG: &str = "/etc/bridgey/bridgey-rendezvous.toml";

/// `bridgey-rendezvous --health [config]`: exit 0 when `/health/ready` answers 200 (container health check).
fn health(path: &str) -> ! {
    use std::io::{Read, Write};
    let listen = std::fs::read_to_string(path)
        .ok()
        .and_then(|t| Config::parse(&t).ok())
        .and_then(|c| c.server.listen.parse::<SocketAddr>().ok())
        .unwrap_or_else(|| SocketAddr::from(([0, 0, 0, 0], 8080)));
    // A wildcard listener is checked on loopback, a specific one on its own address.
    let target = if listen.ip().is_unspecified() { SocketAddr::from(([127, 0, 0, 1], listen.port())) } else { listen };
    let ok = std::net::TcpStream::connect_timeout(&target, Duration::from_secs(2))
        .and_then(|mut stream| {
            stream.set_read_timeout(Some(Duration::from_secs(2)))?;
            stream.write_all(b"GET /health/ready HTTP/1.0\r\nHost: localhost\r\n\r\n")?;
            let mut head = [0u8; 12];
            stream.read_exact(&mut head)?;
            Ok(head.ends_with(b" 200"))
        })
        .unwrap_or(false);
    std::process::exit(if ok { 0 } else { 1 })
}

#[tokio::main]
async fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let health_check = args.first().map(|a| a == "--health").unwrap_or(false);
    if health_check {
        args.remove(0);
    }
    let path = args.first().cloned().or_else(|| std::env::var("BRIDGEY_RENDEZVOUS_CONFIG").ok()).unwrap_or_else(|| DEFAULT_CONFIG.into());
    if health_check {
        health(&path);
    }
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| fail(&format!("cannot read {path}: {e}")));
    let config = Config::parse(&text).unwrap_or_else(|e| fail(&format!("invalid {path}: {e}")));
    let secrets = config.secrets(|name| std::env::var(name).ok());
    for relay in config.relays.iter().filter(|r| r.enabled) {
        if !secrets.contains_key(&relay.id) {
            eprintln!("relay {} has no secret in ${}; it is skipped", relay.id, relay.secret_env);
        }
    }
    let listen: SocketAddr = config.server.listen.parse().unwrap_or_else(|_| fail("server.listen is not an address"));
    let app = Arc::new(App {
        trust_proxy: config.server.trust_proxy,
        limits: config.limits.clone(),
        environment: config.server.environment.clone(),
        hub: Mutex::new(Hub::new(config, secrets)),
        per_ip: Mutex::new(HashMap::new()),
    });
    let router = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/health/ready", get(ready))
        .route("/v1/status", get(status))
        .route("/v1/ws", get(upgrade))
        .with_state(app);
    let listener = tokio::net::TcpListener::bind(listen).await.unwrap_or_else(|e| fail(&format!("cannot listen on {listen}: {e}")));
    eprintln!("bridgey-rendezvous {} listening on {listen}", env!("CARGO_PKG_VERSION"));
    axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async {
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("signal");
            tokio::select! { _ = term.recv() => {}, _ = tokio::signal::ctrl_c() => {} }
        })
        .await
        .unwrap_or_else(|e| fail(&format!("server: {e}")));
}

fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1)
}

async fn ready(State(app): State<Arc<App>>) -> Response {
    let hub = app.hub.lock().unwrap();
    let relays = hub.config().relays.iter().filter(|r| r.enabled && hub.has_secret(&r.id)).count();
    if relays == 0 && !hub.config().relays.is_empty() {
        return (StatusCode::SERVICE_UNAVAILABLE, "no relay secrets").into_response();
    }
    "ready".into_response()
}

async fn status(State(app): State<Arc<App>>) -> Json<serde_json::Value> {
    let hub = app.hub.lock().unwrap();
    let relays: Vec<_> = hub
        .config()
        .relays
        .iter()
        .map(|r| serde_json::json!({ "id": r.id, "kind": r.kind, "enabled": r.enabled, "configured": hub.has_secret(&r.id) }))
        .collect();
    Json(serde_json::json!({
        "environment": app.environment,
        "version": env!("CARGO_PKG_VERSION"),
        "connections": hub.connections(),
        "nodes": hub.nodes(),
        "relays": relays,
        "counters": hub.counters,
    }))
}

async fn upgrade(State(app): State<Arc<App>>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, ws: WebSocketUpgrade) -> Response {
    let ip = if app.trust_proxy {
        headers.get("x-real-ip").and_then(|v| v.to_str().ok()).and_then(|v| v.trim().parse().ok()).unwrap_or(peer.ip())
    } else {
        peer.ip()
    };
    {
        let mut per_ip = app.per_ip.lock().unwrap();
        let count = per_ip.entry(ip).or_insert(0);
        if *count >= app.limits.connections_per_ip {
            return (StatusCode::TOO_MANY_REQUESTS, "too many connections").into_response();
        }
        *count += 1;
    }
    ws.max_message_size(rdv::MAX_FRAME_BYTES).max_frame_size(rdv::MAX_FRAME_BYTES).on_upgrade(move |socket| async move {
        session(app.clone(), socket).await;
        let mut per_ip = app.per_ip.lock().unwrap();
        if let Some(count) = per_ip.get_mut(&ip) {
            *count -= 1;
            if *count == 0 {
                per_ip.remove(&ip);
            }
        }
    })
}

async fn send(socket: &mut WebSocket, msg: Msg) -> bool {
    socket.send(Message::Text(msg.to_text().into())).await.is_ok()
}

/// Reads the next text frame, answering nothing else; `None` on close, error or timeout.
async fn next_text(socket: &mut WebSocket, timeout: Duration) -> Option<String> {
    loop {
        match tokio::time::timeout(timeout, socket.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => return Some(text.to_string()),
            Ok(Some(Ok(Message::Ping(_) | Message::Pong(_)))) => continue,
            _ => return None,
        }
    }
}

/// hello, challenge, auth, welcome (spec 6.2). The node key is P-256; the signature is DER ECDSA.
async fn authenticate(app: &App, socket: &mut WebSocket) -> Option<(String, u32)> {
    let deadline = Duration::from_secs(app.limits.auth_timeout_s);
    let Some(Msg::Hello { v, node, keepalive, .. }) = next_text(socket, deadline).await.and_then(|t| Msg::parse(&t)) else {
        send(socket, Msg::Error { code: "bad_request".into(), retry_after_ms: None }).await;
        return None;
    };
    let node_key = b64::url_decode(&node).filter(|k| k.len() == 65 && k[0] == 4);
    let Some(node_key) = node_key.filter(|_| v == rdv::PROTOCOL_VERSION) else {
        send(socket, Msg::Error { code: "bad_request".into(), retry_after_ms: None }).await;
        return None;
    };
    let mut nonce = [0u8; 32];
    ring::rand::SystemRandom::new().fill(&mut nonce).ok()?;
    let pow = app.limits.pow_bits;
    if !send(socket, Msg::Challenge { nonce: b64::url_encode(&nonce), pow }).await {
        return None;
    }
    let Some(Msg::Auth { sig, pow: solution }) = next_text(socket, deadline).await.and_then(|t| Msg::parse(&t)) else {
        send(socket, Msg::Error { code: "unauthenticated".into(), retry_after_ms: None }).await;
        return None;
    };
    let signature = b64::url_decode(&sig).unwrap_or_default();
    let key = ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_ASN1, &node_key);
    let signed = key.verify(&derive::auth_message(&nonce, &node_key), &signature).is_ok();
    let solved = derive::pow_ok(&nonce, &node_key, &solution.and_then(|s| b64::url_decode(&s)).unwrap_or_default(), pow);
    if !signed || !solved {
        app.hub.lock().unwrap().counters.rejected_auth += 1;
        let code = if signed { "pow_required" } else { "unauthenticated" };
        send(socket, Msg::Error { code: code.into(), retry_after_ms: None }).await;
        return None;
    }
    let node_id = derive::node_id(&node_key);
    let welcome = Msg::Welcome {
        node_id: node_id.clone(),
        now: hub::unix_ms(),
        limits: Limits {
            max_ids: app.limits.max_ids as u32,
            max_signal_bytes: rdv::MAX_SIGNAL_BODY as u32,
            signals_per_minute: app.limits.signals_per_minute,
        },
    };
    if !send(socket, welcome).await {
        return None;
    }
    Some((node_id, keepalive.clamp(60, 270)))
}

async fn session(app: Arc<App>, mut socket: WebSocket) {
    let Some((node_id, keepalive)) = authenticate(&app, &mut socket).await else { return };
    let (tx, mut rx) = mpsc::channel::<String>(64);
    let joined = app.hub.lock().unwrap().join(node_id, tx);
    let Some(id) = joined else {
        send(&mut socket, Msg::Error { code: "server_busy".into(), retry_after_ms: Some(30_000) }).await;
        return;
    };
    // The client keeps the socket warm every `keepalive` seconds; three silent intervals end it.
    let idle = Duration::from_secs(u64::from(keepalive) * 3);
    loop {
        tokio::select! {
            outgoing = rx.recv() => {
                let Some(text) = outgoing else { break };
                if socket.send(Message::Text(text.into())).await.is_err() { break }
            }
            incoming = tokio::time::timeout(idle, socket.next()) => {
                let msg = match incoming {
                    Ok(Some(Ok(Message::Text(text)))) => Msg::parse(text.as_str()),
                    Ok(Some(Ok(Message::Ping(_) | Message::Pong(_)))) => continue,
                    _ => break,
                };
                let Some(msg) = msg else {
                    let _ = socket.send(Message::Text(Msg::Error { code: "bad_request".into(), retry_after_ms: None }.to_text().into())).await;
                    continue;
                };
                if app.hub.lock().unwrap().handle(id, msg) == Outcome::Close { break }
            }
        }
    }
    app.hub.lock().unwrap().leave(id);
}
