//! The clipboard on Linux, honestly by desktop:
//!
//! | Desktop | This computer to the phone | The phone to this computer |
//! | --- | --- | --- |
//! | Wayland with data-control (KDE Plasma, Sway, Hyprland, COSMIC, niri, labwc) | automatic, in the background | set at once |
//! | X11 (any desktop) | automatic, in the background | set at once |
//! | GNOME on Wayland | through XWayland, in the background (Mutter mirrors the clipboard both ways); without XWayland only while Bridgey is in front | the same; without XWayland a banner with Copy |
//!
//! GNOME's compositor offers no clipboard protocol for background apps and gives the Wayland clipboard only to the
//! app in front, so Bridgey there talks to the X11 clipboard that GNOME keeps in step with Wayland. When even that is
//! missing (a GNOME session started without X11 support), Bridgey reads the clipboard when its window is in front and
//! sets it after one click on the banner, which brings Bridgey in front for a moment.
//!
//! Copied text goes as text. Copied images and files go as files to the device (Send copied item, or automatically
//! with Automatic clipboard on), which is how they reach a phone that has no clipboard offer from this computer yet.
//! Text a password manager marks secret (`x-kde-passwordManagerHint`, KeePassXC and others) is never sent by itself.

use std::path::PathBuf;

use super::{datacontrol, x11clip, UiTx};

/// Offered by Bridgey's own clipboard sources, so it never reads its own text back.
pub const OWNER_MIME: &str = "application/x-bridgey-owner";
/// What Bridgey offers when it sets text, and reads first.
pub const TEXT_MIMES: [&str; 5] = ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT"];
pub const SECRET_HINT: &str = "x-kde-passwordManagerHint";
/// Text over 1 MiB is not read (the session sends at most 32 KiB of text anyway).
pub const TEXT_CAP: usize = 1024 * 1024;
pub const IMAGE_CAP: usize = 64 * 1024 * 1024;
const IMAGE_MIMES: [&str; 4] = ["image/png", "image/jpeg", "image/webp", "image/gif"];

#[derive(Clone, Debug, PartialEq)]
pub enum Clip {
    Text { text: String, secret: bool },
    Image { mime: String, data: Vec<u8> },
    Files(Vec<PathBuf>),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Text,
    Image,
    UriList,
}

/// What to read from a new clip, given the MIME types it offers.
#[derive(Clone, Debug, PartialEq)]
pub struct Plan {
    pub mime: String,
    pub kind: Kind,
    pub secret: bool,
    pub cap: usize,
}

pub fn plan(mimes: &[String]) -> Option<Plan> {
    if mimes.iter().any(|m| m == OWNER_MIME) {
        return None;
    }
    let secret = mimes.iter().any(|m| m == SECRET_HINT);
    let has = |m: &str| mimes.iter().any(|x| x.eq_ignore_ascii_case(m));
    // Files from a file manager: a URI list, usually with the GNOME or KDE marker; the plain text beside it is the paths.
    if has("text/uri-list") && (has("x-special/gnome-copied-files") || has("application/x-kde-cutselection") || !TEXT_MIMES.iter().any(|t| has(t))) {
        return Some(Plan { mime: "text/uri-list".into(), kind: Kind::UriList, secret, cap: TEXT_CAP });
    }
    if let Some(t) = TEXT_MIMES.iter().find(|t| has(t)) {
        return Some(Plan { mime: t.to_string(), kind: Kind::Text, secret, cap: TEXT_CAP });
    }
    if let Some(i) = IMAGE_MIMES.iter().find(|i| has(i)) {
        return Some(Plan { mime: i.to_string(), kind: Kind::Image, secret, cap: IMAGE_CAP });
    }
    if has("text/uri-list") {
        return Some(Plan { mime: "text/uri-list".into(), kind: Kind::UriList, secret, cap: TEXT_CAP });
    }
    None
}

pub fn decode(plan: &Plan, bytes: Vec<u8>) -> Option<Clip> {
    match plan.kind {
        Kind::Text => {
            let text = String::from_utf8(bytes).ok().or(None)?;
            (!text.is_empty()).then_some(Clip::Text { text, secret: plan.secret })
        }
        Kind::Image => (!bytes.is_empty()).then(|| Clip::Image { mime: plan.mime.clone(), data: bytes }),
        Kind::UriList => {
            let text = String::from_utf8_lossy(&bytes).to_string();
            let files = file_uris(&text);
            if files.is_empty() {
                // Links, not files: send them as text.
                let text = text.lines().filter(|l| !l.starts_with('#')).collect::<Vec<_>>().join("\n");
                (!text.trim().is_empty()).then_some(Clip::Text { text, secret: plan.secret })
            } else {
                Some(Clip::Files(files))
            }
        }
    }
}

/// The local paths in a `text/uri-list` (RFC 2483), when every entry is a file URI; empty otherwise.
pub fn file_uris(list: &str) -> Vec<PathBuf> {
    let entries: Vec<&str> = list.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')).filter(|l| *l != "copy" && *l != "cut").collect();
    let mut out = Vec::new();
    for e in &entries {
        let Some(rest) = e.strip_prefix("file://") else { return Vec::new() };
        let path = rest.strip_prefix("localhost").unwrap_or(rest);
        if !path.starts_with('/') {
            return Vec::new();
        }
        out.push(PathBuf::from(percent_decode(path)));
    }
    out
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = |b: u8| (b as char).to_digit(16);
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

/// How the clipboard works on this desktop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Wayland's data-control protocol.
    DataControl,
    /// An X11 session.
    X11,
    /// A Wayland session without data-control, through XWayland's clipboard.
    XWayland,
    /// Only while Bridgey's window is in front.
    Foreground,
}

pub enum Background {
    DataControl(datacontrol::DataControl),
    X11(x11clip::X11Clipboard),
}

impl Background {
    pub fn set_text(&self, text: &str) {
        match self {
            Background::DataControl(d) => d.set_text(text),
            Background::X11(x) => x.set_text(text),
        }
    }
}

/// Starts the background watcher this desktop allows, or none (`Mode::Foreground`).
pub fn start(tx: UiTx, enabled: bool) -> (Mode, Option<Background>) {
    if !enabled {
        return (Mode::Foreground, None);
    }
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some_and(|v| !v.is_empty());
    if wayland {
        if let Some(d) = datacontrol::start(tx.clone()) {
            return (Mode::DataControl, Some(Background::DataControl(d)));
        }
    }
    if std::env::var_os("DISPLAY").is_some_and(|v| !v.is_empty()) && std::env::var("BRIDGEY_X11_CLIPBOARD").as_deref() != Ok("0") {
        match x11clip::start(tx) {
            Ok(x) => return (if wayland { Mode::XWayland } else { Mode::X11 }, Some(Background::X11(x))),
            Err(e) => eprintln!("bridgey: no X11 clipboard: {e}"),
        }
    }
    (Mode::Foreground, None)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn plans_pick_text_files_or_images() {
        assert_eq!(plan(&m(&["TEXT", "text/plain;charset=utf-8", "UTF8_STRING"])).unwrap().mime, "text/plain;charset=utf-8");
        let files = plan(&m(&["x-special/gnome-copied-files", "text/uri-list", "text/plain;charset=utf-8"])).unwrap();
        assert_eq!(files.kind, Kind::UriList);
        assert_eq!(plan(&m(&["image/png", "image/bmp"])).unwrap().kind, Kind::Image);
        assert!(plan(&m(&["text/plain", OWNER_MIME])).is_none(), "our own text is never read back");
        assert!(plan(&m(&["text/plain", SECRET_HINT])).unwrap().secret);
        assert!(plan(&m(&["application/x-unknown"])).is_none());
        assert_eq!(plan(&m(&["text/html", "text/plain", "text/uri-list"])).unwrap().kind, Kind::Text, "a browser's link copy is text");
    }

    #[test]
    fn uri_lists_become_paths_only_when_all_are_files() {
        assert_eq!(file_uris("file:///home/a/My%20photo.jpg\r\nfile:///tmp/b\n"), vec![PathBuf::from("/home/a/My photo.jpg"), PathBuf::from("/tmp/b")]);
        assert_eq!(file_uris("copy\nfile:///tmp/%D1%84.txt"), vec![PathBuf::from("/tmp/ф.txt")]);
        assert!(file_uris("https://example.com\nfile:///tmp/b").is_empty());
        let plan = Plan { mime: "text/uri-list".into(), kind: Kind::UriList, secret: false, cap: TEXT_CAP };
        assert_eq!(decode(&plan, b"https://example.com\n".to_vec()), Some(Clip::Text { text: "https://example.com".into(), secret: false }));
    }
}
