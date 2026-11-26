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

/// `ip` is on one of this device's own subnets (same IPv4 network, or the same IPv6 /64): a LAN address of a
/// peer that is probably on this network right now, where the app's LAN connection should get a head start.
pub fn on_link(ip: IpAddr) -> bool {
    if_addrs::get_if_addrs().unwrap_or_default().into_iter().filter(|i| !i.is_loopback()).any(|iface| match (&iface.addr, ip) {
        (if_addrs::IfAddr::V4(a), IpAddr::V4(other)) => {
            let mask = u32::from(a.netmask);
            mask != 0 && u32::from(a.ip) & mask == u32::from(other) & mask
        }
        (if_addrs::IfAddr::V6(a), IpAddr::V6(other)) => {
            let mine = a.ip.segments();
            (mine[0] & 0xffc0) != 0xfe80 && mine[..4] == other.segments()[..4]
        }
        _ => false,
    })
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

/// The address group per-source limits count by: an IPv4 address, or the /64 an IPv6 address is in (one host
/// usually holds a whole /64, so counting single IPv6 addresses would not limit it).
pub fn source_group(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => IpAddr::V6(Ipv6Addr::from(u128::from(v6) & !((1u128 << 64) - 1))),
        },
        v4 => v4,
    }
}

/// Incoming QUIC tunnels the app has not authenticated yet, and handshakes under way, allowed at once.
pub const MAX_PENDING_DIRECT: usize = 16;
pub const MAX_PENDING_PER_SOURCE: usize = 3;
pub const MAX_PENDING_ICE: usize = 32;
pub const MAX_HANDSHAKES: usize = 32;

/// Whether an incoming QUIC connection may start its handshake. `pending` holds the remote address of every tunnel
/// not yet authenticated (`None` for ICE tunnels, which come from virtual addresses after sealed signalling and a
/// pin check, and for this node's own dials); `handshaking` counts direct handshakes under way. Anyone who can reach
/// the UDP port can fill the direct allowance, so ICE tunnels have their own and are never refused because of it.
pub fn admit_incoming(source: IpAddr, ice: bool, pending: &[Option<IpAddr>], handshaking: usize) -> bool {
    if ice {
        return pending.iter().filter(|p| p.is_none()).count() < MAX_PENDING_ICE;
    }
    let group = source_group(source);
    let direct = pending.iter().flatten().count();
    let here = pending.iter().flatten().filter(|ip| source_group(**ip) == group).count();
    handshaking < MAX_HANDSHAKES && direct < MAX_PENDING_DIRECT && here < MAX_PENDING_PER_SOURCE
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn incoming_tunnels_cannot_crowd_out_ice() {
        // Security review 1.0, C5: 16 direct handshakes from a host on the network refused every ICE tunnel too.
        let ip = |s: &str| s.parse::<IpAddr>().unwrap();
        let lan: Vec<Option<IpAddr>> = (1..=16).map(|i| Some(ip(&format!("192.168.1.{i}")))).collect();
        assert!(!admit_incoming(ip("192.168.1.99"), false, &lan, 0));
        assert!(admit_incoming(ip("fd00::1"), true, &lan, 0), "an ICE tunnel still gets in");
        let ice: Vec<Option<IpAddr>> = vec![None; 32];
        assert!(!admit_incoming(ip("fd00::1"), true, &ice, 0));
        assert!(admit_incoming(ip("192.168.1.2"), false, &ice, 0), "and the other way round");
        // Three per source, counting a whole IPv6 /64 as one source.
        let one_host: Vec<Option<IpAddr>> = ["2001:db8:1:2::1", "2001:db8:1:2::2", "2001:db8:1:2:ffff::3"].iter().map(|a| Some(ip(a))).collect();
        assert!(!admit_incoming(ip("2001:db8:1:2::99"), false, &one_host, 0));
        assert!(admit_incoming(ip("2001:db8:1:3::1"), false, &one_host, 0));
        // Handshakes under way count too.
        assert!(!admit_incoming(ip("192.168.1.2"), false, &[], MAX_HANDSHAKES));
        assert_eq!(source_group(ip("::ffff:10.0.0.1")), ip("10.0.0.1"));
    }

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
