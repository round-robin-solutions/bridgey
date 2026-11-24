//! Cloudflare Realtime TURN (docs/connect-anywhere.md, section 9.4): credentials minted per grant, and the account's
//! usage for the free-tier cap. A small HTTPS client (HTTP/1.1, one request per connection, the Web PKI roots built
//! in) keeps the service one static binary on `scratch`.
//!
//! Nothing here logs or returns a secret: errors carry status codes and Cloudflare's error messages only, never a URL
//! (the key ID is in the path), a header or a response body.

use crate::config::{CloudflareSecrets, CloudflareSettings};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Credentials Cloudflare minted for one grant.
#[derive(Clone, Debug, PartialEq)]
pub struct Minted {
    pub urls: Vec<String>,
    pub username: String,
    pub credential: String,
}

pub struct Cloudflare {
    settings: CloudflareSettings,
    secrets: CloudflareSecrets,
}

/// Responses larger than this are refused (both answers are well under 4 KiB).
const MAX_RESPONSE: usize = 256 * 1024;
const GB: u64 = 1_000_000_000;

impl Cloudflare {
    pub fn new(settings: CloudflareSettings, secrets: CloudflareSecrets) -> Cloudflare {
        Cloudflare { settings, secrets }
    }

    /// The usage query needs the account ID and an analytics token; without them Cloudflare is never used.
    pub fn can_read_usage(&self) -> bool {
        self.secrets.account.is_some() && self.secrets.analytics_token.is_some()
    }

    /// `POST {api_base}/turn/keys/{keyId}/credentials/generate-ice-servers` with the grant's lifetime.
    pub async fn mint(&self, ttl_s: u64) -> Result<Minted, String> {
        let url = format!("{}/turn/keys/{}/credentials/generate-ice-servers", self.settings.api_base.trim_end_matches('/'), self.secrets.key_id);
        let auth = format!("Bearer {}", self.secrets.token);
        let body = serde_json::json!({ "ttl": ttl_s }).to_string();
        let timeout = Duration::from_millis(self.settings.mint_timeout_ms);
        let (status, bytes) = post(&url, &[("Authorization", &auth)], body.as_bytes(), timeout).await.map_err(|e| format!("mint: {e}"))?;
        if !(200..300).contains(&status) {
            return Err(format!("mint answered {status}"));
        }
        parse_ice_servers(&bytes)
    }

    /// Bytes counted against the free tier in the current window: TURN (and the SFU, which shares the free tier)
    /// egress, plus ingress if `count_ingress`.
    pub async fn usage(&self, now_unix_s: u64) -> Result<u64, String> {
        let (Some(account), Some(token)) = (&self.secrets.account, &self.secrets.analytics_token) else {
            return Err("no account ID or analytics token".into());
        };
        let since = window_start(now_unix_s, self.settings.cycle_day, self.settings.window_days);
        let query = "query($tag: string!, $since: Time!, $until: Time!) { viewer { accounts(filter: {accountTag: $tag}) { \
            turn: callsTurnUsageAdaptiveGroups(limit: 1, filter: {datetime_geq: $since, datetime_lt: $until}) { sum { egressBytes ingressBytes } } \
            sfu: callsUsageAdaptiveGroups(limit: 1, filter: {datetime_geq: $since, datetime_lt: $until}) { sum { egressBytes ingressBytes } } } } }";
        let body = serde_json::json!({
            "query": query,
            "variables": { "tag": account, "since": rfc3339(since), "until": rfc3339(now_unix_s + 60) },
        })
        .to_string();
        let auth = format!("Bearer {token}");
        let (status, bytes) = post(&self.settings.graphql_url, &[("Authorization", &auth)], body.as_bytes(), Duration::from_secs(20)).await.map_err(|e| format!("usage: {e}"))?;
        if !(200..300).contains(&status) {
            return Err(format!("usage answered {status}"));
        }
        parse_usage(&bytes, self.settings.count_ingress)
    }
}

pub type Shared = Arc<Cloudflare>;

/// The TURN entry of a `generate-ice-servers` answer. Cloudflare returns `iceServers` as a list (a STUN entry and a
/// TURN entry with the credentials); older answers had one object.
pub fn parse_ice_servers(bytes: &[u8]) -> Result<Minted, String> {
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| "mint: not JSON".to_string())?;
    let servers = match value.get("iceServers") {
        Some(serde_json::Value::Array(list)) => list.clone(),
        Some(one @ serde_json::Value::Object(_)) => vec![one.clone()],
        _ => return Err("mint: no iceServers".into()),
    };
    for server in servers {
        let (Some(username), Some(credential)) = (server.get("username").and_then(|v| v.as_str()), server.get("credential").and_then(|v| v.as_str())) else {
            continue;
        };
        let urls: Vec<String> = match server.get("urls") {
            Some(serde_json::Value::Array(list)) => list.iter().filter_map(|u| u.as_str().map(String::from)).collect(),
            Some(serde_json::Value::String(one)) => vec![one.clone()],
            _ => Vec::new(),
        };
        if username.is_empty() || credential.is_empty() {
            continue;
        }
        return Ok(Minted { urls, username: username.to_string(), credential: credential.to_string() });
    }
    Err("mint: no TURN credentials in the answer".into())
}

/// The summed bytes of a usage answer; any GraphQL error is an error (a partial answer could undercount).
pub fn parse_usage(bytes: &[u8], count_ingress: bool) -> Result<u64, String> {
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| "usage: not JSON".to_string())?;
    if let Some(errors) = value.get("errors").and_then(|e| e.as_array()).filter(|e| !e.is_empty()) {
        let first = errors[0].get("message").and_then(|m| m.as_str()).unwrap_or("error");
        return Err(format!("usage: {}", first.chars().take(160).collect::<String>()));
    }
    let accounts = value.pointer("/data/viewer/accounts").and_then(|a| a.as_array()).ok_or("usage: no accounts in the answer")?;
    let account = accounts.first().ok_or("usage: the token cannot read this account")?;
    let mut total = 0u64;
    for dataset in ["turn", "sfu"] {
        let groups = account.get(dataset).and_then(|g| g.as_array()).ok_or("usage: a dataset is missing")?;
        for group in groups {
            let sum = |field: &str| group.pointer(&format!("/sum/{field}")).and_then(|v| v.as_f64()).unwrap_or(0.0).max(0.0) as u64;
            total = total.saturating_add(sum("egressBytes"));
            if count_ingress {
                total = total.saturating_add(sum("ingressBytes"));
            }
        }
    }
    Ok(total)
}

pub fn gb(bytes: u64) -> f64 {
    bytes as f64 / GB as f64
}

pub fn gb_bytes(gb: u64) -> u64 {
    gb.saturating_mul(GB)
}

/// Where the usage window starts. `cycle_day` 0: `window_days` ago (a rolling window, at least as long as any
/// billing month, so it never counts less than the bill does). 1 to 28: that day of this month (or of last month
/// before it comes), 00:00 UTC.
pub fn window_start(now_unix_s: u64, cycle_day: u32, window_days: u32) -> u64 {
    if cycle_day == 0 {
        return now_unix_s.saturating_sub(u64::from(window_days) * 86_400);
    }
    let days = (now_unix_s / 86_400) as i64;
    let (year, month, day) = civil_from_days(days);
    let (year, month) = if day >= cycle_day { (year, month) } else if month == 1 { (year - 1, 12) } else { (year, month - 1) };
    (days_from_civil(year, month, cycle_day) as u64) * 86_400
}

/// `YYYY-MM-DDTHH:MM:SSZ`.
pub fn rfc3339(unix_s: u64) -> String {
    let days = (unix_s / 86_400) as i64;
    let secs = unix_s % 86_400;
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", secs / 3_600, secs / 60 % 60, secs % 60)
}

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian (Howard Hinnant's algorithm).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = i64::from(if m > 2 { m - 3 } else { m + 9 });
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

// region HTTPS

trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

/// One `POST` with a JSON body; returns the status and body. `https://` always, `http://` to loopback only (tests).
pub async fn post(url: &str, headers: &[(&str, &str)], body: &[u8], timeout: Duration) -> Result<(u16, Vec<u8>), String> {
    tokio::time::timeout(timeout, post_inner(url, headers, body)).await.map_err(|_| "timed out".to_string())?
}

async fn post_inner(url: &str, headers: &[(&str, &str)], body: &[u8]) -> Result<(u16, Vec<u8>), String> {
    let (tls, rest) = match (url.strip_prefix("https://"), url.strip_prefix("http://")) {
        (Some(rest), _) => (true, rest),
        (None, Some(rest)) => (false, rest),
        _ => return Err("not an http(s) URL".into()),
    };
    let (authority, path) = rest.split_once('/').map(|(a, p)| (a, format!("/{p}"))).unwrap_or((rest, "/".into()));
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !h.contains(']') || h.ends_with(']') => (h.trim_matches(|c| c == '[' || c == ']'), p.parse::<u16>().map_err(|_| "bad port")?),
        _ => (authority.trim_matches(|c| c == '[' || c == ']'), if tls { 443 } else { 80 }),
    };
    if !tls && !host.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback()) && host != "localhost" {
        return Err("plain http only to loopback".into());
    }
    let tcp = tokio::net::TcpStream::connect((host, port)).await.map_err(|e| format!("connect: {}", e.kind()))?;
    let _ = tcp.set_nodelay(true);
    let mut stream: Box<dyn Stream> = if tls {
        let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|_| "bad host name")?;
        Box::new(tokio_rustls::TlsConnector::from(tls_config()).connect(name, tcp).await.map_err(|e| format!("tls: {}", e.kind()))?)
    } else {
        Box::new(tcp)
    };
    let mut request = format!(
        "POST {path} HTTP/1.1\r\nHost: {authority}\r\nUser-Agent: bridgey-rendezvous\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    for (name, value) in headers {
        request.push_str(name);
        request.push_str(": ");
        request.push_str(value);
        request.push_str("\r\n");
    }
    request.push_str("\r\n");
    let mut out = request.into_bytes();
    out.extend_from_slice(body);
    stream.write_all(&out).await.map_err(|e| format!("send: {}", e.kind()))?;
    stream.flush().await.map_err(|e| format!("send: {}", e.kind()))?;
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8_192];
    loop {
        match stream.read(&mut chunk).await {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.len() > MAX_RESPONSE {
                    return Err("response too large".into());
                }
                if let Some(done) = parse_response(&buf, false)? {
                    return Ok(done);
                }
            }
            // A server that closes without TLS close_notify: the answer may still be complete.
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(e) => return Err(format!("read: {}", e.kind())),
        }
    }
    parse_response(&buf, true)?.ok_or_else(|| "incomplete response".into())
}

/// The status and body of an HTTP/1.1 response in `buf`, `None` while more is needed. `eof`: nothing more comes.
pub fn parse_response(buf: &[u8], eof: bool) -> Result<Option<(u16, Vec<u8>)>, String> {
    let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") else {
        return if eof { Err("no response head".into()) } else { Ok(None) };
    };
    let head = std::str::from_utf8(&buf[..end]).map_err(|_| "bad response head")?;
    let mut lines = head.split("\r\n");
    let status: u16 = lines.next().and_then(|l| l.split_whitespace().nth(1)).and_then(|s| s.parse().ok()).ok_or("bad status line")?;
    let mut length = None;
    let mut chunked = false;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else { continue };
        let (name, value) = (name.trim().to_ascii_lowercase(), value.trim());
        if name == "content-length" {
            length = Some(value.parse::<usize>().map_err(|_| "bad content-length")?);
        } else if name == "transfer-encoding" && value.to_ascii_lowercase().contains("chunked") {
            chunked = true;
        }
    }
    let body = &buf[end + 4..];
    if chunked {
        return match dechunk(body)? {
            Some(decoded) => Ok(Some((status, decoded))),
            None if eof => Err("truncated chunked body".into()),
            None => Ok(None),
        };
    }
    match length {
        Some(n) if body.len() >= n => Ok(Some((status, body[..n].to_vec()))),
        Some(_) if eof => Err("truncated body".into()),
        Some(_) => Ok(None),
        None if eof => Ok(Some((status, body.to_vec()))),
        None => Ok(None),
    }
}

/// A complete chunked body, decoded; `None` while the last chunk has not arrived.
fn dechunk(mut body: &[u8]) -> Result<Option<Vec<u8>>, String> {
    let mut out = Vec::new();
    loop {
        let Some(line_end) = body.windows(2).position(|w| w == b"\r\n") else { return Ok(None) };
        let size_text = std::str::from_utf8(&body[..line_end]).map_err(|_| "bad chunk size")?;
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16).map_err(|_| "bad chunk size")?;
        body = &body[line_end + 2..];
        if size == 0 {
            return Ok(Some(out));
        }
        if body.len() < size + 2 {
            return Ok(None);
        }
        out.extend_from_slice(&body[..size]);
        body = &body[size + 2..];
    }
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: std::sync::OnceLock<Arc<rustls::ClientConfig>> = std::sync::OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let config = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .expect("TLS versions")
                .with_root_certificates(roots)
                .with_no_client_auth();
            Arc::new(config)
        })
        .clone()
}

// endregion

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    /// A stand-in for Cloudflare's API on loopback: answers each connection with `response`, after `delay`, and hands
    /// back what it was sent.
    async fn mock(response: &'static str, delay: Duration) -> (String, tokio::sync::mpsc::UnboundedReceiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Ok((mut sock, _)) = listener.accept().await {
                let tx = tx.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 16_384];
                    let mut got = Vec::new();
                    loop {
                        let n = sock.read(&mut buf).await.unwrap_or(0);
                        got.extend_from_slice(&buf[..n]);
                        let text = String::from_utf8_lossy(&got).to_string();
                        if let Some(end) = text.find("\r\n\r\n") {
                            let length: usize = text.lines().find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse().unwrap())).unwrap_or(0);
                            if got.len() >= end + 4 + length {
                                let _ = tx.send(text);
                                break;
                            }
                        }
                        if n == 0 {
                            return;
                        }
                    }
                    tokio::time::sleep(delay).await;
                    let _ = sock.write_all(response.as_bytes()).await;
                    let _ = sock.shutdown().await;
                });
            }
        });
        (base, rx)
    }

    fn client(api_base: &str, graphql: &str, timeout_ms: u64) -> Cloudflare {
        let settings = CloudflareSettings { api_base: api_base.into(), graphql_url: graphql.into(), mint_timeout_ms: timeout_ms, ..Default::default() };
        let secrets = CloudflareSecrets { key_id: "KEYID".into(), token: "TOKEN".into(), account: Some("ACCT".into()), analytics_token: Some("ANALYTICS".into()) };
        Cloudflare::new(settings, secrets)
    }

    const MINTED: &str = "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n\
        3a\r\n{\"iceServers\":[{\"urls\":[\"stun:stun.cloudflare.com:3478\"]},\r\n\
        88\r\n{\"urls\":[\"turn:turn.cloudflare.com:3478?transport=udp\",\"turns:turn.cloudflare.com:443?transport=tcp\"],\"username\":\"u\",\"credential\":\"c\"}]}\r\n0\r\n\r\n";

    #[tokio::test]
    async fn mints_through_the_api() {
        let (base, mut seen) = mock(MINTED, Duration::ZERO).await;
        let cf = client(&format!("{base}/v1"), "", 2_000);
        let minted = cf.mint(7_200).await.expect("minted");
        assert_eq!(minted.username, "u");
        assert_eq!(minted.credential, "c");
        assert_eq!(minted.urls.len(), 2);
        let request = seen.recv().await.unwrap();
        assert!(request.starts_with("POST /v1/turn/keys/KEYID/credentials/generate-ice-servers HTTP/1.1\r\n"));
        assert!(request.contains("Authorization: Bearer TOKEN\r\n"));
        assert!(request.ends_with("{\"ttl\":7200}"));
    }

    #[tokio::test]
    async fn mint_failures_carry_no_secrets() {
        let (base, _) = mock("HTTP/1.1 401 Unauthorized\r\nContent-Length: 2\r\n\r\n{}", Duration::ZERO).await;
        let err = client(&base, "", 2_000).mint(60).await.unwrap_err();
        assert_eq!(err, "mint answered 401");
        // Slower than the mint timeout: a failure, so the grant goes to the own pool.
        let (base, _) = mock(MINTED, Duration::from_millis(800)).await;
        let err = client(&base, "", 200).mint(60).await.unwrap_err();
        assert!(err.contains("timed out"), "{err}");
        // Nothing listening.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let closed = format!("http://{}", listener.local_addr().unwrap());
        drop(listener);
        let err = client(&closed, "", 2_000).mint(60).await.unwrap_err();
        assert!(!err.contains("KEYID") && !err.contains("TOKEN"), "{err}");
        // A body with no credentials.
        let (base, _) = mock("HTTP/1.1 201 Created\r\nContent-Length: 17\r\n\r\n{\"iceServers\":[]}", Duration::ZERO).await;
        assert!(client(&base, "", 2_000).mint(60).await.is_err());
    }

    #[tokio::test]
    async fn reads_usage() {
        let answer = "HTTP/1.1 200 OK\r\nContent-Length: 171\r\n\r\n{\"data\":{\"viewer\":{\"accounts\":[{\"turn\":[{\"sum\":{\"egressBytes\":5000000000,\"ingressBytes\":7}}],\"sfu\":[{\"sum\":{\"egressBytes\":1000000000,\"ingressBytes\":1}}]}]}},\"errors\":null}";
        let (base, mut seen) = mock(answer, Duration::ZERO).await;
        let cf = client("", &format!("{base}/client/v4/graphql"), 2_000);
        assert_eq!(cf.usage(1_764_000_000).await, Ok(6_000_000_000));
        let request = seen.recv().await.unwrap();
        assert!(request.contains("Authorization: Bearer ANALYTICS\r\n"));
        assert!(request.contains("\"tag\":\"ACCT\""));
        assert!(request.contains("callsTurnUsageAdaptiveGroups"));
        let (base, _) = mock("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{\"data\":null,\"errors\":[{\"message\":\"not allowed\"}]}", Duration::ZERO).await;
        assert_eq!(client("", &base, 2_000).usage(1_764_000_000).await, Err("usage: not allowed".into()));
    }

    #[test]
    fn usage_answers() {
        let empty = br#"{"data":{"viewer":{"accounts":[{"turn":[],"sfu":[]}]}},"errors":null}"#;
        assert_eq!(parse_usage(empty, false), Ok(0));
        let both = br#"{"data":{"viewer":{"accounts":[{"turn":[{"sum":{"egressBytes":10,"ingressBytes":4}}],"sfu":[]}]}}}"#;
        assert_eq!(parse_usage(both, false), Ok(10));
        assert_eq!(parse_usage(both, true), Ok(14));
        assert!(parse_usage(br#"{"data":{"viewer":{"accounts":[]}}}"#, false).is_err(), "a token without the account counts nothing");
        assert!(parse_usage(br#"{"data":{"viewer":{"accounts":[{"turn":[]}]}}}"#, false).is_err(), "a missing dataset is an error");
    }

    #[test]
    fn ice_server_answers() {
        let old = br#"{"iceServers":{"urls":["turn:turn.cloudflare.com:3478?transport=udp"],"username":"u","credential":"c"}}"#;
        assert_eq!(parse_ice_servers(old).unwrap().urls, vec!["turn:turn.cloudflare.com:3478?transport=udp".to_string()]);
        assert!(parse_ice_servers(br#"{"iceServers":[{"urls":["stun:a"]}]}"#).is_err());
        assert!(parse_ice_servers(b"nope").is_err());
    }

    #[test]
    fn responses() {
        assert_eq!(parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi", false), Ok(Some((200, b"hi".to_vec()))));
        assert_eq!(parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nhi", false), Ok(None));
        assert!(parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nhi", true).is_err());
        assert_eq!(parse_response(b"HTTP/1.1 204 No Content\r\n\r\n", true), Ok(Some((204, Vec::new()))));
        assert_eq!(parse_response(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n1;x=y\r\n!\r\n0\r\n\r\n", false), Ok(Some((200, b"hi!".to_vec()))));
        assert_eq!(parse_response(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nh", false), Ok(None));
        assert_eq!(parse_response(b"HTTP/1.1 200 OK\r\n", false), Ok(None));
    }

    #[test]
    fn windows_and_dates() {
        // 2026-11-24T10:00:00Z
        let now = 1_795_514_400;
        assert_eq!(rfc3339(now), "2026-11-24T10:00:00Z");
        assert_eq!(rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(window_start(now, 0, 31), now - 31 * 86_400);
        assert_eq!(rfc3339(window_start(now, 1, 31)), "2026-11-01T00:00:00Z");
        assert_eq!(rfc3339(window_start(now, 24, 31)), "2026-11-24T00:00:00Z");
        assert_eq!(rfc3339(window_start(now, 25, 31)), "2026-10-25T00:00:00Z");
        // January, before the cycle day: December of the year before.
        assert_eq!(rfc3339(window_start(1_799_150_400, 15, 31)), "2026-12-15T00:00:00Z");
        assert_eq!(rfc3339(1_799_150_400), "2027-01-05T12:00:00Z");
        assert_eq!(gb_bytes(950), 950_000_000_000);
    }
}
