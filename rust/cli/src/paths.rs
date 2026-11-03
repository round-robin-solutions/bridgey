//! One folder for everything: `~/.config/bridgey/` (`$XDG_CONFIG_HOME/bridgey`), the same path on macOS.
//! A profile (`--profile`, `BRIDGEY_PROFILE`) is its own folder under `profiles/`, so its own paired device.
//!
//! ```text
//! config.toml            settings (0600)
//! keys/identity.p8       P-256 identity key, PKCS#8 (0600, folder 0700)
//! keys/node.p8           P-256 node key for the control service (0600)
//! state/trust.json       this device's ID, paired devices, pinned keys, pair secrets (0600)
//! state/core.json        what the Connect anywhere core keeps between runs (relay round trips)
//! state/asks.json        open questions (IDs and expiries, never answers)
//! state/audit.jsonl      this install's audit log (0600, 10 MB x 5)
//! state/daemon.log       the background agent's log (no message text, codes or clipboard)
//! run/daemon.sock        the agent socket (0600, folder 0700, peer user checked)
//! ```

use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct Paths {
    pub profile: String,
    pub root: PathBuf,
    pub config: PathBuf,
    pub keys: PathBuf,
    pub state: PathBuf,
    pub run: PathBuf,
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

pub fn valid_profile(name: &str) -> bool {
    !name.is_empty() && name.len() <= 32 && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

impl Paths {
    pub fn resolve(profile: Option<&str>) -> Result<Paths, String> {
        let profile = profile.map(str::to_string).or_else(|| std::env::var("BRIDGEY_PROFILE").ok()).filter(|p| !p.is_empty()).unwrap_or_else(|| "default".into());
        if !valid_profile(&profile) {
            return Err(format!("profile names use letters, digits, - and _ (got {profile})"));
        }
        let base = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).unwrap_or_else(|| home().join(".config")).join("bridgey");
        let root = if profile == "default" { base } else { base.join("profiles").join(&profile) };
        let config = std::env::var_os("BRIDGEY_CONFIG").map(PathBuf::from).unwrap_or_else(|| root.join("config.toml"));
        // Inside the config folder on every system: a cron job or an ssh command without XDG_RUNTIME_DIR finds
        // the same socket as the systemd service.
        let run = root.join("run");
        Ok(Paths { profile, keys: root.join("keys"), state: root.join("state"), config, run, root })
    }

    pub fn socket(&self) -> PathBuf {
        self.run.join("daemon.sock")
    }

    pub fn ensure(&self) -> std::io::Result<()> {
        for dir in [&self.root, &self.keys, &self.state, &self.run] {
            private_dir(dir)?;
        }
        Ok(())
    }
}

/// A folder only its owner can enter (0700), created if missing; an existing one is tightened.
pub fn private_dir(dir: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    let mode = fs::metadata(dir)?.permissions().mode() & 0o777;
    if mode != 0o700 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Writes a file only its owner can read (0600), atomically: a temporary file in the same folder, then rename.
pub fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(".{}.tmp{}", path.file_name().and_then(|n| n.to_str()).unwrap_or("file"), std::process::id()));
    {
        let mut f = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    fs::rename(&tmp, path)
}

/// The permission bits of a file, if it exists.
pub fn mode(path: &Path) -> Option<u32> {
    fs::metadata(path).ok().map(|m| m.permissions().mode() & 0o777)
}
