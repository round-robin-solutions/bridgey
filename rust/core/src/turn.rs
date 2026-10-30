//! A TURN client over UDP (RFC 8656), sharing the node's socket: Allocate, Refresh and ChannelBind
//! with long-term credentials from a relay grant (TURN REST usernames, spec 9.5).

use crate::addrs::canonical;
use crate::mux::{Mux, Path};
use crate::stun::{self, Message};
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub struct Allocation {
    mux: Arc<Mux>,
    pub server: SocketAddr,
    pub relay_id: String,
    username: String,
    password: String,
    auth: Mutex<Auth>,
    pub relayed: SocketAddr,
    pub mapped: SocketAddr,
    pub lifetime: Duration,
}

#[derive(Clone, Default)]
struct Auth {
    realm: String,
    nonce: String,
    key: Vec<u8>,
}

/// The relay already holds an allocation for this socket (RFC 8656 437): a process that was killed left it.
pub const MISMATCH: &str = "allocation mismatch (437)";

/// A relay's realm and nonce from an earlier exchange: the next request can carry credentials at once
/// instead of being refused first (one round trip less). A stale nonce costs that round trip back (438).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Realm {
    pub realm: String,
    pub nonce: String,
}

/// `turn:host:port?transport=udp` to (host, port); other schemes and transports are skipped in phase 1.
pub fn parse_udp_url(url: &str) -> Option<(String, u16)> {
    let rest = url.strip_prefix("turn:")?;
    let (hostport, query) = rest.split_once('?').unwrap_or((rest, ""));
    if !query.is_empty() && query != "transport=udp" {
        return None;
    }
    let (host, port) = match hostport.rsplit_once(':') {
        Some((h, p)) if !h.ends_with(']') || h.starts_with('[') => (h.trim_matches(|c| c == '[' || c == ']'), p.parse().ok()?),
        _ => (hostport, 3478),
    };
    Some((host.to_string(), port))
}

/// Asks the relay for its realm and nonce (an unauthenticated request it refuses with 401).
async fn challenge(mux: &Mux, server: SocketAddr) -> Result<Realm, String> {
    let mut first = Message::request(stun::ALLOCATE);
    first.add(stun::ATTR_REQUESTED_TRANSPORT, vec![17, 0, 0, 0]);
    let (reply, _) = mux.transact(Path::direct(server), &first.encode(None, true), first.txid, 5, true).await.ok_or("relay did not answer")?;
    match reply.error_code() {
        Some(401) => Ok(Realm { realm: reply.string(stun::ATTR_REALM).ok_or("no realm")?, nonce: reply.string(stun::ATTR_NONCE).ok_or("no nonce")? }),
        Some(437) => Err(MISMATCH.into()),
        code => Err(format!("unexpected allocate reply {code:?}")),
    }
}

/// Ends an allocation this process does not hold (one a killed process left on the relay for this socket),
/// with that allocation's own credentials. `Ok(true)`: ended; `Ok(false)`: the relay had none for this socket.
pub async fn release_left_behind(mux: Arc<Mux>, server: SocketAddr, username: &str, password: &str, realm: Option<Realm>) -> Result<bool, String> {
    let server = canonical(server);
    let realm = match realm {
        Some(r) => r,
        None => challenge_any(&mux, server).await?,
    };
    let key = stun::long_term_key(username, &realm.realm, password);
    let probe = Allocation {
        mux: mux.clone(),
        server,
        relay_id: String::new(),
        username: username.to_string(),
        password: password.to_string(),
        auth: Mutex::new(Auth { realm: realm.realm, nonce: realm.nonce, key }),
        relayed: server,
        mapped: server,
        lifetime: Duration::ZERO,
    };
    match probe.refresh(0).await {
        Ok(()) => Ok(true),
        Err(e) if e == MISMATCH => Ok(false),
        Err(e) => Err(e),
    }
}

/// The realm and nonce with a Refresh (refused with 401 either way, and it works while an allocation exists).
async fn challenge_any(mux: &Mux, server: SocketAddr) -> Result<Realm, String> {
    let mut first = Message::request(stun::REFRESH);
    first.add(stun::ATTR_LIFETIME, 0u32.to_be_bytes().to_vec());
    let (reply, _) = mux.transact(Path::direct(server), &first.encode(None, true), first.txid, 5, true).await.ok_or("relay did not answer")?;
    match reply.error_code() {
        Some(401) | Some(438) => Ok(Realm { realm: reply.string(stun::ATTR_REALM).ok_or("no realm")?, nonce: reply.string(stun::ATTR_NONCE).ok_or("no nonce")? }),
        Some(437) => Err(MISMATCH.into()),
        code => Err(format!("unexpected refresh reply {code:?}")),
    }
}

impl Allocation {
    pub async fn allocate(mux: Arc<Mux>, server: SocketAddr, relay_id: &str, username: &str, password: &str) -> Result<Arc<Allocation>, String> {
        Self::allocate_with(mux, server, relay_id, username, password, None).await
    }

    /// Allocates with the relay's realm and nonce from an earlier exchange when there is one (one round trip).
    pub async fn allocate_with(mux: Arc<Mux>, server: SocketAddr, relay_id: &str, username: &str, password: &str, cached: Option<Realm>) -> Result<Arc<Allocation>, String> {
        let server = canonical(server);
        let Realm { realm, nonce } = match cached {
            Some(r) => r,
            None => challenge(&mux, server).await?,
        };
        let key = stun::long_term_key(username, &realm, password);
        let partial = Allocation {
            mux: mux.clone(),
            server,
            relay_id: relay_id.to_string(),
            username: username.to_string(),
            password: password.to_string(),
            auth: Mutex::new(Auth { realm, nonce, key }),
            relayed: server,
            mapped: server,
            lifetime: Duration::from_secs(600),
        };
        let reply = partial
            .authed(|| {
                let mut m = Message::request(stun::ALLOCATE);
                m.add(stun::ATTR_REQUESTED_TRANSPORT, vec![17, 0, 0, 0]);
                m.add(stun::ATTR_LIFETIME, 600u32.to_be_bytes().to_vec());
                m
            })
            .await?;
        let relayed = reply.xor_address(stun::ATTR_XOR_RELAYED_ADDRESS).ok_or("no relayed address")?;
        let mapped = reply.xor_address(stun::ATTR_XOR_MAPPED_ADDRESS).unwrap_or(server);
        let lifetime = Duration::from_secs(u64::from(reply.u32(stun::ATTR_LIFETIME).unwrap_or(600)));
        mux.add_turn(server);
        let mut seed = [0u8; 2];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut seed).expect("random");
        mux.seed_channels(server, u16::from_be_bytes(seed));
        let allocation = Arc::new(Allocation { relayed: canonical(relayed), mapped: canonical(mapped), lifetime, ..partial });
        let keeper = Arc::downgrade(&allocation);
        tokio::spawn(async move {
            // Refresh the allocation before it lapses, and re-bind channels (10 minutes) and permissions (5) every 4.
            loop {
                tokio::time::sleep(Duration::from_secs(240)).await;
                let Some(allocation) = keeper.upgrade() else { break };
                if allocation.refresh(600).await.is_err() {
                    break;
                }
                let permitted = allocation.mux.permitted(allocation.server);
                let _ = allocation.permit(&permitted).await;
                for peer in allocation.mux.channel_peers(allocation.server) {
                    let _ = allocation.bind(peer).await;
                }
            }
        });
        Ok(allocation)
    }

    /// The relay's realm and nonce as last seen, for the next allocation on this relay.
    pub fn realm(&self) -> Realm {
        let auth = self.auth.lock().unwrap();
        Realm { realm: auth.realm.clone(), nonce: auth.nonce.clone() }
    }

    pub fn username(&self) -> &str {
        &self.username
    }

    /// Installs permissions for `ips` in one request (RFC 8656 CreatePermission), so datagrams from them reach
    /// us and ours reach them as Send indications before any channel is bound. At most 16 per request.
    pub async fn permit(&self, ips: &[IpAddr]) -> Result<(), String> {
        let family: Vec<IpAddr> = ips.iter().copied().filter(|ip| ip.is_ipv4() == self.relayed.is_ipv4()).collect();
        for chunk in family.chunks(16) {
            self.authed(|| {
                let mut m = Message::request(stun::CREATE_PERMISSION);
                for ip in chunk {
                    let xor = stun::encode_xor_address(SocketAddr::new(*ip, 0), &m.txid);
                    m.add(stun::ATTR_XOR_PEER_ADDRESS, xor);
                }
                m
            })
            .await?;
            self.mux.permit(self.server, chunk);
        }
        Ok(())
    }

    /// Sends an authenticated request, retrying once on a stale nonce (438) or a new realm (401).
    async fn authed(&self, build: impl Fn() -> Message) -> Result<Message, String> {
        for _ in 0..2 {
            let auth = self.auth.lock().unwrap().clone();
            let mut m = build();
            m.add(stun::ATTR_USERNAME, self.username.as_bytes().to_vec());
            m.add(stun::ATTR_REALM, auth.realm.as_bytes().to_vec());
            m.add(stun::ATTR_NONCE, auth.nonce.as_bytes().to_vec());
            let bytes = m.encode(Some(&auth.key), true);
            let (reply, _) = self.mux.transact(Path::direct(self.server), &bytes, m.txid, 5, true).await.ok_or("relay did not answer")?;
            match (reply.class, reply.error_code()) {
                (stun::SUCCESS, _) => return Ok(reply),
                (_, Some(437)) => return Err(MISMATCH.into()),
                (_, Some(438)) | (_, Some(401)) => {
                    let mut auth = self.auth.lock().unwrap();
                    if let Some(nonce) = reply.string(stun::ATTR_NONCE) {
                        auth.nonce = nonce;
                    }
                    if let Some(realm) = reply.string(stun::ATTR_REALM) {
                        auth.realm = realm;
                        auth.key = stun::long_term_key(&self.username, &auth.realm, &self.password);
                    }
                }
                (_, code) => return Err(format!("relay refused ({code:?})")),
            }
        }
        Err("relay refused the credentials".into())
    }

    pub async fn refresh(&self, lifetime: u32) -> Result<(), String> {
        self.authed(|| {
            let mut m = Message::request(stun::REFRESH);
            m.add(stun::ATTR_LIFETIME, lifetime.to_be_bytes().to_vec());
            m
        })
        .await
        .map(|_| ())
    }

    /// Binds a channel to `peer` (which also installs the permission). Idempotent.
    pub async fn bind(&self, peer: SocketAddr) -> Result<(), String> {
        let peer = canonical(peer);
        let number = self.mux.channel_for(self.server, peer);
        let txid_peer = peer;
        self.authed(|| {
            let mut m = Message::request(stun::CHANNEL_BIND);
            let mut channel = number.to_be_bytes().to_vec();
            channel.extend_from_slice(&[0, 0]);
            m.add(stun::ATTR_CHANNEL_NUMBER, channel);
            let xor = stun::encode_xor_address(txid_peer, &m.txid);
            m.add(stun::ATTR_XOR_PEER_ADDRESS, xor);
            m
        })
        .await?;
        self.mux.bound(self.server, peer, number);
        Ok(())
    }

    /// Ends the allocation (Refresh with lifetime 0) and stops routing through it.
    pub async fn release(&self) {
        let _ = self.refresh(0).await;
        self.mux.remove_turn(self.server);
    }
}

/// A STUN Binding request to a server: the address it sees us as (server-reflexive), and the round trip.
pub async fn reflexive(mux: &Mux, server: SocketAddr) -> Option<(SocketAddr, Duration)> {
    let m = Message::request(stun::BINDING);
    let started = std::time::Instant::now();
    let (reply, _) = mux.transact(Path::direct(server), &m.encode(None, true), m.txid, 3, true).await?;
    let mapped = reply.xor_address(stun::ATTR_XOR_MAPPED_ADDRESS)?;
    Some((canonical(mapped), started.elapsed()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls() {
        assert_eq!(parse_udp_url("turn:relay-in.roundrobin.in:3478?transport=udp"), Some(("relay-in.roundrobin.in".into(), 3478)));
        assert_eq!(parse_udp_url("turn:192.0.2.1"), Some(("192.0.2.1".into(), 3478)));
        assert_eq!(parse_udp_url("turn:[2001:db8::1]:3478"), Some(("2001:db8::1".into(), 3478)));
        assert_eq!(parse_udp_url("turn:a:3478?transport=tcp"), None);
        assert_eq!(parse_udp_url("turns:a:5349?transport=tcp"), None);
    }
}
