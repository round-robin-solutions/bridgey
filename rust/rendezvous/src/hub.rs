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
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
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
    /// The address group of the connection that made it, for the per-address cap.
    group: Option<IpAddr>,
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
    /// Every credential minted and not yet expired or confirmed revoked, and the mints under way. A credential keeps
    /// working until it expires unless Cloudflare confirms its revocation, so these count against the cap, not just
    /// new mints; one queued for revocation still counts until then. Saved to the state file when there is one.
    outstanding: Vec<CfCredential>,
    in_flight: usize,
    /// Usernames for the socket layer to revoke through Cloudflare's API, and those whose revocation failed (queued
    /// again at the next reading).
    revoke: Vec<String>,
    revoke_retry: Vec<String>,
    /// Cloudflare credentials minted per address group in the last hour.
    per_ip: HashMap<IpAddr, Window>,
    /// After a start without the state file: credentials the previous run may have left, assumed out ([Inherited]).
    inherited: Option<Inherited>,
    /// `outstanding` changed since it was last saved.
    dirty: bool,
}

/// Credentials an earlier run of the service may have handed out, unknown after a restart without the state file:
/// as many as the budget at the first fresh reading, assumed to expire evenly over the warm grant lifetime.
struct Inherited {
    since: Instant,
    span: Duration,
    count: Option<usize>,
}

/// A Cloudflare credential that is out: Cloudflare's username, when it expires, the node it went to, whether it is
/// that node's warm one, and whether its revocation is under way.
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CfCredential {
    pub username: String,
    expiry_unix_s: u64,
    node: String,
    warm: bool,
    minted_unix_s: u64,
    #[serde(default)]
    revoking: bool,
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
    /// Pending grants in the order they expire (a refreshed one leaves a stale entry, skipped), and how many each
    /// address group holds.
    pending_order: VecDeque<(Instant, (String, String))>,
    pending_per_group: HashMap<IpAddr, usize>,
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
    /// Cloudflare grants that went to the own pool because the budget or the address limit was reached; Cloudflare
    /// credentials queued for revocation because usage left no room for them, and revocations Cloudflare confirmed.
    pub cf_over_budget: u64,
    pub cf_revoking: u64,
    pub cf_revoked: u64,
    /// Messages dropped by the per-connection limit; session grants not remembered for a claim (an address group
    /// past its share) and remembered ones dropped to make room.
    pub messages_dropped: u64,
    pub pending_skipped: u64,
    pub pending_evicted: u64,
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
            pending_order: VecDeque::new(),
            pending_per_group: HashMap::new(),
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
            revoke_retry: Vec::new(),
            per_ip: HashMap::new(),
            inherited: None,
            dirty: false,
        });
    }

    /// After a start: the credentials the state file kept (expired ones dropped, revocations under way queued
    /// again), or, without them, the assumption that the previous run left the budget's worth out ([Inherited]).
    pub fn restore_cloudflare(&mut self, saved: Option<Vec<CfCredential>>, now: Instant) {
        let span = Duration::from_secs(self.config.limits.warm_grant_lifetime_s);
        let Some(cf) = self.cf.as_mut() else { return };
        let unix_s = unix_ms() / 1_000;
        match saved {
            Some(list) => {
                cf.outstanding = list.into_iter().filter(|c| c.expiry_unix_s > unix_s).collect();
                cf.revoke = cf.outstanding.iter().filter(|c| c.revoking).map(|c| c.username.clone()).collect();
            }
            None => cf.inherited = Some(Inherited { since: now, span, count: None }),
        }
    }

    /// The credentials to save, when they changed since the last call.
    pub fn cloudflare_to_save(&mut self) -> Option<Vec<CfCredential>> {
        let cf = self.cf.as_mut().filter(|cf| cf.dirty)?;
        cf.dirty = false;
        Some(cf.outstanding.clone())
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
        let fresh = reading.is_ok();
        {
            let Some(cf) = self.cf.as_mut() else { return };
            match reading {
                Ok(bytes) => {
                    cf.usage = Some((bytes, now));
                    cf.usage_error = None;
                }
                Err(e) => cf.usage_error = Some(e),
            }
        }
        // The first fresh reading after a start without the state file sets how many credentials are assumed left.
        let budget = self.cf_budget(now);
        if let (true, Some(budget), Some(cf)) = (fresh, budget, self.cf.as_mut()) {
            if let Some(inherited) = cf.inherited.as_mut().filter(|i| i.count.is_none()) {
                inherited.count = Some(budget);
            }
        }
        self.plan_revocations(now);
    }

    /// How many Cloudflare credentials may be out at once, so that what they can carry before the next reading
    /// (and the revocation it can trigger) stays under the hard cap: the room left under the cap divided by what one
    /// credential can carry in that time. Every credential handed out keeps working until it expires or is revoked,
    /// so this, not the tier alone, is what keeps the free tier from being exceeded. `None` when the budget is off
    /// (`budget_kbps = 0`); 0 without a fresh reading.
    pub fn cf_budget(&self, now: Instant) -> Option<usize> {
        let cf = self.cf.as_ref()?;
        if cf.budget_bytes_per_s == 0 {
            return None;
        }
        let Some((bytes, at)) = cf.usage.filter(|(_, at)| now.saturating_duration_since(*at) <= cf.max_age) else { return Some(0) };
        // Counted from the reading: what credentials out can carry until the next one, plus the extra. A late reading
        // (the analytics API failing) adds the time it is late and the next try (review of PR #67: adding the age to a
        // full interval cut the budget towards the end of every interval).
        let age = now.saturating_duration_since(at);
        let interval = self.cf_poll_interval();
        let to_next = if age < interval { interval } else { age + interval.min(Duration::from_secs(120)) };
        let horizon = to_next + cf.budget_extra;
        let per_credential = cf.budget_bytes_per_s.saturating_mul(horizon.as_secs().max(1));
        Some(usize::try_from(cf.hard_bytes.saturating_sub(bytes) / per_credential).unwrap_or(usize::MAX))
    }

    /// Credentials assumed left by an earlier run ([Inherited]), fewer as time passes.
    fn cf_inherited(&self, now: Instant) -> usize {
        let Some(Inherited { since, span, count }) = self.cf.as_ref().and_then(|cf| cf.inherited.as_ref()) else { return 0 };
        let Some(count) = *count else { return 0 };
        let left = span.saturating_sub(now.saturating_duration_since(*since));
        if span.is_zero() {
            return 0;
        }
        (count as u128 * left.as_millis()).div_ceil(span.as_millis().max(1)) as usize
    }

    /// Credentials out now (unexpired, including those whose revocation is not confirmed), mints under way and
    /// those assumed left by an earlier run.
    fn cf_out(&self, now: Instant) -> usize {
        let Some(cf) = &self.cf else { return 0 };
        let unix_s = unix_ms() / 1_000;
        cf.outstanding.iter().filter(|c| c.expiry_unix_s > unix_s).count() + cf.in_flight + self.cf_inherited(now)
    }

    /// One more Cloudflare credential fits the budget and this address's hourly allowance.
    fn cf_room(&self, ip: Option<IpAddr>, now: Instant) -> bool {
        let Some(cf) = &self.cf else { return false };
        if self.cf_budget(now).is_some_and(|budget| self.cf_out(now) >= budget) {
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

    /// At every reading: credentials a node has replaced (its newest warm credential is another one) with more than an
    /// hour left are revoked whatever the budget, since nothing uses them (an app restart, or a node that came back
    /// with new ones) and they would otherwise hold budget slots for up to 12 hours; a renewal's predecessor, in its
    /// last hour and possibly still under a session, is left to expire. Then, with a fresh reading, the credentials the
    /// budget has no room for, in order: other replaced ones, session credentials, and a node's current warm
    /// credential only if the budget still has no room, the newest first within each (long-held devices before fresh
    /// keys); at the hard cap all of them. A stale reading stops minting and revokes nothing more, and with the budget
    /// off nothing ever is. Failed revocations are tried again.
    fn plan_revocations(&mut self, now: Instant) {
        let Some(budget) = self.cf_budget(now) else { return };
        let inherited = self.cf_inherited(now);
        let unix_s = unix_ms() / 1_000;
        let Some(cf) = self.cf.as_mut() else { return };
        let before = cf.outstanding.len();
        cf.outstanding.retain(|c| c.expiry_unix_s > unix_s);
        cf.dirty |= cf.outstanding.len() != before;
        let retry = std::mem::take(&mut cf.revoke_retry);
        let out: HashSet<&str> = cf.outstanding.iter().map(|c| c.username.as_str()).collect();
        let again: Vec<String> = retry.into_iter().filter(|u| out.contains(u.as_str())).collect();
        cf.revoke.extend(again);
        // Each node's current warm credential is its newest, so this holds after a restart that loaded the state file.
        let mut newest: HashMap<&str, u64> = HashMap::new();
        for c in cf.outstanding.iter().filter(|c| c.warm) {
            let at = newest.entry(c.node.as_str()).or_insert(0);
            *at = (*at).max(c.minted_unix_s);
        }
        let current = |c: &CfCredential| c.warm && newest.get(c.node.as_str()) == Some(&c.minted_unix_s);
        let unused: Vec<String> =
            cf.outstanding.iter().filter(|c| !c.revoking && c.warm && !current(c) && c.expiry_unix_s > unix_s + 3_600).map(|c| c.username.clone()).collect();
        let mut victims: HashSet<String> = unused.into_iter().collect();
        if let Some((bytes, _)) = cf.usage.filter(|(_, at)| now.saturating_duration_since(*at) <= cf.max_age) {
            let live = cf.outstanding.iter().filter(|c| !c.revoking && !victims.contains(&c.username)).count();
            let excess = if bytes >= cf.hard_bytes { live } else { (live + cf.in_flight + inherited).saturating_sub(budget).min(live) };
            // Lower sorts first: replaced, then session, then current warm; the newest first within each.
            let rank = |c: &CfCredential| if !c.warm { 1 } else if current(c) { 2 } else { 0 };
            let mut order: Vec<(u8, u64, String)> = cf
                .outstanding
                .iter()
                .filter(|c| !c.revoking && !victims.contains(&c.username))
                .map(|c| (rank(c), u64::MAX - c.minted_unix_s, c.username.clone()))
                .collect();
            order.sort();
            victims.extend(order.into_iter().take(excess).map(|(_, _, username)| username));
        }
        if victims.is_empty() {
            return;
        }
        for credential in cf.outstanding.iter_mut().filter(|c| victims.contains(&c.username)) {
            credential.revoking = true;
        }
        // A reclaim never hands out a credential being revoked.
        cf.warm.retain(|_, w| !victims.contains(&w.username));
        let mut queued: Vec<String> = victims.into_iter().collect();
        queued.sort();
        self.counters.cf_revoking += queued.len() as u64;
        cf.revoke.extend(queued);
        cf.dirty = true;
    }

    /// Usernames for the socket layer to revoke through Cloudflare's API.
    pub fn take_revocations(&mut self) -> Vec<String> {
        self.cf.as_mut().map(|cf| std::mem::take(&mut cf.revoke)).unwrap_or_default()
    }

    /// A revocation's outcome: a confirmed one stops counting; a failed one still counts and is tried again at the
    /// next reading.
    pub fn finish_revoke(&mut self, username: &str, revoked: bool) {
        let Some(cf) = self.cf.as_mut() else { return };
        if !revoked {
            cf.revoke_retry.push(username.to_string());
            return;
        }
        let before = cf.outstanding.len();
        cf.outstanding.retain(|c| c.username != username);
        if cf.outstanding.len() != before {
            cf.dirty = true;
            self.counters.cf_revoked += 1;
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
            "credentialsOut": self.cf_out(now),
            "budget": self.cf_budget(now).map(|b| b.min(1_000_000)),
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
                cf.outstanding.push(CfCredential {
                    username: m.username.clone(),
                    expiry_unix_s: expiry,
                    node: job.node.clone(),
                    warm: job.rdv.is_none(),
                    minted_unix_s: unix_ms() / 1_000,
                    revoking: false,
                });
                cf.dirty = true;
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
        while self.pending_order.front().is_some_and(|(at, _)| *at <= now) {
            let (_, key) = self.pending_order.pop_front().expect("front");
            if self.pending.get(&key).is_some_and(|p| p.expires <= now) {
                self.forget_pending(&key);
            }
        }
        self.grants_per_node.retain(|_, window| !window.expired(now));
        if let Some(cf) = self.cf.as_mut() {
            let unix_s = unix_ms() / 1_000;
            cf.per_ip.retain(|_, window| !window.expired(now));
            let before = cf.outstanding.len();
            cf.outstanding.retain(|c| c.expiry_unix_s > unix_s);
            cf.dirty |= cf.outstanding.len() != before;
            if cf.inherited.as_ref().is_some_and(|i| now.saturating_duration_since(i.since) >= i.span) {
                cf.inherited = None;
            }
        }
    }

    /// Remembers which relay a session got, for the other side's claim. Only a convenience (a claim without it
    /// chooses again, and ICE pairs relays on different servers), so nothing is refused when it is full: an address
    /// group past its share is not remembered, and the oldest entry makes room for a new one.
    fn remember_pending(&mut self, key: (String, String), relay: String, expires: Instant, group: Option<IpAddr>) {
        if let Some(existing) = self.pending.get_mut(&key) {
            existing.relay = relay;
            existing.expires = expires;
            self.pending_order.push_back((expires, key));
            return;
        }
        let (per_group, max) = (self.config.limits.pending_per_ip, self.config.limits.max_pending);
        if group.is_some_and(|g| self.pending_per_group.get(&g).copied().unwrap_or(0) >= per_group) {
            self.counters.pending_skipped += 1;
            return;
        }
        while self.pending.len() >= max {
            let Some((at, oldest)) = self.pending_order.pop_front() else { break };
            if self.pending.get(&oldest).is_some_and(|p| p.expires == at) {
                self.forget_pending(&oldest);
                self.counters.pending_evicted += 1;
            }
        }
        if let Some(g) = group {
            *self.pending_per_group.entry(g).or_insert(0) += 1;
        }
        self.pending.insert(key.clone(), PendingGrant { relay, expires, group });
        self.pending_order.push_back((expires, key));
        // Refreshed grants leave stale entries behind: compact once they outnumber the live ones.
        if self.pending_order.len() > 2 * self.pending.len() + 1_024 {
            let pending = &self.pending;
            self.pending_order.retain(|(at, k)| pending.get(k).is_some_and(|p| p.expires == *at));
        }
    }

    fn forget_pending(&mut self, key: &(String, String)) {
        let Some(grant) = self.pending.remove(key) else { return };
        if let Some(g) = grant.group {
            if let Some(count) = self.pending_per_group.get_mut(&g) {
                *count -= 1;
                if *count == 0 {
                    self.pending_per_group.remove(&g);
                }
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
        let lifetime = self.config.limits.grant_lifetime_s;
        self.remember_pending(key, relay_id.clone(), now + Duration::from_secs(lifetime), ip);
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
        assert_eq!(cf_hub(Some(850)).cf_poll_interval(), Duration::from_secs(60));

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

    /// Mints a warm credential for an existing connection (a renewal, or the same node again).
    fn cf_warm_again(hub: &mut Hub, id: ConnId, username: &str) {
        hub.handle(id, Msg::RelayWarm { request: WarmRequest::default() });
        for job in hub.take_mints() {
            let ok = Ok(Minted { urls: vec!["turn:turn.cloudflare.com:3478?transport=udp".into()], username: username.into(), credential: "c".into() });
            hub.finish_mint(job, ok, Instant::now());
        }
    }

    #[test]
    fn cloudflare_credentials_out_stay_within_the_budget() {
        // Security review 1.0, C1: unpaired nodes with fresh keys used to get a 12-hour Cloudflare credential each,
        // without limit, and nothing ended them at the hard cap.
        let mut hub = cf_hub(Some(0));
        let now = Instant::now();
        let budget = hub.cf_budget(now).unwrap();
        // 950 GB of room; 100 Mbit/s for 15 minutes to the next reading plus 5 minutes: 15 GB a credential.
        assert_eq!(budget, 63);
        let granted = (0..500).filter(|i| cf_warm_mint(&mut hub, *i, None)).count();
        assert_eq!(granted, budget, "the rest go to the own pool");
        assert_eq!(hub.counters.cf_over_budget, (500 - budget) as u64);
        hub.set_cf_usage(Ok(0), Instant::now());
        assert!(hub.take_revocations().is_empty(), "nothing over the budget is out");
        // Usage grows: the budget shrinks (readings every minute past the soft cap) and the excess is revoked.
        hub.set_cf_usage(Ok(900_000_000_000), Instant::now());
        let shrunk = hub.cf_budget(Instant::now()).unwrap();
        assert_eq!(shrunk, 11, "50 GB of room, 60 s to the next reading plus 5 minutes");
        let revoked = hub.take_revocations();
        assert_eq!(revoked.len(), budget - shrunk);
        // Queued for revocation is not revoked: they still count until Cloudflare confirms, and are not queued twice.
        assert_eq!(hub.cf_out(Instant::now()), budget);
        hub.set_cf_usage(Ok(900_000_000_000), Instant::now());
        assert!(hub.take_revocations().is_empty());
        for name in &revoked {
            hub.finish_revoke(name, true);
        }
        assert_eq!(hub.cf_out(Instant::now()), shrunk);
        assert_eq!(hub.counters.cf_revoked, (budget - shrunk) as u64);
        // At the hard cap every credential still out is revoked, and none is minted.
        hub.set_cf_usage(Ok(950_000_000_000), Instant::now());
        assert_eq!(hub.take_revocations().len(), shrunk);
        assert!(!cf_warm_mint(&mut hub, 1_000, None));
        // A credential being revoked is never handed back by a reclaim.
        assert!(hub.cf.as_ref().unwrap().warm.is_empty());
    }

    /// Sets when a credential was minted and when it expires (Unix seconds), for ordering tests.
    fn cf_set(hub: &mut Hub, username: &str, minted: u64, expiry: u64) {
        let c = hub.cf.as_mut().unwrap().outstanding.iter_mut().find(|c| c.username == username).unwrap();
        c.minted_unix_s = minted;
        c.expiry_unix_s = expiry;
    }

    #[test]
    fn cloudflare_revokes_replaced_credentials_first_and_live_warm_ones_last() {
        // Reviews of PR #67: a node's current warm credential carries its sessions, so it goes last, the newest first
        // (fresh keys before long-held devices); replaced ones with hours left are unused and go at every reading.
        let now_s = unix_ms() / 1_000;
        let mut hub = cf_hub(Some(0));
        let (tx, _rx) = mpsc::channel(64);
        let a = hub.join_with("node-a".into(), tx, &caps(true), None).unwrap();
        let (tx_b, _rx_b) = mpsc::channel(64);
        let b = hub.join_with("node-b".into(), tx_b, &caps(true), None).unwrap();
        hub.handle(a, Msg::Register { ids: vec![RDV.into()] });
        hub.handle(b, Msg::Register { ids: vec![RDV.into()] });
        cf_warm_again(&mut hub, a, "a-restart");
        cf_warm_again(&mut hub, a, "a-renewal");
        cf_warm_again(&mut hub, a, "a-current");
        cf_warm_again(&mut hub, b, "b-current");
        hub.handle(a, Msg::RelayRequest { rdv: RDV.into(), sid: SID.into(), side: 0, rtts: None, need: None, est_bytes: None, exclude: None });
        for job in hub.take_mints() {
            let ok = Ok(Minted { urls: vec!["turn:turn.cloudflare.com:3478?transport=udp".into()], username: "session".into(), credential: "c".into() });
            hub.finish_mint(job, ok, Instant::now());
        }
        // A restart left one with 11 hours; a renewal left one in its last hour; b's device signed in after a's.
        cf_set(&mut hub, "a-restart", now_s - 3_600, now_s + 11 * 3_600);
        cf_set(&mut hub, "a-renewal", now_s - 2 * 3_600, now_s + 1_800);
        cf_set(&mut hub, "a-current", now_s - 600, now_s + 42_000);
        cf_set(&mut hub, "b-current", now_s - 60, now_s + 42_600);
        assert_eq!(hub.cf_out(Instant::now()), 5);
        // Any reading, plenty of room: the unused replaced credential goes; the renewal's predecessor is left to expire.
        hub.set_cf_usage(Ok(0), Instant::now());
        assert_eq!(hub.take_revocations(), vec!["a-restart".to_string()]);
        // 936 GB: room for three (14 GB at 4.5 GB each), four live: the other replaced one goes first.
        hub.set_cf_usage(Ok(936_000_000_000), Instant::now());
        assert_eq!(hub.take_revocations(), vec!["a-renewal".to_string()]);
        // 941 GB: room for two: the session credential.
        hub.set_cf_usage(Ok(941_000_000_000), Instant::now());
        assert_eq!(hub.take_revocations(), vec!["session".to_string()]);
        // 945 GB: room for one: of the current warm credentials, the newest goes (b's), a's long-held one stays.
        hub.set_cf_usage(Ok(945_000_000_000), Instant::now());
        assert_eq!(hub.take_revocations(), vec!["b-current".to_string()]);
        assert_eq!(hub.cf.as_ref().unwrap().warm["node-a"].username, "a-current");
        // 949 GB: no room at all: a's goes too, and its core moves to another relay.
        hub.set_cf_usage(Ok(949_000_000_000), Instant::now());
        assert_eq!(hub.take_revocations(), vec!["a-current".to_string()]);
    }

    #[test]
    fn cloudflare_current_warm_credentials_are_known_after_a_restart() {
        // Review of PR #67: which credential is current lived only in memory, so after a restart every warm credential
        // counted as replaced and live ones went first. The newest per node is current.
        let now_s = unix_ms() / 1_000;
        let mut first = cf_hub(Some(0));
        let (tx, _rx) = mpsc::channel(64);
        let a = first.join_with("node-a".into(), tx, &caps(true), None).unwrap();
        cf_warm_again(&mut first, a, "old");
        cf_warm_again(&mut first, a, "live");
        cf_set(&mut first, "old", now_s - 3_600, now_s + 11 * 3_600);
        cf_set(&mut first, "live", now_s - 60, now_s + 43_000);
        let saved = first.cloudflare_to_save().unwrap();
        let mut restarted = cf_hub(None);
        restarted.restore_cloudflare(Some(saved), Instant::now());
        assert!(restarted.cf.as_ref().unwrap().warm.is_empty(), "no credential is kept on disk, so no reclaim map");
        restarted.set_cf_usage(Ok(0), Instant::now());
        assert_eq!(restarted.take_revocations(), vec!["old".to_string()], "the live one stays");
    }

    #[test]
    fn cloudflare_budget_holds_through_the_interval() {
        // Review of PR #67: the reading's age was added to a full interval, cutting the budget late in each interval.
        let start = Instant::now();
        let hub = cf_hub(Some(0));
        assert_eq!(hub.cf_budget(start), Some(63));
        assert_eq!(hub.cf_budget(start + Duration::from_secs(890)), Some(63));
        // Late (the next reading failed): the time it is late counts.
        assert!(hub.cf_budget(start + Duration::from_secs(1_800)).unwrap() < 63);
    }

    #[test]
    fn cloudflare_readings_that_stop_end_minting_not_sessions() {
        // Review of PR #67: an analytics outage or an expired token used to revoke every credential.
        let start = Instant::now();
        let mut hub = cf_hub(Some(0));
        assert!(cf_warm_mint(&mut hub, 0, None));
        hub.set_cf_usage(Err("usage: timed out".into()), start + Duration::from_secs(3_601));
        assert!(hub.take_revocations().is_empty(), "nothing is revoked");
        assert!(!hub.cf_room(None, start + Duration::from_secs(3_601)), "nothing more is minted");
        assert_eq!(hub.cf_tier(start + Duration::from_secs(3_601), &[]), CfTier::Off);
        // A revocation that fails still counts and is queued again at the next fresh reading.
        hub.set_cf_usage(Ok(950_000_000_000), Instant::now());
        let revoked = hub.take_revocations();
        assert_eq!(revoked.len(), 1);
        hub.finish_revoke(&revoked[0], false);
        assert_eq!(hub.cf_out(Instant::now()), 1);
        hub.set_cf_usage(Ok(950_000_000_000), Instant::now());
        assert_eq!(hub.take_revocations(), revoked);
        hub.finish_revoke(&revoked[0], true);
        assert_eq!(hub.cf_out(Instant::now()), 0);
    }

    #[test]
    fn cloudflare_budget_off_means_no_budget_and_no_revocations() {
        let mut hub = cf_hub(Some(0));
        hub.cf.as_mut().unwrap().budget_bytes_per_s = 0;
        assert_eq!(hub.cf_budget(Instant::now()), None);
        assert_eq!((0..100).filter(|i| cf_warm_mint(&mut hub, *i, None)).count(), 100);
        hub.set_cf_usage(Err("usage: not allowed".into()), Instant::now() + Duration::from_secs(3_601));
        hub.set_cf_usage(Ok(960_000_000_000), Instant::now());
        assert!(hub.take_revocations().is_empty());
    }

    #[test]
    fn cloudflare_credentials_survive_a_restart_or_are_assumed_out() {
        // Review of PR #67: the list was memory only, so after a restart earlier credentials were invisible.
        let start = Instant::now();
        let mut hub = cf_hub(None);
        hub.restore_cloudflare(None, start);
        hub.set_cf_usage(Ok(0), start);
        assert_eq!(hub.cf_out(start), 63, "the budget's worth assumed out");
        assert!(!hub.cf_room(None, start));
        let later = start + Duration::from_secs(6 * 3_600);
        assert_eq!(hub.cf_out(later), 32, "half of them after half the warm grant lifetime");
        hub.set_cf_usage(Ok(0), later);
        assert_eq!(hub.cf_out(later), 32, "a later reading does not change the assumption");
        assert!(hub.cf_room(None, later));
        assert_eq!(hub.cf_out(start + Duration::from_secs(12 * 3_600)), 0);
        // With the state file: what it kept counts, expired entries go, revocations under way are queued again.
        let mut saved = cf_hub(Some(0));
        assert!(cf_warm_mint(&mut saved, 1, None));
        assert!(cf_warm_mint(&mut saved, 2, None));
        saved.set_cf_usage(Ok(949_000_000_000), Instant::now());
        let queued = saved.take_revocations();
        let list = saved.cloudflare_to_save().expect("changed");
        assert!(saved.cloudflare_to_save().is_none(), "saved once per change");
        let text = serde_json::to_string(&list).unwrap();
        assert!(!text.contains("\"credential\""), "no secret in the state file");
        let mut expired = list[0].clone();
        expired.username = "gone".into();
        expired.expiry_unix_s = 1;
        let mut restored = cf_hub(Some(0));
        restored.restore_cloudflare(Some(serde_json::from_str::<Vec<CfCredential>>(&text).unwrap().into_iter().chain([expired]).collect()), Instant::now());
        assert_eq!(restored.cf_out(Instant::now()), 2);
        let mut again = restored.take_revocations();
        again.sort();
        let mut queued = queued;
        queued.sort();
        assert_eq!(again, queued);
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
        // Pending grants expire with their lifetime; a full table makes room by dropping the oldest instead of
        // refusing grants (review of PR #67: fresh keys from a few addresses could fill it for everyone).
        let mut hub = Hub::new(
            Config::parse("[server]\nlisten='x'\n[limits]\nmax_pending=2\npending_per_ip=2\n[[relays]]\nid='bom'\nkind='coturn'\nurls=['turn:a:3478']\nsecret_env='A'\n").unwrap(),
            HashMap::from([("bom".to_string(), b"s1".to_vec())]),
        );
        let request = |hub: &mut Hub, id: ConnId, sid: &str| {
            hub.handle(id, Msg::RelayRequest { rdv: RDV.into(), sid: sid.into(), side: 0, rtts: None, need: None, est_bytes: None, exclude: None });
        };
        let (tx, mut rx) = mpsc::channel(16);
        let a = hub.join("a".into(), tx).unwrap();
        hub.handle(a, Msg::Register { ids: vec![RDV.into()] });
        drain(&mut rx);
        for sid in ["AAAAAAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCC"] {
            request(&mut hub, a, sid);
            assert!(matches!(drain(&mut rx).pop(), Some(Msg::RelayGrantMsg { .. })), "every grant is given");
        }
        assert_eq!(hub.pending.len(), 2);
        assert!(!hub.pending.contains_key(&(RDV.to_string(), "AAAAAAAAAAAAAAAAAAAAAA".to_string())), "the oldest made room");
        assert_eq!(hub.counters.pending_evicted, 1);
        hub.sweep(Instant::now() + Duration::from_secs(7_201));
        assert!(hub.pending.is_empty() && hub.pending_order.is_empty());
        // One address group gets its share; past it grants are still given, just not remembered.
        let ip: IpAddr = "203.0.113.5".parse().unwrap();
        let (tx, mut rx) = mpsc::channel(16);
        let b = hub.join_with("b".into(), tx, &[], Some(ip)).unwrap();
        hub.handle(b, Msg::Register { ids: vec![RDV.into()] });
        drain(&mut rx);
        for sid in ["DDDDDDDDDDDDDDDDDDDDDD", "EEEEEEEEEEEEEEEEEEEEEE", "FFFFFFFFFFFFFFFFFFFFFF"] {
            request(&mut hub, b, sid);
            assert!(matches!(drain(&mut rx).pop(), Some(Msg::RelayGrantMsg { .. })));
        }
        assert_eq!(hub.pending_per_group[&ip], 2);
        assert_eq!(hub.counters.pending_skipped, 1);
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
