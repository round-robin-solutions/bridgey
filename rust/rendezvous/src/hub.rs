//! Presence, sealed signal forwarding and relay grants, independent of the socket layer.
//!
//! Kept in memory only (spec 6.7): which connection holds which rendezvous ID, pending grants and
//! rate-limit counters. Nothing here is logged with an address, an ID or a body.

use crate::config::{Config, Relay};
use bridgey_connect_proto::rdv::{self, Msg, RelayGrant, RelayInfo, WarmRequest};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

pub type ConnId = u64;

pub struct Conn {
    pub node_id: String,
    pub tx: mpsc::Sender<String>,
    pub ids: HashSet<String>,
    signals: Window,
}

/// A fixed window counter.
struct Window {
    start: Instant,
    count: u32,
    length: Duration,
}

impl Window {
    fn new(length: Duration) -> Self {
        Window { start: Instant::now(), count: 0, length }
    }

    /// Counts one event; false when the window already holds `limit`.
    fn hit(&mut self, limit: u32, now: Instant) -> bool {
        if now.duration_since(self.start) >= self.length {
            self.start = now;
            self.count = 0;
        }
        if self.count >= limit {
            return false;
        }
        self.count += 1;
        true
    }

    fn retry_after(&self, now: Instant) -> u64 {
        self.length.saturating_sub(now.duration_since(self.start)).as_millis() as u64
    }
}

struct PendingGrant {
    relay: String,
    expires: Instant,
}

pub struct Hub {
    config: Config,
    secrets: HashMap<String, Vec<u8>>,
    conns: HashMap<ConnId, Conn>,
    by_rdv: HashMap<String, HashSet<ConnId>>,
    sockets_per_node: HashMap<String, usize>,
    grants_per_node: HashMap<String, Window>,
    pending: HashMap<(String, String), PendingGrant>,
    next_id: ConnId,
    pub counters: Counters,
}

#[derive(Default, Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Counters {
    pub signals_forwarded: u64,
    pub signals_undeliverable: u64,
    pub grants: u64,
    pub denied: u64,
    pub rejected_auth: u64,
    pub warm_grants: u64,
    pub reclaimed: u64,
    /// Sign-ins that took the single flight (hello in the upgrade request).
    pub fast_hellos: u64,
}

/// What a connection must do after a message.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    Continue,
    Close,
}

impl Hub {
    pub fn new(config: Config, secrets: HashMap<String, Vec<u8>>) -> Self {
        Hub {
            config,
            secrets,
            conns: HashMap::new(),
            by_rdv: HashMap::new(),
            sockets_per_node: HashMap::new(),
            grants_per_node: HashMap::new(),
            pending: HashMap::new(),
            next_id: 1,
            counters: Counters::default(),
        }
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn has_secret(&self, relay: &str) -> bool {
        self.secrets.contains_key(relay)
    }

    pub fn connections(&self) -> usize {
        self.conns.len()
    }

    pub fn nodes(&self) -> usize {
        self.sockets_per_node.len()
    }

    /// Admits an authenticated node, or `None` when it already holds its socket allowance.
    pub fn join(&mut self, node_id: String, tx: mpsc::Sender<String>) -> Option<ConnId> {
        let sockets = self.sockets_per_node.entry(node_id.clone()).or_insert(0);
        if *sockets >= self.config.limits.sockets_per_node || self.conns.len() >= self.config.limits.max_connections {
            if *sockets == 0 {
                self.sockets_per_node.remove(&node_id);
            }
            return None;
        }
        *sockets += 1;
        let id = self.next_id;
        self.next_id += 1;
        self.conns.insert(id, Conn { node_id, tx, ids: HashSet::new(), signals: Window::new(Duration::from_secs(60)) });
        Some(id)
    }

    pub fn leave(&mut self, id: ConnId) {
        let Some((node, ids)) = self.conns.get(&id).map(|c| (c.node_id.clone(), c.ids.clone())) else { return };
        for rdv in ids.iter() {
            self.unlink(id, &node, rdv);
        }
        let Some(conn) = self.conns.remove(&id) else { return };
        if let Some(count) = self.sockets_per_node.get_mut(&conn.node_id) {
            *count -= 1;
            if *count == 0 {
                self.sockets_per_node.remove(&conn.node_id);
            }
        }
    }

    pub fn handle(&mut self, id: ConnId, msg: Msg) -> Outcome {
        let now = Instant::now();
        self.pending.retain(|_, grant| grant.expires > now);
        match msg {
            Msg::Register { ids } => self.register(id, ids),
            Msg::Signal { rdv, side, sid, body } => self.signal(id, rdv, side, sid, body, now),
            Msg::RelayRequest { rdv, sid, side, rtts, exclude, .. } => self.relay(id, rdv, sid, side, rtts, exclude.unwrap_or_default(), false, now),
            Msg::RelayClaim { rdv, sid, side } => self.relay(id, rdv, sid, side, None, Vec::new(), true, now),
            Msg::RelayWarm { request } => self.warm(id, request, now),
            Msg::RelayRelease { .. } => Outcome::Continue,
            _ => {
                self.send(id, Msg::Error { code: "bad_request".into(), retry_after_ms: None });
                Outcome::Continue
            }
        }
    }

    fn send(&self, id: ConnId, msg: Msg) {
        if let Some(conn) = self.conns.get(&id) {
            // A connection that cannot keep up loses messages; its socket task closes on a full queue.
            let _ = conn.tx.try_send(msg.to_text());
        }
    }

    /// Other nodes (not this connection's node) registered for `rdv`.
    fn others(&self, id: ConnId, rdv: &str) -> Vec<ConnId> {
        let Some(node) = self.conns.get(&id).map(|c| c.node_id.clone()) else { return Vec::new() };
        self.by_rdv
            .get(rdv)
            .map(|set| set.iter().copied().filter(|other| self.conns.get(other).map(|c| c.node_id != node).unwrap_or(false)).collect())
            .unwrap_or_default()
    }

    fn node_holds(&self, node: &str, rdv: &str, except: Option<ConnId>) -> bool {
        self.by_rdv
            .get(rdv)
            .map(|set| set.iter().any(|c| Some(*c) != except && self.conns.get(c).map(|x| x.node_id == node).unwrap_or(false)))
            .unwrap_or(false)
    }

    fn register(&mut self, id: ConnId, ids: Vec<String>) -> Outcome {
        if ids.len() > self.config.limits.max_ids {
            self.send(id, Msg::Error { code: "too_many_ids".into(), retry_after_ms: None });
            return Outcome::Continue;
        }
        if !ids.iter().all(|r| rdv::valid_rdv(r)) {
            self.send(id, Msg::Error { code: "bad_request".into(), retry_after_ms: None });
            return Outcome::Continue;
        }
        let Some(conn) = self.conns.get(&id) else { return Outcome::Close };
        let node = conn.node_id.clone();
        let new: HashSet<String> = ids.into_iter().collect();
        let old = conn.ids.clone();
        for gone in old.difference(&new) {
            self.unlink(id, &node, gone);
        }
        for added in new.difference(&old) {
            let first = !self.node_holds(&node, added, None);
            self.by_rdv.entry(added.clone()).or_default().insert(id);
            if first {
                for other in self.others(id, added) {
                    self.send(other, Msg::Presence { rdv: added.clone(), online: true });
                }
            }
        }
        if let Some(conn) = self.conns.get_mut(&id) {
            conn.ids = new.clone();
        }
        let mut online: Vec<String> = new.into_iter().filter(|r| !self.others(id, r).is_empty()).collect();
        online.sort();
        self.send(id, Msg::Registered { online });
        Outcome::Continue
    }

    fn unlink(&mut self, id: ConnId, node: &str, rdv: &str) {
        let others = self.others(id, rdv);
        if let Some(set) = self.by_rdv.get_mut(rdv) {
            set.remove(&id);
            if set.is_empty() {
                self.by_rdv.remove(rdv);
            }
        }
        if !self.node_holds(node, rdv, Some(id)) {
            for other in others {
                self.send(other, Msg::Presence { rdv: rdv.to_string(), online: false });
            }
        }
    }

    fn holds(&self, id: ConnId, rdv: &str) -> bool {
        self.conns.get(&id).map(|c| c.ids.contains(rdv)).unwrap_or(false)
    }

    fn signal(&mut self, id: ConnId, rdv: String, side: u8, sid: String, body: String, now: Instant) -> Outcome {
        if !self.holds(id, &rdv) || side > 1 || !rdv::valid_sid(&sid) || body.len() > rdv::MAX_SIGNAL_BODY {
            self.send(id, Msg::Error { code: "bad_request".into(), retry_after_ms: None });
            return Outcome::Continue;
        }
        let limit = self.config.limits.signals_per_minute;
        let Some(conn) = self.conns.get_mut(&id) else { return Outcome::Close };
        if !conn.signals.hit(limit, now) {
            let retry = conn.signals.retry_after(now);
            self.send(id, Msg::Error { code: "rate_limited".into(), retry_after_ms: Some(retry) });
            return Outcome::Continue;
        }
        let targets = self.others(id, &rdv);
        if targets.is_empty() {
            self.counters.signals_undeliverable += 1;
            self.send(id, Msg::Undeliverable { rdv, sid });
            return Outcome::Continue;
        }
        self.counters.signals_forwarded += 1;
        for target in targets {
            self.send(target, Msg::Signal { rdv: rdv.clone(), side, sid: sid.clone(), body: body.clone() });
        }
        Outcome::Continue
    }

    #[allow(clippy::too_many_arguments)]
    fn relay(&mut self, id: ConnId, rdv: String, sid: String, side: u8, rtts: Option<BTreeMap<String, u32>>, exclude: Vec<String>, claim: bool, now: Instant) -> Outcome {
        if !self.holds(id, &rdv) || side > 1 || !rdv::valid_sid(&sid) {
            self.send(id, Msg::Error { code: "bad_request".into(), retry_after_ms: None });
            return Outcome::Continue;
        }
        let node = self.conns[&id].node_id.clone();
        let limit = self.config.limits.grants_per_hour;
        let window = self.grants_per_node.entry(node).or_insert_with(|| Window::new(Duration::from_secs(3_600)));
        if !window.hit(limit, now) {
            let retry = window.retry_after(now);
            self.counters.denied += 1;
            self.send(id, Msg::RelayDenied { sid, code: "rate_limited".into(), retry_after_ms: retry });
            return Outcome::Continue;
        }
        let key = (rdv.clone(), sid.clone());
        // The service picks one relay per session for both sides (spec 9.3): a claim reuses it.
        let chosen = match (claim, self.pending.get(&key)) {
            (true, Some(grant)) if !exclude.contains(&grant.relay) => Some(grant.relay.clone()),
            _ => self.pick(rtts.as_ref(), &exclude).map(|r| r.id.clone()),
        };
        let Some(relay_id) = chosen else {
            self.counters.denied += 1;
            self.send(id, Msg::RelayDenied { sid, code: "pool_exhausted".into(), retry_after_ms: 60_000 });
            return Outcome::Continue;
        };
        let lifetime = self.config.limits.grant_lifetime_s;
        self.pending.insert(key, PendingGrant { relay: relay_id.clone(), expires: now + Duration::from_secs(lifetime) });
        let relay = self.config.relays.iter().find(|r| r.id == relay_id).expect("chosen relay").clone();
        let expiry = unix_ms() / 1_000 + lifetime;
        let (username, credential) = rdv::turn_rest_credentials(&self.secrets[&relay_id], expiry, &sid, side);
        self.counters.grants += 1;
        self.send(
            id,
            Msg::RelayGrantMsg {
                sid,
                relay: RelayGrant {
                    id: relay.id,
                    kind: relay.kind,
                    urls: relay.urls,
                    username,
                    credential,
                    spki: relay.spki,
                    expires_at: expiry * 1_000,
                    max_kbps: relay.max_kbps,
                },
            },
        );
        Outcome::Continue
    }

    /// The relays a node may use, for `welcome`: it probes them and keeps permissions for all of them.
    pub fn relay_infos(&self) -> Vec<RelayInfo> {
        self.config.relays.iter().filter(|r| r.enabled && self.secrets.contains_key(&r.id)).filter_map(|r| Some(RelayInfo { id: r.id.clone(), stun: r.stun()? })).collect()
    }

    /// A node's own relay credentials, kept warm across sessions (docs/connect-anywhere-latency.md): the username
    /// is tied to the node, so after a crash the node (and only it, signed in with its key) can get the
    /// credential of its earlier allocation back and end it, instead of waiting out the relay's 437.
    pub fn warm(&mut self, id: ConnId, request: WarmRequest, now: Instant) -> Outcome {
        let Some(node) = self.conns.get(&id).map(|c| c.node_id.clone()) else { return Outcome::Close };
        let limit = self.config.limits.grants_per_hour;
        let window = self.grants_per_node.entry(node.clone()).or_insert_with(|| Window::new(Duration::from_secs(3_600)));
        if !window.hit(limit, now) {
            let retry = window.retry_after(now);
            self.counters.denied += 1;
            self.send(id, Msg::RelayDenied { sid: rdv::WARM_SID.into(), code: "rate_limited".into(), retry_after_ms: retry });
            return Outcome::Continue;
        }
        let unix_s = unix_ms() / 1_000;
        if let Some(reclaim) = &request.reclaim {
            let found = self.config.relays.iter().find(|r| r.id == reclaim.relay && self.secrets.contains_key(&r.id)).cloned();
            if let Some(relay) = found {
                let secret = &self.secrets[&relay.id];
                // Only a username made for this node, and not expired, gets its credential back.
                if let Some(expiry) = rdv::warm_username_expiry(secret, &reclaim.username, &node).filter(|e| *e > unix_s) {
                    let credential = rdv::turn_rest_credential(secret, &reclaim.username);
                    self.counters.reclaimed += 1;
                    self.send(id, Msg::RelayGrantMsg { sid: rdv::RECLAIM_SID.into(), relay: grant(&relay, reclaim.username.clone(), credential, expiry) });
                }
            }
        }
        let exclude = request.exclude.unwrap_or_default();
        let Some(relay) = self.pick(request.rtts.as_ref(), &exclude).cloned() else {
            self.counters.denied += 1;
            self.send(id, Msg::RelayDenied { sid: rdv::WARM_SID.into(), code: "pool_exhausted".into(), retry_after_ms: 60_000 });
            return Outcome::Continue;
        };
        let expiry = unix_s + self.config.limits.warm_grant_lifetime_s;
        let secret = &self.secrets[&relay.id];
        let username = rdv::warm_username(secret, expiry, &node);
        let credential = rdv::turn_rest_credential(secret, &username);
        self.counters.grants += 1;
        self.counters.warm_grants += 1;
        self.send(id, Msg::RelayGrantMsg { sid: rdv::WARM_SID.into(), relay: grant(&relay, username, credential, expiry) });
        Outcome::Continue
    }

    /// Lowest round trip plus penalty among enabled relays with a secret (spec 9.3, phase 1:
    /// no allowance tiers yet). Unknown round trips count as 200 ms.
    fn pick(&self, rtts: Option<&BTreeMap<String, u32>>, exclude: &[String]) -> Option<&Relay> {
        self.config
            .relays
            .iter()
            .filter(|r| r.enabled && self.secrets.contains_key(&r.id) && !exclude.contains(&r.id))
            .min_by_key(|r| rtts.and_then(|m| m.get(&r.id)).copied().unwrap_or(200).saturating_add(r.penalty_ms))
    }
}

fn grant(relay: &Relay, username: String, credential: String, expiry_unix_s: u64) -> RelayGrant {
    RelayGrant {
        id: relay.id.clone(),
        kind: relay.kind.clone(),
        urls: relay.urls.clone(),
        username,
        credential,
        spki: relay.spki.clone(),
        expires_at: expiry_unix_s * 1_000,
        max_kbps: relay.max_kbps,
    }
}

pub fn unix_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hub() -> Hub {
        let config = Config::parse(
            r#"
[server]
listen = "127.0.0.1:0"
[limits]
signals_per_minute = 2
[[relays]]
id = "bom"
kind = "coturn"
urls = ["turn:a:3478"]
secret_env = "A"
[[relays]]
id = "sin"
kind = "coturn"
urls = ["turn:b:3478"]
secret_env = "B"
penalty_ms = 10
"#,
        )
        .unwrap();
        let secrets = HashMap::from([("bom".to_string(), b"s1".to_vec()), ("sin".to_string(), b"s2".to_vec())]);
        Hub::new(config, secrets)
    }

    fn drain(rx: &mut mpsc::Receiver<String>) -> Vec<Msg> {
        let mut out = Vec::new();
        while let Ok(text) = rx.try_recv() {
            out.push(Msg::parse(&text).unwrap());
        }
        out
    }

    const RDV: &str = "AAAAAAAAAAAAAAAAAAAAAA";
    const SID: &str = "BBBBBBBBBBBBBBBBBBBBBB";

    #[test]
    fn presence_signal_and_grants() {
        let mut hub = hub();
        let (tx_a, mut rx_a) = mpsc::channel(16);
        let (tx_b, mut rx_b) = mpsc::channel(16);
        let a = hub.join("node-a".into(), tx_a).unwrap();
        let b = hub.join("node-b".into(), tx_b).unwrap();
        hub.handle(a, Msg::Register { ids: vec![RDV.into()] });
        assert_eq!(drain(&mut rx_a), vec![Msg::Registered { online: vec![] }]);
        hub.handle(a, Msg::Signal { rdv: RDV.into(), side: 0, sid: SID.into(), body: "x".into() });
        assert_eq!(drain(&mut rx_a), vec![Msg::Undeliverable { rdv: RDV.into(), sid: SID.into() }]);
        hub.handle(b, Msg::Register { ids: vec![RDV.into()] });
        assert_eq!(drain(&mut rx_b), vec![Msg::Registered { online: vec![RDV.into()] }]);
        assert_eq!(drain(&mut rx_a), vec![Msg::Presence { rdv: RDV.into(), online: true }]);
        hub.handle(a, Msg::Signal { rdv: RDV.into(), side: 0, sid: SID.into(), body: "x".into() });
        assert_eq!(drain(&mut rx_b), vec![Msg::Signal { rdv: RDV.into(), side: 0, sid: SID.into(), body: "x".into() }]);
        // Rate limit: 2 a minute in this config.
        hub.handle(a, Msg::Signal { rdv: RDV.into(), side: 0, sid: SID.into(), body: "x".into() });
        hub.handle(a, Msg::Signal { rdv: RDV.into(), side: 0, sid: SID.into(), body: "x".into() });
        assert!(matches!(drain(&mut rx_a).last(), Some(Msg::Error { code, .. }) if code == "rate_limited"));
        drain(&mut rx_b);
        // Relay: lowest rtt plus penalty; the claim gets the same relay with its own side.
        let rtts = BTreeMap::from([("bom".to_string(), 100), ("sin".to_string(), 50)]);
        hub.handle(a, Msg::RelayRequest { rdv: RDV.into(), sid: SID.into(), side: 0, rtts: Some(rtts), need: None, est_bytes: None, exclude: None });
        let Some(Msg::RelayGrantMsg { relay, .. }) = drain(&mut rx_a).pop() else { panic!() };
        assert_eq!(relay.id, "sin");
        assert!(relay.username.ends_with(":BBBBBBBB.0"));
        hub.handle(b, Msg::RelayClaim { rdv: RDV.into(), sid: SID.into(), side: 1 });
        let Some(Msg::RelayGrantMsg { relay, .. }) = drain(&mut rx_b).pop() else { panic!() };
        assert_eq!(relay.id, "sin");
        assert!(relay.username.ends_with(":BBBBBBBB.1"));
        // A node that does not hold the rendezvous ID gets nothing.
        let (tx_c, mut rx_c) = mpsc::channel(16);
        let c = hub.join("node-c".into(), tx_c).unwrap();
        hub.handle(c, Msg::RelayClaim { rdv: RDV.into(), sid: SID.into(), side: 1 });
        assert!(matches!(drain(&mut rx_c).pop(), Some(Msg::Error { code, .. }) if code == "bad_request"));
        // Leaving tells the other side.
        hub.leave(b);
        assert_eq!(drain(&mut rx_a), vec![Msg::Presence { rdv: RDV.into(), online: false }]);
    }

    #[test]
    fn warm_grants_and_reclaim() {
        let mut hub = hub();
        let (tx, mut rx) = mpsc::channel(16);
        let a = hub.join("node-a".into(), tx).unwrap();
        // No rendezvous ID needed: the grant is the node's own.
        let rtts = BTreeMap::from([("bom".to_string(), 100), ("sin".to_string(), 50)]);
        hub.handle(a, Msg::RelayWarm { request: WarmRequest { rtts: Some(rtts), ..Default::default() } });
        let Some(Msg::RelayGrantMsg { sid, relay }) = drain(&mut rx).pop() else { panic!() };
        assert_eq!((sid.as_str(), relay.id.as_str()), (rdv::WARM_SID, "sin"));
        assert!(relay.username.contains(":w."));
        assert_eq!(relay.credential, rdv::turn_rest_credential(b"s2", &relay.username));
        // The same node gets its earlier username's credential back, and a new grant.
        let reclaim = rdv::Reclaim { relay: "sin".into(), username: relay.username.clone() };
        hub.handle(a, Msg::RelayWarm { request: WarmRequest { reclaim: Some(reclaim.clone()), ..Default::default() } });
        let got = drain(&mut rx);
        assert!(matches!(&got[0], Msg::RelayGrantMsg { sid, relay: r } if sid == rdv::RECLAIM_SID && r.username == relay.username && r.credential == relay.credential));
        assert!(matches!(&got[1], Msg::RelayGrantMsg { sid, .. } if sid == rdv::WARM_SID));
        // Another node never does.
        let (tx_b, mut rx_b) = mpsc::channel(16);
        let b = hub.join("node-b".into(), tx_b).unwrap();
        hub.handle(b, Msg::RelayWarm { request: WarmRequest { reclaim: Some(reclaim), ..Default::default() } });
        let got = drain(&mut rx_b);
        assert_eq!(got.len(), 1);
        assert!(matches!(&got[0], Msg::RelayGrantMsg { sid, .. } if sid == rdv::WARM_SID));
        // Session usernames are never reclaimable.
        let session = rdv::turn_rest_credentials(b"s2", unix_ms() / 1_000 + 60, SID, 0).0;
        hub.handle(a, Msg::RelayWarm { request: WarmRequest { reclaim: Some(rdv::Reclaim { relay: "sin".into(), username: session }), ..Default::default() } });
        assert_eq!(drain(&mut rx).len(), 1);
        assert_eq!(hub.relay_infos().len(), 2);
    }

    #[test]
    fn socket_allowance() {
        let mut hub = hub();
        for _ in 0..3 {
            let (tx, _rx) = mpsc::channel(1);
            assert!(hub.join("n".into(), tx).is_some());
        }
        let (tx, _rx) = mpsc::channel(1);
        assert!(hub.join("n".into(), tx).is_none());
    }

    #[test]
    fn exclude_and_exhaust() {
        let mut hub = hub();
        let (tx, mut rx) = mpsc::channel(16);
        let a = hub.join("a".into(), tx).unwrap();
        hub.handle(a, Msg::Register { ids: vec![RDV.into()] });
        drain(&mut rx);
        hub.handle(a, Msg::RelayRequest { rdv: RDV.into(), sid: SID.into(), side: 0, rtts: None, need: None, est_bytes: None, exclude: Some(vec!["bom".into(), "sin".into()]) });
        assert!(matches!(drain(&mut rx).pop(), Some(Msg::RelayDenied { code, .. }) if code == "pool_exhausted"));
    }
}
