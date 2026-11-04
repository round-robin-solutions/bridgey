//! Codes from email: the thin email-only layer in front of the shared reader (Swift EmailCodeRules.swift; the
//! research's `email_precheck`, final rule, in outputs/bridgey/research/otp-tiny-model/email/email_guard.py).
//!
//! 1. [`email_code_precheck`] decides whether a mail is worth reading: a code-shaped token with a code word within
//!    100 characters, where tokens in links and copyright years do not count; a token whose own sentence says the
//!    code expired or was used does not count; in a meeting invite or a mail with a marketing phrase only strong
//!    words count, and a marketing mail that says "unsubscribe" is refused outright.
//! 2. [`email_model_snippets`]: when the first read of a mail finds nothing, the reader reads up to two short
//!    pieces around the best tokens, inside the same budget.

use crate::text::{alnum_split, code_guard_text, looks_like_otp_traffic, otp_split, otp_token};
use crate::utf16::{self, regex, Span};
use fancy_regex::Regex;
use std::sync::OnceLock;

const LATIN_L: &str = "(?<![0-9A-Za-z])";
const LATIN_R: &str = "(?![0-9A-Za-z])";
const CYRILLIC_L: &str = "(?<![\\x{0400}-\\x{04FF}])";

/// Characters (UTF-16 units) between a token and the nearest code word.
pub const CODE_WORD_WINDOW: usize = 100;

macro_rules! pattern {
    ($name:ident, $build:expr) => {
        fn $name() -> &'static Regex {
            static CELL: OnceLock<Regex> = OnceLock::new();
            CELL.get_or_init(|| regex(&$build))
        }
    };
}

pattern!(code_word, format!(
    "(?i){LATIN_L}(?:code|otp|passcode|pin)s?{LATIN_R}|{LATIN_L}(?:one-time|one[ \\-]?time|verification|verify|2fa|two-factor|two-step|security[ \\-]?code|authentication|confirm){LATIN_R}|{CYRILLIC_L}(?:код|пароль|подтвержд)|ओटीपी|कोड"
));
pattern!(strong_word, format!(
    "(?i){LATIN_L}(?:otp|one-time|one[ \\-]?time|verification|verify|2fa|two-factor|two-step|security[ \\-]?code|authentication)s?{LATIN_R}|{CYRILLIC_L}(?:код|подтвержд)|ओटीपी"
));
pattern!(dead, format!(
    "(?i){LATIN_L}(?:expired|no longer valid|no longer works|already (?:been )?used|(?:was|has been|been) used){LATIN_R}|{CYRILLIC_L}(?:истёк|истек|больше не действует|уже использован)|समाप्त|अमान्य"
));
pattern!(sentence_end, "[.!?\\n\u{0964}]");
pattern!(marketing, format!(
    "(?i)(?<![0-9A-Za-z\\-])(?:promo ?code|coupon|discount code|voucher|gift code|referral code|offer code){LATIN_R}|\\d+ ?% ?off{LATIN_R}|{CYRILLIC_L}(?:промокод|купон|скидк)|प्रोमो|कूपन|छूट"
));
pattern!(unsubscribe, "(?i)unsubscribe");
pattern!(meeting, "(?i)meeting id|meeting number|conference id|join zoom|zoom meeting|teams meeting|microsoft teams|webex|google meet|join by phone|webinar");
pattern!(entity_space, "&nbsp;|&#160;");
pattern!(invisible, "&#8203;|&zwnj;|\u{200B}|\u{200C}");
pattern!(image_placeholder, "(?i)\\[(?:image|cid):[^\\]]*\\]");

/// A qualifying token, its distance to the nearest code word.
struct Qualifying {
    distance: usize,
    token: Span,
}

/// The sentence around `token` (UTF-16 bounds from the sentence ends), as text.
fn sentence(text: &str, ends: &[Span], token: &Span) -> String {
    let start = ends.iter().rev().find(|e| e.max() <= token.location).map(|e| e.max()).unwrap_or(0);
    let units: Vec<u16> = text.encode_utf16().collect();
    let end = ends.iter().find(|e| e.location >= token.max()).map(|e| e.location).unwrap_or(units.len());
    String::from_utf16_lossy(&units[start..end.max(start)])
}

/// Every token that passes, closest to a code word first (then by position). Empty: not a code mail.
fn qualifying_tokens(text: &str) -> Vec<Qualifying> {
    let scan = code_guard_text(text);
    if !(looks_like_otp_traffic(&scan) || utf16::is_match(alnum_split(), &scan)) {
        return Vec::new();
    }
    let marketing_spans = utf16::matches(marketing(), &scan);
    if !marketing_spans.is_empty() && utf16::is_match(unsubscribe(), &scan) {
        return Vec::new();
    }
    let strong_only = !marketing_spans.is_empty() || utf16::is_match(meeting(), &scan);
    let words: Vec<Span> = utf16::matches(if strong_only { strong_word() } else { code_word() }, &scan)
        .into_iter()
        .filter(|w| !marketing_spans.iter().any(|m| m.location <= w.location && w.max() <= m.max()))
        .collect();
    if words.is_empty() {
        return Vec::new();
    }
    let mut tokens: Vec<Span> = Vec::new();
    for span in utf16::matches(otp_token(), &scan).into_iter().chain(utf16::matches(otp_split(), &scan)).chain(utf16::matches(alnum_split(), &scan)) {
        if !tokens.iter().any(|t| t.location == span.location && t.length == span.length) {
            tokens.push(span);
        }
    }
    let ends = utf16::matches(sentence_end(), &scan);
    let mut found = Vec::new();
    for token in tokens {
        if utf16::is_match(dead(), &sentence(&scan, &ends, &token)) {
            continue;
        }
        // The first nearest word, as Swift's min(by:) picks it.
        let mut nearest: Option<usize> = None;
        for word in &words {
            let gap = (word.location as i64 - token.max() as i64).max(token.location as i64 - word.max() as i64).max(0) as usize;
            if nearest.is_none_or(|n| gap < n) {
                nearest = Some(gap);
            }
        }
        if let Some(gap) = nearest.filter(|g| *g <= CODE_WORD_WINDOW) {
            found.push(Qualifying { distance: gap, token });
        }
    }
    found.sort_by_key(|q| (q.distance, q.token.location, q.token.length));
    found
}

/// Whether a (joined) mail preview may hold a one-time code, before the model reads it.
pub fn email_code_precheck(text: &str) -> bool {
    !qualifying_tokens(text).is_empty()
}

fn is_space(unit: u16) -> bool {
    char::from_u32(unit as u32).is_some_and(char::is_whitespace)
}

/// The second read's texts: for the two best tokens, the whitespace-flattened text from 100 characters before the
/// token to 60 after it, trimmed to whole words. Empty when the pre-check fails.
pub fn email_model_snippets(text: &str) -> Vec<String> {
    let flat = email_flattened(text);
    let units: Vec<u16> = flat.encode_utf16().collect();
    let length = units.len();
    let mut snippets: Vec<String> = Vec::new();
    for found in qualifying_tokens(&flat).into_iter().take(2) {
        let mut start = found.token.location.saturating_sub(100);
        let mut end = (found.token.max() + 60).min(length);
        while start > 0 && start < length && !is_space(units[start - 1]) {
            start += 1;
        }
        while end < length && end > 0 && !is_space(units[end]) {
            end -= 1;
        }
        if end <= start {
            continue;
        }
        let piece = String::from_utf16_lossy(&units[start..end]).trim().to_string();
        if !piece.is_empty() && !snippets.contains(&piece) {
            snippets.push(piece);
        }
    }
    snippets
}

/// HTML leftovers removed and every run of whitespace made one space.
pub fn email_flattened(text: &str) -> String {
    let value = utf16::replacing(entity_space(), text, |_| Some(" ".into()));
    let value = utf16::replacing(invisible(), &value, |_| Some(String::new()));
    let value = utf16::replacing(image_placeholder(), &value, |_| Some(" ".into()));
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}
