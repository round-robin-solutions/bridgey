//! The session client, called directly as a Rust crate (not through the C ABI): it listens on 42458, finds devices
//! with DNS-SD, pairs with protocol 2 and keeps one encrypted session per trusted device. Its events are drained on a
//! thread of their own and handed to the GTK main loop through a channel.

use bridgey_core::{Client, Config, Event, FileStorage, Next};
use std::sync::Arc;
use std::time::Duration;

use crate::paths;
use crate::settings::AppSettings;

pub struct Core {
    pub client: Arc<Client>,
}

/// The name other devices see: the setting, else this computer's host name.
pub fn device_name(settings: &AppSettings) -> String {
    if !settings.device_name.trim().is_empty() {
        return settings.device_name.trim().to_string();
    }
    let pretty = std::fs::read_to_string("/etc/machine-info").ok().and_then(|t| {
        t.lines().find_map(|l| l.strip_prefix("PRETTY_HOSTNAME=").map(|v| v.trim_matches('"').to_string()))
    });
    pretty
        .filter(|p| !p.is_empty())
        .or_else(|| std::fs::read_to_string("/proc/sys/kernel/hostname").ok().map(|h| h.trim().to_string()))
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "Linux".into())
}

impl Core {
    pub fn start(settings: &AppSettings) -> Result<Core, String> {
        let dir = paths::private_dir(&paths::data_dir().join("core")).map_err(|e| e.to_string())?;
        let storage = Arc::new(FileStorage::new(dir)?);
        let mut config = Config::new(&device_name(settings), "linux");
        if let Some(port) = std::env::var("BRIDGEY_PORT").ok().and_then(|p| p.parse().ok()) {
            config.port = port;
        }
        config.discovery = std::env::var("BRIDGEY_DISCOVERY").map(|v| v != "0").unwrap_or(true);
        for (key, on) in settings.feature_defaults() {
            config.defaults.set(key, on);
        }
        let receive = settings.receive_dir();
        let _ = std::fs::create_dir_all(&receive);
        config.receive_dir = Some(receive);
        config.fast_transfers = settings.fast_transfers;
        let client = Client::start(config, storage).map_err(|e| e.to_string())?;
        client.set_codes(settings.codes_from_messages, settings.codes_from_messages && settings.codes_from_email);
        client.set_links_open(settings.open_links_right_away);
        Ok(Core { client: Arc::new(client) })
    }

    /// Starts the thread that drains the client's events into `tx`; it ends when the client stops.
    pub fn pump(&self, tx: async_channel::Sender<Event>) {
        let client = self.client.clone();
        std::thread::Builder::new()
            .name("bridgey-events".into())
            .spawn(move || loop {
                match client.next_event(Duration::from_secs(30)) {
                    Next::Event(e) => {
                        if tx.send_blocking(e).is_err() {
                            return;
                        }
                    }
                    Next::Timeout => {}
                    Next::Closed => return,
                }
            })
            .expect("event thread");
    }
}
