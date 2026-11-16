//! Rules shared by files and links (docs/protocol.md "Files (`files.v1`)" and "Quick actions"): what a received
//! file is called and where it lands, the hash both ends check, and which links may be sent or shown.
//!
//! The session (session.rs) runs the messages; this module has no network code.

use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

/// The JSON transport's chunk: 24 KiB of file bytes before encryption.
pub const FILE_CHUNK: usize = 24 * 1024;
/// The largest file either app takes (the Mac's limit).
pub const MAX_FILE: u64 = 10 * 1024 * 1024 * 1024;
/// A received JSON chunk may be larger than this end's own (peers differ), never larger than a frame allows.
pub const MAX_CHUNK_IN: usize = 48 * 1024;
/// `quick.request` and `quick.result` plaintexts.
pub const QUICK_MAX: usize = 8 * 1024;
/// A link's longest form.
pub const LINK_MAX: usize = 4 * 1024;
/// A received file's name, in bytes, before any " 2" numbering.
const NAME_MAX: usize = 200;

/// The base64 SHA-256 of a file, read in 256 KiB pieces. Also returns its size.
pub fn hash_file(path: &Path) -> io::Result<(String, u64)> {
    let mut file = File::open(path)?;
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buf = vec![0u8; 256 * 1024];
    let mut size = 0u64;
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        size += n as u64;
        ctx.update(&buf[..n]);
    }
    Ok((crate::crypto::b64(ctx.finish().as_ref()), size))
}

/// A sender's display name as a safe file name on every system the client runs on: the last path component,
/// visible characters only, none of Windows' reserved characters, no leading dot (hidden files), no trailing dots or
/// spaces (Windows drops them), never a Windows device name (`CON`, `COM1`, ...), at most 200 bytes with the extension
/// kept. Never empty.
pub fn safe_name(name: &str) -> String {
    let last = name.rsplit(['/', '\\']).next().unwrap_or("");
    let cleaned: String = last.chars().filter(|c| !crate::session::invisible(*c) && !matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|')).collect();
    let trimmed = cleaned.trim().trim_start_matches('.').trim_end_matches(['.', ' ']).trim();
    let mut out = if trimmed.is_empty() || trimmed == ".." { "file".to_string() } else { trimmed.to_string() };
    if reserved_on_windows(split_ext(&out).0) {
        out = format!("_{out}");
    }
    if out.len() > NAME_MAX {
        let (stem, ext) = split_ext(&out);
        let ext = if ext.len() > 16 { "" } else { ext };
        let mut stem = stem.to_string();
        while stem.len() + ext.len() > NAME_MAX {
            stem.pop();
        }
        out = format!("{stem}{ext}");
    }
    out
}

/// A Windows device name, whatever the extension and case: `CON`, `PRN`, `AUX`, `NUL`, `COM1` to `COM9`, `LPT1` to
/// `LPT9` (and the superscript digits Windows also reserves).
fn reserved_on_windows(stem: &str) -> bool {
    let upper = stem.trim_end().to_ascii_uppercase();
    let device = |prefix: &str| upper.starts_with(prefix) && upper.chars().count() == 4 && upper.chars().nth(3).is_some_and(|c| c.is_ascii_digit() && c != '0' || matches!(c, '¹' | '²' | '³'));
    matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$") || device("COM") || device("LPT")
}

/// "photo.jpg" -> ("photo", ".jpg"); a leading dot or none -> (name, "").
fn split_ext(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(i) if i > 0 && i < name.len() - 1 => (&name[..i], &name[i..]),
        _ => (name, ""),
    }
}

/// The n-th candidate for a name: "photo.jpg", then "photo 2.jpg", "photo 3.jpg" (Finder's numbering, as the Mac);
/// on Windows "photo (1).jpg", "photo (2).jpg", as Windows names downloads.
pub fn numbered(name: &str, n: u32) -> String {
    if n <= 1 {
        return name.to_string();
    }
    let (stem, ext) = split_ext(name);
    if cfg!(windows) {
        format!("{stem} ({}){ext}", n - 1)
    } else {
        format!("{stem} {n}{ext}")
    }
}

/// Moves a verified partial file to the first free name in `dir`, never over an existing file. Returns its path.
pub fn place(part: &Path, dir: &Path, name: &str) -> io::Result<PathBuf> {
    for n in 1..10_000u32 {
        let target = dir.join(numbered(name, n));
        // A hard link fails when the name exists, so nothing is ever overwritten, even by a racing writer.
        match fs::hard_link(part, &target) {
            Ok(()) => {
                let _ = fs::remove_file(part);
                return Ok(target);
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(_) => {
                // A file system without hard links: check, then rename.
                if target.exists() {
                    continue;
                }
                fs::rename(part, &target)?;
                return Ok(target);
            }
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free name"))
}

/// The hidden partial file for a transfer, beside where the file will land.
pub fn part_path(dir: &Path, transfer_id: &str) -> PathBuf {
    dir.join(format!(".bridgey-{transfer_id}.part"))
}

/// A MIME type from a file name, for `files.offer` when the host does not know one.
pub fn mime_for(name: &str) -> &'static str {
    let ext = split_ext(name).1.trim_start_matches('.').to_ascii_lowercase();
    match ext.as_str() {
        "txt" | "log" | "md" => "text/plain",
        "json" => "application/json",
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "heic" => "image/heic",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "zip" => "application/zip",
        "gz" | "tgz" => "application/gzip",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        _ => "application/octet-stream",
    }
}

/// A link the apps send and show: http or https, a host, no user name or password, no spaces, control characters
/// or backslashes, a valid port if any, at most 4,096 bytes (docs/protocol.md, `links` / `offer`).
pub fn valid_link(url: &str) -> bool {
    if url.is_empty() || url.len() > LINK_MAX || url.chars().any(|c| c.is_whitespace() || c.is_control() || c == '\\') {
        return false;
    }
    let lower = url.to_ascii_lowercase();
    let rest = if let Some(r) = lower.strip_prefix("https://") {
        &url[url.len() - r.len()..]
    } else if let Some(r) = lower.strip_prefix("http://") {
        &url[url.len() - r.len()..]
    } else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.is_empty() || authority.contains('@') {
        return false;
    }
    let (host, port) = if let Some(v6) = authority.strip_prefix('[') {
        match v6.split_once(']') {
            Some((h, p)) => (h, p.strip_prefix(':')),
            None => return false,
        }
    } else {
        match authority.rsplit_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (authority, None),
        }
    };
    if host.is_empty() {
        return false;
    }
    match port {
        None => true,
        Some(p) => !p.is_empty() && p.len() <= 5 && p.chars().all(|c| c.is_ascii_digit()) && p.parse::<u32>().is_ok_and(|n| (1..=65_535).contains(&n)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_safe() {
        assert_eq!(safe_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_name("C:\\Users\\a\\photo.jpg"), "photo.jpg");
        assert_eq!(safe_name(".hidden"), "hidden");
        assert_eq!(safe_name("  "), "file");
        assert_eq!(safe_name(".."), "file");
        assert_eq!(safe_name("a\u{202E}b.txt"), "ab.txt");
        let long = format!("{}.jpeg", "x".repeat(400));
        let s = safe_name(&long);
        assert!(s.len() <= 200 && s.ends_with(".jpeg"));
        // Windows: device names, trailing dots and spaces.
        assert_eq!(safe_name("CON.txt"), "_CON.txt");
        assert_eq!(safe_name("com1"), "_com1");
        assert_eq!(safe_name("LPT9.log"), "_LPT9.log");
        assert_eq!(safe_name("COM0.txt"), "COM0.txt");
        assert_eq!(safe_name("console.txt"), "console.txt");
        assert_eq!(safe_name("notes. . "), "notes");
    }

    #[test]
    #[cfg(not(windows))]
    fn numbering_follows_finder() {
        assert_eq!(numbered("photo.jpg", 1), "photo.jpg");
        assert_eq!(numbered("photo.jpg", 2), "photo 2.jpg");
        assert_eq!(numbered("README", 3), "README 3");
        assert_eq!(numbered("archive.tar.gz", 2), "archive.tar 2.gz");
    }

    #[test]
    #[cfg(windows)]
    fn numbering_follows_windows() {
        assert_eq!(numbered("photo.jpg", 1), "photo.jpg");
        assert_eq!(numbered("photo.jpg", 2), "photo (1).jpg");
        assert_eq!(numbered("README", 3), "README (2)");
    }

    #[test]
    fn placing_never_overwrites() {
        let dir = std::env::temp_dir().join(format!("bridgey-place-{}", crate::crypto::uuid4()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.txt"), b"old").unwrap();
        let part = part_path(&dir, "t1");
        fs::write(&part, b"new").unwrap();
        let placed = place(&part, &dir, "a.txt").unwrap();
        assert_eq!(placed.file_name().unwrap(), numbered("a.txt", 2).as_str());
        assert_eq!(fs::read(dir.join("a.txt")).unwrap(), b"old");
        assert_eq!(fs::read(&placed).unwrap(), b"new");
        assert!(!part.exists());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn links_follow_the_apps_rules() {
        for ok in ["https://example.com", "http://example.com:8080/a?b#c", "https://[::1]:443/x", "HTTPS://Example.com/Path"] {
            assert!(valid_link(ok), "{ok}");
        }
        for bad in [
            "",
            "ftp://example.com",
            "https://",
            "https://user:pass@example.com",
            "https://example.com/a b",
            "https://example.com\\x",
            "https://example.com:99999",
            "https://example.com:",
            "javascript:alert(1)",
            "https://:80",
        ] {
            assert!(!valid_link(bad), "{bad}");
        }
        assert!(!valid_link(&format!("https://example.com/{}", "a".repeat(LINK_MAX))));
    }

    #[test]
    fn hashing_matches_ring() {
        let path = std::env::temp_dir().join(format!("bridgey-hash-{}", crate::crypto::uuid4()));
        fs::write(&path, b"abc").unwrap();
        let (hash, size) = hash_file(&path).unwrap();
        assert_eq!(size, 3);
        assert_eq!(hash, "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=");
        fs::remove_file(&path).unwrap();
    }
}
