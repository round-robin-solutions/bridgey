//! Code text rules shared by every code message, SMS and email alike (Swift CodeText.swift, Kotlin CodeCore.kt):
//!
//! - [`code_read_text`] joins codes flattened from HTML digit boxes ("4 8 2 9 1 3", "6-0-2-7-3-1"); the model and the
//!   guard read the joined text.
//! - [`looks_like_code_text`] is the gate before the model (on joined text); [`phone_gate`] joins first, which is what
//!   the phone checks before it sends a preview.
//! - [`code_guard_text`] blanks links and copyright years, so a code found only in a link or "(c) 2026" is refused.

use crate::utf16::{self, regex};
use fancy_regex::Regex;
use std::sync::OnceLock;

/// The longest message the reader takes (UTF-16 units, as the relay and the phone count them). Never cut: that
/// could drop the code.
pub const MAXIMUM_TEXT_LENGTH: usize = 600;
/// The longest sender in the prompt (UTF-16 units).
pub const MAXIMUM_SENDER_LENGTH: usize = 64;

const EDGE_L: &str = "(?<![0-9A-Za-z])";
const EDGE_R: &str = "(?![0-9A-Za-z])";

macro_rules! pattern {
    ($name:ident, $build:expr) => {
        pub(crate) fn $name() -> &'static Regex {
            static CELL: OnceLock<Regex> = OnceLock::new();
            CELL.get_or_init(|| regex(&$build))
        }
    };
}

// The relay's cheap pre-check: a whole token of 4 to 10 letters or digits with a digit, or two digit groups.
pattern!(otp_token, "(?<![0-9A-Za-z])(?=[0-9A-Za-z]*[0-9])[0-9A-Za-z]{4,10}(?![0-9A-Za-z])");
pattern!(otp_split, "(?<![0-9A-Za-z])[0-9]{2,5}[ -][0-9]{2,5}(?![0-9A-Za-z])");
// A split letters-and-digits code, each half with a digit: "7Q3-9XT", "AB12-CD34".
pattern!(alnum_split, format!("{EDGE_L}(?=[A-Za-z]*[0-9])[0-9A-Za-z]{{3,4}}-(?=[A-Za-z]*[0-9])[0-9A-Za-z]{{3,4}}{EDGE_R}"));
pattern!(url, "(?:https?://|www\\.)[^\\s<>\"]+|(?<![0-9A-Za-z@.])[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*\\.[A-Za-z]{2,}/[^\\s<>\"]*");
pattern!(copyright, "(?i)(?:\u{00A9}|\\(c\\)|copyright)\\s*(?:[0-9]{4}\\s*[-,]\\s*)?[0-9]{4}");
// 3 to 8 groups of 1 or 2 digits split by single spaces: "4 8 2 9 1 3", "48 29 13".
pattern!(spaced_digits, format!("{EDGE_L}[0-9]{{1,2}}(?: [0-9]{{1,2}}){{2,7}}{EDGE_R}"));
// 4 to 8 single digits joined by hyphens: "6-0-2-7-3-1" (dates have two-digit parts and stay).
pattern!(hyphen_digits, "(?<![0-9A-Za-z\\-])[0-9](?:-[0-9]){3,7}(?![0-9A-Za-z\\-])");

/// The relay's pre-check, also the first half of the gate.
pub fn looks_like_otp_traffic(text: &str) -> bool {
    utf16::is_match(otp_token(), text) || utf16::is_match(otp_split(), text)
}

/// Joins codes flattened from HTML digit boxes. The phone's preview gate makes the same join.
pub fn code_read_text(text: &str) -> String {
    let spaced = utf16::replacing(spaced_digits(), text, |m| {
        let digits: String = m.chars().filter(|c| *c != ' ').collect();
        (4..=8).contains(&digits.len()).then_some(digits)
    });
    utf16::replacing(hyphen_digits(), &spaced, |m| Some(m.replace('-', "")))
}

/// Links and copyright years replaced by spaces of the same UTF-16 length, so offsets stay.
pub fn code_guard_text(text: &str) -> String {
    let blank = |m: &str| Some(" ".repeat(utf16::len(m)));
    let without_links = utf16::replacing(url(), text, blank);
    utf16::replacing(copyright(), &without_links, blank)
}

/// The gate before the model, for SMS and mail alike, on joined text.
pub fn looks_like_code_text(joined: &str) -> bool {
    looks_like_otp_traffic(joined) || utf16::is_match(alnum_split(), joined)
}

/// What the phone checks before it sends a mail preview or a code candidate: the gate after the join.
pub fn phone_gate(text: &str) -> bool {
    looks_like_code_text(&code_read_text(text))
}

/// Trimmed, non-empty and at most [`MAXIMUM_TEXT_LENGTH`] UTF-16 units; `None` otherwise (never cut).
pub fn readable(text: &str) -> Option<&str> {
    let trimmed = text.trim();
    (!trimmed.is_empty() && utf16::len(trimmed) <= MAXIMUM_TEXT_LENGTH).then_some(trimmed)
}
