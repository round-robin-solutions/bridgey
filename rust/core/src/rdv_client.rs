//! The rendezvous client: one WebSocket per device to the control service (spec 4.7, 6.2).
//!
//! Signs in with the node key (signed by the app's keystore through `Signer`). The fast way is one flight:
//! the signature is made while DNS, TCP and TLS run, and the hello, the sign-in, the registration and the
//! warm relay request ride in the upgrade request (docs/connect-anywhere-latency.md). A service that does not
//! take it (older, or the clock is off) gets the challenge flow. The socket stays warm with an adaptive
//! keep-alive (60 s, doubling after 3 clean intervals up to 270 s, halving after a drop) and reconnects with
//! full jitter (2 s base, 5 minute cap) after one quick retry, or at once when asked to refresh.

use bridgey_connect_proto::rdv::{self, FastHello, Msg, RelayInfo, WarmRequest};
use bridgey_connect_proto::{b64, derive};
use futures_util::{FutureExt, SinkExt, StreamExt};
use std::future::Future;
use std::net::IpAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, Notify};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message as WsMessage;

pub type Signer = Arc<dyn Fn(Vec<u8>) -> Pin<Box<dyn Future<Output = Option<Vec<u8>>> + Send>> + Send + Sync>;

#[derive(Debug)]
pub enum RdvEvent {
    /// A step of the connection finished (dns, tcp, tls, upgrade, challenge, signed), for the waterfall.
    Timing(&'static str),
    /// Signed in. `inline_ids`: the registration that went with the sign-in (the service answers `registered`
    /// next). `warm_inline`: the warm relay request went too. `relays`: the pool, when the service lists it.
    Connected { inline_ids: Option<Vec<String>>, warm_inline: bool, relays: Vec<RelayInfo> },
    Disconnected(String),
    Msg(Msg),
}

/// What the next sign-in carries, kept current by the node.
#[derive(Default)]
pub struct Shared {
    pub ids: Mutex<Vec<String>>,
    pub warm: Mutex<Option<WarmRequest>>,
    last_heard: Mutex<Option<Instant>>,
}

pub struct RdvClient {
    out: mpsc::UnboundedSender<Msg>,
    stop: tokio::sync::watch::Sender<bool>,
    kick: Arc<Notify>,
    pub shared: Arc<Shared>,
}

impl RdvClient {
    pub fn send(&self, msg: Msg) {
        let _ = self.out.send(msg);
    }

    pub fn stop(&self) {
        let _ = self.stop.send(true);
    }

    /// Reconnect now, without the back-off: after a network change, or when the socket has been quiet too long
    /// to trust (a phone that was asleep may hold a socket its network dropped long ago).
    pub fn refresh(&self) {
        self.kick.notify_one();
    }

    /// How long since the service last sent anything (a frame or a pong); `None` before the first connection.
    pub fn quiet_for(&self) -> Option<Duration> {
        self.shared.last_heard.lock().unwrap().map(|t| t.elapsed())
    }
}

impl Drop for RdvClient {
    fn drop(&mut self) {
        let _ = self.stop.send(true);
    }
}

/// `wss://` always; `ws://` only to loopback, private, carrier-NAT or tailnet addresses (local tests).
pub fn allowed_url(url: &str) -> bool {
    if url.starts_with("wss://") {
        return true;
    }
    let Some(rest) = url.strip_prefix("ws://") else { return false };
    let host = rest.split('/').next().unwrap_or_default();
    let host = host.rsplit_once(':').map(|(h, _)| h).unwrap_or(host).trim_matches(|c| c == '[' || c == ']');
    match host.parse::<IpAddr>() {
        Ok(ip) => crate::addrs::route_of(ip) != crate::addrs::Route::Direct || ip.is_loopback(),
        Err(_) => host == "localhost",
    }
}

fn full_jitter(attempt: u32) -> Duration {
    let cap = 300_000u64;
    let base = 2_000u64.saturating_mul(1u64 << attempt.min(10)).min(cap);
    let mut bytes = [0u8; 8];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).expect("random");
    Duration::from_millis(u64::from_be_bytes(bytes) % base.max(1))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

pub fn start(url: String, node_public_key: Vec<u8>, app: String, signer: Signer, shared: Arc<Shared>, events: mpsc::UnboundedSender<RdvEvent>) -> RdvClient {
    let (out, mut out_rx) = mpsc::unbounded_channel::<Msg>();
    let (stop, mut stop_rx) = tokio::sync::watch::channel(false);
    let kick = Arc::new(Notify::new());
    let client = RdvClient { out, stop, kick: kick.clone(), shared: shared.clone() };
    tokio::spawn(async move {
        let mut attempt = 0u32;
        let mut keepalive = 60u64;
        loop {
            if *stop_rx.borrow() {
                break;
            }
            let outcome = session(&url, &node_public_key, &app, &signer, &shared, &events, &mut out_rx, &mut stop_rx, &kick, &mut keepalive).await;
            if *stop_rx.borrow() {
                break;
            }
            let _ = events.send(RdvEvent::Disconnected(outcome.clone()));
            let refresh = outcome == "refresh";
            if outcome == "clean" || refresh {
                attempt = 0;
            } else {
                attempt = attempt.saturating_add(1);
                keepalive = (keepalive / 2).max(60);
            }
            // A refresh reconnects at once. The first failure retries almost at once (a process Android has just
            // started can be refused the network for its first moments); later ones back off with full jitter,
            // unless a refresh (network change, foreground) cuts the wait short.
            let wait = if refresh {
                Duration::ZERO
            } else if attempt == 1 && outcome != "clean" {
                Duration::from_millis(500)
            } else {
                full_jitter(attempt)
            };
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = kick.notified() => { attempt = 0; }
                _ = stop_rx.changed() => break,
            }
        }
    });
    client
}

#[allow(clippy::too_many_arguments)]
async fn session(
    url: &str,
    node: &[u8],
    app: &str,
    signer: &Signer,
    shared: &Shared,
    events: &mpsc::UnboundedSender<RdvEvent>,
    out_rx: &mut mpsc::UnboundedReceiver<Msg>,
    stop_rx: &mut tokio::sync::watch::Receiver<bool>,
    kick: &Notify,
    keepalive: &mut u64,
) -> String {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    if !allowed_url(url) {
        return "insecure_url".into();
    }
    let Ok(mut request) = url.into_client_request() else { return "insecure_url".into() };
    let authority = request.uri().authority().map(|a| a.as_str().to_string()).unwrap_or_default();
    // The single flight: sign while DNS, TCP and TLS run (the keystore can take tens of milliseconds).
    let ts = now_ms();
    let mut cnonce = [0u8; 16];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut cnonce).expect("random");
    let signing = signer(derive::auth_message_v2(&authority, ts, &cnonce, node));
    let (transport, signature) = tokio::join!(
        tokio::time::timeout(Duration::from_secs(10), transport(&request, events)),
        tokio::time::timeout(Duration::from_secs(10), signing.map(|sig| {
            let _ = events.send(RdvEvent::Timing("signed"));
            sig
        })),
    );
    let Ok(Some(stream)) = transport else { return "connect_failed".into() };
    let ids = shared.ids.lock().unwrap().clone();
    let warm = shared.warm.lock().unwrap().clone();
    let mut fast_sent = None;
    if let Ok(Some(sig)) = signature {
        let hello = FastHello {
            v: rdv::PROTOCOL_VERSION,
            node: b64::url_encode(node),
            app: app.to_string(),
            keepalive: *keepalive as u32,
            ts,
            cnonce: b64::url_encode(&cnonce),
            sig: b64::url_encode(&sig),
            ids: (!ids.is_empty()).then(|| ids.clone()),
            warm: warm.clone(),
        };
        let value = b64::url_encode(serde_json::to_string(&hello).expect("hello").as_bytes());
        if let Ok(header) = value.parse() {
            request.headers_mut().insert(rdv::HELLO_HEADER, header);
            fast_sent = Some(hello);
        }
    }
    let config = WebSocketConfig::default().max_message_size(Some(rdv::MAX_FRAME_BYTES)).max_frame_size(Some(rdv::MAX_FRAME_BYTES));
    let upgrade = tokio_tungstenite::client_async_with_config(request, stream, Some(config));
    let (mut ws, response) = match tokio::time::timeout(Duration::from_secs(10), upgrade).await {
        Ok(Ok(pair)) => pair,
        _ => return "connect_failed".into(),
    };
    let _ = events.send(RdvEvent::Timing("upgrade"));
    let next = |text: Option<Result<WsMessage, _>>| -> Option<Msg> {
        match text {
            Some(Ok(WsMessage::Text(t))) => Msg::parse(t.as_str()),
            _ => None,
        }
    };
    let fast = fast_sent.filter(|_| response.headers().contains_key(rdv::WELCOME_HEADER));
    let fast_ids = fast.as_ref().and_then(|h| h.ids.clone());
    let warm_inline = fast.as_ref().is_some_and(|h| h.warm.is_some());
    if fast.is_none() {
        // The challenge flow: an older service, or one that did not take the single flight.
        let hello = Msg::Hello { v: rdv::PROTOCOL_VERSION, node: b64::url_encode(node), app: app.to_string(), keepalive: *keepalive as u32 };
        if ws.send(WsMessage::Text(hello.to_text().into())).await.is_err() {
            return "send_failed".into();
        }
        let Ok(challenge) = tokio::time::timeout(Duration::from_secs(10), ws.next()).await else { return "timeout".into() };
        let Some(Msg::Challenge { nonce, pow }) = next(challenge) else { return "no_challenge".into() };
        let _ = events.send(RdvEvent::Timing("challenge"));
        let Some(nonce) = b64::url_decode(&nonce).filter(|n| n.len() == 32) else { return "bad_challenge".into() };
        let message = derive::auth_message(&nonce, node);
        let Some(signature) = signer(message).await else { return "sign_failed".into() };
        let _ = events.send(RdvEvent::Timing("signed"));
        let solution = (pow > 0 && pow <= 24).then(|| b64::url_encode(&derive::pow_solve(&nonce, node, pow)));
        let auth = Msg::Auth { sig: b64::url_encode(&signature), pow: solution };
        if ws.send(WsMessage::Text(auth.to_text().into())).await.is_err() {
            return "send_failed".into();
        }
    }
    let Ok(welcome) = tokio::time::timeout(Duration::from_secs(10), ws.next()).await else { return "timeout".into() };
    let relays = match next(welcome) {
        Some(Msg::Welcome { relays, .. }) => relays.unwrap_or_default(),
        Some(Msg::Error { code, .. }) => return format!("refused_{code}"),
        _ => return "no_welcome".into(),
    };
    *shared.last_heard.lock().unwrap() = Some(Instant::now());
    let _ = events.send(RdvEvent::Connected { inline_ids: fast_ids, warm_inline, relays });
    // A refresh asked for while this connection was being made is already answered by it.
    let _ = kick.notified().now_or_never();
    let mut clean_intervals = 0u32;
    let mut ping = tokio::time::interval(Duration::from_secs(*keepalive));
    ping.tick().await;
    let mut last_heard = tokio::time::Instant::now();
    loop {
        tokio::select! {
            _ = stop_rx.changed() => {
                let _ = ws.close(None).await;
                return "stopped".into();
            }
            _ = kick.notified() => {
                let _ = ws.close(None).now_or_never();
                return "refresh".into();
            }
            msg = out_rx.recv() => {
                let Some(msg) = msg else { return "stopped".into() };
                if ws.send(WsMessage::Text(msg.to_text().into())).await.is_err() {
                    return "send_failed".into();
                }
            }
            _ = ping.tick() => {
                if last_heard.elapsed() > Duration::from_secs(*keepalive * 2 + 10) {
                    return "keepalive_timeout".into();
                }
                if ws.send(WsMessage::Ping(Vec::new().into())).await.is_err() {
                    return "send_failed".into();
                }
                clean_intervals += 1;
                if clean_intervals >= 3 && *keepalive < 270 {
                    // The network kept the socket for three intervals: try a longer one next session.
                    *keepalive = (*keepalive * 2).min(270);
                    clean_intervals = 0;
                }
            }
            incoming = ws.next() => {
                last_heard = tokio::time::Instant::now();
                *shared.last_heard.lock().unwrap() = Some(Instant::now());
                match incoming {
                    Some(Ok(WsMessage::Text(text))) => {
                        if let Some(msg) = Msg::parse(text.as_str()) {
                            let _ = events.send(RdvEvent::Msg(msg));
                        }
                    }
                    Some(Ok(WsMessage::Close(_))) | None | Some(Err(_)) => return "closed".into(),
                    _ => {}
                }
            }
        }
    }
}

/// DNS, TCP and TLS as separate steps, each reported for the waterfall; the upgrade follows with the hello.
async fn transport(request: &tokio_tungstenite::tungstenite::handshake::client::Request, events: &mpsc::UnboundedSender<RdvEvent>) -> Option<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let host = request.uri().host()?.trim_matches(|c| c == '[' || c == ']').to_string();
    let tls = request.uri().scheme_str() == Some("wss");
    let port = request.uri().port_u16().unwrap_or(if tls { 443 } else { 80 });
    let addrs: Vec<std::net::SocketAddr> = tokio::net::lookup_host((host.as_str(), port)).await.ok()?.collect();
    let _ = events.send(RdvEvent::Timing("dns"));
    let mut tcp = None;
    for addr in addrs {
        if let Ok(stream) = tokio::net::TcpStream::connect(addr).await {
            tcp = Some(stream);
            break;
        }
    }
    let tcp = tcp?;
    let _ = tcp.set_nodelay(true);
    let _ = events.send(RdvEvent::Timing("tcp"));
    if !tls {
        return Some(tokio_tungstenite::MaybeTlsStream::Plain(tcp));
    }
    let name = rustls::pki_types::ServerName::try_from(host).ok()?;
    let stream = tokio_rustls::TlsConnector::from(tls_config()).connect(name, tcp).await.ok()?;
    let _ = events.send(RdvEvent::Timing("tls"));
    Some(tokio_tungstenite::MaybeTlsStream::Rustls(stream))
}

/// One TLS configuration per process, so reconnects can resume the TLS session.
fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: std::sync::OnceLock<Arc<rustls::ClientConfig>> = std::sync::OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let tls = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .expect("TLS versions")
                .with_root_certificates(roots)
                .with_no_client_auth();
            Arc::new(tls)
        })
        .clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls() {
        assert!(allowed_url("wss://connect.roundrobin.in/v1/ws"));
        assert!(allowed_url("ws://127.0.0.1:8080/v1/ws"));
        assert!(allowed_url("ws://100.121.85.33:18450/v1/ws"));
        assert!(allowed_url("ws://localhost:8080/v1/ws"));
        assert!(!allowed_url("ws://connect.roundrobin.in/v1/ws"));
        assert!(!allowed_url("ws://8.8.8.8/v1/ws"));
        assert!(!allowed_url("http://x"));
    }
}
