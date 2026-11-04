//! UTF-16 offsets for regex matches. Every length and distance in the code rules is in UTF-16 units, as the Mac
//! (NSRange) and Android (Java strings) count them, so the three agree on text with emoji.

use fancy_regex::Regex;

/// A match as UTF-16 `location` and `length`, plus its byte range in the text it came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub location: usize,
    pub length: usize,
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub fn max(&self) -> usize {
        self.location + self.length
    }
}

/// UTF-16 offset of every byte offset that starts a character (and of the end).
pub struct Offsets {
    by_byte: Vec<usize>,
}

impl Offsets {
    pub fn new(text: &str) -> Offsets {
        let mut by_byte = vec![0; text.len() + 1];
        let mut units = 0;
        for (index, ch) in text.char_indices() {
            by_byte[index] = units;
            units += ch.len_utf16();
        }
        by_byte[text.len()] = units;
        Offsets { by_byte }
    }

    pub fn at(&self, byte: usize) -> usize {
        self.by_byte[byte]
    }
}

pub fn len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// Every non-overlapping match, as NSRegularExpression and java.util.regex find them (an empty match moves on
/// by one character). A pattern that fails at run time (backtracking limit) yields what it found so far.
pub fn matches(pattern: &Regex, text: &str) -> Vec<Span> {
    let offsets = Offsets::new(text);
    pattern
        .find_iter(text)
        .map_while(Result::ok)
        .map(|m| Span { location: offsets.at(m.start()), length: offsets.at(m.end()) - offsets.at(m.start()), start: m.start(), end: m.end() })
        .collect()
}

pub fn is_match(pattern: &Regex, text: &str) -> bool {
    pattern.is_match(text).unwrap_or(false)
}

/// Replaces each match with what `transform` returns for it (`None` keeps the match).
pub fn replacing(pattern: &Regex, text: &str, mut transform: impl FnMut(&str) -> Option<String>) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for m in pattern.find_iter(text).map_while(Result::ok) {
        out.push_str(&text[last..m.start()]);
        match transform(m.as_str()) {
            Some(replacement) => out.push_str(&replacement),
            None => out.push_str(m.as_str()),
        }
        last = m.end();
    }
    out.push_str(&text[last..]);
    out
}

/// At most `limit` UTF-16 units of whole characters.
pub fn prefix(value: &str, limit: usize) -> String {
    let mut out = String::new();
    let mut units = 0;
    for ch in value.chars() {
        if units + ch.len_utf16() > limit {
            break;
        }
        units += ch.len_utf16();
        out.push(ch);
    }
    out
}

pub fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("code rule pattern")
}
