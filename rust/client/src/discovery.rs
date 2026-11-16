//! DNS-SD on the local network: publishes this device as `_bridgey._tcp` and browses for the others, with
//! the apps' TXT keys (`id`, `name`, `version`, `platform`; docs/protocol.md "Discovery"). Everything found
//! is an unauthenticated hint until a session authenticates.

use crate::client::Inner;
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::net::{IpAddr, SocketAddr};
use std::sync::Weak;
use std::time::Duration;

const SERVICE: &str = "_bridgey._tcp.local.";

pub struct Discovery {
    daemon: ServiceDaemon,
    fullname: Option<String>,
    device_id: String,
    platform: String,
    port: u16,
}

/// A TXT value as the Mac reads it: present, not empty, at most `limit` bytes, UTF-8.
fn txt(value: Option<Option<&[u8]>>, limit: usize) -> Option<String> {
    let bytes = value.flatten()?;
    if bytes.is_empty() || bytes.len() > limit {
        return None;
    }
    std::str::from_utf8(bytes).ok().map(str::to_string)
}

fn platform_ok(p: &str) -> bool {
    let b = p.as_bytes();
    !b.is_empty() && b.len() <= 16 && b[0].is_ascii_lowercase() && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

fn instance(fullname: &str) -> String {
    fullname.strip_suffix(SERVICE).map(|s| s.trim_end_matches('.')).unwrap_or(fullname).to_string()
}

impl Discovery {
    pub fn start(client: Weak<Inner>, device_id: &str, name: &str, platform: &str, port: u16, publish: bool) -> Result<Discovery, String> {
        let daemon = ServiceDaemon::new().map_err(|e| e.to_string())?;
        let mut d = Discovery { daemon, fullname: None, device_id: device_id.to_string(), platform: platform.to_string(), port };
        if publish {
            d.publish(name)?;
        }
        let events = d.daemon.browse(SERVICE).map_err(|e| e.to_string())?;
        let own = device_id.to_string();
        std::thread::Builder::new()
            .name("bridgey-discovery".into())
            .spawn(move || {
                while let Ok(event) = events.recv() {
                    let Some(client) = client.upgrade() else { return };
                    match event {
                        ServiceEvent::ServiceResolved(info) => {
                            let id = txt(info.get_property_val("id"), 36).filter(|i| crate::crypto::is_uuid(i)).map(|i| i.to_ascii_lowercase());
                            if id.as_deref() == Some(own.as_str()) {
                                continue;
                            }
                            let name = txt(info.get_property_val("name"), 64).unwrap_or_else(|| instance(info.get_fullname()).chars().take(64).collect());
                            let platform = txt(info.get_property_val("platform"), 16).filter(|p| platform_ok(p));
                            // IPv4 first, then routable IPv6; link-local IPv6 needs a scope this client does not track.
                            let mut ips: Vec<IpAddr> = info.get_addresses().iter().map(|a| a.to_ip_addr()).filter(|ip| !matches!(ip, IpAddr::V6(v6) if (v6.segments()[0] & 0xffc0) == 0xfe80)).collect();
                            ips.sort_by_key(|ip| (!ip.is_ipv4(), *ip));
                            let addrs: Vec<SocketAddr> = ips.into_iter().map(|ip| SocketAddr::new(ip, info.get_port())).collect();
                            client.found(info.get_fullname().to_string(), id, name, platform, addrs);
                        }
                        ServiceEvent::ServiceRemoved(_, fullname) => client.lost(&fullname),
                        _ => {}
                    }
                }
            })
            .map_err(|e| e.to_string())?;
        Ok(d)
    }

    fn publish(&mut self, name: &str) -> Result<(), String> {
        let short: String = name.chars().take(64).collect();
        let mut name_bytes = short.clone();
        while name_bytes.len() > 64 {
            name_bytes.pop();
        }
        // The instance name must be unique on the network; the TXT name is what the apps show.
        let instance = format!("{} {}", name_bytes.chars().filter(|c| *c != '.').take(40).collect::<String>().trim(), &self.device_id[..8]);
        let host = format!("bridgey-{}.local.", &self.device_id[..8]);
        let props = [("id", self.device_id.as_str()), ("name", name_bytes.as_str()), ("version", "1"), ("platform", self.platform.as_str())];
        let info = ServiceInfo::new(SERVICE, instance.trim(), &host, "", self.port, &props[..]).map_err(|e| e.to_string())?.enable_addr_auto();
        let fullname = info.get_fullname().to_string();
        self.daemon.register(info).map_err(|e| e.to_string())?;
        self.fullname = Some(fullname);
        Ok(())
    }

    pub fn rename(&mut self, name: &str) {
        if let Some(old) = self.fullname.take() {
            if let Ok(rx) = self.daemon.unregister(&old) {
                let _ = rx.recv_timeout(Duration::from_secs(1));
            }
            let _ = self.publish(name);
        }
    }

    pub fn stop(self) {
        if let Some(old) = &self.fullname {
            if let Ok(rx) = self.daemon.unregister(old) {
                let _ = rx.recv_timeout(Duration::from_millis(500));
            }
        }
        if let Ok(rx) = self.daemon.shutdown() {
            let _ = rx.recv_timeout(Duration::from_millis(500));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn txt_rules_match_the_mac() {
        assert_eq!(txt(Some(Some(b"abc")), 3).as_deref(), Some("abc"));
        assert_eq!(txt(Some(Some(b"abcd")), 3), None);
        assert_eq!(txt(Some(Some(b"")), 3), None);
        assert_eq!(txt(Some(None), 3), None);
        assert!(platform_ok("windows") && platform_ok("macos") && !platform_ok("Windows") && !platform_ok("9x"));
        assert_eq!(instance("Rahul's PC 1234abcd._bridgey._tcp.local."), "Rahul's PC 1234abcd");
    }
}
