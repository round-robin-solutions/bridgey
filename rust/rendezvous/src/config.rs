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
    pub auth_timeout_s: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_ids: 64,
            sockets_per_node: 3,
            signals_per_minute: 120,
            grants_per_hour: 30,
            connections_per_ip: 32,
            max_connections: 20_000,
            pow_bits: 0,
            grant_lifetime_s: 7_200,
            auth_timeout_s: 10,
        }
    }
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Relay {
    pub id: String,
    /// `coturn` (TURN REST credentials). `cloudflare` is reserved for phase 3.
    pub kind: String,
    pub urls: Vec<String>,
    /// Environment variable holding this relay's `static-auth-secret`.
    pub secret_env: String,
    #[serde(default)]
    pub penalty_ms: u32,
    #[serde(default = "default_kbps")]
    pub max_kbps: u32,
    /// base64 SHA-256 of the relay's TLS public key, for `turns:` URLs.
    #[serde(default)]
    pub spki: Option<String>,
    #[serde(default = "yes")]
    pub enabled: bool,
}

fn default_kbps() -> u32 {
    50_000
}

fn yes() -> bool {
    true
}

impl Config {
    pub fn parse(text: &str) -> Result<Config, String> {
        let config: Config = toml::from_str(text).map_err(|e| e.to_string())?;
        for relay in &config.relays {
            if relay.kind != "coturn" {
                return Err(format!("relay {}: kind {} is not supported yet", relay.id, relay.kind));
            }
            if relay.urls.is_empty() {
                return Err(format!("relay {}: no urls", relay.id));
            }
        }
        Ok(config)
    }

    /// Each enabled relay's secret, read from its environment variable. Relays without one are skipped.
    pub fn secrets(&self, env: impl Fn(&str) -> Option<String>) -> HashMap<String, Vec<u8>> {
        self.relays
            .iter()
            .filter(|r| r.enabled)
            .filter_map(|r| env(&r.secret_env).filter(|s| !s.is_empty()).map(|s| (r.id.clone(), s.into_bytes())))
            .collect()
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
    }

    #[test]
    fn rejects_unknown() {
        assert!(Config::parse("[server]\nlisten='x'\nnope=1").is_err());
    }
}
