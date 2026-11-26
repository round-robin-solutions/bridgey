//! Presence, sealed signal forwarding and relay grants, independent of the socket layer.
//!
//! Kept in memory only (spec 6.7): which connection holds which rendezvous ID, pending grants and
//! rate-limit counters. Nothing here is logged with an address, an ID or a body.
//!
//! Relay choice (spec 9.3): Cloudflare Realtime TURN first for clients that said they can use it, the own coturn pool
//! as the backup and for every other client. A Cloudflare grant needs credentials from Cloudflare's API, so the hub
//! queues a [MintJob] and the socket layer finishes it with [Hub::finish_mint]; a failed mint falls back to the pool.

use crate::cloudflare::{self, Minted};
use crate::config::{Config, Relay};
use bridgey_connect_proto::rdv::{self, Msg, RelayGrant, RelayInfo, WarmRequest};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::net::IpAddr;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

pub type ConnId = u64;

pub struct Conn {
    pub node_id: String,
    pub tx: mpsc::Sender<String>,
    pub ids: HashSet<String>,
    signals: Window,
    /// Every message, and how many were dropped past the limit in a row.
    messages: Window,
    dropped: u32,
    /// The client sent [rdv::CAP_CLOUDFLARE]: it can use Cloudflare grants.
    cloudflare: bool,
    /// The client's address group ([ip_group]), in memory only: Cloudflare credentials are limited per address.
    ip: Option<IpAddr>,
}

/// An IPv4 address, or the /64 an IPv6 address is in (one household or one server gets a whole /64).
pub fn ip_group(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => IpAddr::V6(std::net::Ipv6Addr::from(u128::from(v6) & !((1u128 << 64) - 1))),
        },
        v4 => v4,
    }
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

    /// One more event would be counted (without counting it).
    fn room(&self, limit: u32, now: Instant) -> bool {
        now.saturating_duration_since(self.start) >= self.length || self.count < limit
    }

    fn expired(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.start) >= self.length
    }
}

struct PendingGrant {
    relay: String,
    expires: Instant,
}

/// The Cloudflare relay: whether grants may go there now (usage under the caps, the API answering).
struct Cf {
    relay: Relay,
    soft_bytes: u64,
    hard_bytes: u64,
    max_age: Duration,
    interval: Duration,
    interval_near: Duration,
    /// The last usage reading and when it was taken.
    usage: Option<(u64, Instant)>,
    usage_error: Option<String>,
    /// Mints that failed in a row, and until when Cloudflare is skipped because of them.
    failures: u32,
    paused_until: Option<Instant>,
    last_error: Option<String>,
    /// Each node's current Cloudflare warm credentials (memory only), so that node alone can end an allocation a
    /// killed process left (the reclaim); coturn derives them from its secret instead.
    warm: HashMap<String, CfWarm>,
    /// The budget ([Hub::cf_budget]): the rate one credential is assumed to carry, in bytes a second, and the time
    /// added to the next reading.
    budget_bytes_per_s: u64,
    budget_extra: Duration,
    mints_per_ip: u32,
    /// Every credential minted and not yet expired or revoked, and the mints under way (memory only). A credential
    /// keeps working until it expires unless it is revoked, so these count against the cap, not just new mints.
    outstanding: Vec<CfCredential>,
    in_flight: usize,
    /// Credentials to revoke through Cloudflare's API, and those whose revocation failed (tried again later).
    revoke: Vec<CfCredential>,
    revoke_later: Vec<CfCredential>,
    /// Cloudflare credentials minted per address group in the last hour.
    per_ip: HashMap<IpAddr, Window>,
}

/// A Cloudflare credential that is out: Cloudflare's username, when it expires, whether it is a node's warm one.
#[derive(Clone, Debug)]
pub struct CfCredential {
    pub username: String,
    expiry_unix_s: u64,
    warm: bool,
    minted: Instant,
}

struct CfWarm {
    username: String,
    credential: String,
    urls: Vec<String>,
    expiry_unix_s: u64,
}

/// Where Cloudflare stands in the choice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CfTier {
    /// Under the soft cap: the first choice.
    First,
    /// Between the soft and hard caps: only when no own relay can take the grant.
    Overflow,
    /// Not configured, over the hard cap, no fresh usage reading, failing, or excluded.
    Off,
}

/// A Cloudflare grant waiting for its credentials: the socket layer mints them and calls [Hub::finish_mint].
#[derive(Clone, Debug)]
pub struct MintJob {
    pub conn: ConnId,
    pub node: String,
    /// The session ID, or [rdv::WARM_SID] for the node's own relay.
    pub sid: String,
    pub side: u8,
    /// The session's rendezvous ID; `None` for a warm grant.
    pub rdv: Option<String>,
    pub rtts: Option<BTreeMap<String, u32>>,
    pub exclude: Vec<String>,
    pub ttl_s: u64,
    /// When the grant was asked for: the credentials expire no later than this plus `ttl_s`.
    pub asked_unix_s: u64,
}

/// Expired entries (pending grants, rate windows, credentials) are swept at most this often, not on every message.
const SWEEP_EVERY: Duration = Duration::from_secs(1);

/// A failed mint keeps Cloudflare out of the choice for this long, doubling with each failure in a row up to the cap.
const CF_PAUSE: Duration = Duration::from_secs(60);
const CF_PAUSE_MAX: Duration = Duration::from_secs(900);

pub struct Hub {
    config: Config,
    secrets: HashMap<String, Vec<u8>>,
    conns: HashMap<ConnId, Conn>,
    by_rdv: HashMap<String, HashSet<ConnId>>,
    sockets_per_node: HashMap<String, usize>,
    grants_per_node: HashMap<String, Window>,
    pending: HashMap<(String, String), PendingGrant>,
    swept_at: Instant,
    next_id: ConnId,
    cf: Option<Cf>,
    mints: Vec<MintJob>,
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
    /// Grants on Cloudflare (counted in `grants` too), and Cloudflare grants that went to the own pool instead
    /// because the mint failed.
    pub cf_grants: u64,
    pub cf_fallbacks: u64,
    /// Cloudflare grants that went to the own pool because the budget or the address limit was reached, and
    /// Cloudflare credentials revoked because usage left no room for them.
    pub cf_over_budget: u64,
    pub cf_revoked: u64,
    /// Messages dropped by the per-connection limit.
    pub messages_dropped: u64,
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
            swept_at: Instant::now(),
            next_id: 1,
            cf: None,
            mints: Vec::new(),
            counters: Counters::default(),
        }
    }

    /// Adds the Cloudflare relay (its TURN key is in the environment). It takes grants once a usage reading shows
    /// room under the caps.
    pub fn enable_cloudflare(&mut self, relay: Relay) {
        let settings = relay.cloudflare.clone().unwrap_or_default();
        self.cf = Some(Cf {
            soft_bytes: cloudflare::gb_bytes(settings.soft_gb),
            hard_bytes: cloudflare::gb_bytes(settings.hard_gb),
            max_age: Duration::from_secs(settings.usage_max_age_s),
            interval: Duration::from_secs(settings.usage_interval_s.max(60)),
            interval_near: Duration::from_secs(settings.usage_interval_near_s.max(60)),
            relay,
            usage: None,
            usage_error: None,
            failures: 0,
            paused_until: None,
            last_error: None,
            warm: HashMap::new(),
            budget_bytes_per_s: u64::from(settings.budget_kbps) * 1_000 / 8,
            budget_extra: Duration::from_secs(settings.budget_extra_s),
            mints_per_ip: settings.mints_per_ip_hour,
            outstanding: Vec::new(),
            in_flight: 0,
            revoke: Vec::new(),
            revoke_later: Vec::new(),
            per_ip: HashMap::new(),
        });
    }

    fn is_cf(&self, relay: &str) -> bool {
        self.cf.as_ref().is_some_and(|cf| cf.relay.id == relay)
    }

    /// Whether `relay` can be granted: a coturn relay with its secret, or the configured Cloudflare relay.
    pub fn configured(&self, relay: &str) -> bool {
        self.secrets.contains_key(relay) || self.is_cf(relay)
    }

    /// Records a usage reading (or the error that stopped one), then queues the revocation of credentials the
    /// usage no longer leaves room for ([Hub::take_revocations]).
    pub fn set_cf_usage(&mut self, reading: Result<u64, String>, now: Instant) {
        let Some(cf) = self.cf.as_mut() else { return };
        match reading {
            Ok(bytes) => {
                cf.usage = Some((bytes, now));
                cf.usage_error = None;
            }
            Err(e) => cf.usage_error = Some(e),
        }
        self.plan_revocations(now);
    }

    /// How many Cloudflare credentials may be out at once, so that what they can carry before the next reading
    /// (and the revocation it can trigger) stays under the hard cap: the room left under the cap divided by what one
    /// credential can carry in that time. Every credential handed out keeps working until it expires or is revoked,
    /// so this, not the tier alone, is what keeps the free tier from being exceeded. 0 without a fresh reading.
    pub fn cf_budget(&self, now: Instant) -> usize {
        let Some(cf) = &self.cf else { return 0 };
        let Some((bytes, at)) = cf.usage else { return 0 };
        let age = now.saturating_duration_since(at);
        if age > cf.max_age {
            return 0;
        }
        if cf.budget_bytes_per_s == 0 {
            return usize::MAX;
        }
        let horizon = age + self.cf_poll_interval() + cf.budget_extra;
        let per_credential = cf.budget_bytes_per_s.saturating_mul(horizon.as_secs().max(1));
        usize::try_from(cf.hard_bytes.saturating_sub(bytes) / per_credential).unwrap_or(usize::MAX)
    }

    /// Credentials out now (unexpired and not revoked) plus mints under way.
    fn cf_out(&self) -> usize {
        let Some(cf) = &self.cf else { return 0 };
        let unix_s = unix_ms() / 1_000;
        cf.outstanding.iter().filter(|c| c.expiry_unix_s > unix_s).count() + cf.in_flight
    }

    /// One more Cloudflare credential fits the budget and this address's hourly allowance.
    fn cf_room(&self, ip: Option<IpAddr>, now: Instant) -> bool {
        let Some(cf) = &self.cf else { return false };
        if self.cf_out() >= self.cf_budget(now) {
            return false;
        }
        ip.map(ip_group).and_then(|g| cf.per_ip.get(&g)).is_none_or(|w| w.room(cf.mints_per_ip, now))
    }

    /// Queues a Cloudflare mint, counting it against the budget and the address at once.
    fn queue_mint(&mut self, job: MintJob, ip: Option<IpAddr>, now: Instant) {
        if let Some(cf) = self.cf.as_mut() {
            cf.in_flight += 1;
            if let Some(group) = ip.map(ip_group) {
                let limit = cf.mints_per_ip;
                cf.per_ip.entry(group).or_insert_with(|| Window::new(Duration::from_secs(3_600))).hit(limit, now);
            }
        }
        self.mints.push(job);
    }

    /// Moves credentials the budget has no room for to the revocation queue: warm ones (a node's standby relay,
    /// whose loss only slows its next connect) before session ones, the newest first. At the hard cap, or without a
    /// fresh reading, that is all of them.
    fn plan_revocations(&mut self, now: Instant) {
        let budget = self.cf_budget(now);
        let unix_s = unix_ms() / 1_000;
        let Some(cf) = self.cf.as_mut() else { return };
        let later = std::mem::take(&mut cf.revoke_later);
        cf.revoke.extend(later.into_iter().filter(|c| c.expiry_unix_s > unix_s));
        cf.outstanding.retain(|c| c.expiry_unix_s > unix_s);
        let out = cf.outstanding.len() + cf.in_flight;
        if out <= budget {
            return;
        }
        let excess = (out - budget).min(cf.outstanding.len());
        // Kept first: session credentials, then the oldest.
        cf.outstanding.sort_by(|a, b| a.warm.cmp(&b.warm).then(a.minted.cmp(&b.minted)));
        let victims = cf.outstanding.split_off(cf.outstanding.len() - excess);
        let names: HashSet<&str> = victims.iter().map(|c| c.username.as_str()).collect();
        cf.warm.retain(|_, w| !names.contains(w.username.as_str()));
        self.counters.cf_revoked += victims.len() as u64;
        cf.revoke.extend(victims);
    }

    /// Credentials for the socket layer to revoke through Cloudflare's API.
    pub fn take_revocations(&mut self) -> Vec<CfCredential> {
        self.cf.as_mut().map(|cf| std::mem::take(&mut cf.revoke)).unwrap_or_default()
    }

    /// A revocation's outcome: a failed one is tried again at the next usage reading.
    pub fn finish_revoke(&mut self, credential: CfCredential, revoked: bool) {
        if let Some(cf) = self.cf.as_mut().filter(|_| !revoked) {
            cf.revoke_later.push(credential);
        }
    }

    /// When to read the usage next: more often once it is past the soft cap.
    pub fn cf_poll_interval(&self) -> Duration {
        match &self.cf {
            Some(cf) if cf.usage.is_some_and(|(bytes, _)| bytes >= cf.soft_bytes) => cf.interval_near,
            Some(cf) if cf.usage_error.is_some() => cf.interval.min(Duration::from_secs(120)),
            Some(cf) => cf.interval,
            None => Duration::from_secs(900),
        }
    }

    /// Where Cloudflare stands for a grant now. Without a fresh usage reading it is off: the cap must hold even when
    /// the analytics API does not answer.
    pub fn cf_tier(&self, now: Instant, exclude: &[String]) -> CfTier {
        let Some(cf) = &self.cf else { return CfTier::Off };
        if !cf.relay.enabled || exclude.contains(&cf.relay.id) || cf.paused_until.is_some_and(|until| until > now) {
            return CfTier::Off;
        }
        match cf.usage {
            Some((bytes, at)) if now.saturating_duration_since(at) <= cf.max_age => {
                if bytes >= cf.hard_bytes {
                    CfTier::Off
                } else if bytes >= cf.soft_bytes {
                    CfTier::Overflow
                } else {
                    CfTier::First
                }
            }
            _ => CfTier::Off,
        }
    }

    /// For `/v1/status`: the caps, the last reading and whether grants go there. No secrets.
    pub fn cloudflare_status(&self, now: Instant) -> Option<serde_json::Value> {
        let cf = self.cf.as_ref()?;
        let tier = match self.cf_tier(now, &[]) {
            CfTier::First => "first",
            CfTier::Overflow => "overflow",
            CfTier::Off => "off",
        };
        Some(serde_json::json!({
            "id": cf.relay.id,
            "tier": tier,
            "usedGb": cf.usage.map(|(bytes, _)| (cloudflare::gb(bytes) * 100.0).round() / 100.0),
            "readSecondsAgo": cf.usage.map(|(_, at)| now.saturating_duration_since(at).as_secs()),
            "softGb": cloudflare::gb(cf.soft_bytes),
            "hardGb": cloudflare::gb(cf.hard_bytes),
            "usageError": cf.usage_error,
            "mintFailuresInARow": cf.failures,
            "pausedSeconds": cf.paused_until.map(|until| until.saturating_duration_since(now).as_secs()).filter(|s| *s > 0),
            "lastMintError": cf.last_error,
            "credentialsOut": self.cf_out(),
            "budget": self.cf_budget(now).min(1_000_000),
        }))
    }

    /// Grants waiting for Cloudflare credentials, for the socket layer to mint.
    pub fn take_mints(&mut self) -> Vec<MintJob> {
        std::mem::take(&mut self.mints)
    }

    /// Finishes a Cloudflare grant: the credentials go to the client, or, when the mint failed, a grant on the own pool
    /// does (and Cloudflare is left out of the choice for a while).
    pub fn finish_mint(&mut self, job: MintJob, minted: Result<Minted, String>, now: Instant) {
        let Some(cf) = self.cf.as_mut() else { return };
        cf.in_flight = cf.in_flight.saturating_sub(1);
        // Only the URLs the settings list go out: a grant with none of them left is a failure too.
        let minted = minted.and_then(|m| {
            let urls: Vec<String> = m.urls.into_iter().filter(|u| cf.relay.urls.contains(u)).collect();
            if urls.is_empty() {
                Err("no usable URL in the answer".to_string())
            } else {
                Ok(Minted { urls, ..m })
            }
        });
        match minted {
            Ok(m) => {
                cf.failures = 0;
                cf.paused_until = None;
                let expiry = job.asked_unix_s + job.ttl_s;
                let grant = RelayGrant {
                    id: cf.relay.id.clone(),
                    kind: cf.relay.kind.clone(),
                    urls: m.urls.clone(),
                    username: m.username.clone(),
                    credential: m.credential.clone(),
                    spki: None,
                    expires_at: expiry * 1_000,
                    max_kbps: cf.relay.max_kbps,
                };
                cf.outstanding.push(CfCredential { username: m.username.clone(), expiry_unix_s: expiry, warm: job.rdv.is_none(), minted: now });
                if job.rdv.is_none() {
                    let unix_s = unix_ms() / 1_000;
                    cf.warm.retain(|_, w| w.expiry_unix_s > unix_s);
                    cf.warm.insert(job.node.clone(), CfWarm { username: m.username, credential: m.credential, urls: m.urls, expiry_unix_s: expiry });
                    self.counters.warm_grants += 1;
                }
                self.counters.grants += 1;
                self.counters.cf_grants += 1;
                self.send(job.conn, Msg::RelayGrantMsg { sid: job.sid, relay: grant });
            }
            Err(e) => {
                cf.failures = cf.failures.saturating_add(1);
                let pause = CF_PAUSE.saturating_mul(1 << (cf.failures - 1).min(4)).min(CF_PAUSE_MAX);
                cf.paused_until = Some(now + pause);
                cf.last_error = Some(e);
                let cf_id = cf.relay.id.clone();
                self.counters.cf_fallbacks += 1;
                let mut exclude = job.exclude.clone();
                exclude.push(cf_id.clone());
                let Some(relay) = self.pick(job.rtts.as_ref(), &exclude).cloned() else {
                    self.counters.denied += 1;
                    self.send(job.conn, Msg::RelayDenied { sid: job.sid, code: "pool_exhausted".into(), retry_after_ms: 60_000 });
                    return;
                };
                match job.rdv {
                    Some(rdv) => {
                        // The other side's claim follows the session to the same fallback relay.
                        if let Some(pending) = self.pending.get_mut(&(rdv, job.sid.clone())).filter(|p| p.relay == cf_id) {
                            pending.relay = relay.id.clone();
                        }
                        self.send_session_grant(job.conn, &relay, job.sid, job.side, job.ttl_s);
                    }
                    None => self.send_warm_grant(job.conn, &relay, &job.node, unix_ms() / 1_000),
                }
            }
        }
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn connections(&self) -> usize {
        self.conns.len()
    }

    pub fn nodes(&self) -> usize {
        self.sockets_per_node.len()
    }

    /// [Hub::join_with] for a client that sent no capabilities.
    #[cfg(test)]
    pub fn join(&mut self, node_id: String, tx: mpsc::Sender<String>) -> Option<ConnId> {
        self.join_with(node_id, tx, &[], None)
    }

    /// Admits an authenticated node with the capabilities it sent in its hello and the address it connected from, or
    /// `None` when it already holds its socket allowance.
    pub fn join_with(&mut self, node_id: String, tx: mpsc::Sender<String>, caps: &[String], ip: Option<IpAddr>) -> Option<ConnId> {
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
        let cloudflare = caps.iter().any(|c| c == rdv::CAP_CLOUDFLARE);
        self.conns.insert(
            id,
            Conn {
                node_id,
                tx,
                ids: HashSet::new(),
                signals: Window::new(Duration::from_secs(60)),
                messages: Window::new(Duration::from_secs(60)),
                dropped: 0,
                cloudflare,
                ip: ip.map(ip_group),
            },
        );
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
        if now.saturating_duration_since(self.swept_at) >= SWEEP_EVERY {
            self.sweep(now);
        }
        // One lock serves every connection, so each message counts, whatever it is.
        let limit = self.config.limits.messages_per_minute;
        let Some(conn) = self.conns.get_mut(&id) else { return Outcome::Close };
        if !conn.messages.hit(limit, now) {
            conn.dropped = conn.dropped.saturating_add(1);
            self.counters.messages_dropped += 1;
            if conn.dropped > limit {
                return Outcome::Close;
            }
            if conn.dropped == 1 {
                let retry = conn.messages.retry_after(now);
                self.send(id, Msg::Error { code: "rate_limited".into(), retry_after_ms: Some(retry) });
            }
            return Outcome::Continue;
        }
        conn.dropped = 0;
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

    /// Drops what has expired: pending grants, rate windows of nodes that went quiet, per-address mint counts and
    /// expired Cloudflare credentials.
    fn sweep(&mut self, now: Instant) {
        self.swept_at = now;
        self.pending.retain(|_, grant| grant.expires > now);
        self.grants_per_node.retain(|_, window| !window.expired(now));
        if let Some(cf) = self.cf.as_mut() {
            let unix_s = unix_ms() / 1_000;
            cf.per_ip.retain(|_, window| !window.expired(now));
            cf.outstanding.retain(|c| c.expiry_unix_s > unix_s);
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
        let mut new: HashSet<String> = ids.into_iter().collect();
        let old = conn.ids.clone();
        // A pair is two nodes: more connections on one ID than two nodes can hold are refused, so a signal never
        // fans out to an unbounded set.
        let cap = self.config.limits.sockets_per_rdv;
        let full: Vec<String> = new.difference(&old).filter(|r| self.by_rdv.get(*r).is_some_and(|set| set.len() >= cap)).cloned().collect();
        if !full.is_empty() {
            for refused in &full {
                new.remove(refused);
            }
            self.send(id, Msg::Error { code: "too_many_ids".into(), retry_after_ms: None });
        }
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
        let capable = self.conns[&id].cloudflare;
        let ip = self.conns[&id].ip;
        // The service picks one relay per session for both sides (spec 9.3): a claim reuses it, unless it is Cloudflare
        // and this client cannot use it, or Cloudflare has since gone off (the hard cap, a failed mint, the budget);
        // then the own pool, as before Cloudflare. Cloudflare is chosen only when every node on the session can use it.
        let pending = self.pending.get(&key).filter(|grant| grant.expires > now).map(|grant| grant.relay.clone());
        let reusable = |relay: &String| !self.is_cf(relay) || (capable && self.cf_tier(now, &exclude) != CfTier::Off && self.cf_room(ip, now));
        let chosen = match (claim, pending) {
            (true, Some(relay)) if !exclude.contains(&relay) && reusable(&relay) => Some(relay),
            _ => {
                let both = capable && self.others_capable(id, &rdv);
                self.choose(both, ip, rtts.as_ref(), &exclude, now)
            }
        };
        let Some(relay_id) = chosen else {
            self.counters.denied += 1;
            self.send(id, Msg::RelayDenied { sid, code: "pool_exhausted".into(), retry_after_ms: 60_000 });
            return Outcome::Continue;
        };
        if self.pending.len() >= self.config.limits.max_pending && !self.pending.contains_key(&key) {
            self.sweep(now);
            if self.pending.len() >= self.config.limits.max_pending {
                self.counters.denied += 1;
                self.send(id, Msg::RelayDenied { sid, code: "pool_exhausted".into(), retry_after_ms: 60_000 });
                return Outcome::Continue;
            }
        }
        let lifetime = self.config.limits.grant_lifetime_s;
        self.pending.insert(key, PendingGrant { relay: relay_id.clone(), expires: now + Duration::from_secs(lifetime) });
        if self.is_cf(&relay_id) {
            let node = self.conns[&id].node_id.clone();
            let job = MintJob { conn: id, node, sid, side, rdv: Some(rdv), rtts, exclude, ttl_s: lifetime, asked_unix_s: unix_ms() / 1_000 };
            self.queue_mint(job, ip, now);
            return Outcome::Continue;
        }
        let relay = self.config.relays.iter().find(|r| r.id == relay_id).expect("chosen relay").clone();
        self.send_session_grant(id, &relay, sid, side, lifetime);
        Outcome::Continue
    }

    /// A coturn session grant: TURN REST credentials for this session and side.
    fn send_session_grant(&mut self, id: ConnId, relay: &Relay, sid: String, side: u8, lifetime_s: u64) {
        let expiry = unix_ms() / 1_000 + lifetime_s;
        let (username, credential) = rdv::turn_rest_credentials(&self.secrets[&relay.id], expiry, &sid, side);
        self.counters.grants += 1;
        self.send(id, Msg::RelayGrantMsg { sid, relay: grant(relay, username, credential, expiry) });
    }

    /// A coturn warm grant: a username tied to the node, so it can reclaim the allocation after a crash.
    fn send_warm_grant(&mut self, id: ConnId, relay: &Relay, node: &str, unix_s: u64) {
        let expiry = unix_s + self.config.limits.warm_grant_lifetime_s;
        let secret = &self.secrets[&relay.id];
        let username = rdv::warm_username(secret, expiry, node);
        let credential = rdv::turn_rest_credential(secret, &username);
        self.counters.grants += 1;
        self.counters.warm_grants += 1;
        self.send(id, Msg::RelayGrantMsg { sid: rdv::WARM_SID.into(), relay: grant(relay, username, credential, expiry) });
    }

    /// Every other node's connections on `rdv` can use Cloudflare grants (and there is at least one).
    fn others_capable(&self, id: ConnId, rdv: &str) -> bool {
        let others = self.others(id, rdv);
        !others.is_empty() && others.iter().all(|c| self.conns.get(c).is_some_and(|conn| conn.cloudflare))
    }

    /// The relays a node may use, for `welcome`: it probes them and keeps permissions for all of them. Cloudflare is
    /// listed only to clients that can use it, so older clients see exactly the pool they saw before.
    pub fn relay_infos(&self, cloudflare: bool) -> Vec<RelayInfo> {
        self.config
            .relays
            .iter()
            .filter(|r| r.enabled && (self.secrets.contains_key(&r.id) || (cloudflare && self.is_cf(&r.id))))
            .filter_map(|r| Some(RelayInfo { id: r.id.clone(), stun: r.stun()? }))
            .collect()
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
            if let Some(cf) = self.cf.as_ref().filter(|cf| cf.relay.id == reclaim.relay) {
                // Cloudflare usernames are Cloudflare's: the node's last one is remembered, and only that node gets it.
                if let Some(w) = cf.warm.get(&node).filter(|w| w.username == reclaim.username && w.expiry_unix_s > unix_s) {
                    let relay = RelayGrant {
                        id: cf.relay.id.clone(),
                        kind: cf.relay.kind.clone(),
                        urls: w.urls.clone(),
                        username: w.username.clone(),
                        credential: w.credential.clone(),
                        spki: None,
                        expires_at: w.expiry_unix_s * 1_000,
                        max_kbps: cf.relay.max_kbps,
                    };
                    self.counters.reclaimed += 1;
                    self.send(id, Msg::RelayGrantMsg { sid: rdv::RECLAIM_SID.into(), relay });
                }
            } else {
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
        }
        let exclude = request.exclude.unwrap_or_default();
        let capable = self.conns.get(&id).is_some_and(|c| c.cloudflare);
        let ip = self.conns.get(&id).and_then(|c| c.ip);
        let Some(relay_id) = self.choose(capable, ip, request.rtts.as_ref(), &exclude, now) else {
            self.counters.denied += 1;
            self.send(id, Msg::RelayDenied { sid: rdv::WARM_SID.into(), code: "pool_exhausted".into(), retry_after_ms: 60_000 });
            return Outcome::Continue;
        };
        if self.is_cf(&relay_id) {
            let ttl_s = self.config.limits.warm_grant_lifetime_s;
            let job = MintJob { conn: id, node, sid: rdv::WARM_SID.into(), side: 0, rdv: None, rtts: request.rtts, exclude, ttl_s, asked_unix_s: unix_s };
            self.queue_mint(job, ip, now);
            return Outcome::Continue;
        }
        let relay = self.config.relays.iter().find(|r| r.id == relay_id).expect("chosen relay").clone();
        self.send_warm_grant(id, &relay, &node, unix_s);
        Outcome::Continue
    }

    /// Where a grant goes (spec 9.3): Cloudflare first when the client (and, for a session, the other side) can use it
    /// and it is under the soft cap; otherwise the own pool by round trip; Cloudflare between the soft and hard caps
    /// only when no own relay can take it. Cloudflare also needs room in the budget and in the client's address
    /// allowance; without it the grant goes to the own pool.
    fn choose(&mut self, cloudflare: bool, ip: Option<IpAddr>, rtts: Option<&BTreeMap<String, u32>>, exclude: &[String], now: Instant) -> Option<String> {
        let mut tier = if cloudflare { self.cf_tier(now, exclude) } else { CfTier::Off };
        if tier != CfTier::Off && !self.cf_room(ip, now) {
            self.counters.cf_over_budget += 1;
            tier = CfTier::Off;
        }
        let cf_id = || self.cf.as_ref().map(|cf| cf.relay.id.clone());
        if tier == CfTier::First {
            return cf_id();
        }
        if let Some(relay) = self.pick(rtts, exclude) {
            return Some(relay.id.clone());
        }
        if tier == CfTier::Overflow {
            return cf_id();
        }
        None
    }

    /// The own pool: lowest round trip plus penalty among enabled coturn relays with a secret (no allowance tiers
    /// yet). Unknown round trips count as 200 ms.
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
        assert_eq!(hub.relay_infos(false).len(), 2);
    }

    /// The hub with the Cloudflare relay as production configures it, and a usage reading of `used_gb`.
    fn cf_hub(used_gb: Option<u64>) -> Hub {
        let config = Config::parse(
            r#"
[server]
listen = "127.0.0.1:0"
[[relays]]
id = "cf"
kind = "cloudflare"
urls = ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"]
stun = "turn.cloudflare.com:3478"
max_kbps = 40000
[relays.cloudflare]
soft_gb = 800
hard_gb = 950
usage_max_age_s = 3600
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
        let cf = config.relays[0].clone();
        let mut hub = Hub::new(config, secrets);
        hub.enable_cloudflare(cf);
        if let Some(gb) = used_gb {
            hub.set_cf_usage(Ok(gb * 1_000_000_000), Instant::now());
        }
        hub
    }

    fn caps(cloudflare: bool) -> Vec<String> {
        if cloudflare {
            vec![rdv::CAP_CLOUDFLARE.to_string()]
        } else {
            Vec::new()
        }
    }

    /// What Cloudflare's API answers: every URL it offers, the settings keep two.
    fn minted() -> Result<Minted, String> {
        Ok(Minted {
            urls: vec![
                "turn:turn.cloudflare.com:3478?transport=udp".into(),
                "turn:turn.cloudflare.com:53?transport=udp".into(),
                "turns:turn.cloudflare.com:443?transport=tcp".into(),
            ],
            username: "cf-user".into(),
            credential: "cf-pass".into(),
        })
    }

    fn warm_rtts() -> WarmRequest {
        WarmRequest { rtts: Some(BTreeMap::from([("bom".to_string(), 100), ("sin".to_string(), 50), ("cf".to_string(), 20)])), ..Default::default() }
    }

    #[test]
    fn cloudflare_warm_grants_only_for_clients_that_can_use_them() {
        let mut hub = cf_hub(Some(1));
        let (tx_new, mut rx_new) = mpsc::channel(16);
        let (tx_old, mut rx_old) = mpsc::channel(16);
        let new = hub.join_with("node-new".into(), tx_new, &caps(true), None).unwrap();
        let old = hub.join_with("node-old".into(), tx_old, &caps(false), None).unwrap();
        // An old client (no caps) gets exactly what it got before: the own pool, at once, and no Cloudflare in welcome.
        hub.handle(old, Msg::RelayWarm { request: warm_rtts() });
        let Some(Msg::RelayGrantMsg { sid, relay }) = drain(&mut rx_old).pop() else { panic!() };
        assert_eq!((sid.as_str(), relay.id.as_str(), relay.kind.as_str()), (rdv::WARM_SID, "sin", "coturn"));
        assert!(hub.take_mints().is_empty());
        assert!(hub.relay_infos(false).iter().all(|r| r.id != "cf"));
        // A new client: Cloudflare first, whatever the round trips, once its credentials are minted.
        hub.handle(new, Msg::RelayWarm { request: warm_rtts() });
        assert!(drain(&mut rx_new).is_empty(), "the grant waits for the mint");
        let jobs = hub.take_mints();
        assert_eq!(jobs.len(), 1);
        assert_eq!((jobs[0].sid.as_str(), jobs[0].rdv.is_none(), jobs[0].ttl_s), (rdv::WARM_SID, true, 43_200));
        hub.finish_mint(jobs[0].clone(), minted(), Instant::now());
        let Some(Msg::RelayGrantMsg { sid, relay }) = drain(&mut rx_new).pop() else { panic!() };
        assert_eq!(sid, rdv::WARM_SID);
        assert_eq!((relay.id.as_str(), relay.kind.as_str(), relay.max_kbps, relay.spki.as_deref()), ("cf", "cloudflare", 40_000, None));
        assert_eq!(relay.urls, vec!["turn:turn.cloudflare.com:3478?transport=udp".to_string(), "turns:turn.cloudflare.com:443?transport=tcp".to_string()]);
        assert_eq!((relay.username.as_str(), relay.credential.as_str()), ("cf-user", "cf-pass"));
        assert_eq!(relay.expires_at, (jobs[0].asked_unix_s + 43_200) * 1_000);
        assert_eq!((hub.counters.cf_grants, hub.counters.warm_grants), (1, 2));
        assert!(hub.relay_infos(true).iter().any(|r| r.id == "cf" && r.stun == "turn.cloudflare.com:3478"));
        // The same node can take back its Cloudflare credential after a crash; another node cannot.
        let reclaim = rdv::Reclaim { relay: "cf".into(), username: "cf-user".into() };
        hub.handle(new, Msg::RelayWarm { request: WarmRequest { reclaim: Some(reclaim.clone()), ..Default::default() } });
        assert!(matches!(drain(&mut rx_new).first(), Some(Msg::RelayGrantMsg { sid, relay }) if sid == rdv::RECLAIM_SID && relay.credential == "cf-pass"));
        hub.take_mints();
        hub.handle(old, Msg::RelayWarm { request: WarmRequest { reclaim: Some(reclaim), ..Default::default() } });
        assert!(drain(&mut rx_old).iter().all(|m| !matches!(m, Msg::RelayGrantMsg { sid, .. } if sid == rdv::RECLAIM_SID)));
    }

    #[test]
    fn cloudflare_sessions_need_both_sides() {
        let mut hub = cf_hub(Some(1));
        let (tx_a, mut rx_a) = mpsc::channel(16);
        let (tx_b, mut rx_b) = mpsc::channel(16);
        let a = hub.join_with("node-a".into(), tx_a, &caps(true), None).unwrap();
        let b = hub.join_with("node-b".into(), tx_b, &caps(false), None).unwrap();
        hub.handle(a, Msg::Register { ids: vec![RDV.into()] });
        hub.handle(b, Msg::Register { ids: vec![RDV.into()] });
        drain(&mut rx_a);
        drain(&mut rx_b);
        // The other side is an old client: both get the own pool, the same relay, as before.
        let rtts = BTreeMap::from([("bom".to_string(), 100), ("sin".to_string(), 50)]);
        hub.handle(a, Msg::RelayRequest { rdv: RDV.into(), sid: SID.into(), side: 0, rtts: Some(rtts), need: None, est_bytes: None, exclude: None });
        assert!(hub.take_mints().is_empty());
        let Some(Msg::RelayGrantMsg { relay, .. }) = drain(&mut rx_a).pop() else { panic!() };
        assert_eq!(relay.id, "sin");
        hub.handle(b, Msg::RelayClaim { rdv: RDV.into(), sid: SID.into(), side: 1 });
        let Some(Msg::RelayGrantMsg { relay, .. }) = drain(&mut rx_b).pop() else { panic!() };
        assert_eq!(relay.id, "sin");
        // Both sides can: Cloudflare for both, each with its own credentials.
        let (tx_c, mut rx_c) = mpsc::channel(16);
        let c = hub.join_with("node-c".into(), tx_c, &caps(true), None).unwrap();
        hub.leave(b);
        hub.handle(c, Msg::Register { ids: vec![RDV.into()] });
        drain(&mut rx_a);
        drain(&mut rx_c);
        let sid2 = "CCCCCCCCCCCCCCCCCCCCCC";
        hub.handle(a, Msg::RelayRequest { rdv: RDV.into(), sid: sid2.into(), side: 0, rtts: None, need: None, est_bytes: None, exclude: None });
        hub.handle(c, Msg::RelayClaim { rdv: RDV.into(), sid: sid2.into(), side: 1 });
        let jobs = hub.take_mints();
        assert_eq!(jobs.iter().map(|j| (j.conn, j.side, j.rdv.as_deref())).collect::<Vec<_>>(), vec![(a, 0, Some(RDV)), (c, 1, Some(RDV))]);
        for job in jobs {
            hub.finish_mint(job, minted(), Instant::now());
        }
        assert!(matches!(drain(&mut rx_a).pop(), Some(Msg::RelayGrantMsg { sid, relay }) if sid == sid2 && relay.id == "cf"));
        assert!(matches!(drain(&mut rx_c).pop(), Some(Msg::RelayGrantMsg { sid, relay }) if sid == sid2 && relay.id == "cf"));
        // A claim after Cloudflare went off (here: over the hard cap since the request) gets the own pool.
        let sid3 = "DDDDDDDDDDDDDDDDDDDDDD";
        hub.handle(a, Msg::RelayRequest { rdv: RDV.into(), sid: sid3.into(), side: 0, rtts: None, need: None, est_bytes: None, exclude: None });
        assert_eq!(hub.take_mints().len(), 1);
        hub.set_cf_usage(Ok(960_000_000_000), Instant::now());
        hub.handle(c, Msg::RelayClaim { rdv: RDV.into(), sid: sid3.into(), side: 1 });
        assert!(hub.take_mints().is_empty());
        assert!(matches!(drain(&mut rx_c).pop(), Some(Msg::RelayGrantMsg { relay, .. }) if relay.kind == "coturn"));
        hub.set_cf_usage(Ok(1_000_000_000), Instant::now());
        // An old client that claims a Cloudflare session (it came back on an older build) gets the own pool instead.
        let (tx_d, mut rx_d) = mpsc::channel(16);
        let d = hub.join_with("node-d".into(), tx_d, &caps(false), None).unwrap();
        hub.handle(d, Msg::Register { ids: vec![RDV.into()] });
        drain(&mut rx_d);
        hub.handle(d, Msg::RelayClaim { rdv: RDV.into(), sid: sid2.into(), side: 1 });
        assert!(hub.take_mints().is_empty());
        assert!(matches!(drain(&mut rx_d).pop(), Some(Msg::RelayGrantMsg { relay, .. }) if relay.kind == "coturn"));
    }

    #[test]
    fn cloudflare_caps_hold() {
        let now = Instant::now();
        // Under the soft cap: first. Between soft and hard: only when the pool cannot take it. At the hard cap: never.
        assert_eq!(cf_hub(Some(799)).cf_tier(now, &[]), CfTier::First);
        assert_eq!(cf_hub(Some(800)).cf_tier(now, &[]), CfTier::Overflow);
        assert_eq!(cf_hub(Some(950)).cf_tier(now, &[]), CfTier::Off);
        assert_eq!(cf_hub(Some(5_000)).cf_tier(now, &[]), CfTier::Off);
        // No reading yet, or one too old (the analytics API stopped answering): off, so the cap cannot be overrun.
        assert_eq!(cf_hub(None).cf_tier(now, &[]), CfTier::Off);
        let mut stale = cf_hub(Some(1));
        assert_eq!(stale.cf_tier(now + Duration::from_secs(3_601), &[]), CfTier::Off);
        stale.set_cf_usage(Err("usage: not allowed".into()), now);
        assert_eq!(stale.cf_tier(now, &[]), CfTier::First, "an error keeps the last reading until it is too old");
        assert_eq!(stale.cf_tier(now, &["cf".into()]), CfTier::Off);
        // Near the cap the usage is read more often.
        assert_eq!(cf_hub(Some(1)).cf_poll_interval(), Duration::from_secs(900));
        assert_eq!(cf_hub(Some(850)).cf_poll_interval(), Duration::from_secs(300));

        let warm = |hub: &mut Hub, exclude: Vec<String>| {
            let (tx, mut rx) = mpsc::channel(16);
            let id = hub.join_with(format!("n{}", hub.connections()), tx, &caps(true), None).unwrap();
            hub.handle(id, Msg::RelayWarm { request: WarmRequest { exclude: Some(exclude), ..warm_rtts() } });
            let mint = !hub.take_mints().is_empty();
            let grant = drain(&mut rx).into_iter().find_map(|m| match m {
                Msg::RelayGrantMsg { relay, .. } => Some(relay.id),
                Msg::RelayDenied { code, .. } => Some(code),
                _ => None,
            });
            (mint, grant)
        };
        // Over the hard cap a client that can use Cloudflare still gets a relay: the own pool.
        assert_eq!(warm(&mut cf_hub(Some(960)), vec![]), (false, Some("sin".into())));
        // Between the caps: the pool while it has room, Cloudflare when it has none.
        assert_eq!(warm(&mut cf_hub(Some(900)), vec![]), (false, Some("sin".into())));
        assert_eq!(warm(&mut cf_hub(Some(900)), vec!["bom".into(), "sin".into()]), (true, None));
        assert_eq!(warm(&mut cf_hub(Some(960)), vec!["bom".into(), "sin".into()]), (false, Some("pool_exhausted".into())));
    }

    #[test]
    fn cloudflare_failures_fall_back_to_the_pool() {
        let mut hub = cf_hub(Some(1));
        let (tx_a, mut rx_a) = mpsc::channel(16);
        let (tx_b, mut rx_b) = mpsc::channel(16);
        let a = hub.join_with("node-a".into(), tx_a, &caps(true), None).unwrap();
        let b = hub.join_with("node-b".into(), tx_b, &caps(true), None).unwrap();
        hub.handle(a, Msg::Register { ids: vec![RDV.into()] });
        hub.handle(b, Msg::Register { ids: vec![RDV.into()] });
        drain(&mut rx_a);
        drain(&mut rx_b);
        // The API fails (unreachable, refused, slow): the session's grant goes to the pool, and the claim follows it.
        let rtts = BTreeMap::from([("bom".to_string(), 30), ("sin".to_string(), 90)]);
        hub.handle(a, Msg::RelayRequest { rdv: RDV.into(), sid: SID.into(), side: 0, rtts: Some(rtts), need: None, est_bytes: None, exclude: None });
        let job = hub.take_mints().pop().unwrap();
        let now = Instant::now();
        hub.finish_mint(job, Err("mint: timed out".into()), now);
        let Some(Msg::RelayGrantMsg { sid, relay }) = drain(&mut rx_a).pop() else { panic!() };
        assert_eq!((sid.as_str(), relay.id.as_str()), (SID, "bom"));
        assert_eq!(relay.credential, rdv::turn_rest_credentials(b"s1", relay.expires_at / 1_000, SID, 0).1);
        hub.handle(b, Msg::RelayClaim { rdv: RDV.into(), sid: SID.into(), side: 1 });
        assert!(hub.take_mints().is_empty());
        assert!(matches!(drain(&mut rx_b).pop(), Some(Msg::RelayGrantMsg { relay, .. }) if relay.id == "bom" && relay.username.ends_with(".1")));
        assert_eq!(hub.counters.cf_fallbacks, 1);
        // Cloudflare stays out of the choice for a while (a minute, doubling), then comes back.
        assert_eq!(hub.cf_tier(now, &[]), CfTier::Off);
        hub.handle(a, Msg::RelayWarm { request: warm_rtts() });
        assert!(hub.take_mints().is_empty());
        assert!(matches!(drain(&mut rx_a).pop(), Some(Msg::RelayGrantMsg { relay, .. }) if relay.kind == "coturn"));
        assert_eq!(hub.cf_tier(now + Duration::from_secs(61), &[]), CfTier::First);
        // An answer without any URL the settings allow is a failure too (and the second one in a row pauses longer).
        let job = MintJob { conn: a, node: "node-a".into(), sid: rdv::WARM_SID.into(), side: 0, rdv: None, rtts: None, exclude: vec![], ttl_s: 60, asked_unix_s: 1 };
        let odd = Ok(Minted { urls: vec!["turn:elsewhere:3478".into()], username: "u".into(), credential: "c".into() });
        hub.finish_mint(job, odd, now);
        assert!(matches!(drain(&mut rx_a).pop(), Some(Msg::RelayGrantMsg { relay, .. }) if relay.kind == "coturn"));
        assert_eq!(hub.cf_tier(now + Duration::from_secs(61), &[]), CfTier::Off);
        assert_eq!(hub.cf_tier(now + Duration::from_secs(121), &[]), CfTier::First);
        let status = hub.cloudflare_status(now).unwrap();
        assert_eq!(status["mintFailuresInARow"], 2);
        assert!(!status.to_string().contains("cf-pass"));
    }

    /// A fresh node key per connection, with the capability: what anyone can make, no pairing needed.
    fn cf_warm_mint(hub: &mut Hub, i: usize, ip: Option<IpAddr>) -> bool {
        let (tx, mut rx) = mpsc::channel(4);
        let id = hub.join_with(format!("node-{i}"), tx, &caps(true), ip).unwrap();
        hub.handle(id, Msg::RelayWarm { request: WarmRequest::default() });
        let mut cloudflare = false;
        for job in hub.take_mints() {
            let ok = Ok(Minted { urls: vec!["turn:turn.cloudflare.com:3478?transport=udp".into()], username: format!("u{i}"), credential: "c".into() });
            hub.finish_mint(job, ok, Instant::now());
        }
        while let Ok(text) = rx.try_recv() {
            cloudflare |= matches!(Msg::parse(&text), Some(Msg::RelayGrantMsg { relay, .. }) if relay.kind == "cloudflare");
        }
        hub.leave(id);
        cloudflare
    }

    #[test]
    fn cloudflare_credentials_out_stay_within_the_budget() {
        // Security review 1.0, C1: unpaired nodes with fresh keys used to get a 12-hour Cloudflare credential each,
        // without limit, and nothing ended them at the hard cap.
        let mut hub = cf_hub(Some(0));
        let budget = hub.cf_budget(Instant::now());
        // 950 GB of room; 50 Mbit/s for 15 minutes to the next reading plus 15 minutes: 11.25 GB a credential.
        assert_eq!(budget, 84);
        let granted = (0..500).filter(|i| cf_warm_mint(&mut hub, *i, None)).count();
        assert_eq!(granted, budget, "the rest go to the own pool");
        assert_eq!(hub.counters.cf_over_budget, (500 - budget) as u64);
        assert!(hub.take_revocations().is_empty(), "nothing over the budget is out");
        // Usage grows: the budget shrinks and the newest credentials beyond it are revoked at the reading.
        hub.set_cf_usage(Ok(900_000_000_000), Instant::now());
        let shrunk = hub.cf_budget(Instant::now());
        assert_eq!(shrunk, 6, "50 GB of room, 300 s to the next reading near the cap");
        let revoked = hub.take_revocations();
        assert_eq!(revoked.len(), budget - shrunk);
        assert!(revoked.iter().all(|c| c.username.parse::<String>().is_ok()));
        assert!(revoked.iter().any(|c| c.username == "u83") && !revoked.iter().any(|c| c.username == "u0"), "the newest go first");
        // At the hard cap every credential still out is revoked, and none is minted.
        hub.set_cf_usage(Ok(950_000_000_000), Instant::now());
        assert_eq!(hub.take_revocations().len(), shrunk);
        assert_eq!(hub.cf_out(), 0);
        assert!(!cf_warm_mint(&mut hub, 1_000, None));
        assert_eq!(hub.counters.cf_revoked, budget as u64);
        // A revoked warm credential is not handed back by a reclaim.
        assert!(hub.cf.as_ref().unwrap().warm.is_empty());
    }

    #[test]
    fn cloudflare_credentials_are_revoked_when_readings_stop() {
        let start = Instant::now();
        let mut hub = cf_hub(Some(0));
        assert!(cf_warm_mint(&mut hub, 0, None));
        // The analytics API stops answering: the budget shrinks as the reading ages, then every credential goes.
        hub.set_cf_usage(Err("usage: timed out".into()), start + Duration::from_secs(600));
        assert!(hub.take_revocations().is_empty());
        hub.set_cf_usage(Err("usage: timed out".into()), start + Duration::from_secs(3_601));
        let revoked = hub.take_revocations();
        assert_eq!(revoked.len(), 1);
        // A revocation that fails is tried again after the next reading.
        hub.finish_revoke(revoked[0].clone(), false);
        hub.set_cf_usage(Err("usage: timed out".into()), start + Duration::from_secs(3_700));
        assert_eq!(hub.take_revocations().len(), 1);
        hub.set_cf_usage(Err("usage: timed out".into()), start + Duration::from_secs(3_800));
        assert!(hub.take_revocations().is_empty());
    }

    #[test]
    fn cloudflare_credentials_per_address() {
        let mut hub = cf_hub(Some(0));
        let home: IpAddr = "2001:db8:1:2:aaaa::1".parse().unwrap();
        let same_64: IpAddr = "2001:db8:1:2:bbbb::9".parse().unwrap();
        let other: IpAddr = "198.51.100.7".parse().unwrap();
        // 30 an hour from one IPv4 address or one IPv6 /64; another address is not affected.
        let from_home = (0..40).filter(|i| cf_warm_mint(&mut hub, *i, Some(if i % 2 == 0 { home } else { same_64 }))).count();
        assert_eq!(from_home, 30);
        assert!(cf_warm_mint(&mut hub, 100, Some(other)));
        assert_eq!(ip_group(home), ip_group(same_64));
        assert_eq!(ip_group("::ffff:198.51.100.7".parse().unwrap()), other);
    }

    #[test]
    fn one_connection_cannot_hold_the_lock() {
        // Security review 1.0, C2: every message swept every pending grant under the one lock, with no limit.
        let mut hub = hub();
        let (tx, mut rx) = mpsc::channel(1_024);
        let a = hub.join("a".into(), tx).unwrap();
        for _ in 0..600 {
            assert_eq!(hub.handle(a, Msg::RelayRelease { sid: SID.into() }), Outcome::Continue);
        }
        assert_eq!(hub.handle(a, Msg::RelayRelease { sid: SID.into() }), Outcome::Continue);
        assert!(matches!(drain(&mut rx).last(), Some(Msg::Error { code, .. }) if code == "rate_limited"));
        let mut outcome = Outcome::Continue;
        for _ in 0..600 {
            outcome = hub.handle(a, Msg::RelayRelease { sid: SID.into() });
        }
        assert_eq!(outcome, Outcome::Close, "a client that keeps going past twice the limit is closed");
        assert_eq!(hub.counters.messages_dropped, 601);
    }

    #[test]
    fn quiet_nodes_and_expired_grants_are_forgotten() {
        let mut hub = hub();
        for i in 0..50 {
            let (tx, _rx) = mpsc::channel(16);
            let id = hub.join(format!("n{i}"), tx).unwrap();
            hub.handle(id, Msg::Register { ids: vec![RDV.into()] });
            hub.handle(id, Msg::RelayWarm { request: WarmRequest::default() });
            hub.leave(id);
        }
        assert_eq!(hub.grants_per_node.len(), 50);
        hub.sweep(Instant::now() + Duration::from_secs(3_601));
        assert!(hub.grants_per_node.is_empty());
        // Pending grants expire with their lifetime, and a full table refuses new grants instead of growing.
        let mut hub = Hub::new(
            Config::parse("[server]\nlisten='x'\n[limits]\nmax_pending=2\n[[relays]]\nid='bom'\nkind='coturn'\nurls=['turn:a:3478']\nsecret_env='A'\n").unwrap(),
            HashMap::from([("bom".to_string(), b"s1".to_vec())]),
        );
        let (tx, mut rx) = mpsc::channel(16);
        let a = hub.join("a".into(), tx).unwrap();
        hub.handle(a, Msg::Register { ids: vec![RDV.into()] });
        for sid in ["AAAAAAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC"] {
            hub.handle(a, Msg::RelayRequest { rdv: RDV.into(), sid: sid.into(), side: 0, rtts: None, need: None, est_bytes: None, exclude: None });
        }
        assert!(matches!(drain(&mut rx).pop(), Some(Msg::RelayDenied { code, .. }) if code == "pool_exhausted"));
        assert_eq!(hub.pending.len(), 2);
        hub.sweep(Instant::now() + Duration::from_secs(7_201));
        assert!(hub.pending.is_empty());
    }

    #[test]
    fn a_rendezvous_id_holds_a_pair_not_a_crowd() {
        let mut hub = hub();
        let mut held = 0;
        for i in 0..20 {
            let (tx, mut rx) = mpsc::channel(64);
            let id = hub.join(format!("n{i}"), tx).unwrap();
            hub.handle(id, Msg::Register { ids: vec![RDV.into()] });
            if drain(&mut rx).iter().any(|m| matches!(m, Msg::Error { code, .. } if code == "too_many_ids")) {
                assert!(!hub.holds(id, RDV));
            } else {
                held += 1;
            }
        }
        assert_eq!(held, 8);
        assert_eq!(hub.by_rdv[RDV].len(), 8);
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
