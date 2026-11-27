//! Where Bridgey keeps things on Linux, by the XDG base directory rules.
//!
//! - Pairing data and settings: `$XDG_DATA_HOME/in.roundrobin.bridgey` (folder 0700, files 0600), or
//!   `BRIDGEY_DATA_DIR` for a separate test profile.
//! - Received files: the XDG Download folder plus `Bridgey` (Settings > Sharing > Files changes it).
//! - Caches (notification icons, update downloads, the ring sound): `$XDG_CACHE_HOME/in.roundrobin.bridgey`.

use std::path::{Path, PathBuf};

use crate::edition;

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn xdg(var: &str, fallback: &str) -> PathBuf {
    match std::env::var_os(var).map(PathBuf::from) {
        Some(p) if p.is_absolute() => p,
        _ => home().join(fallback),
    }
}

/// A test profile: its own pairing data, never the autostart entry, the app menu or the file manager actions, and
/// its own single instance.
pub fn separate_profile() -> Option<PathBuf> {
    std::env::var_os("BRIDGEY_DATA_DIR").filter(|v| !v.is_empty()).map(PathBuf::from)
}

pub fn is_separate_profile() -> bool {
    separate_profile().is_some()
}

pub fn data_dir() -> PathBuf {
    separate_profile().unwrap_or_else(|| xdg("XDG_DATA_HOME", ".local/share").join(edition::APP_ID))
}

pub fn cache_dir() -> PathBuf {
    match separate_profile() {
        Some(p) => p.join("cache"),
        None => xdg("XDG_CACHE_HOME", ".cache").join(edition::APP_ID),
    }
}

pub fn config_home() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config")
}

pub fn data_home() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share")
}

/// Makes a private folder (0700) and returns it.
pub fn private_dir(path: &Path) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(path.to_path_buf())
}

/// The XDG Download folder from `user-dirs.dirs` (`XDG_DOWNLOAD_DIR="$HOME/Downloads"`), else ~/Downloads.
pub fn download_dir() -> PathBuf {
    let file = config_home().join("user-dirs.dirs");
    if let Ok(text) = std::fs::read_to_string(file) {
        if let Some(dir) = parse_user_dirs(&text, "XDG_DOWNLOAD_DIR", &home()) {
            return dir;
        }
    }
    home().join("Downloads")
}

/// One entry of `user-dirs.dirs`: `KEY="$HOME/Folder"` or an absolute path. Nothing for `$HOME` itself (the spec's
/// way of turning a folder off) or anything else.
pub fn parse_user_dirs(text: &str, key: &str, home: &Path) -> Option<PathBuf> {
    for line in text.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix(key).and_then(|r| r.trim_start().strip_prefix('=')) else { continue };
        let value = rest.trim().trim_matches('"');
        let path = if let Some(tail) = value.strip_prefix("$HOME") {
            let tail = tail.trim_start_matches('/');
            if tail.is_empty() {
                return None;
            }
            home.join(tail)
        } else if value.starts_with('/') {
            PathBuf::from(value)
        } else {
            return None;
        };
        return Some(path);
    }
    None
}

/// Where received files go when Settings names no folder.
pub fn default_receive_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("BRIDGEY_RECEIVE_DIR").filter(|v| !v.is_empty()) {
        return PathBuf::from(dir);
    }
    download_dir().join("Bridgey")
}

/// The AppImage this process runs from (the runtime sets `APPIMAGE`), else the executable itself.
pub fn launcher() -> PathBuf {
    if let Some(p) = std::env::var_os("APPIMAGE").filter(|v| !v.is_empty()) {
        return PathBuf::from(p);
    }
    std::env::current_exe().unwrap_or_else(|_| PathBuf::from("bridgey-linux"))
}

/// The files that came with the app: the AppImage's `usr/share/bridgey`, or `linux/data` in a source checkout.
pub fn resources() -> PathBuf {
    if let Some(dir) = std::env::var_os("BRIDGEY_RESOURCES").filter(|v| !v.is_empty()) {
        return PathBuf::from(dir);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(bin) = exe.parent() {
            let installed = bin.join("../share/bridgey");
            if installed.is_dir() {
                return installed;
            }
        }
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("data")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_dirs_follow_the_spec() {
        let home = Path::new("/home/a");
        let text = "# comment\nXDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_DOWNLOAD_DIR=\"$HOME/Загрузки\"\n";
        assert_eq!(parse_user_dirs(text, "XDG_DOWNLOAD_DIR", home), Some(PathBuf::from("/home/a/Загрузки")));
        assert_eq!(parse_user_dirs("XDG_DOWNLOAD_DIR=\"/data/dl\"", "XDG_DOWNLOAD_DIR", home), Some(PathBuf::from("/data/dl")));
        assert_eq!(parse_user_dirs("XDG_DOWNLOAD_DIR=\"$HOME/\"", "XDG_DOWNLOAD_DIR", home), None, "$HOME means off");
        assert_eq!(parse_user_dirs("XDG_DOWNLOAD_DIR=\"relative\"", "XDG_DOWNLOAD_DIR", home), None);
        assert_eq!(parse_user_dirs("XDG_DESKTOP_DIR=\"$HOME/Desktop\"", "XDG_DOWNLOAD_DIR", home), None);
    }
}
