//! Keys and trust records on disk, owner-only (0600 files in 0700 folders).

use crate::crypto::{self, SigningKey};
use crate::paths::{mode, write_private, Paths};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

pub struct Keys {
    pub identity: SigningKey,
    pub node: SigningKey,
}

fn load_or_create(path: &std::path::Path) -> Result<SigningKey, String> {
    match std::fs::read(path) {
        Ok(bytes) => {
            if let Some(m) = mode(path) {
                if m & 0o077 != 0 {
                    return Err(format!("{} is readable by others (mode {m:o}); run chmod 600 on it", path.display()));
                }
            }
            SigningKey::from_pkcs8(&bytes).ok_or_else(|| format!("{} is not a P-256 key", path.display()))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let pkcs8 = SigningKey::generate_pkcs8();
            write_private(path, &pkcs8).map_err(|e| format!("{}: {e}", path.display()))?;
            SigningKey::from_pkcs8(&pkcs8).ok_or_else(|| "key".to_string())
        }
        Err(e) => Err(format!("{}: {e}", path.display())),
    }
}

impl Keys {
    pub fn load(paths: &Paths) -> Result<Keys, String> {
        paths.ensure().map_err(|e| format!("{}: {e}", paths.root.display()))?;
        let identity = paths.keys.join("identity.p8");
        // A lost identity with pairings left would make every phone refuse this install: never replace it silently.
        if !identity.exists() && Trust::load_existing(paths)?.is_some_and(|t| !t.peers.is_empty()) {
            return Err(format!("{} is missing but devices are paired; restore it, or pair again after removing state/trust.json", identity.display()));
        }
        Ok(Keys { identity: load_or_create(&identity)?, node: load_or_create(&paths.keys.join("node.p8"))? })
    }

    pub fn identity_public(&self) -> String {
        crypto::b64(&self.identity.public_raw())
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Learned {
    pub port: u16,
    #[serde(default)]
    pub addrs: Vec<Value>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Peer {
    pub device_id: String,
    pub name: String,
    #[serde(default)]
    pub platform: String,
    pub identity_key: String,
    pub paired_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pair_secret: Option<String>,
    #[serde(default)]
    pub learned: Learned,
    #[serde(default)]
    pub last_seen_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_route: Option<String>,
    /// The phone's last `agent.grants` (no secrets), so `bridgey grants` can answer while it is away.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grants: Option<Value>,
    #[serde(default)]
    pub grants_at: u64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Trust {
    pub device_id: String,
    pub created_at: u64,
    #[serde(default)]
    pub peers: BTreeMap<String, Peer>,
}

impl Trust {
    pub fn path(paths: &Paths) -> std::path::PathBuf {
        paths.state.join("trust.json")
    }

    fn load_existing(paths: &Paths) -> Result<Option<Trust>, String> {
        let path = Self::path(paths);
        match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map(Some).map_err(|e| format!("{}: {e}", path.display())),
            Err(_) => Ok(None),
        }
    }

    pub fn load(paths: &Paths) -> Result<Trust, String> {
        let path = Self::path(paths);
        // Pair secrets live here: refuse a file others can read, as for the keys.
        if let Some(m) = mode(&path).filter(|m| m & 0o077 != 0) {
            return Err(format!("{} is readable by others (mode {m:o}); run chmod 600 on it", path.display()));
        }
        match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(|e| format!("{}: {e}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let t = Trust { device_id: crypto::uuid4(), created_at: crate::time::now_ms(), peers: BTreeMap::new() };
                t.save(paths)?;
                Ok(t)
            }
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    pub fn save(&self, paths: &Paths) -> Result<(), String> {
        let path = Self::path(paths);
        write_private(&path, &serde_json::to_vec_pretty(self).expect("trust")).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// A device by ID, ID prefix (at least 4 characters) or name (case-insensitive).
    pub fn find(&self, query: &str) -> Result<&Peer, String> {
        if let Some(p) = self.peers.get(query) {
            return Ok(p);
        }
        let q = query.to_lowercase();
        let matches: Vec<&Peer> = self.peers.values().filter(|p| p.name.to_lowercase() == q || (q.len() >= 4 && p.device_id.starts_with(&q))).collect();
        match matches.len() {
            1 => Ok(matches[0]),
            0 => Err(format!("no paired device called {query}; see bridgey devices")),
            _ => Err(format!("{query} matches more than one device; use its ID from bridgey devices")),
        }
    }
}
