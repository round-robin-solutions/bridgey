//! The app's state, kept apart from GTK so it can be tested on its own: trusted devices with their status, devices
//! nearby, the activity list, phone notifications, pairing and the ringing state. Events from the session client go
//! through `apply`, which changes the state and returns what the desktop should do (`Effect`). The UI draws from the
//! state; the platform layer carries out the effects.

use bridgey_core::{Event, SendStatus};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;

use crate::i18n::{t, tf};
use crate::settings::AppSettings;

/// At most this many rows in the activity list, newest first (as Windows).
pub const ACTIVITY_LIMIT: usize = 200;
/// At most this many phone notifications kept in memory.
pub const NOTIFICATION_LIMIT: usize = 200;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub platform: Option<String>,
    pub connected: bool,
    pub battery: Option<(u8, bool)>,
    /// The other device says it is ringing (after Ring).
    pub ringing: bool,
    /// Connect away from home is set up with it.
    pub away: bool,
    pub local: HashMap<String, bool>,
    pub remote: HashMap<String, bool>,
}

impl Device {
    fn on(map: &HashMap<String, bool>, key: &str) -> bool {
        map.get(key).copied().unwrap_or(false)
    }

    /// A feature works when this device's switch and the other device's are both on, while connected.
    pub fn ready(&self, key: &str) -> bool {
        self.connected && Self::on(&self.local, key) && Self::on(&self.remote, key)
    }

    pub fn local_on(&self, key: &str) -> bool {
        Self::on(&self.local, key)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Nearby {
    pub device_id: Option<String>,
    pub name: String,
    pub platform: Option<String>,
    pub host: String,
    pub port: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direction {
    Sent,
    Received,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Activity {
    pub id: u64,
    pub direction: Direction,
    pub title: String,
    pub preview: String,
    pub status: String,
    /// A received or sent file, for Open and Show in folder.
    pub path: Option<PathBuf>,
    /// bytes, total while a transfer runs.
    pub progress: Option<(u64, u64)>,
    pub at_ms: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PhoneNotice {
    pub device_id: String,
    pub device_name: String,
    pub n: bridgey_core::notifications::Notification,
    pub received_ms: u64,
}

impl PhoneNotice {
    pub fn key(&self) -> (String, String) {
        (self.device_id.clone(), self.n.notification_id.clone())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Pairing {
    /// The other device has not allowed pairing yet; the client retries for two minutes.
    Waiting { pairing: u64, name: String },
    /// Compare the code and confirm.
    Code { pairing: u64, device_id: String, name: String, code: String },
    Done { name: String },
    Failed { reason: String },
}

/// What the desktop should do after an event.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    /// Read everything from the client again (devices changed or events were dropped).
    Refresh,
    SetClipboard { text: String, html: Option<String>, from: String },
    ShowNotification(Box<PhoneNotice>),
    RemoveNotification { device_id: String, notification_id: String },
    /// A code to copy at once (Copy codes automatically).
    CopyCode(String),
    StartRinging { from: String },
    StopRinging,
    OpenLink(String),
    FileArrived { path: PathBuf, name: String, from: String },
    MediaCommand { device_id: String, request_id: String, action: String, value: Option<i64> },
    /// The phone asks for a Bluetooth LE advertisement Linux does not offer yet: answer no.
    RefuseAdvertise { device_id: String, service_uuid: String },
    /// A short message for a toast.
    Toast(String),
    /// Show the pairing dialog (a code is waiting for the person).
    ShowPairing,
}

#[derive(Default)]
pub struct State {
    pub this_id: String,
    pub devices: Vec<Device>,
    pub nearby: Vec<Nearby>,
    pub activity: VecDeque<Activity>,
    pub notifications: VecDeque<PhoneNotice>,
    pub pairing: Option<Pairing>,
    /// Someone asked to pair while pairing was not allowed here: (device ID, name).
    pub pairing_request: Option<(String, String)>,
    /// The device ringing this computer.
    pub ringing_from: Option<String>,
    /// A link waiting for Open or Dismiss: (device ID, URL).
    pub pending_link: Option<(String, String)>,
    pub connect_state: String,
    pub codes_status: HashMap<String, String>,
    /// Requests waiting for their answer: request ID to activity ID.
    pending: HashMap<u64, u64>,
    /// Transfers: transfer ID to activity ID.
    transfers: HashMap<u64, u64>,
    next_activity: u64,
    /// The last text received, so writing it to the clipboard is not sent straight back.
    pub last_received: Option<String>,
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn map(value: Option<&Value>) -> HashMap<String, bool> {
    match value {
        Some(Value::Object(o)) => o.iter().filter_map(|(k, v)| v.as_bool().map(|b| (k.clone(), b))).collect(),
        _ => HashMap::new(),
    }
}

pub fn preview(text: &str) -> String {
    let line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > 120 {
        format!("{}…", line.chars().take(119).collect::<String>())
    } else {
        line
    }
}

impl State {
    pub fn new() -> State {
        State { connect_state: "off".into(), next_activity: 1, ..Default::default() }
    }

    pub fn device(&self, id: &str) -> Option<&Device> {
        self.devices.iter().find(|d| d.id == id)
    }

    fn device_mut(&mut self, id: &str) -> Option<&mut Device> {
        self.devices.iter_mut().find(|d| d.id == id)
    }

    pub fn name_of(&self, id: &str) -> String {
        self.device(id).map(|d| d.name.clone()).filter(|n| !n.is_empty()).unwrap_or_else(|| t("device.unnamed").to_string())
    }

    pub fn connected(&self) -> Vec<&Device> {
        self.devices.iter().filter(|d| d.connected).collect()
    }

    /// "Connected to Pixel 9", for the tray and the window.
    pub fn status_text(&self) -> String {
        let connected = self.connected();
        match connected.len() {
            0 if self.devices.is_empty() => t("status.none_paired").into(),
            0 => t("status.none_connected").into(),
            1 => tf("status.connected_to", &[&connected[0].name]),
            n => tf("status.connected_count", &[&n.to_string()]),
        }
    }

    /// The device a send goes to when none is named: the only connected one that takes it.
    pub fn default_target(&self, key: &str) -> Option<String> {
        let ready: Vec<&Device> = self.devices.iter().filter(|d| d.ready(key)).collect();
        (ready.len() == 1).then(|| ready[0].id.clone())
    }

    pub fn add_activity(&mut self, direction: Direction, title: String, preview: String, status: String) -> u64 {
        let id = self.next_activity;
        self.next_activity += 1;
        self.activity.push_front(Activity { id, direction, title, preview, status, path: None, progress: None, at_ms: now_ms() });
        self.activity.truncate(ACTIVITY_LIMIT);
        id
    }

    pub fn activity_mut(&mut self, id: u64) -> Option<&mut Activity> {
        self.activity.iter_mut().find(|a| a.id == id)
    }

    /// A request sent (clipboard, link, ping): its row waits for the answer.
    pub fn track(&mut self, request: u64, activity: u64) {
        self.pending.insert(request, activity);
    }

    pub fn track_transfer(&mut self, transfer: u64, activity: u64) {
        self.transfers.insert(transfer, activity);
    }

    /// Reads the client's snapshot: trusted devices with their switches, devices nearby, Connect away from home.
    pub fn load_snapshot(&mut self, snap: &Value) {
        self.this_id = snap["deviceId"].as_str().unwrap_or("").to_string();
        let mut devices = Vec::new();
        for d in snap["devices"].as_array().into_iter().flatten() {
            let id = d["deviceId"].as_str().unwrap_or("").to_string();
            if id.is_empty() {
                continue;
            }
            devices.push(Device {
                name: d["name"].as_str().unwrap_or("").to_string(),
                platform: d["platform"].as_str().map(str::to_string),
                connected: d["connected"].as_bool().unwrap_or(false),
                battery: d["battery"].as_object().and_then(|b| Some((b.get("level")?.as_u64()?.min(100) as u8, b.get("charging")?.as_bool()?))),
                ringing: d["ringing"].as_bool().unwrap_or(false),
                away: d["away"].as_bool().unwrap_or(false),
                local: map(d.get("local")),
                remote: map(d.get("remote")),
                id,
            });
        }
        devices.sort_by(|a, b| b.connected.cmp(&a.connected).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
        self.devices = devices;
        self.nearby.clear();
        for n in snap["nearby"].as_array().into_iter().flatten() {
            if n["trusted"].as_bool().unwrap_or(false) {
                continue;
            }
            let (Some(host), Some(port)) = (n["host"].as_str(), n["port"].as_u64()) else { continue };
            self.nearby.push(Nearby {
                device_id: n["deviceId"].as_str().map(str::to_string),
                name: n["name"].as_str().unwrap_or(host).to_string(),
                platform: n["platform"].as_str().map(str::to_string),
                host: host.to_string(),
                port: port as u16,
            });
        }
        if let Some(state) = snap["connect"]["state"].as_str() {
            self.connect_state = state.to_string();
        }
        if let Some(from) = &self.ringing_from {
            if !self.devices.iter().any(|d| &d.id == from && d.connected) {
                self.ringing_from = None;
            }
        }
    }

    fn status_word(status: SendStatus) -> &'static str {
        match status {
            SendStatus::Delivered => "",
            SendStatus::Rejected => t("activity.declined"),
            SendStatus::TimedOut => t("activity.no_answer"),
            SendStatus::Failed => t("activity.not_delivered"),
        }
    }

    pub fn apply(&mut self, event: Event, settings: &AppSettings) -> Vec<Effect> {
        let mut fx = Vec::new();
        match event {
            Event::Found { device_id, name, platform, host, port } => {
                let trusted = device_id.as_ref().is_some_and(|id| self.device(id).is_some());
                let known = self.nearby.iter().any(|n| (device_id.is_some() && n.device_id == device_id) || (device_id.is_none() && n.host == host));
                if !trusted && !known {
                    self.nearby.push(Nearby { device_id, name: if name.is_empty() { host.clone() } else { name }, platform, host, port });
                }
            }
            Event::Lost { device_id, host, .. } => {
                self.nearby.retain(|n| !(n.host == host && (device_id.is_none() || n.device_id == device_id)));
            }
            Event::PairingRequest { device_id, name } => {
                if !matches!(self.pairing, Some(Pairing::Code { .. })) {
                    self.pairing_request = Some((device_id, name));
                }
            }
            Event::PairingWaiting { pairing, name } => {
                self.pairing = Some(Pairing::Waiting { pairing, name });
            }
            Event::PairingCode { pairing, device_id, name, code } => {
                self.pairing_request = None;
                self.pairing = Some(Pairing::Code { pairing, device_id, name, code });
                fx.push(Effect::ShowPairing);
            }
            Event::PairingFinished { ok, name, reason, .. } => {
                let name = name.unwrap_or_default();
                self.pairing = Some(if ok { Pairing::Done { name } } else { Pairing::Failed { reason: pairing_reason(&reason).to_string() } });
                fx.push(Effect::Refresh);
            }
            Event::Connected { device_id, name } => {
                if self.device(&device_id).is_none() {
                    fx.push(Effect::Refresh);
                } else if let Some(d) = self.device_mut(&device_id) {
                    d.connected = true;
                    if !name.is_empty() {
                        d.name = name;
                    }
                }
                self.nearby.retain(|n| n.device_id.as_deref() != Some(device_id.as_str()));
            }
            Event::Disconnected { device_id, .. } => {
                if let Some(d) = self.device_mut(&device_id) {
                    d.connected = false;
                    d.battery = None;
                    d.remote.clear();
                    d.ringing = false;
                }
                if self.ringing_from.as_deref() == Some(device_id.as_str()) {
                    self.ringing_from = None;
                    fx.push(Effect::StopRinging);
                }
            }
            Event::Features { device_id, local, remote } => {
                if let Some(d) = self.device_mut(&device_id) {
                    d.local = map(Some(&local.to_json()));
                    d.remote = map(Some(&remote.to_json()));
                    if !d.ready("battery") {
                        d.battery = None;
                    }
                }
            }
            Event::TrustChanged { .. } | Event::Dropped { .. } => fx.push(Effect::Refresh),
            Event::Clipboard { device_id, text, html } => {
                let from = self.name_of(&device_id);
                self.last_received = Some(text.clone());
                let shown = if settings.show_previews { preview(&text) } else { String::new() };
                self.add_activity(Direction::Received, tf("activity.clipboard_from", &[&from]), shown, String::new());
                fx.push(Effect::SetClipboard { text, html, from });
            }
            Event::ClipboardSent { request, status, .. } | Event::PingResult { request, status, .. } => {
                if let Some(row) = self.pending.remove(&request) {
                    if let Some(a) = self.activity_mut(row) {
                        a.status = Self::status_word(status).to_string();
                    }
                }
            }
            Event::Ping { device_id } => {
                let from = self.name_of(&device_id);
                self.add_activity(Direction::Received, tf("activity.ping_from", &[&from]), String::new(), String::new());
                fx.push(Effect::Toast(tf("activity.ping_from", &[&from])));
            }
            Event::FileIncoming { transfer, device_id, name, size, .. } => {
                let from = self.name_of(&device_id);
                let row = self.add_activity(Direction::Received, tf("activity.file_from", &[&from]), name, t("activity.receiving").into());
                if let Some(a) = self.activity_mut(row) {
                    a.progress = Some((0, size));
                }
                self.transfers.insert(transfer, row);
            }
            Event::FileProgress { transfer, bytes, total, .. } => {
                if let Some(row) = self.transfers.get(&transfer).copied() {
                    if let Some(a) = self.activity_mut(row) {
                        a.progress = Some((bytes, total));
                    }
                }
            }
            Event::FileDone { transfer, device_id, incoming, name, path, .. } => {
                let row = self.transfers.remove(&transfer);
                if let Some(a) = row.and_then(|r| self.activity_mut(r)) {
                    a.status = if incoming { t("activity.saved").into() } else { String::new() };
                    a.progress = None;
                    a.preview = name.clone();
                    if let Some(p) = &path {
                        a.path = Some(PathBuf::from(p));
                    }
                }
                if incoming {
                    if let Some(p) = path {
                        fx.push(Effect::FileArrived { path: PathBuf::from(p), name, from: self.name_of(&device_id) });
                    }
                }
            }
            Event::FileFailed { transfer, reason, .. } => {
                if let Some(a) = self.transfers.remove(&transfer).and_then(|r| self.activity_mut(r)) {
                    a.status = file_reason(&reason).to_string();
                    a.progress = None;
                }
            }
            Event::Link { device_id, url, open } => {
                let from = self.name_of(&device_id);
                self.add_activity(Direction::Received, tf("activity.link_from", &[&from]), url.clone(), String::new());
                if open {
                    fx.push(Effect::OpenLink(url));
                } else {
                    self.pending_link = Some((device_id, url));
                }
            }
            Event::LinkSent { request, status, .. } => {
                if let Some(row) = self.pending.remove(&request) {
                    if let Some(a) = self.activity_mut(row) {
                        a.status = match status {
                            SendStatus::Rejected => t("activity.links_off").into(),
                            other => Self::status_word(other).into(),
                        };
                    }
                }
            }
            Event::Battery { device_id, level, charging } => {
                if let Some(d) = self.device_mut(&device_id) {
                    d.battery = Some((level.min(100), charging));
                }
            }
            Event::FindRequested { device_id, ring } => {
                if ring {
                    self.ringing_from = Some(device_id.clone());
                    fx.push(Effect::StartRinging { from: self.name_of(&device_id) });
                } else if self.ringing_from.as_deref() == Some(device_id.as_str()) {
                    self.ringing_from = None;
                    fx.push(Effect::StopRinging);
                }
            }
            Event::FindState { device_id, ringing } => {
                if let Some(d) = self.device_mut(&device_id) {
                    d.ringing = ringing;
                }
            }
            Event::Notification { device_id, notification } => {
                let notice = PhoneNotice { device_name: self.name_of(&device_id), device_id, n: *notification, received_ms: now_ms() };
                let key = notice.key();
                self.notifications.retain(|n| n.key() != key);
                if settings.copy_codes {
                    if let Some(code) = &notice.n.code {
                        fx.push(Effect::CopyCode(code.code.clone()));
                    }
                }
                let muted = settings.muted_apps.iter().any(|m| m == &notice.n.package_name);
                if settings.notification_banners && !notice.n.quiet && !muted {
                    fx.push(Effect::ShowNotification(Box::new(notice.clone())));
                }
                self.notifications.push_front(notice);
                self.notifications.truncate(NOTIFICATION_LIMIT);
            }
            Event::NotificationRemoved { device_id, notification_id, .. } => {
                self.notifications.retain(|n| !(n.device_id == device_id && n.n.notification_id == notification_id));
                fx.push(Effect::RemoveNotification { device_id, notification_id });
            }
            Event::CodesStatus { device_id, status } => {
                self.codes_status.insert(device_id, status);
            }
            Event::CodesAdvertise { device_id, service_uuid, start, .. } => {
                if start {
                    fx.push(Effect::RefuseAdvertise { device_id, service_uuid });
                }
            }
            Event::MediaCommand { device_id, request_id, action, value } => {
                fx.push(Effect::MediaCommand { device_id, request_id, action, value });
            }
            Event::ConnectState { state, .. } => {
                self.connect_state = state;
            }
            Event::Phone { .. } | Event::Error { .. } => {}
        }
        fx
    }

    /// The person dismissed or acted on a notification here: it leaves the list.
    pub fn remove_notification(&mut self, device_id: &str, notification_id: &str) {
        self.notifications.retain(|n| !(n.device_id == device_id && n.n.notification_id == notification_id));
    }
}

pub fn file_reason(reason: &str) -> &'static str {
    match reason {
        "rejected" => t("file.rejected"),
        "cancelled" => t("file.cancelled"),
        "cancelled_remote" => t("file.cancelled_remote"),
        "not_accepted" | "not_confirmed" => t("file.not_accepted"),
        "stalled" | "interrupted" | "not_connected" => t("file.interrupted"),
        "verification_failed" | "changed" | "invalid" => t("file.changed"),
        "unreadable" => t("file.unreadable"),
        "storage" => t("file.storage"),
        _ => t("file.failed"),
    }
}

/// What a failed pairing tells the person (reasons from rust/client, as Windows reads them).
pub fn pairing_reason(reason: &str) -> &'static str {
    match reason {
        "cancelled_remote:mismatch" | "code_rejected" => t("pair.failed.code"),
        "not_allowed" => t("pair.failed.not_allowed"),
        "unreachable" => t("pair.failed.unreachable"),
        "needs_protocol_2" | "cancelled_remote:needs_protocol_2" => t("pair.failed.update"),
        "cancelled_remote:busy" | "refused:busy" => t("pair.failed.busy"),
        "cancelled_remote:rate_limited" => t("pair.failed.rate"),
        "code_timeout" | "cancelled_remote:timeout" => t("pair.failed.timeout"),
        "cancelled_remote:cancelled" => t("pair.failed.cancelled_there"),
        "identity_changed" => t("pair.failed.identity"),
        _ => t("pair.failed.other"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bridgey_core::FeatureMap;
    use serde_json::json;

    fn snapshot() -> Value {
        json!({
            "deviceId": "self",
            "devices": [
                {"deviceId": "p1", "name": "Pixel", "platform": "android", "connected": true,
                 "local": {"clipboard": true, "files": true, "battery": true, "links": true},
                 "remote": {"clipboard": true, "files": true, "battery": true, "links": false},
                 "battery": {"level": 81, "charging": true}, "away": true, "ringing": false},
                {"deviceId": "m1", "name": "Mac", "platform": "macos", "connected": false, "local": {}, "remote": null}
            ],
            "nearby": [
                {"deviceId": "n1", "name": "Other phone", "platform": "android", "host": "192.168.1.5", "port": 42458, "trusted": false},
                {"deviceId": "p1", "name": "Pixel", "host": "192.168.1.6", "port": 42458, "trusted": true}
            ],
            "connect": {"state": "online"}
        })
    }

    #[test]
    fn snapshot_gives_devices_readiness_and_nearby() {
        let mut s = State::new();
        s.load_snapshot(&snapshot());
        assert_eq!(s.devices.len(), 2);
        let p = s.device("p1").unwrap();
        assert!(p.ready("clipboard") && p.ready("files") && !p.ready("links"));
        assert_eq!(p.battery, Some((81, true)));
        assert_eq!(s.nearby.len(), 1, "trusted devices are not offered for pairing");
        assert_eq!(s.connect_state, "online");
        assert_eq!(s.default_target("files").as_deref(), Some("p1"));
        assert!(s.status_text().contains("Pixel"));
    }

    #[test]
    fn clipboard_from_a_phone_is_set_here_and_listed() {
        let mut s = State::new();
        s.load_snapshot(&snapshot());
        let fx = s.apply(Event::Clipboard { device_id: "p1".into(), text: "hello\nworld".into(), html: None }, &AppSettings::default());
        assert_eq!(fx, vec![Effect::SetClipboard { text: "hello\nworld".into(), html: None, from: "Pixel".into() }]);
        assert_eq!(s.activity[0].preview, "hello world");
        assert_eq!(s.last_received.as_deref(), Some("hello\nworld"));
        let quiet = AppSettings { show_previews: false, ..Default::default() };
        s.apply(Event::Clipboard { device_id: "p1".into(), text: "secret".into(), html: None }, &quiet);
        assert_eq!(s.activity[0].preview, "", "no preview when previews are off");
    }

    #[test]
    fn answers_update_their_rows() {
        let mut s = State::new();
        s.load_snapshot(&snapshot());
        let row = s.add_activity(Direction::Sent, "Clipboard".into(), "x".into(), "Sending".into());
        s.track(7, row);
        s.apply(Event::ClipboardSent { request: 7, device_id: "p1".into(), status: SendStatus::Rejected }, &AppSettings::default());
        assert_eq!(s.activity[0].status, t("activity.declined"));
    }

    #[test]
    fn files_progress_and_arrive() {
        let mut s = State::new();
        s.load_snapshot(&snapshot());
        let st = AppSettings::default();
        s.apply(Event::FileIncoming { transfer: 3, device_id: "p1".into(), name: "a.jpg".into(), size: 100, mime: "image/jpeg".into() }, &st);
        s.apply(Event::FileProgress { transfer: 3, device_id: "p1".into(), incoming: true, bytes: 50, total: 100 }, &st);
        assert_eq!(s.activity[0].progress, Some((50, 100)));
        let fx = s.apply(Event::FileDone { transfer: 3, device_id: "p1".into(), incoming: true, name: "a (1).jpg".into(), path: Some("/tmp/a (1).jpg".into()), size: 100 }, &st);
        assert_eq!(fx, vec![Effect::FileArrived { path: "/tmp/a (1).jpg".into(), name: "a (1).jpg".into(), from: "Pixel".into() }]);
        assert_eq!(s.activity[0].path.as_deref(), Some(std::path::Path::new("/tmp/a (1).jpg")));
        s.apply(Event::FileIncoming { transfer: 4, device_id: "p1".into(), name: "b".into(), size: 1, mime: "x/y".into() }, &st);
        s.apply(Event::FileFailed { transfer: 4, device_id: "p1".into(), incoming: true, name: "b".into(), reason: "storage".into() }, &st);
        assert_eq!(s.activity[0].status, t("file.storage"));
    }

    #[test]
    fn ringing_starts_and_stops_and_ends_with_the_connection() {
        let mut s = State::new();
        s.load_snapshot(&snapshot());
        let st = AppSettings::default();
        assert_eq!(s.apply(Event::FindRequested { device_id: "p1".into(), ring: true }, &st), vec![Effect::StartRinging { from: "Pixel".into() }]);
        assert_eq!(s.ringing_from.as_deref(), Some("p1"));
        assert_eq!(s.apply(Event::Disconnected { device_id: "p1".into(), reason: "x".into() }, &st), vec![Effect::StopRinging]);
        assert!(s.ringing_from.is_none());
        assert!(!s.device("p1").unwrap().connected);
        assert_eq!(s.device("p1").unwrap().battery, None);
    }

    #[test]
    fn links_open_at_once_or_wait() {
        let mut s = State::new();
        s.load_snapshot(&snapshot());
        let st = AppSettings::default();
        assert_eq!(s.apply(Event::Link { device_id: "p1".into(), url: "https://a.example".into(), open: true }, &st), vec![Effect::OpenLink("https://a.example".into())]);
        assert!(s.apply(Event::Link { device_id: "p1".into(), url: "https://b.example".into(), open: false }, &st).is_empty());
        assert_eq!(s.pending_link, Some(("p1".into(), "https://b.example".into())));
    }

    fn notification(id: &str, quiet: bool, package: &str) -> Box<bridgey_core::notifications::Notification> {
        let payload = json!({"notificationId": id, "packageName": package, "applicationName": "Chat", "title": "Ana", "text": "Hi", "timestamp": 1});
        let mut n = bridgey_core::notifications::decode_post(payload.to_string().as_bytes(), false).unwrap();
        n.quiet = quiet;
        Box::new(n)
    }

    #[test]
    fn notifications_show_unless_quiet_or_muted_and_go_when_removed() {
        let mut s = State::new();
        s.load_snapshot(&snapshot());
        let st = AppSettings { muted_apps: vec!["muted.app".into()], ..Default::default() };
        let fx = s.apply(Event::Notification { device_id: "p1".into(), notification: notification("1", false, "com.chat") }, &st);
        assert!(matches!(fx.as_slice(), [Effect::ShowNotification(_)]));
        assert!(s.apply(Event::Notification { device_id: "p1".into(), notification: notification("2", true, "com.chat") }, &st).is_empty(), "quiet");
        assert!(s.apply(Event::Notification { device_id: "p1".into(), notification: notification("3", false, "muted.app") }, &st).is_empty(), "muted");
        assert_eq!(s.notifications.len(), 3, "all are kept in the list");
        s.apply(Event::Notification { device_id: "p1".into(), notification: notification("1", false, "com.chat") }, &st);
        assert_eq!(s.notifications.len(), 3, "an update replaces the old one");
        let fx = s.apply(Event::NotificationRemoved { device_id: "p1".into(), notification_id: "1".into(), call_ended: false }, &st);
        assert_eq!(fx, vec![Effect::RemoveNotification { device_id: "p1".into(), notification_id: "1".into() }]);
        assert_eq!(s.notifications.len(), 2);
    }

    #[test]
    fn features_update_readiness_and_pairing_moves_through_its_states() {
        let mut s = State::new();
        s.load_snapshot(&snapshot());
        let st = AppSettings::default();
        let mut local = FeatureMap::all_off();
        local.set("links", true);
        let mut remote = FeatureMap::all_off();
        remote.set("links", true);
        s.apply(Event::Features { device_id: "p1".into(), local, remote }, &st);
        assert!(s.device("p1").unwrap().ready("links"));
        assert!(!s.device("p1").unwrap().ready("clipboard"));

        s.apply(Event::PairingWaiting { pairing: 1, name: "Phone".into() }, &st);
        assert!(matches!(s.pairing, Some(Pairing::Waiting { .. })));
        let fx = s.apply(Event::PairingCode { pairing: 1, device_id: "x".into(), name: "Phone".into(), code: "123456".into() }, &st);
        assert_eq!(fx, vec![Effect::ShowPairing]);
        s.apply(Event::PairingRequest { device_id: "y".into(), name: "Other".into() }, &st);
        assert!(s.pairing_request.is_none(), "no request card over a code being compared");
        s.apply(Event::PairingFinished { pairing: 1, device_id: Some("x".into()), name: Some("Phone".into()), ok: false, reason: "code_timeout".into() }, &st);
        assert_eq!(s.pairing, Some(Pairing::Failed { reason: t("pair.failed.timeout").into() }));
    }
}
