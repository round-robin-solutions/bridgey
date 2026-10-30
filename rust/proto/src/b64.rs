//! Base64 helpers: standard with padding (app payloads) and URL-safe without padding (rendezvous).

use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;

pub fn std_encode(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

pub fn std_decode(text: &str) -> Option<Vec<u8>> {
    STANDARD.decode(text).ok()
}

pub fn url_encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn url_decode(text: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text).ok()
}
