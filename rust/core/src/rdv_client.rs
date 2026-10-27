//! The rendezvous client: one WebSocket per device to the control service (spec 4.7, 6.2).
//!
//! Authenticates with the node key (signed by the app's keystore through `Signer`), keeps the
//! socket warm with an adaptive keep-alive (60 s, doubling after 3 clean intervals up to 270 s,
//! halving after a drop) and reconnects with full jitter (2 s base, 5 minute cap).

use bridgey_connect_proto::b64;
use bridgey_connect_proto::rdv::{self, Msg};
use futures_util::{SinkExt, StreamExt};
use std::future::Future;
use std::net::IpAddr;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message as WsMessage;

pub type Signer = Arc<dyn Fn(Vec<u8>) -> Pin<Box<dyn Future<Output = Option<Vec<u8>>> + Send>> + Send + Sync>;

#[derive(Debug)]
pub enum RdvEvent {
    Connected,
    Disconnected(String),
    Msg(Msg),
}

pub struct RdvClient {
    out: mpsc::UnboundedSender<Msg>,
    stop: tokio::sync::watch::Sender<bool>,
}

impl RdvClient {
    pub fn send(&self, msg: Msg) {
        let _ = self.out.send(msg);
    }

    pub fn stop(&self) {
        let _ = self.stop.send(true);
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

pub fn start(url: String, node_public_key: Vec<u8>, app: String, signer: Signer, events: mpsc::UnboundedSender<RdvEvent>) -> RdvClient {
    let (out, mut out_rx) = mpsc::unbounded_channel::<Msg>();
    let (stop, mut stop_rx) = tokio::sync::watch::channel(false);
    tokio::spawn(async move {
        let mut attempt = 0u32;
        let mut keepalive = 60u64;
        loop {
            if *stop_rx.borrow() {
                break;
            }
            let outcome = session(&url, &node_public_key, &app, &signer, &events, &mut out_rx, &mut stop_rx, &mut keepalive).await;
            if *stop_rx.borrow() {
                break;
            }
            let _ = events.send(RdvEvent::Disconnected(outcome.clone()));
            if outcome == "clean" {
                attempt = 0;
            } else {
                attempt = attempt.saturating_add(1);
                keepalive = (keepalive / 2).max(60);
            }
            let wait = full_jitter(attempt);
            tokio::select! {
                _ = tokio::time::sleep(wait) => {}
                _ = stop_rx.changed() => break,
            }
        }
    });
    RdvClient { out, stop }
}

#[allow(clippy::too_many_arguments)]
async fn session(
    url: &str,
    node: &[u8],
    app: &str,
    signer: &Signer,
    events: &mpsc::UnboundedSender<RdvEvent>,
    out_rx: &mut mpsc::UnboundedReceiver<Msg>,
    stop_rx: &mut tokio::sync::watch::Receiver<bool>,
    keepalive: &mut u64,
) -> String {
    if !allowed_url(url) {
        return "insecure_url".into();
    }
    let config = WebSocketConfig::default().max_message_size(Some(rdv::MAX_FRAME_BYTES)).max_frame_size(Some(rdv::MAX_FRAME_BYTES));
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .expect("TLS versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
    let connector = tokio_tungstenite::Connector::Rustls(Arc::new(tls));
    let connect = tokio_tungstenite::connect_async_tls_with_config(url, Some(config), true, Some(connector));
    let mut ws = match tokio::time::timeout(Duration::from_secs(10), connect).await {
        Ok(Ok((ws, _))) => ws,
        _ => return "connect_failed".into(),
    };
    let hello = Msg::Hello { v: rdv::PROTOCOL_VERSION, node: b64::url_encode(node), app: app.to_string(), keepalive: *keepalive as u32 };
    if ws.send(WsMessage::Text(hello.to_text().into())).await.is_err() {
        return "send_failed".into();
    }
    let next = |text: Option<Result<WsMessage, _>>| -> Option<Msg> {
        match text {
            Some(Ok(WsMessage::Text(t))) => Msg::parse(t.as_str()),
            _ => None,
        }
    };
    let Ok(challenge) = tokio::time::timeout(Duration::from_secs(10), ws.next()).await else { return "timeout".into() };
    let Some(Msg::Challenge { nonce, pow }) = next(challenge) else { return "no_challenge".into() };
    let Some(nonce) = b64::url_decode(&nonce).filter(|n| n.len() == 32) else { return "bad_challenge".into() };
    let message = bridgey_connect_proto::derive::auth_message(&nonce, node);
    let Some(signature) = signer(message).await else { return "sign_failed".into() };
    let solution = (pow > 0 && pow <= 24).then(|| b64::url_encode(&bridgey_connect_proto::derive::pow_solve(&nonce, node, pow)));
    let auth = Msg::Auth { sig: b64::url_encode(&signature), pow: solution };
    if ws.send(WsMessage::Text(auth.to_text().into())).await.is_err() {
        return "send_failed".into();
    }
    let Ok(welcome) = tokio::time::timeout(Duration::from_secs(10), ws.next()).await else { return "timeout".into() };
    match next(welcome) {
        Some(Msg::Welcome { .. }) => {}
        Some(Msg::Error { code, .. }) => return format!("refused_{code}"),
        _ => return "no_welcome".into(),
    }
    let _ = events.send(RdvEvent::Connected);
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
