//! Which service a code is from (Swift CodeCards.swift): the name a card shows and the key that folds the same
//! service ("same service" for Latest and Older, and the phone's codes broker).

use crate::utf16::regex;
use fancy_regex::Regex;
use std::sync::OnceLock;

/// Words that say nothing about which service sent a code.
const NOISE: &[&str] = &[
    "do not reply", "no-reply", "noreply", "notifications", "notification", "verification", "accounts", "account", "security", "support",
    "alerts", "alert", "team", "info", "mail", "the", "via",
];

fn noise() -> &'static [Regex] {
    static CELL: OnceLock<Vec<Regex>> = OnceLock::new();
    CELL.get_or_init(|| NOISE.iter().map(|w| regex(&format!("(?<![\\p{{L}}\\p{{N}}]){}(?![\\p{{L}}\\p{{N}}])", fancy_regex::escape(w)))).collect())
}

fn dlt_prefix() -> &'static Regex {
    static CELL: OnceLock<Regex> = OnceLock::new();
    CELL.get_or_init(|| regex("^[a-z]{2}-"))
}

fn dlt_suffix() -> &'static Regex {
    static CELL: OnceLock<Regex> = OnceLock::new();
    CELL.get_or_init(|| regex("-[a-z]$"))
}

fn summary_title() -> &'static Regex {
    static CELL: OnceLock<Regex> = OnceLock::new();
    CELL.get_or_init(|| regex("(?i)^\\d+ new"))
}

/// The sender reduced to a key for "same service": lowercase, an Indian DLT SMS header ("AX-HDFCBK-S") cut to its
/// sender part, noise words removed, then letters and digits only. "" for a sender that is only a phone number (or
/// empty), which matches any service.
pub fn code_service_key(sender: &str) -> String {
    let mut value = sender.trim().to_lowercase();
    if let Ok(Some(m)) = dlt_prefix().find(&value) {
        value.replace_range(m.range(), "");
    }
    if let Ok(Some(m)) = dlt_suffix().find(&value) {
        value.replace_range(m.range(), "");
    }
    for word in noise() {
        value = crate::utf16::replacing(word, &value, |_| Some(" ".into()));
    }
    let key: String = value.chars().filter(|c| c.is_alphanumeric()).collect();
    if key.chars().all(char::is_numeric) {
        String::new()
    } else {
        key
    }
}

/// The key the phone's broker folds on (codes.found `serviceKey`): the service key, or for a sender with no known
/// service (a bare number) the sender itself, lowercased, so the same code from the same sender still folds.
pub fn broker_service_key(sender: &str) -> String {
    let key = code_service_key(sender);
    let key = if key.is_empty() { sender.trim().to_lowercase() } else { key };
    key.chars().take(64).collect()
}

/// The name a code card shows: the notification title (an SMS contact or sender ID, a mail's sender), else the
/// app's name. A title like "2 new emails" is a summary, not a sender.
pub fn code_sender(title: &str, application_name: &str) -> String {
    let trimmed = title.trim();
    if trimmed.is_empty() || summary_title().is_match(trimmed).unwrap_or(false) {
        application_name.to_string()
    } else {
        trimmed.to_string()
    }
}

/// Two service keys match when equal, when one starts with the other, or when both have at least four characters
/// and share the first four. An unknown service ("") matches any.
pub fn services_match(a: &str, b: &str) -> bool {
    if a.is_empty() || b.is_empty() || a == b || a.starts_with(b) || b.starts_with(a) {
        return true;
    }
    a.chars().count() >= 4 && b.chars().count() >= 4 && a.chars().take(4).eq(b.chars().take(4))
}
