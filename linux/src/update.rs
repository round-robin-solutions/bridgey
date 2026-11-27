//! Self-update, the Windows way (rust/client/src/update.rs): the edition's channel feed (`linux` entry), then the
//! AppImage's size, SHA-256 and the release key's Ed25519 signature checked before anything is replaced, and only
//! when the person says Install. The new AppImage replaces the old file in place (same folder, then an atomic rename),
//! and Bridgey restarts from it. Outside an AppImage (a source build or a distribution package) Bridgey only says
//! that a new version exists.

use std::io::Read;
use std::path::{Path, PathBuf};

use bridgey_core::update::{self, Offer};

use crate::edition;
use crate::paths;

#[derive(Clone, Debug)]
pub struct Source {
    pub feed_base: String,
    pub trusted_prefix: String,
    pub public_key: String,
    pub arch: &'static str,
    pub current_build: u64,
}

pub fn arch() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "aarch64",
        _ => "x86_64",
    }
}

/// The edition's feeds, download prefix and release key. A test profile may point all three at a local server; a
/// normal install never reads these overrides.
pub fn source() -> Source {
    let env = |name: &str, fallback: &str| -> String {
        if paths::is_separate_profile() {
            if let Ok(v) = std::env::var(name) {
                if !v.is_empty() {
                    return v;
                }
            }
        }
        fallback.to_string()
    };
    Source {
        feed_base: env("BRIDGEY_UPDATE_FEED_BASE", edition::UPDATE_FEED_BASE),
        trusted_prefix: env("BRIDGEY_UPDATE_TRUSTED_PREFIX", edition::UPDATE_ASSET_PREFIX),
        public_key: env("BRIDGEY_UPDATE_PUBLIC_KEY", edition::UPDATE_PUBLIC_KEY),
        arch: arch(),
        current_build: env("BRIDGEY_UPDATE_CURRENT_BUILD", "").parse().unwrap_or(edition::BUILD_NUMBER),
    }
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(std::time::Duration::from_secs(600)))
        .timeout_connect(Some(std::time::Duration::from_secs(15)))
        .user_agent(format!("Bridgey-Linux/{}", edition::VERSION_NAME))
        .build()
        .into()
}

/// Asks the channel's feed (blocking: call it off the main loop).
pub fn check(src: &Source, channel: &str) -> Result<Option<Offer>, String> {
    let url = format!("{}/{}.json", src.feed_base.trim_end_matches('/'), channel);
    let mut res = agent().get(&url).call().map_err(|e| e.to_string())?;
    let feed = res.body_mut().with_config().limit(1024 * 1024).read_to_string().map_err(|e| e.to_string())?;
    update::check_platform(&feed, "linux", edition::APP_ID, channel, src.arch, src.current_build, &src.trusted_prefix)
}

/// The running AppImage, when Bridgey can replace it: a file in a folder this user can write to.
pub fn installable() -> Option<PathBuf> {
    let path = PathBuf::from(std::env::var_os("APPIMAGE").filter(|v| !v.is_empty())?);
    let dir = path.parent()?;
    let probe = dir.join(format!(".bridgey-write-test-{}", std::process::id()));
    std::fs::write(&probe, b"").ok()?;
    let _ = std::fs::remove_file(probe);
    path.is_file().then_some(path)
}

/// Downloads the offer into the cache and checks it. `progress(bytes, total)` is called as it goes.
pub fn download(src: &Source, offer: &Offer, progress: &dyn Fn(u64, u64)) -> Result<PathBuf, String> {
    let dir = paths::cache_dir().join("update");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let name = offer.url.rsplit('/').next().filter(|n| !n.is_empty() && !n.contains("..")).unwrap_or("Bridgey.AppImage");
    let path = dir.join(name);
    let mut res = agent().get(&offer.url).call().map_err(|e| e.to_string())?;
    let mut reader = res.body_mut().with_config().limit(update::MAX_SIZE + 1).reader();
    let mut file = std::fs::File::create(&path).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; 256 * 1024];
    let mut got = 0u64;
    loop {
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        got += n as u64;
        if got > offer.size {
            return Err("the download is larger than the feed says".into());
        }
        std::io::Write::write_all(&mut file, &buf[..n]).map_err(|e| e.to_string())?;
        progress(got, offer.size);
    }
    drop(file);
    update::verify_file(&path, &offer.sha256, offer.size, &offer.signature, &src.public_key).map_err(str::to_string)?;
    Ok(path)
}

/// Puts a checked AppImage in place of `target`: copied beside it, made executable, then renamed over it.
pub fn install(download: &Path, target: &Path) -> Result<(), String> {
    let dir = target.parent().ok_or("no folder")?;
    let staged = dir.join(format!(".{}.new", target.file_name().and_then(|n| n.to_str()).unwrap_or("Bridgey.AppImage")));
    std::fs::copy(download, &staged).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    }
    std::fs::rename(&staged, target).map_err(|e| {
        let _ = std::fs::remove_file(&staged);
        e.to_string()
    })?;
    let _ = std::fs::remove_file(download);
    Ok(())
}

/// Whether a check is due when Bridgey opens: at most every six hours.
pub fn due(last_check: u64, now: u64) -> bool {
    now.saturating_sub(last_check) >= 6 * 3600
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checks_wait_six_hours() {
        assert!(due(0, 1_800_000_000));
        assert!(!due(1_800_000_000, 1_800_000_000 + 3600));
        assert!(due(1_800_000_000, 1_800_000_000 + 6 * 3600));
    }

    #[test]
    fn install_replaces_the_file_in_place() {
        let dir = std::env::temp_dir().join(format!("bridgey-install-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("Bridgey.AppImage");
        std::fs::write(&target, b"old").unwrap();
        let download = dir.join("new.AppImage");
        std::fs::write(&download, b"new").unwrap();
        install(&download, &target).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        assert!(!download.exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o755);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
