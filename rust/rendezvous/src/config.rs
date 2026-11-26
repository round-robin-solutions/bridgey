//! `bridgey-rendezvous.toml`: the one settings file. Only secrets come from the environment.

use serde::Deserialize;
use std::collections::HashMap;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub server: Server,
    #[serde(default)]
    pub limits: Limits,
    #[serde(default)]
    pub relays: Vec<Relay>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Server {
    /// Address the WebSocket and health endpoints listen on, for example `0.0.0.0:8080`.
    pub listen: String,
    /// Read the client address from `X-Real-IP` (set by the host nginx). Off when clients connect directly.
    #[serde(default)]
    pub trust_proxy: bool,
    /// Deployment name shown by `/v1/status` (`production`, `staging`, `local`).
    #[serde(default = "default_environment")]
    pub environment: String,
    /// The host name clients connect to (`connect.roundrobin.in`). A single-flight sign-in signs it, so a
    /// signature made for another service is refused. Unset: no single-flight sign-ins (the challenge only).
    #[serde(default)]
    pub public_host: Option<String>,
}

fn default_environment() -> String {
    "local".into()
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Limits {
    pub max_ids: usize,
    pub sockets_per_node: usize,
    pub signals_per_minute: u32,
    pub grants_per_hour: u32,
    pub connections_per_ip: usize,
    pub max_connections: usize,
    /// Proof-of-work bits asked of every node (0 = off).
    pub pow_bits: u32,
    pub grant_lifetime_s: u64,
    /// How long a node's warm relay credentials last (it re-asks before then).
    pub warm_grant_lifetime_s: u64,
    pub auth_timeout_s: u64,
    /// Messages one connection may send a minute (signals have their own lower limit); past it they are dropped,
    /// and past twice it the connection closes. Every message takes the hub's one lock.
    pub messages_per_minute: u32,
    /// Session grants remembered for the other side's claim, across all nodes; past it new grants are refused.
    pub max_pending: usize,
    /// Connections that may hold one rendezvous ID (a pair is two nodes of at most three sockets each).
    pub sockets_per_rdv: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_ids: 64,
            sockets_per_node: 3,
            signals_per_minute: 120,
            grants_per_hour: 120,
            connections_per_ip: 32,
            max_connections: 20_000,
            pow_bits: 0,
            grant_lifetime_s: 7_200,
            warm_grant_lifetime_s: 43_200,
            auth_timeout_s: 10,
            messages_per_minute: 600,
            max_pending: 100_000,
            sockets_per_rdv: 8,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Relay {
    pub id: String,
    /// `coturn` (TURN REST credentials from the relay's shared secret) or `cloudflare` (Cloudflare Realtime TURN
    /// credentials, minted per grant through Cloudflare's API; docs/connect-anywhere.md section 9.4).
    pub kind: String,
    /// coturn: the URLs clients get. cloudflare: which of the URLs in Cloudflare's answer clients get (the rest are
    /// dropped; a grant with none left counts as a failed mint).
    pub urls: Vec<String>,
    /// coturn: the environment variable holding this relay's `static-auth-secret`.
    #[serde(default)]
    pub secret_env: String,
    /// `host:port` where the relay's STUN answers, for `welcome` (default: the first UDP TURN URL).
    #[serde(default)]
    pub stun: Option<String>,
    #[serde(default)]
    pub penalty_ms: u32,
    #[serde(default = "default_kbps")]
    pub max_kbps: u32,
    /// base64 SHA-256 of the relay's TLS public key, for `turns:` URLs.
    #[serde(default)]
    pub spki: Option<String>,
    #[serde(default = "yes")]
    pub enabled: bool,
    /// kind `cloudflare`: the API, the free-tier caps and where the usage comes from.
    #[serde(default)]
    pub cloudflare: Option<CloudflareSettings>,
}

impl Relay {
    pub fn is_cloudflare(&self) -> bool {
        self.kind == "cloudflare"
    }

    /// `host:port` of the relay's STUN listener: `stun` if set, else the first UDP TURN URL.
    pub fn stun(&self) -> Option<String> {
        if let Some(stun) = self.stun.as_ref().filter(|s| !s.is_empty()) {
            return Some(stun.clone());
        }
        self.urls.iter().find_map(|u| {
            let rest = u.strip_prefix("turn:")?;
            let (hostport, query) = rest.split_once('?').unwrap_or((rest, ""));
            if !query.is_empty() && query != "transport=udp" {
                return None;
            }
            Some(if hostport.rsplit_once(':').is_some_and(|(h, _)| !h.ends_with(']') || h.starts_with('[')) && !hostport.ends_with(']') { hostport.to_string() } else { format!("{hostport}:3478") })
        })
    }
}

/// A Cloudflare Realtime TURN relay: secrets from the environment, the rest here. Cloudflare's free tier is
/// 1,000 GB a month; grants stop at `hard_gb` (and Cloudflare stops being the first choice at `soft_gb`), so the
/// account never pays for relay traffic.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct CloudflareSettings {
    /// Environment variable with the TURN key ID.
    pub key_id_env: String,
    /// Environment variable with the TURN key's API token (a bearer token for `rtc.live.cloudflare.com`).
    pub token_env: String,
    /// Environment variable with the Cloudflare account ID (for the usage query).
    pub account_env: String,
    /// Environment variable with an API token that can read the account's analytics (Account Analytics Read).
    pub analytics_token_env: String,
    /// `{api_base}/turn/keys/{keyId}/credentials/generate-ice-servers` mints a grant's credentials.
    pub api_base: String,
    pub graphql_url: String,
    /// Above this many GB in the window, Cloudflare is used only when no own relay can take the session.
    pub soft_gb: u64,
    /// At this many GB in the window, no Cloudflare grants at all (GB = 10^9 bytes, the smaller unit).
    pub hard_gb: u64,
    /// How often the usage is read, and how often once it is past `soft_gb`.
    pub usage_interval_s: u64,
    pub usage_interval_near_s: u64,
    /// A usage reading older than this (the analytics API failing) stops Cloudflare grants until a fresh one.
    pub usage_max_age_s: u64,
    /// 0: the window is the last `window_days` days, which covers any billing month whatever day it starts.
    /// 1 to 28: the window starts on this day of the month, 00:00 UTC (once the billing day is confirmed).
    pub cycle_day: u32,
    pub window_days: u32,
    /// Count bytes sent to Cloudflare too (it bills only what its edge sends to TURN clients).
    pub count_ingress: bool,
    /// A mint that takes longer fails over to the own pool.
    pub mint_timeout_ms: u64,
    /// The rate one credential is assumed to carry when the service works out how many may be out at once (a
    /// client that ignores the 40 Mbit/s pace reaches Cloudflare's own per-allocation limit, 50 to 100 Mbit/s).
    /// 0 turns the budget off.
    pub budget_kbps: u32,
    /// Added to the time until the next usage reading when working out that budget: the analytics delay plus the
    /// life of an allocation after its credential is revoked (it can no longer refresh).
    pub budget_extra_s: u64,
    /// Cloudflare credentials one address (an IPv4 address or an IPv6 /64) may get an hour; past it, the own pool.
    pub mints_per_ip_hour: u32,
}

impl Default for CloudflareSettings {
    fn default() -> Self {
        CloudflareSettings {
            key_id_env: "CF_TURN_KEY_ID".into(),
            token_env: "CF_TURN_API_TOKEN".into(),
            account_env: "CF_ACCOUNT_ID".into(),
            analytics_token_env: "CF_ANALYTICS_TOKEN".into(),
            api_base: "https://rtc.live.cloudflare.com/v1".into(),
            graphql_url: "https://api.cloudflare.com/client/v4/graphql".into(),
            soft_gb: 800,
            hard_gb: 950,
            usage_interval_s: 900,
            usage_interval_near_s: 300,
            usage_max_age_s: 3_600,
            cycle_day: 0,
            window_days: 31,
            count_ingress: false,
            mint_timeout_ms: 3_000,
            budget_kbps: 50_000,
            budget_extra_s: 900,
            mints_per_ip_hour: 30,
        }
    }
}

/// A Cloudflare relay's secrets, read from the environment. Never logged.
#[derive(Clone)]
pub struct CloudflareSecrets {
    pub key_id: String,
    pub token: String,
    /// The usage query needs both; without them the relay is never used (its usage cannot be checked).
    pub account: Option<String>,
    pub analytics_token: Option<String>,
}

impl std::fmt::Debug for CloudflareSecrets {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CloudflareSecrets").field("usage", &(self.account.is_some() && self.analytics_token.is_some())).finish_non_exhaustive()
    }
}

fn default_kbps() -> u32 {
    50_000
}

fn yes() -> bool {
    true
}

impl Config {
    pub fn parse(text: &str) -> Result<Config, String> {
        let mut config: Config = toml::from_str(text).map_err(|e| e.to_string())?;
        let mut cloudflare = 0;
        for relay in &mut config.relays {
            match relay.kind.as_str() {
                "coturn" => {
                    if relay.secret_env.is_empty() {
                        return Err(format!("relay {}: no secret_env", relay.id));
                    }
                    if relay.cloudflare.is_some() {
                        return Err(format!("relay {}: [cloudflare] settings on a coturn relay", relay.id));
                    }
                }
                "cloudflare" => {
                    cloudflare += 1;
                    let settings = relay.cloudflare.get_or_insert_with(CloudflareSettings::default);
                    if settings.soft_gb > settings.hard_gb {
                        return Err(format!("relay {}: soft_gb is above hard_gb", relay.id));
                    }
                    if settings.cycle_day > 28 || (settings.cycle_day == 0 && !(1..=32).contains(&settings.window_days)) {
                        return Err(format!("relay {}: cycle_day must be 0 to 28, window_days 1 to 32", relay.id));
                    }
                }
                other => return Err(format!("relay {}: kind {other} is not supported", relay.id)),
            }
            if relay.urls.is_empty() {
                return Err(format!("relay {}: no urls", relay.id));
            }
        }
        if cloudflare > 1 {
            return Err("at most one relay of kind cloudflare".into());
        }
        Ok(config)
    }

    /// Each enabled coturn relay's secret, read from its environment variable. Relays without one are skipped.
    pub fn secrets(&self, env: impl Fn(&str) -> Option<String>) -> HashMap<String, Vec<u8>> {
        self.relays
            .iter()
            .filter(|r| r.enabled && !r.is_cloudflare())
            .filter_map(|r| env(&r.secret_env).filter(|s| !s.is_empty()).map(|s| (r.id.clone(), s.into_bytes())))
            .collect()
    }

    /// The enabled Cloudflare relay and its secrets, when its TURN key ID and token are set.
    pub fn cloudflare(&self, env: impl Fn(&str) -> Option<String>) -> Option<(Relay, CloudflareSecrets)> {
        let relay = self.relays.iter().find(|r| r.enabled && r.is_cloudflare())?;
        let settings = relay.cloudflare.as_ref()?;
        let get = |name: &str| env(name).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        let secrets = CloudflareSecrets {
            key_id: get(&settings.key_id_env)?,
            token: get(&settings.token_env)?,
            account: get(&settings.account_env),
            analytics_token: get(&settings.analytics_token_env),
        };
        Some((relay.clone(), secrets))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_example() {
        let config = Config::parse(include_str!("../../../server/rendezvous/bridgey-rendezvous.toml")).unwrap();
        assert!(!config.relays.is_empty());
        assert_eq!(config.limits.max_ids, 64);
        let secrets = config.secrets(|name| (name == "TURN_SECRET_BOM").then(|| "x".to_string()));
        assert_eq!(secrets.len(), 1);
        // The Cloudflare relay: free-tier caps by default, used only with its key in the environment.
        let cf = config.relays.iter().find(|r| r.is_cloudflare()).expect("a cloudflare relay");
        let settings = cf.cloudflare.as_ref().unwrap();
        assert_eq!((settings.soft_gb, settings.hard_gb), (800, 950));
        assert_eq!(cf.stun().as_deref(), Some("turn.cloudflare.com:3478"));
        assert!(config.cloudflare(|_| None).is_none());
        let env = |name: &str| ["CF_TURN_KEY_ID", "CF_TURN_API_TOKEN"].contains(&name).then(|| "s3cr3t-value".to_string());
        let (relay, secrets) = config.cloudflare(env).unwrap();
        assert_eq!(relay.id, "cf");
        assert!(secrets.account.is_none() && secrets.analytics_token.is_none());
        assert!(!format!("{secrets:?}").contains("s3cr3t"), "secrets never show in Debug output");
    }

    #[test]
    fn cloudflare_settings_are_checked() {
        let base = "[server]\nlisten='x'\n[[relays]]\nid='cf'\nkind='cloudflare'\nurls=['turn:turn.cloudflare.com:3478?transport=udp']\n";
        let config = Config::parse(base).unwrap();
        assert_eq!(config.relays[0].cloudflare.as_ref().unwrap().hard_gb, 950);
        assert!(Config::parse(&format!("{base}[relays.cloudflare]\nsoft_gb=900\nhard_gb=800\n")).is_err());
        assert!(Config::parse(&format!("{base}[relays.cloudflare]\ncycle_day=31\n")).is_err());
        assert!(Config::parse(&format!("{base}[[relays]]\nid='cf2'\nkind='cloudflare'\nurls=['turn:a']\n")).is_err());
        assert!(Config::parse("[server]\nlisten='x'\n[[relays]]\nid='a'\nkind='coturn'\nurls=['turn:a']\n").is_err(), "coturn needs secret_env");
        assert!(Config::parse("[server]\nlisten='x'\n[[relays]]\nid='a'\nkind='other'\nurls=['turn:a']\nsecret_env='A'\n").is_err());
    }

    #[test]
    fn stun_addresses() {
        let relay = |url: &str| Relay { id: "x".into(), kind: "coturn".into(), urls: vec![url.into()], secret_env: "X".into(), stun: None, penalty_ms: 0, max_kbps: 1, spki: None, enabled: true, cloudflare: None };
        assert_eq!(relay("turn:relay-sg.roundrobin.in:3478?transport=udp").stun().as_deref(), Some("relay-sg.roundrobin.in:3478"));
        assert_eq!(relay("turn:a").stun().as_deref(), Some("a:3478"));
        assert_eq!(relay("turns:a:5349?transport=tcp").stun(), None);
    }

    #[test]
    fn rejects_unknown() {
        assert!(Config::parse("[server]\nlisten='x'\nnope=1").is_err());
    }
}
