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
use axum::serve::ListenerExt;
use axum::{Json, Router};
use bridgey_connect_proto::rdv::{self, FastHello, Limits, Msg, WarmRequest};
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
    public_host: Option<String>,
    /// Single-flight sign-ins already taken: (node ID, cnonce) until their window ends, so none is taken twice.
    /// In memory: the service runs as one instance (stop-first deploys), so this covers every sign-in it takes.
    seen_hellos: Mutex<SeenHellos>,
}

#[derive(Default)]
struct SeenHellos {
    entries: HashMap<(String, String), u64>,
    /// Expired entries are swept at most once a second, so a flood of sign-ins cannot make each one scan the map.
    swept_at: u64,
}

/// A connection's place in the per-address count, given back however the connection ends (a failed upgrade too).
struct IpSlot {
    app: Arc<App>,
    ip: IpAddr,
}

impl Drop for IpSlot {
    fn drop(&mut self) {
        let mut per_ip = self.app.per_ip.lock().unwrap();
        if let Some(count) = per_ip.get_mut(&self.ip) {
            *count -= 1;
            if *count == 0 {
                per_ip.remove(&self.ip);
            }
        }
    }
}

/// At most this many single-flight sign-ins are remembered; past it, they fall back to the challenge.
const MAX_SEEN_HELLOS: usize = 200_000;

/// A node that signed in with its upgrade request: who it is and what it asked for in the same flight.
struct FastSignIn {
    node_id: String,
    keepalive: u32,
    ids: Option<Vec<String>>,
    warm: Option<WarmRequest>,
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
    if config.server.trust_proxy && config.server.public_host.is_none() {
        // Behind a proxy the Host header is not the name clients signed; without public_host a sign-in made for
        // this service could be replayed to another that shares node keys.
        fail("server.public_host is required with trust_proxy");
    }
    let app = Arc::new(App {
        trust_proxy: config.server.trust_proxy,
        limits: config.limits.clone(),
        environment: config.server.environment.clone(),
        public_host: config.server.public_host.clone(),
        seen_hellos: Mutex::new(SeenHellos::default()),
        hub: Mutex::new(Hub::new(config, secrets)),
        per_ip: Mutex::new(HashMap::new()),
    });
    let router = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/health/ready", get(ready))
        .route("/v1/status", get(status))
        .route("/v1/ws", get(upgrade))
        .with_state(app);
    // No Nagle: signals are small frames, and one sent while the previous is unacknowledged would otherwise wait for the
    // peer's delayed acknowledgement (about 40 ms on Linux) on every hop.
    let listener = tokio::net::TcpListener::bind(listen).await.unwrap_or_else(|e| fail(&format!("cannot listen on {listen}: {e}"))).tap_io(|tcp| {
        let _ = tcp.set_nodelay(true);
    });
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
    let slot = IpSlot { app: app.clone(), ip };
    // The single-flight sign-in: a valid hello in the upgrade request skips the hello, challenge and auth frames.
    // Anything wrong with it (an old clock, a reused nonce) only means the client signs in the usual way.
    let fast = headers.get(rdv::HELLO_HEADER).and_then(|v| v.to_str().ok()).and_then(|v| fast_sign_in(&app, &headers, v));
    let accepted = fast.is_some();
    let mut response = ws.max_message_size(rdv::MAX_FRAME_BYTES).max_frame_size(rdv::MAX_FRAME_BYTES).on_upgrade(move |socket| async move {
        let _slot = slot;
        session(app.clone(), socket, fast).await;
    });
    if accepted {
        response.headers_mut().insert(rdv::WELCOME_HEADER, axum::http::HeaderValue::from_static("1"));
    }
    response
}

/// Checks a [FastHello]: the node key, the signature over this service's host, the time window and a nonce
/// not seen before. `None` for anything else.
fn fast_sign_in(app: &App, headers: &HeaderMap, value: &str) -> Option<FastSignIn> {
    if value.len() > rdv::MAX_FRAME_BYTES {
        return None;
    }
    let hello: FastHello = serde_json::from_slice(&b64::url_decode(value)?).ok()?;
    let node_key = b64::url_decode(&hello.node).filter(|k| k.len() == 65 && k[0] == 4)?;
    let cnonce = b64::url_decode(&hello.cnonce).filter(|n| n.len() == 16)?;
    if hello.v != rdv::PROTOCOL_VERSION || app.limits.pow_bits > 0 {
        return None;
    }
    let now = hub::unix_ms();
    if hello.ts.abs_diff(now) > rdv::FAST_HELLO_WINDOW_MS {
        return None;
    }
    let host = match &app.public_host {
        Some(host) => host.clone(),
        None => headers.get(axum::http::header::HOST)?.to_str().ok()?.to_string(),
    };
    let signature = b64::url_decode(&hello.sig)?;
    let key = ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_ASN1, &node_key);
    if key.verify(&derive::auth_message_v2(&host, hello.ts, &cnonce, &node_key), &signature).is_err() {
        app.hub.lock().unwrap().counters.rejected_auth += 1;
        return None;
    }
    let node_id = derive::node_id(&node_key);
    {
        let mut seen = app.seen_hellos.lock().unwrap();
        if seen.entries.len() >= MAX_SEEN_HELLOS / 2 && now.saturating_sub(seen.swept_at) >= 1_000 {
            seen.swept_at = now;
            seen.entries.retain(|_, until| *until > now);
        }
        if seen.entries.len() >= MAX_SEEN_HELLOS {
            return None;
        }
        // Remembered until the timestamp can no longer pass the window check.
        if seen.entries.insert((node_id.clone(), hello.cnonce.clone()), hello.ts + rdv::FAST_HELLO_WINDOW_MS + 1_000).is_some() {
            return None;
        }
    }
    app.hub.lock().unwrap().counters.fast_hellos += 1;
    Some(FastSignIn { node_id, keepalive: hello.keepalive.clamp(60, 270), ids: hello.ids, warm: hello.warm })
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
    if !send(socket, welcome(app, &node_id)).await {
        return None;
    }
    Some((node_id, keepalive.clamp(60, 270)))
}

fn welcome(app: &App, node_id: &str) -> Msg {
    Msg::Welcome {
        node_id: node_id.to_string(),
        now: hub::unix_ms(),
        limits: Limits {
            max_ids: app.limits.max_ids as u32,
            max_signal_bytes: rdv::MAX_SIGNAL_BODY as u32,
            signals_per_minute: app.limits.signals_per_minute,
        },
        relays: Some(app.hub.lock().unwrap().relay_infos()),
    }
}

async fn session(app: Arc<App>, mut socket: WebSocket, fast: Option<FastSignIn>) {
    let (node_id, keepalive, ids, warm) = match fast {
        Some(f) => {
            if !send(&mut socket, welcome(&app, &f.node_id)).await {
                return;
            }
            (f.node_id, f.keepalive, f.ids, f.warm)
        }
        None => {
            let Some((node_id, keepalive)) = authenticate(&app, &mut socket).await else { return };
            (node_id, keepalive, None, None)
        }
    };
    let (tx, mut rx) = mpsc::channel::<String>(64);
    let joined = app.hub.lock().unwrap().join(node_id, tx);
    let Some(id) = joined else {
        send(&mut socket, Msg::Error { code: "server_busy".into(), retry_after_ms: Some(30_000) }).await;
        return;
    };
    // What the single flight also asked for: registration and the node's warm relay credentials.
    {
        let mut hub = app.hub.lock().unwrap();
        if let Some(ids) = ids {
            hub.handle(id, Msg::Register { ids });
        }
        if let Some(request) = warm {
            hub.handle(id, Msg::RelayWarm { request });
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING};

    fn app() -> App {
        let config = Config::parse("[server]\nlisten = \"127.0.0.1:0\"\npublic_host = \"connect.example\"\n").unwrap();
        App {
            trust_proxy: false,
            limits: config.limits.clone(),
            environment: "test".into(),
            public_host: config.server.public_host.clone(),
            seen_hellos: Mutex::new(SeenHellos::default()),
            hub: Mutex::new(Hub::new(config, HashMap::new())),
            per_ip: Mutex::new(HashMap::new()),
        }
    }

    fn hello(key: &EcdsaKeyPair, host: &str, ts: u64, cnonce: [u8; 16]) -> String {
        let rng = ring::rand::SystemRandom::new();
        let node = key.public_key().as_ref().to_vec();
        let sig = key.sign(&rng, &derive::auth_message_v2(host, ts, &cnonce, &node)).unwrap();
        let hello = FastHello {
            v: rdv::PROTOCOL_VERSION,
            node: b64::url_encode(&node),
            app: "test".into(),
            keepalive: 120,
            ts,
            cnonce: b64::url_encode(&cnonce),
            sig: b64::url_encode(sig.as_ref()),
            ids: Some(vec!["AAAAAAAAAAAAAAAAAAAAAA".into()]),
            warm: None,
        };
        b64::url_encode(serde_json::to_string(&hello).unwrap().as_bytes())
    }

    #[test]
    fn fast_sign_in_once_in_window_for_this_host() {
        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng).unwrap();
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng).unwrap();
        let app = app();
        let headers = HeaderMap::new();
        let now = hub::unix_ms();
        let good = hello(&key, "connect.example", now, [1; 16]);
        let signed_in = fast_sign_in(&app, &headers, &good).expect("valid hello");
        assert_eq!(signed_in.node_id, derive::node_id(key.public_key().as_ref()));
        assert_eq!(signed_in.ids.as_deref().map(<[String]>::len), Some(1));
        // The same hello again (a replay) is refused; the client would fall back to the challenge.
        assert!(fast_sign_in(&app, &headers, &good).is_none());
        // Outside the two-minute window, for another host, or with a broken signature: refused.
        assert!(fast_sign_in(&app, &headers, &hello(&key, "connect.example", now - 200_000, [2; 16])).is_none());
        assert!(fast_sign_in(&app, &headers, &hello(&key, "other.example", now, [3; 16])).is_none());
        let mut tampered: FastHello = serde_json::from_slice(&b64::url_decode(&hello(&key, "connect.example", now, [4; 16])).unwrap()).unwrap();
        tampered.ts += 1;
        assert!(fast_sign_in(&app, &headers, &b64::url_encode(serde_json::to_string(&tampered).unwrap().as_bytes())).is_none());
        assert!(fast_sign_in(&app, &headers, "not base64 json").is_none());
        // A fresh nonce within the window works.
        assert!(fast_sign_in(&app, &headers, &hello(&key, "connect.example", now, [5; 16])).is_some());
        assert_eq!(app.hub.lock().unwrap().counters.fast_hellos, 2);
    }
}
