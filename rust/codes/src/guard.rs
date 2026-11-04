//! The guard: accepts the model's code only if it appears in the message as a whole token and looks like a code.
//! It can only refuse; it never finds a code itself. Same rule as `strict_guard` in the model research
//! (outputs/bridgey/research/otp-tiny-model/common.py), the Mac's CodeGuard and Android's CodeGuard.

use crate::utf16::regex;
use fancy_regex::Regex;
use std::sync::OnceLock;

const EDGE_L: &str = "(?<![0-9A-Za-z])";
const EDGE_R: &str = "(?![0-9A-Za-z])";
/// 3 or more letters or digits with at least one digit.
const DIGIT_GROUP: &str = "(?=[0-9A-Za-z]*[0-9])[0-9A-Za-z]{3,}";

/// A lookahead, so overlapping candidates are all tried: an optional 1 or 2 letter prefix, then digit groups
/// joined by one space or hyphen each.
fn split_token() -> &'static Regex {
    static CELL: OnceLock<Regex> = OnceLock::new();
    CELL.get_or_init(|| regex(&format!("(?={EDGE_L}((?:[A-Za-z]{{1,2}}[ \\-])?{DIGIT_GROUP}(?:[ \\-]{DIGIT_GROUP})*){EDGE_R})")))
}

fn is_separator(c: char) -> bool {
    c == ' ' || c == '-' || c.is_whitespace()
}

fn is_short_prefix(part: &str) -> bool {
    (1..=2).contains(&part.chars().count()) && part.chars().all(|c| c.is_ascii_alphabetic())
}

/// The code to show and copy (separators and a short prefix such as "G-" removed, letter case as in the message),
/// or `None` to fall back to the plain notification. `text` is the guard text (`code_guard_text` of the joined
/// message).
///
/// - a leading prefix of one or two letters ("G-482913") is dropped; every remaining part (split on spaces and
///   hyphens) contains a digit, and when there are several parts each has at least three characters;
/// - the code is 4 to 8 letters or digits in all;
/// - the answer is in the message literally, as a whole token (any letter case), or the message has a split token
///   ("482 913", "PP-301842") whose groups each have 3 or more characters and a digit, and which equals the answer
///   once its separators are removed. A space or hyphen is never allowed between any two characters, so "5minMe"
///   does not match "5 min me".
pub fn accept(answer: Option<&str>, text: &str) -> Option<String> {
    let mut raw = answer?.trim().to_string();
    if raw.is_empty() || raw.chars().count() > 24 {
        return None;
    }
    let mut parts: Vec<String> = raw.split(is_separator).filter(|p| !p.is_empty()).map(str::to_string).collect();
    if parts.len() > 1 && is_short_prefix(&parts[0]) {
        parts.remove(0);
        raw = raw.trim_start_matches(|c: char| !is_separator(c)).trim_start_matches(is_separator).to_string();
    }
    if parts.is_empty() || !parts.iter().all(|p| p.chars().any(|c| c.is_ascii_digit())) {
        return None;
    }
    if parts.len() > 1 && !parts.iter().all(|p| p.chars().count() >= 3) {
        return None;
    }
    let core: String = parts.concat();
    if !(4..=8).contains(&core.chars().count()) || !core.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }

    // 1. Literally in the message, as a whole token.
    if let Ok(literal) = Regex::new(&format!("(?i){EDGE_L}{}{EDGE_R}", fancy_regex::escape(&raw))) {
        if let Ok(Some(found)) = literal.find(text) {
            return Some(found.as_str().chars().filter(char::is_ascii_alphanumeric).collect());
        }
    }

    // 2. A split token in the message whose groups, joined, are the answer.
    let wanted = core.to_ascii_uppercase();
    for captures in split_token().captures_iter(text).map_while(Result::ok) {
        let Some(token) = captures.get(1).map(|m| m.as_str()) else { continue };
        if !token.chars().any(is_separator) {
            continue;
        }
        let mut groups: Vec<&str> = token.split(is_separator).filter(|g| !g.is_empty()).collect();
        let mut prefix = String::new();
        if is_short_prefix(groups[0]) {
            prefix = groups.remove(0).to_ascii_uppercase();
        }
        if groups.is_empty() || !groups.iter().all(|g| g.chars().any(|c| c.is_ascii_digit())) {
            continue;
        }
        let joined: String = groups.concat();
        let upper = joined.to_ascii_uppercase();
        if wanted == upper || wanted == format!("{prefix}{upper}") {
            return Some(joined);
        }
    }
    None
}
