//! Local addresses and how Bridgey labels them (spec 4.1, 4.2).

use serde::Serialize;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

/// Route kinds in their order of preference.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Route {
    Lan,
    Vpn,
    Direct,
    Relay,
}

impl Route {
    pub fn as_str(self) -> &'static str {
        match self {
            Route::Lan => "lan",
            Route::Vpn => "vpn",
            Route::Direct => "direct",
            Route::Relay => "relay",
        }
    }
}

/// Address kind in `connect.addresses`: `lan`, `vpn` or `public6`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Lan,
    Vpn,
    Public6,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct LocalAddress {
    pub a: String,
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vpn: Option<&'static str>,
    #[serde(skip)]
    pub ip: IpAddr,
}

/// IPv4-mapped IPv6 becomes plain IPv4, so the same peer has one form everywhere.
pub fn canonical(addr: SocketAddr) -> SocketAddr {
    match addr {
        SocketAddr::V6(v6) => match v6.ip().to_ipv4_mapped() {
            Some(v4) => SocketAddr::new(IpAddr::V4(v4), v6.port()),
            None => addr,
        },
        _ => addr,
    }
}

fn excluded_interface(name: &str) -> bool {
    name == "docker0" || name.starts_with("br-") || name.starts_with("veth") || name.starts_with("lo") || name.starts_with("dummy")
        || name.starts_with("awdl") || name.starts_with("llw") || name.starts_with("anpi") || name.starts_with("ap1")
}

fn vpn_interface(name: &str) -> bool {
    name.starts_with("tun") || name.starts_with("utun") || name.starts_with("wg") || name.starts_with("tailscale") || name.starts_with("ipsec")
}

pub fn is_tailscale(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
        IpAddr::V4(_) => false,
    }
}

/// 100.64.0.0/10, shared by Tailscale, other VPNs and carrier NAT.
pub fn is_cgnat(ip: IpAddr) -> bool {
    matches!(ip, IpAddr::V4(v4) if v4.octets()[0] == 100 && (v4.octets()[1] & 0xC0) == 64)
}

fn is_ula(v6: &Ipv6Addr) -> bool {
    (v6.segments()[0] & 0xfe00) == 0xfc00
}

fn is_link_local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_link_local(),
        IpAddr::V6(v6) => (v6.segments()[0] & 0xffc0) == 0xfe80,
    }
}

fn is_global_v6(v6: &Ipv6Addr) -> bool {
    (v6.segments()[0] & 0xe000) == 0x2000
}

/// Classifies an address on a named interface; `None` for addresses never offered.
pub fn classify(interface: &str, ip: IpAddr) -> Option<(Kind, Option<&'static str>)> {
    if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() || is_link_local(ip) || excluded_interface(interface) {
        return None;
    }
    if is_tailscale(ip) || interface.starts_with("tailscale") {
        return Some((Kind::Vpn, Some("tailscale")));
    }
    if vpn_interface(interface) || is_cgnat(ip) {
        return Some((Kind::Vpn, Some("other")));
    }
    match ip {
        IpAddr::V4(v4) if v4.is_private() => Some((Kind::Lan, None)),
        IpAddr::V6(v6) if is_ula(&v6) => Some((Kind::Lan, None)),
        IpAddr::V6(v6) if is_global_v6(&v6) => Some((Kind::Public6, None)),
        // A public IPv4 on an interface (a server): reachable directly, offered like a global IPv6.
        IpAddr::V4(_) => Some((Kind::Public6, None)),
        _ => None,
    }
}

/// The route a remote address belongs to, when nothing better is known (an inbound direct dial).
pub fn route_of(ip: IpAddr) -> Route {
    let ip = match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(v6)),
        v4 => v4,
    };
    if is_tailscale(ip) || is_cgnat(ip) {
        return Route::Vpn;
    }
    match ip {
        IpAddr::V4(v4) if v4.is_private() || v4.is_loopback() || v4.is_link_local() => Route::Lan,
        IpAddr::V6(v6) if is_ula(&v6) || is_link_local(IpAddr::V6(v6)) || v6.is_loopback() => Route::Lan,
        _ => Route::Direct,
    }
}

/// Every address this device can offer, at most 16, LAN first.
pub fn local_addresses() -> Vec<LocalAddress> {
    let mut out: Vec<LocalAddress> = if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|iface| {
            let ip = iface.ip();
            classify(&iface.name, ip).map(|(kind, vpn)| LocalAddress { a: ip.to_string(), kind, vpn, ip })
        })
        .collect();
    out.sort_by_key(|a| (rank(a.kind), a.ip.is_ipv4()));
    out.dedup_by(|a, b| a.ip == b.ip);
    out.truncate(16);
    out
}

fn rank(kind: Kind) -> u8 {
    match kind {
        Kind::Lan => 0,
        Kind::Vpn => 1,
        Kind::Public6 => 2,
    }
}

/// An address peers send in `connect.addresses`; unusable values are refused.
pub fn parse_learned(a: &str, port: u16) -> Option<SocketAddr> {
    let ip: IpAddr = a.parse().ok()?;
    if ip.is_loopback() || ip.is_unspecified() || ip.is_multicast() || port == 0 {
        return None;
    }
    if let IpAddr::V4(v4) = ip {
        if v4 == Ipv4Addr::BROADCAST {
            return None;
        }
    }
    Some(SocketAddr::new(ip, port))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels() {
        let ip = |s: &str| s.parse::<IpAddr>().unwrap();
        assert_eq!(classify("wlan0", ip("192.168.1.5")), Some((Kind::Lan, None)));
        assert_eq!(classify("tailscale0", ip("100.101.1.2")), Some((Kind::Vpn, Some("tailscale"))));
        assert_eq!(classify("utun4", ip("100.101.1.2")), Some((Kind::Vpn, Some("other"))));
        assert_eq!(classify("en0", ip("fd7a:115c:a1e0::1")), Some((Kind::Vpn, Some("tailscale"))));
        assert_eq!(classify("en0", ip("2409:4040::1")), Some((Kind::Public6, None)));
        assert_eq!(classify("en0", ip("fe80::1")), None);
        assert_eq!(classify("docker0", ip("172.17.0.1")), None);
        assert_eq!(classify("lo", ip("127.0.0.1")), None);
        assert_eq!(route_of(ip("10.0.0.2")), Route::Lan);
        assert_eq!(route_of(ip("::ffff:192.168.1.2")), Route::Lan);
        assert_eq!(route_of(ip("100.121.85.33")), Route::Vpn);
        assert_eq!(route_of(ip("2409:4040::1")), Route::Direct);
        assert!(Route::Lan < Route::Relay);
        assert_eq!(canonical("[::ffff:10.0.0.1]:5".parse().unwrap()), "10.0.0.1:5".parse().unwrap());
        assert!(parse_learned("127.0.0.1", 42458).is_none());
        assert!(parse_learned("192.168.1.2", 42458).is_some());
    }
}
