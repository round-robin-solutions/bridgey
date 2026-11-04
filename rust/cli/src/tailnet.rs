//! Pairing over the tailnet (docs/mesh-and-codes.md, phase 2): Bridgey devices on the same Tailscale tailnet find and
//! pair with each other directly, without being on the same local network. Discovery reads `tailscale status --json`
//! (the local tailscaled), a name or address can be given by hand, and the pairing itself is the normal protocol 2 first
//! pairing over plain TCP to port 42458 (commitment, reveal, the code compared at both ends, Allow pairing on the
//! receiving side). Nothing here is trusted until that pairing completes.

use serde_json::Value;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::time::Duration;

/// The apps' TCP port, and the one `bridgey pair --allow` listens on.
pub const PORT: u16 = 42458;

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct TailnetPeer {
    pub name: String,
    pub dns: String,
    pub ips: Vec<String>,
    pub os: String,
    pub online: bool,
}

/// Tailscale's address ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48. A connection from anywhere else is not a
/// tailnet device (loopback is allowed for tests on one host).
pub fn is_tailnet(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            o[0] == 100 && (o[1] & 0xc0) == 64
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_tailnet(IpAddr::V4(v4));
            }
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

pub fn accepted_source(ip: IpAddr) -> bool {
    is_tailnet(ip) || ip.is_loopback() || matches!(ip, IpAddr::V6(v6) if v6.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback()))
}

/// The peers in `tailscale status --json` (never this device), online first.
pub fn parse_status(json: &Value) -> Vec<TailnetPeer> {
    let mut peers: Vec<TailnetPeer> = json["Peer"]
        .as_object()
        .map(|m| {
            m.values()
                .filter_map(|p| {
                    let name = p["HostName"].as_str()?.chars().filter(|c| !c.is_control()).take(64).collect::<String>();
                    let ips: Vec<String> = p["TailscaleIPs"].as_array()?.iter().filter_map(|i| i.as_str()?.parse::<IpAddr>().ok().filter(|ip| is_tailnet(*ip)).map(|ip| ip.to_string())).collect();
                    if ips.is_empty() {
                        return None;
                    }
                    Some(TailnetPeer {
                        name,
                        dns: p["DNSName"].as_str().unwrap_or("").trim_end_matches('.').to_string(),
                        ips,
                        os: p["OS"].as_str().unwrap_or("").to_string(),
                        online: p["Online"].as_bool().unwrap_or(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    peers.sort_by(|a, b| b.online.cmp(&a.online).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    peers
}

/// The peer a name means: its host name, its MagicDNS name, or the first label of it (case-insensitive).
pub fn find<'a>(peers: &'a [TailnetPeer], name: &str) -> Option<&'a TailnetPeer> {
    let wanted = name.trim().trim_end_matches('.').to_lowercase();
    peers.iter().find(|p| {
        p.name.to_lowercase() == wanted || p.dns.to_lowercase() == wanted || p.dns.split('.').next().is_some_and(|first| first.to_lowercase() == wanted)
    })
}

fn binary() -> Option<PathBuf> {
    let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"];
    std::env::var_os("PATH")
        .into_iter()
        .flat_map(|p| std::env::split_paths(&p).map(|d| d.join("tailscale")).collect::<Vec<_>>())
        .chain(candidates.iter().map(PathBuf::from))
        .find(|p| p.is_file())
}

/// This device's tailnet peers, or an error saying why there are none (no Tailscale, not running).
pub fn status() -> Result<Vec<TailnetPeer>, String> {
    let bin = binary().ok_or("Tailscale is not installed here (no tailscale command)")?;
    let out = std::process::Command::new(bin).args(["status", "--json"]).output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err("Tailscale is not running here".into());
    }
    let json: Value = serde_json::from_slice(&out.stdout).map_err(|_| "unreadable tailscale status")?;
    if json["BackendState"].as_str().is_some_and(|s| s != "Running") {
        return Err("Tailscale is not running here".into());
    }
    Ok(parse_status(&json))
}

/// `host`, `host:port`, an address, or a tailnet name, to an address to dial (IPv4 first).
pub async fn resolve(target: &str) -> Result<SocketAddr, String> {
    let target = target.trim();
    if let Ok(addr) = target.parse::<SocketAddr>() {
        return Ok(addr);
    }
    if let Ok(ip) = target.parse::<IpAddr>() {
        return Ok(SocketAddr::new(ip, PORT));
    }
    let (host, port) = match target.rsplit_once(':') {
        Some((h, p)) if p.parse::<u16>().is_ok() && !h.contains(':') => (h, p.parse::<u16>().unwrap()),
        _ => (target, PORT),
    };
    if let Ok(peers) = status() {
        if let Some(peer) = find(&peers, host) {
            let ip = peer.ips.iter().filter_map(|i| i.parse::<IpAddr>().ok()).min_by_key(|ip| ip.is_ipv6()).ok_or("no address")?;
            return Ok(SocketAddr::new(ip, port));
        }
    }
    tokio::net::lookup_host((host, port)).await.map_err(|e| format!("{host}: {e}"))?.min_by_key(|a| a.is_ipv6()).ok_or_else(|| format!("{host}: no address"))
}

/// Whether something answers on Bridgey's port there (a short TCP connect, nothing sent).
pub async fn probe(addr: SocketAddr, timeout: Duration) -> bool {
    matches!(tokio::time::timeout(timeout, tokio::net::TcpStream::connect(addr)).await, Ok(Ok(_)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tailnet_ranges() {
        assert!(is_tailnet("100.77.183.42".parse().unwrap()));
        assert!(is_tailnet("100.64.0.1".parse().unwrap()));
        assert!(is_tailnet("100.127.255.254".parse().unwrap()));
        assert!(!is_tailnet("100.128.0.1".parse().unwrap()));
        assert!(!is_tailnet("100.63.255.255".parse().unwrap()));
        assert!(!is_tailnet("192.168.1.10".parse().unwrap()));
        assert!(is_tailnet("fd7a:115c:a1e0::9833:b72b".parse().unwrap()));
        assert!(!is_tailnet("fd7a:115c:a1e1::1".parse().unwrap()));
        assert!(is_tailnet("::ffff:100.77.183.42".parse().unwrap()));
        assert!(accepted_source("127.0.0.1".parse().unwrap()));
        assert!(!accepted_source("203.0.113.9".parse().unwrap()));
    }

    #[test]
    fn status_peers_and_names() {
        let status = json!({"BackendState": "Running", "Self": {"HostName": "contabo-europe", "TailscaleIPs": ["100.121.85.33"]}, "Peer": {
            "a": {"HostName": "personal", "DNSName": "personal.tail1234.ts.net.", "TailscaleIPs": ["100.77.183.42", "fd7a:115c:a1e0::9833:b72b"], "OS": "macOS", "Online": true},
            "b": {"HostName": "OnePlus 11 5G", "DNSName": "oneplus-11-5g.tail1234.ts.net.", "TailscaleIPs": ["100.80.1.2"], "OS": "android", "Online": false},
            "c": {"HostName": "odd", "TailscaleIPs": ["8.8.8.8"], "Online": true},
            "d": {"HostName": "work\u{7}", "DNSName": "work.tail1234.ts.net.", "TailscaleIPs": ["100.90.0.3"], "OS": "macOS", "Online": true}
        }});
        let peers = parse_status(&status);
        assert_eq!(peers.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), vec!["personal", "work", "OnePlus 11 5G"], "online first, no self, no outside address, no control characters");
        assert_eq!(find(&peers, "Personal").unwrap().ips[0], "100.77.183.42");
        assert_eq!(find(&peers, "personal.tail1234.ts.net").unwrap().name, "personal");
        assert_eq!(find(&peers, "oneplus-11-5g").unwrap().os, "android");
        assert!(find(&peers, "contabo-europe").is_none());
    }
}
