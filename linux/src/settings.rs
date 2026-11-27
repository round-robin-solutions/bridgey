//! The app's own settings: settings.json in the data folder, camelCase keys as on Windows. Every setting has a default
//! and a switch in Settings. Pairing data is not here: the session client keeps it in its own files.
//!
//! Upgrades (docs/upgrade-policy.md): keys are only ever added; a missing key reads as its default and an unknown one
//! is ignored; a file that cannot be read gives the defaults and is left on disk for the next build to try.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    /// The name other devices show. Empty uses this computer's host name.
    pub device_name: String,
    pub theme: Theme,
    /// Less motion than the desktop allows; the desktop's own "reduce animation" always applies.
    pub reduce_motion: bool,
    /// Copies on this computer go to connected devices by themselves (as on Windows, off until chosen).
    pub automatic_clipboard: bool,
    /// Clipboard on for devices without their own switch.
    pub clipboard: bool,
    /// Watch and set the clipboard while Bridgey is in the background, where the desktop allows it.
    pub background_clipboard: bool,
    pub start_at_sign_in: bool,
    /// Closing the window keeps Bridgey running (in the tray where the desktop has one).
    pub keep_running: bool,
    /// One-line previews of clipboard text in the activity list.
    pub show_previews: bool,
    pub files: bool,
    /// Empty is Downloads/Bridgey.
    pub receive_folder: String,
    pub file_notifications: bool,
    /// "Send to Bridgey" in Files (Nautilus), Nemo and Dolphin.
    pub file_manager_actions: bool,
    /// Bridgey in the app menu (a .desktop file pointing at this AppImage).
    pub app_menu_entry: bool,
    pub battery: bool,
    pub find_device: bool,
    pub ping: bool,
    pub notifications: bool,
    /// Desktop notifications for phone notifications (off: they only appear in Bridgey).
    pub notification_banners: bool,
    /// Android package names whose notifications show no banner here.
    pub muted_apps: Vec<String>,
    /// Keep phone notifications for seven days (at most 200), in an owner-only file.
    pub notification_history: bool,
    pub codes_from_messages: bool,
    pub codes_from_email: bool,
    pub copy_codes: bool,
    /// Tell the phone when this computer is in use (whether there was input, never what).
    pub share_activity: bool,
    pub links: bool,
    pub open_links_right_away: bool,
    /// The phone's media buttons control what plays here (MPRIS). Off until chosen, as on the Mac and Windows.
    pub media: bool,
    pub connect_away: bool,
    /// stable, beta or nightly. Empty: the channel this build came from.
    pub update_channel: String,
    pub auto_update_check: bool,
    /// Unix seconds of the last check.
    pub last_update_check: u64,
    pub fast_transfers: bool,
    pub setup_done: bool,
}

impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            device_name: String::new(),
            theme: Theme::System,
            reduce_motion: false,
            automatic_clipboard: false,
            clipboard: true,
            background_clipboard: true,
            start_at_sign_in: true,
            keep_running: true,
            show_previews: true,
            files: true,
            receive_folder: String::new(),
            file_notifications: true,
            file_manager_actions: true,
            app_menu_entry: true,
            battery: true,
            find_device: true,
            ping: true,
            notifications: true,
            notification_banners: true,
            muted_apps: Vec::new(),
            notification_history: false,
            codes_from_messages: false,
            codes_from_email: false,
            copy_codes: false,
            share_activity: true,
            links: true,
            open_links_right_away: true,
            media: false,
            connect_away: true,
            update_channel: String::new(),
            auto_update_check: true,
            last_update_check: 0,
            fast_transfers: true,
            setup_done: false,
        }
    }
}

impl AppSettings {
    /// The switches the session client keeps per device, from this computer's defaults (features.update keys).
    pub fn feature_defaults(&self) -> Vec<(&'static str, bool)> {
        vec![
            ("clipboard", self.clipboard),
            ("files", self.files),
            ("battery", self.battery),
            ("find_device", self.find_device),
            ("ping", self.ping),
            ("notifications", self.notifications),
            ("links", self.links),
            ("media", self.media),
        ]
    }

    /// The update channel: the setting, else the one this build came from (a beta build follows Beta).
    pub fn channel(&self, version: &str) -> &'static str {
        match self.update_channel.as_str() {
            "stable" => "stable",
            "beta" => "beta",
            "nightly" => "nightly",
            _ => build_channel(version),
        }
    }

    pub fn receive_dir(&self) -> PathBuf {
        if self.receive_folder.is_empty() {
            crate::paths::default_receive_dir()
        } else {
            PathBuf::from(&self.receive_folder)
        }
    }
}

/// The channel a version name belongs to: 1.0.0 Stable, 1.0.0-beta.2 Beta, 1.0.0-nightly.20261116 Nightly; a local
/// `-dev` build follows Beta.
pub fn build_channel(version: &str) -> &'static str {
    if version.contains("-nightly.") {
        "nightly"
    } else if version.contains("-beta.") || version.ends_with("-dev") {
        "beta"
    } else {
        "stable"
    }
}

pub struct SettingsStore {
    path: PathBuf,
}

impl SettingsStore {
    pub fn new(folder: &Path) -> SettingsStore {
        SettingsStore { path: folder.join("settings.json") }
    }

    pub fn load(&self) -> AppSettings {
        match std::fs::read(&self.path) {
            Ok(bytes) => parse(&bytes),
            Err(_) => AppSettings::default(),
        }
    }

    /// Atomic: written to a temporary file (0600) and renamed over the old one.
    pub fn save(&self, settings: &AppSettings) -> std::io::Result<()> {
        if let Some(parent) = self.path.parent() {
            crate::paths::private_dir(parent)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        {
            use std::io::Write;
            let mut file = options.open(&tmp)?;
            file.write_all(serde_json::to_string_pretty(settings).unwrap_or_default().as_bytes())?;
            file.sync_all()?;
        }
        std::fs::rename(tmp, &self.path)
    }
}

/// Reads settings.json leniently: a field with the wrong type falls back to its default on its own, rather than the
/// whole file being lost.
pub fn parse(bytes: &[u8]) -> AppSettings {
    if let Ok(s) = serde_json::from_slice::<AppSettings>(bytes) {
        return s;
    }
    let Ok(serde_json::Value::Object(map)) = serde_json::from_slice::<serde_json::Value>(bytes) else { return AppSettings::default() };
    let defaults = serde_json::to_value(AppSettings::default()).unwrap();
    let mut merged = defaults.as_object().unwrap().clone();
    for (k, v) in map {
        let Some(default) = merged.get(&k) else { continue };
        let mut probe = merged.clone();
        probe.insert(k.clone(), v.clone());
        if serde_json::from_value::<AppSettings>(serde_json::Value::Object(probe)).is_ok() {
            merged.insert(k, v);
        } else {
            let _ = default;
        }
    }
    serde_json::from_value(serde_json::Value::Object(merged)).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_windows_where_they_overlap() {
        let s = AppSettings::default();
        assert!(s.clipboard && s.files && s.notifications && s.links && s.open_links_right_away && s.connect_away);
        assert!(!s.automatic_clipboard && !s.media && !s.codes_from_messages && !s.notification_history);
        assert!(s.start_at_sign_in && s.keep_running && s.auto_update_check && s.share_activity);
    }

    #[test]
    fn the_m1_fixture_loads_and_unknown_or_wrong_keys_do_not_lose_the_rest() {
        let fixture = include_bytes!("../../protocol/test-vectors/migrations/linux/settings.m1.json");
        let s = parse(fixture);
        assert_eq!(s.device_name, "Test laptop");
        assert_eq!(s.theme, Theme::Dark);
        assert!(s.automatic_clipboard);
        assert_eq!(s.muted_apps, vec!["com.example.chat".to_string()]);
        assert_eq!(s.update_channel, "beta");

        let odd = br#"{"deviceName": "PC", "clipboard": "yes", "futureKey": 3, "media": true}"#;
        let s = parse(odd);
        assert_eq!(s.device_name, "PC");
        assert!(s.clipboard, "a wrong type keeps the default");
        assert!(s.media);
        assert_eq!(parse(b"not json"), AppSettings::default());
    }

    #[test]
    fn save_and_load_round_trip_owner_only() {
        let dir = std::env::temp_dir().join(format!("bridgey-settings-{}", std::process::id()));
        let store = SettingsStore::new(&dir);
        let s = AppSettings { device_name: "Laptop".into(), media: true, ..Default::default() };
        store.save(&s).unwrap();
        assert_eq!(store.load(), s);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.join("settings.json")).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn channels_follow_the_build() {
        assert_eq!(build_channel("1.0.0"), "stable");
        assert_eq!(build_channel("1.0.0-beta.14"), "beta");
        assert_eq!(build_channel("1.0.0-nightly.20261127"), "nightly");
        assert_eq!(build_channel("1.0.0-dev"), "beta");
        let s = AppSettings { update_channel: "nightly".into(), ..Default::default() };
        assert_eq!(s.channel("1.0.0"), "nightly");
    }
}
