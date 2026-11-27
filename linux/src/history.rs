//! Notification history (Settings > Phone > Notifications > Keep history, off by default): phone notifications for
//! seven days, at most 200, in an owner-only file. Codes and icons are never kept.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::path::PathBuf;

use crate::paths;
use crate::state::{now_ms, PhoneNotice};

const DAYS_MS: u64 = 7 * 24 * 3600 * 1000;
const LIMIT: usize = 200;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Stored {
    pub device_id: String,
    pub device_name: String,
    pub package_name: String,
    pub application_name: String,
    pub notification_id: String,
    pub title: String,
    pub text: String,
    pub timestamp: i64,
    pub received_at: u64,
}

fn file() -> PathBuf {
    paths::data_dir().join("notification-history.json")
}

pub fn encode(list: &VecDeque<PhoneNotice>, now: u64) -> String {
    let items: Vec<Stored> = list
        .iter()
        .filter(|n| now.saturating_sub(n.received_ms) < DAYS_MS)
        .take(LIMIT)
        .map(|n| Stored {
            device_id: n.device_id.clone(),
            device_name: n.device_name.clone(),
            package_name: n.n.package_name.clone(),
            application_name: n.n.application_name.clone(),
            notification_id: n.n.notification_id.clone(),
            title: n.n.title.clone(),
            text: if n.n.code.is_some() { String::new() } else { n.n.text.clone() },
            timestamp: n.n.timestamp,
            received_at: n.received_ms,
        })
        .collect();
    serde_json::to_string(&items).unwrap_or_else(|_| "[]".into())
}

/// Reads the history; a bad entry is dropped on its own and a bad file gives none.
pub fn decode(text: &str, now: u64) -> Vec<Stored> {
    let Ok(serde_json::Value::Array(items)) = serde_json::from_str::<serde_json::Value>(text) else { return vec![] };
    items
        .into_iter()
        .filter_map(|v| serde_json::from_value::<Stored>(v).ok())
        .filter(|s| !s.notification_id.is_empty() && now.saturating_sub(s.received_at) < DAYS_MS)
        .take(LIMIT)
        .collect()
}

pub fn save(list: &VecDeque<PhoneNotice>) {
    let path = file();
    let tmp = path.with_extension("json.tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    if let Ok(mut f) = options.open(&tmp) {
        use std::io::Write;
        if f.write_all(encode(list, now_ms()).as_bytes()).is_ok() {
            let _ = std::fs::rename(tmp, path);
        }
    }
}

pub fn load() -> Vec<Stored> {
    std::fs::read_to_string(file()).map(|t| decode(&t, now_ms())).unwrap_or_default()
}

/// Stored rows as notifications in the list (quiet: they were shown when they came).
pub fn to_notices(items: Vec<Stored>) -> Vec<PhoneNotice> {
    items
        .into_iter()
        .map(|s| PhoneNotice {
            device_id: s.device_id,
            device_name: s.device_name,
            received_ms: s.received_at,
            n: bridgey_core::notifications::Notification {
                package_name: s.package_name,
                application_name: s.application_name,
                notification_id: s.notification_id,
                title: s.title,
                text: s.text,
                timestamp: s.timestamp,
                icon: None,
                call_type: None,
                actions: Vec::new(),
                sms_default_app: None,
                redacted: None,
                email_app: None,
                preview: None,
                quiet: true,
                event_id: None,
                code: None,
                sms_reply: false,
                sms_thread_id: None,
            },
        })
        .collect()
}

pub fn clear() {
    let _ = std::fs::remove_file(file());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_and_bad_entries_are_dropped() {
        let now = 1_900_000_000_000u64;
        let text = format!(
            r#"[{{"notificationId": "1", "title": "A", "receivedAt": {}}}, {{"notificationId": "2", "receivedAt": {}}}, {{"title": 5}}, {{"notificationId": "", "receivedAt": {}}}]"#,
            now - 1000,
            now - DAYS_MS - 1,
            now
        );
        let got = decode(&text, now);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].title, "A");
        assert!(decode("nonsense", now).is_empty());
    }
}
