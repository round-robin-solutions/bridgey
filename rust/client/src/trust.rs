//! This device's identity and the devices it trusts, kept through a storage the host provides (Credential
//! Locker or DPAPI on Windows, the Keychain on iOS), as two values: `identity` and `trust`.
//!
//! A trusted device is pinned to the identity key it confirmed with and to protocol 2: a later session that
//! confirms with another key is refused, and only a new pairing with a code replaces the pin.

use crate::crypto::{self, SigningKey};
use crate::features::FeatureMap;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

/// Where the identity and the trusted devices are kept. Called from the client's own threads.
pub trait Storage: Send + Sync {
    fn load(&self, key: &str) -> Result<Option<Vec<u8>>, String>;
    fn store(&self, key: &str, value: &[u8]) -> Result<(), String>;
    fn remove(&self, key: &str) -> Result<(), String>;
}

/// Nothing survives the process: tests and throwaway peers.
#[derive(Default)]
pub struct MemoryStorage(Mutex<HashMap<String, Vec<u8>>>);

impl Storage for MemoryStorage {
    fn load(&self, key: &str) -> Result<Option<Vec<u8>>, String> {
        Ok(self.0.lock().unwrap().get(key).cloned())
    }
    fn store(&self, key: &str, value: &[u8]) -> Result<(), String> {
        self.0.lock().unwrap().insert(key.into(), value.to_vec());
        Ok(())
    }
    fn remove(&self, key: &str) -> Result<(), String> {
        self.0.lock().unwrap().remove(key);
        Ok(())
    }
}

/// Owner-only files in a directory (Linux, and hosts without a secure store).
pub struct FileStorage {
    dir: PathBuf,
}

impl FileStorage {
    pub fn new(dir: impl Into<PathBuf>) -> Result<FileStorage, String> {
        let dir = dir.into();
        std::fs::create_dir_all(&dir).map_err(|e| format!("data folder: {e}"))?;
        Ok(FileStorage { dir })
    }

    fn path(&self, key: &str) -> Result<PathBuf, String> {
        if key.is_empty() || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
            return Err("bad storage key".into());
        }
        Ok(self.dir.join(format!("{key}.json")))
    }
}

impl Storage for FileStorage {
    fn load(&self, key: &str) -> Result<Option<Vec<u8>>, String> {
        match std::fs::read(self.path(key)?) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.to_string()),
        }
    }

    fn store(&self, key: &str, value: &[u8]) -> Result<(), String> {
        let path = self.path(key)?;
        let tmp = path.with_extension("tmp");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        {
            use std::io::Write;
            let mut file = options.open(&tmp).map_err(|e| e.to_string())?;
            file.write_all(value).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
        }
        std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
    }

    fn remove(&self, key: &str) -> Result<(), String> {
        match std::fs::remove_file(self.path(key)?) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
            _ => Ok(()),
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IdentityRecord {
    version: u32,
    device_id: String,
    /// Base64 PKCS#8 of the P-256 signing key.
    pkcs8: String,
}

pub struct Identity {
    pub device_id: String,
    pub key: SigningKey,
    /// Base64 of the uncompressed public point, as `identityKey` carries it.
    pub public: String,
}

impl Identity {
    /// The stored identity, or a new one (a random device ID and signing key) saved first.
    pub fn load_or_create(storage: &dyn Storage) -> Result<Identity, String> {
        if let Some(bytes) = storage.load("identity")? {
            let record: IdentityRecord = serde_json::from_slice(&bytes).map_err(|_| "stored identity is unreadable".to_string())?;
            let pkcs8 = crypto::unb64(&record.pkcs8).ok_or("stored identity is unreadable")?;
            let key = SigningKey::from_pkcs8(&pkcs8).ok_or("stored identity is unreadable")?;
            if !crypto::is_uuid(&record.device_id) {
                return Err("stored identity is unreadable".into());
            }
            let public = crypto::b64(&key.public_raw());
            return Ok(Identity { device_id: record.device_id.to_ascii_lowercase(), key, public });
        }
        let pkcs8 = SigningKey::generate_pkcs8();
        let record = IdentityRecord { version: 1, device_id: crypto::uuid4(), pkcs8: crypto::b64(&pkcs8) };
        storage.store("identity", &serde_json::to_vec(&record).unwrap())?;
        let key = SigningKey::from_pkcs8(&pkcs8).ok_or("new identity")?;
        let public = crypto::b64(&key.public_raw());
        Ok(Identity { device_id: record.device_id, key, public })
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KnownAddress {
    pub host: String,
    pub port: u16,
    /// `discovery` (a hint), `outbound` or `inbound` (a connection there authenticated).
    pub source: String,
    pub last_seen_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedDevice {
    pub device_id: String,
    pub name: String,
    #[serde(default)]
    pub platform: Option<String>,
    /// The pinned identity key (base64 uncompressed P-256 point).
    pub identity_key: String,
    /// Always 2: this client pairs only on protocol 2, and a device paired on it is pinned to it.
    pub protocol: u32,
    pub paired_at_ms: u64,
    #[serde(default)]
    pub last_connected_ms: Option<u64>,
    /// Most recent first, at most four.
    #[serde(default)]
    pub addresses: Vec<KnownAddress>,
    /// This device's own switches for that device (per-device grants). Missing keys use the client's defaults.
    #[serde(default)]
    pub features: HashMap<String, bool>,
    /// Connect away from home: the pair secret both devices derived with connect.setup (standard base64).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pair_secret: Option<String>,
    /// The device's own addresses and UDP port from connect.addresses, for direct tunnels.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub learned_port: Option<u16>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub learned: Vec<LearnedAddress>,
}

/// One of a device's own addresses (connect.addresses): an IP, `lan`, `vpn` or `public6`, and the VPN's name.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct LearnedAddress {
    pub a: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vpn: Option<String>,
}

/// The Connect anywhere node's key (P-256), separate from the identity: the control service sees only this one.
pub fn node_key(storage: &dyn Storage) -> Result<SigningKey, String> {
    if let Some(bytes) = storage.load("node")? {
        let pkcs8 = crypto::unb64(std::str::from_utf8(&bytes).map_err(|_| "stored node key is unreadable")?).ok_or("stored node key is unreadable")?;
        return SigningKey::from_pkcs8(&pkcs8).ok_or_else(|| "stored node key is unreadable".to_string());
    }
    let pkcs8 = SigningKey::generate_pkcs8();
    storage.store("node", crypto::b64(&pkcs8).as_bytes())?;
    SigningKey::from_pkcs8(&pkcs8).ok_or_else(|| "new node key".to_string())
}

pub const ADDRESSES_PER_DEVICE: usize = 4;

impl TrustedDevice {
    pub fn remember(&mut self, address: KnownAddress) {
        self.addresses.retain(|a| !(a.host == address.host && a.port == address.port));
        self.addresses.insert(0, address);
        self.addresses.truncate(ADDRESSES_PER_DEVICE);
    }

    /// The local policy for this device: defaults overlaid with its own switches.
    pub fn policy(&self, defaults: &FeatureMap) -> FeatureMap {
        let mut map = defaults.clone();
        for (key, on) in &self.features {
            map.set(key, *on);
        }
        map
    }
}

#[derive(Serialize, Deserialize, Default)]
struct TrustRecord {
    version: u32,
    devices: Vec<TrustedDevice>,
}

/// The trusted devices, saved after every change.
pub struct TrustStore {
    devices: Vec<TrustedDevice>,
}

impl TrustStore {
    pub fn load(storage: &dyn Storage) -> Result<TrustStore, String> {
        let devices = match storage.load("trust")? {
            None => Vec::new(),
            Some(bytes) => {
                let record: TrustRecord = serde_json::from_slice(&bytes).map_err(|_| "stored trust is unreadable".to_string())?;
                record
                    .devices
                    .into_iter()
                    .filter(|d| crypto::is_uuid(&d.device_id) && d.protocol >= 2)
                    .map(|mut d| {
                        d.device_id = d.device_id.to_ascii_lowercase();
                        d
                    })
                    .collect()
            }
        };
        Ok(TrustStore { devices })
    }

    pub fn save(&self, storage: &dyn Storage) -> Result<(), String> {
        let record = TrustRecord { version: 1, devices: self.devices.clone() };
        storage.store("trust", &serde_json::to_vec(&record).unwrap())
    }

    pub fn get(&self, device_id: &str) -> Option<&TrustedDevice> {
        self.devices.iter().find(|d| d.device_id.eq_ignore_ascii_case(device_id))
    }

    pub fn get_mut(&mut self, device_id: &str) -> Option<&mut TrustedDevice> {
        self.devices.iter_mut().find(|d| d.device_id.eq_ignore_ascii_case(device_id))
    }

    pub fn all(&self) -> &[TrustedDevice] {
        &self.devices
    }

    /// Adds or replaces (a new pairing with a code replaces the pin and keeps the device's switches).
    pub fn put(&mut self, mut device: TrustedDevice) {
        if let Some(old) = self.get(&device.device_id) {
            for (k, v) in &old.features {
                device.features.entry(k.clone()).or_insert(*v);
            }
            for a in old.addresses.clone().into_iter().rev() {
                if !device.addresses.iter().any(|x| x.host == a.host && x.port == a.port) {
                    device.addresses.push(a);
                }
            }
            device.addresses.truncate(ADDRESSES_PER_DEVICE);
            // A pairing again with the same identity keeps Connect away from home; a new identity sets it up again.
            if old.identity_key == device.identity_key && device.pair_secret.is_none() {
                device.pair_secret = old.pair_secret.clone();
                device.learned_port = old.learned_port;
                device.learned = old.learned.clone();
            }
        }
        self.devices.retain(|d| !d.device_id.eq_ignore_ascii_case(&device.device_id));
        self.devices.push(device);
    }

    pub fn remove(&mut self, device_id: &str) -> bool {
        let before = self.devices.len();
        self.devices.retain(|d| !d.device_id.eq_ignore_ascii_case(device_id));
        before != self.devices.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_created_once_and_reloaded() {
        let storage = MemoryStorage::default();
        let a = Identity::load_or_create(&storage).unwrap();
        let b = Identity::load_or_create(&storage).unwrap();
        assert_eq!(a.device_id, b.device_id);
        assert_eq!(a.public, b.public);
        assert!(crypto::is_uuid(&a.device_id));
    }

    #[test]
    fn unreadable_identity_is_an_error_not_a_new_identity() {
        let storage = MemoryStorage::default();
        storage.store("identity", b"{}").unwrap();
        assert!(Identity::load_or_create(&storage).is_err());
    }

    #[test]
    fn trust_round_trips_and_repairing_keeps_switches() {
        let storage = MemoryStorage::default();
        let mut store = TrustStore::load(&storage).unwrap();
        let id = crypto::uuid4();
        let device = |key: &str| TrustedDevice {
            device_id: id.clone(),
            name: "Phone".into(),
            platform: Some("android".into()),
            identity_key: key.into(),
            protocol: 2,
            paired_at_ms: 1,
            last_connected_ms: None,
            addresses: vec![],
            features: HashMap::new(),
            pair_secret: None,
            learned_port: None,
            learned: vec![],
        };
        store.put(device("k1"));
        store.get_mut(&id).unwrap().features.insert("clipboard".into(), false);
        store.save(&storage).unwrap();
        let mut again = TrustStore::load(&storage).unwrap();
        assert_eq!(again.get(&id).unwrap().identity_key, "k1");
        again.put(device("k2"));
        assert_eq!(again.get(&id).unwrap().identity_key, "k2");
        assert_eq!(again.get(&id).unwrap().features.get("clipboard"), Some(&false));
        assert!(again.remove(&id));
        assert!(again.get(&id).is_none());
    }

    #[test]
    fn addresses_are_most_recent_first_and_bounded() {
        let mut d = TrustedDevice {
            device_id: crypto::uuid4(),
            name: String::new(),
            platform: None,
            identity_key: String::new(),
            protocol: 2,
            paired_at_ms: 0,
            last_connected_ms: None,
            addresses: vec![],
            features: HashMap::new(),
            pair_secret: None,
            learned_port: None,
            learned: vec![],
        };
        for i in 0..6 {
            d.remember(KnownAddress { host: format!("10.0.0.{i}"), port: 42458, source: "outbound".into(), last_seen_ms: i });
        }
        d.remember(KnownAddress { host: "10.0.0.3".into(), port: 42458, source: "inbound".into(), last_seen_ms: 9 });
        assert_eq!(d.addresses.len(), ADDRESSES_PER_DEVICE);
        assert_eq!(d.addresses[0].host, "10.0.0.3");
    }

    #[test]
    fn file_storage_is_owner_only() {
        let dir = std::env::temp_dir().join(format!("bridgey-client-test-{}", crypto::uuid4()));
        let storage = FileStorage::new(&dir).unwrap();
        storage.store("trust", b"{}").unwrap();
        assert_eq!(storage.load("trust").unwrap().unwrap(), b"{}");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.join("trust.json")).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert!(storage.store("../x", b"").is_err());
        storage.remove("trust").unwrap();
        assert!(storage.load("trust").unwrap().is_none());
        let _ = std::fs::remove_dir_all(dir);
    }
}
