//! One-time codes from the phone's messages and mail, read on this device (draft `sms_codes_draft1` and
//! `email_codes_draft1`, docs/protocol.md "Codes from messages").
//!
//! The Mac asks a model (on the Mac or the relay) for the code; this client has no model, so it finds the code with
//! rules: the token nearest a code word ("OTP", "code", "PIN", "ओटीपी"), never an amount, a time, a date, a masked
//! account, a phone or reference number, or a code the message calls old. The shared reader decides what is read and
//! what is accepted: `bridgey_codes::code_candidate` picks the messages (SMS apps, the four mail apps) and their text,
//! and its guard (`bridgey_codes::accept`) refuses anything that is not literally in the message and shaped like a
//! code. Nothing leaves this device. Message text and codes are never logged.
//!
//! Checked against protocol/test-vectors/otp-samples.json: every code it shows is the right one.

use bridgey_codes::candidate::{code_candidate, Channel, NotificationFields};
use bridgey_codes::text::code_guard_text;

/// A code found in a phone notification.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    pub code: String,
    /// Who it is from: the notification's title (an SMS sender, a mail's sender) or the app's name.
    pub service: String,
    pub channel: Channel,
}

/// The code in one forwarded notification, or None. `fields.email_codes` is this device's "Also read codes in
/// email" switch; `title` and `application_name` name who the code is from.
pub fn find(fields: &NotificationFields, title: &str, application_name: &str) -> Option<Found> {
    let candidate = code_candidate(fields)?;
    let guard_text = code_guard_text(&candidate.text);
    let answer = rules_answer(&guard_text)?;
    let code = bridgey_codes::accept(Some(&answer), &guard_text)?;
    Some(Found { code, service: bridgey_codes::service::code_sender(title, application_name), channel: candidate.channel })
}

/// Words that say a message carries a code.
const CODE_WORDS: &[&str] = &[
    "otp", "code", "passcode", "password", "pin", "verification", "verify", "one-time", "one time", "login", "log in", "sign in", "sign-in", "2fa", "ओटीपी", "कोड", "पासवर्ड",
];
/// Words that, right before a number, say it is not the code.
const NOT_BEFORE: &[&str] = &[
    "rs", "inr", "usd", "eur", "gbp", "aed", "pnr", "ref", "refno", "id", "no", "ifsc", "pan", "order", "token", "ending", "card", "account", "acct", "ac", "txn", "upi", "mobile", "phone", "call", "tel", "flight", "train", "trn", "room", "flat", "pincode", "zip", "qty", "rupees", "amount", "balance", "bal", "fare",
];
/// Words a little before a number that say it is no longer the code.
const STALE: &[&str] = &["previous", "old", "earlier", "expired"];
/// Marketing words: with these and no stronger code word, "code" means a promotion.
const PROMO: &[&str] = &["promo", "coupon", "% off", "offer", "discount", "cashback", "referral", "voucher"];
const STRONG: &[&str] = &["otp", "verification", "one-time", "one time", "login", "passcode", "ओटीपी"];
/// How far (in characters) a code may be from its code word.
const MAX_DISTANCE: usize = 90;

#[derive(Debug)]
struct Token {
    start: usize,
    end: usize,
    value: String,
}

fn is_alnum(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

/// Letters-and-digits runs, with their character offsets.
fn runs(chars: &[char]) -> Vec<Token> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if is_alnum(chars[i]) {
            let start = i;
            while i < chars.len() && is_alnum(chars[i]) {
                i += 1;
            }
            out.push(Token { start, end: i, value: chars[start..i].iter().collect() });
        } else {
            i += 1;
        }
    }
    out
}

/// Code-shaped tokens: one run of 4 to 8 letters or digits with a digit, or digit groups joined by single spaces or
/// hyphens ("591-047", "441 902") with 4 to 8 digits in all.
fn candidates(chars: &[char]) -> Vec<Token> {
    let runs = runs(chars);
    let mut out = Vec::new();
    for (i, r) in runs.iter().enumerate() {
        let len = r.value.chars().count();
        if (4..=8).contains(&len) && r.value.chars().any(|c| c.is_ascii_digit()) {
            out.push(Token { start: r.start, end: r.end, value: r.value.clone() });
        }
        // Digit groups: this run and the next ones, each 2 to 5 digits, one separator between.
        if r.value.chars().all(|c| c.is_ascii_digit()) && (2..=5).contains(&len) {
            let mut value = r.value.clone();
            let mut end = r.end;
            for next in runs.iter().skip(i + 1) {
                let gap: String = chars[end..next.start].iter().collect();
                if !(gap == " " || gap == "-") || !next.value.chars().all(|c| c.is_ascii_digit()) || !(2..=5).contains(&next.value.len()) {
                    break;
                }
                value.push_str(&gap);
                value.push_str(&next.value);
                end = next.end;
                let digits = value.chars().filter(char::is_ascii_digit).count();
                if (4..=8).contains(&digits) {
                    out.push(Token { start: r.start, end, value: value.clone() });
                }
                if digits >= 8 {
                    break;
                }
            }
        }
    }
    out
}

/// The words before a position, lowercased, nearest first (punctuation dropped).
fn words_before(chars: &[char], at: usize, count: usize) -> Vec<String> {
    let text: String = chars[..at].iter().collect();
    text.split(|c: char| c.is_whitespace() || matches!(c, ':' | '(' | ')' | ',' | ';' | '[' | ']'))
        .filter(|w| !w.is_empty())
        .rev()
        .take(count)
        .map(|w| w.trim_matches(|c: char| matches!(c, '.' | '-' | '\'' | '"')).to_lowercase())
        .collect()
}

fn word_at(lower: &[char], at: usize, word: &str) -> bool {
    let w: Vec<char> = word.chars().collect();
    if at + w.len() > lower.len() || lower[at..at + w.len()] != w[..] {
        return false;
    }
    let ascii = word.is_ascii();
    let before_ok = at == 0 || !ascii || !lower[at - 1].is_ascii_alphanumeric();
    let after_ok = at + w.len() == lower.len() || !ascii || !lower[at + w.len()].is_ascii_alphanumeric();
    before_ok && after_ok
}

fn contains_word(lower: &[char], word: &str) -> bool {
    (0..lower.len()).any(|i| word_at(lower, i, word))
}

/// The code a person would read in `text` (the shared reader's guard text), or None.
pub fn rules_answer(text: &str) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    let lower: Vec<char> = text.to_lowercase().chars().collect();
    if lower.len() != chars.len() {
        return None;
    }
    let mut keywords: Vec<(usize, usize)> = Vec::new();
    for i in 0..lower.len() {
        for w in CODE_WORDS.iter().filter(|w| word_at(&lower, i, w)) {
            keywords.push((i, i + w.chars().count()));
        }
    }
    if keywords.is_empty() {
        return None;
    }
    let lower_text: String = lower.iter().collect();
    if PROMO.iter().any(|p| lower_text.contains(p)) && !STRONG.iter().any(|s| contains_word(&lower, s)) {
        return None;
    }
    let mut best: Option<(usize, Token)> = None;
    for t in candidates(&chars) {
        if t.value.chars().any(|c| c.is_ascii_lowercase()) || t.value.to_ascii_uppercase().contains("XX") {
            continue;
        }
        // Amounts, times, dates and decimals: a digit joined by . , : / on either side, or a percentage.
        let before = t.start.checked_sub(1).map(|i| chars[i]);
        let before2 = t.start.checked_sub(2).map(|i| chars[i]);
        let after = chars.get(t.end).copied();
        let after2 = chars.get(t.end + 1).copied();
        let joined_before = matches!(before, Some('.' | ',' | ':' | '/' | '-')) && before2.is_some_and(|c| c.is_ascii_digit());
        let joined_after = matches!(after, Some('.' | ',' | ':' | '/' | '-')) && after2.is_some_and(|c| c.is_ascii_digit());
        if joined_before || joined_after || after == Some('%') {
            continue;
        }
        // A 4-digit year next to a date word or with a hyphenated tail is a year.
        if let Ok(year) = t.value.parse::<u32>() {
            if t.value.len() == 4 && (1900..=2099).contains(&year) && matches!(after, Some('-')) {
                continue;
            }
        }
        let prev = chars[..t.start].iter().rev().find(|c| !c.is_whitespace()).copied();
        if matches!(prev, Some('#' | '₹' | '$' | '€' | '£' | '+')) {
            continue;
        }
        let words = words_before(&chars, t.start, 3);
        if words.first().is_some_and(|w| NOT_BEFORE.contains(&w.as_str())) || words.iter().take(3).any(|w| STALE.contains(&w.as_str())) {
            continue;
        }
        let distance = keywords
            .iter()
            .map(|&(ks, ke)| if ke <= t.start { t.start - ke } else { ks.saturating_sub(t.end) })
            .min()
            .unwrap_or(usize::MAX);
        if distance > MAX_DISTANCE {
            continue;
        }
        // "OTP is 482913", "code: 74219", "482913 is your code": the usual shapes come first.
        let pointed = words.first().is_some_and(|w| matches!(w.as_str(), "is" | "otp" | "code" | "pin" | "passcode" | "password" | "ओटीपी" | "कोड"));
        let leading = chars[t.end..].iter().collect::<String>().trim_start().to_lowercase().starts_with("is ");
        let digits_only = t.value.chars().all(|c| c.is_ascii_digit() || c == ' ' || c == '-');
        let score = distance.saturating_sub(if pointed || leading { 30 } else { 0 }) + if digits_only { 0 } else { 5 };
        if best.as_ref().is_none_or(|(s, b)| score < *s || (score == *s && t.value.len() > b.value.len())) {
            best = Some((score, t));
        }
    }
    best.map(|(_, t)| t.value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    #[allow(clippy::too_many_arguments)]
    fn read(package_name: &str, application_name: &str, title: &str, text: &str, sms_default_app: Option<bool>, redacted: Option<bool>, email_app: Option<bool>, preview: Option<&str>, email: bool) -> Option<Found> {
        let fields = NotificationFields { package_name: package_name.into(), sms_default_app, redacted, text: text.into(), email_app, preview: preview.map(str::to_string), email_codes: email };
        find(&fields, title, application_name)
    }

    fn strip(code: &str) -> String {
        code.chars().filter(|c| c.is_ascii_alphanumeric()).collect::<String>().trim_start_matches("G").to_string()
    }

    /// Every code shown is the right one; messages without a code show none; and most codes are found.
    #[test]
    fn shared_samples_never_show_a_wrong_code() {
        let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocol/test-vectors/otp-samples.json")).unwrap();
        let v: Value = serde_json::from_str(&text).unwrap();
        let (mut found, mut positives) = (0, 0);
        for s in v["samples"].as_array().unwrap() {
            let body = s["body"].as_str().unwrap();
            let expected: Vec<String> = s["code"].as_array().unwrap().iter().map(|c| strip(c.as_str().unwrap())).collect();
            let got = read("com.google.android.apps.messaging", "Messages", s["sender"].as_str().unwrap_or(""), body, Some(true), Some(false), None, None, false);
            match (&got, expected.is_empty()) {
                (None, _) => {}
                (Some(f), true) => panic!("{}: showed {} for a message without a code", s["id"], f.code),
                (Some(f), false) => {
                    assert!(expected.contains(&strip(&f.code)), "{}: showed {}, expected {:?}", s["id"], f.code, expected);
                    found += 1;
                }
            }
            if !expected.is_empty() {
                positives += 1;
            }
        }
        eprintln!("rules reader: {found} of {positives} codes found, none wrong");
        assert!(found * 10 >= positives * 9, "found {found} of {positives}");
    }

    #[test]
    fn redacted_mail_and_other_apps_are_not_read() {
        let body = "Your OTP is 482913";
        assert!(read("com.google.android.apps.messaging", "Messages", "HDFC", body, Some(true), Some(true), None, None, false).is_none(), "Android hid the text");
        assert!(read("com.whatsapp", "WhatsApp", "Ravi", body, Some(false), None, None, None, false).is_none(), "not an SMS app");
        let mail = "Your Google verification code is 739108";
        assert!(read("com.google.android.gm", "Gmail", "Google", mail, Some(false), None, Some(true), Some(mail), false).is_none(), "mail needs its switch");
        let f = read("com.google.android.gm", "Gmail", "Google", mail, Some(false), None, Some(true), Some(mail), true).unwrap();
        assert_eq!((f.code.as_str(), f.service.as_str(), f.channel), ("739108", "Google", Channel::Email));
    }

    #[test]
    fn promotions_and_stale_codes_are_not_codes() {
        assert_eq!(rules_answer("Use code SAVE50 for 50% off your next order"), None);
        assert_eq!(rules_answer("Your new OTP is 553108 (previous OTP 129774 is no longer valid)").as_deref(), Some("553108"));
        assert_eq!(rules_answer("OTP for e-verification of ITR for AY 2026-27, PAN XXXXX1234X, is 718263.").as_deref(), Some("718263"));
    }
}
