//! The folders draft's pure rules (docs/protocol.md "Draft: folders, places and settings sync", docs/folders-and-
//! settings-sync.md): portable names, manifest and existing paths, the order of a manifest, conflict names, the
//! manifest digest and the receiver's check of a manifest. The same rules as FolderCore.swift and FolderCore.kt, checked
//! against protocol/test-vectors/folders-v1.json.
//!
//! One difference: the apps compose names to NFC before they compare or convert them, and this crate has no Unicode
//! tables. Hosts pass names already in NFC (Windows' file names almost always are; the Windows app normalises the
//! names it uploads), and two names that differ only in their composition count as two names here.

use serde_json::{json, Value};

pub(crate) const MAX_FILES: usize = 10_000;
pub(crate) const MAX_FOLDERS: usize = 2_000;
const MAX_DEPTH: usize = 32;
const MAX_NAME_BYTES: usize = 220;
const MAX_PATH_BYTES: usize = 1_024;
const MAX_EXISTING_COMPONENT_BYTES: usize = 255;
pub(crate) const MAX_FILE_SIZE: u64 = 10 * 1024 * 1024 * 1024;
pub(crate) const MAX_TOTAL_SIZE: u64 = 1 << 40;
pub(crate) const MAX_PAGES: usize = 128;
pub(crate) const MAX_ENTRIES_PER_PAGE: usize = 256;
pub(crate) const MAX_PAGE_BYTES: usize = 32 * 1024;
const MAX_MANIFEST_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_REPORTED_FAILURES: usize = 500;
const PART_SUFFIX: &str = ".bridgey-part";
const MAX_EXTENSION_BYTES: usize = 16;

/// Portable names, steps 1 to 6: control characters and `" * / : < > ? \ |` become `_`, no leading spaces, no trailing
/// spaces or dots, never empty, Windows device names and `.bridgey-part` endings get `_`.
pub fn normalize_name(name: &str) -> String {
    let replaced: String = name.chars().map(|c| if (c as u32) < 0x20 || c as u32 == 0x7f || "\"*/:<>?\\|".contains(c) { '_' } else { c }).collect();
    let mut value = trim(&replaced);
    let head: String = value.chars().take_while(|c| *c != '.').collect();
    let upper = head.to_uppercase();
    let reserved = matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || ((upper.starts_with("COM") || upper.starts_with("LPT")) && upper.len() == 4 && upper.as_bytes()[3].is_ascii_digit() && upper.as_bytes()[3] != b'0');
    if reserved {
        value = format!("{head}_{}", &value[head.len()..]);
    }
    if value.to_lowercase().ends_with(PART_SUFFIX) {
        value.push('_');
    }
    value
}

/// The sender's conversion, steps 1 to 7: normalised, then cut to 220 bytes keeping an extension of up to 16 bytes.
pub fn portable_name(name: &str) -> String {
    let value = normalize_name(name);
    if value.len() <= MAX_NAME_BYTES {
        return value;
    }
    let ext = match value.rfind('.') {
        Some(dot) if dot > 0 && value.len() - dot <= MAX_EXTENSION_BYTES => &value[dot..],
        _ => "",
    };
    let stem = &value[..value.len() - ext.len()];
    let limit = MAX_NAME_BYTES - ext.len();
    let mut kept = String::new();
    for c in stem.chars() {
        if kept.len() + c.len_utf8() > limit {
            break;
        }
        kept.push(c);
    }
    trim(&format!("{kept}{ext}"))
}

/// The receiver's check: the name does not change under steps 1 to 6 and fits in 220 bytes.
pub fn is_portable(name: &str) -> bool {
    !name.is_empty() && normalize_name(name) == name && name.len() <= MAX_NAME_BYTES
}

fn trim(value: &str) -> String {
    let t = value.trim_start_matches(' ').trim_end_matches([' ', '.']);
    if t.is_empty() {
        "_".into()
    } else {
        t.to_string()
    }
}

/// The key two names clash under (the apps compose to NFC first; see the module note).
pub fn case_key(name: &str) -> String {
    name.to_lowercase()
}

fn components(path: &str) -> Vec<&str> {
    if path.is_empty() {
        vec![]
    } else {
        path.split('/').collect()
    }
}

/// A manifest path: portable components joined by "/", at most 32 components and 1,024 bytes.
pub fn is_manifest_path(path: &str) -> bool {
    if path.is_empty() || path.len() > MAX_PATH_BYTES {
        return false;
    }
    let parts = components(path);
    parts.len() <= MAX_DEPTH && parts.iter().all(|p| is_portable(p))
}

/// A path of existing folders (browse, destination); "" is the place itself.
pub fn is_existing_path(path: &str) -> bool {
    if path.is_empty() {
        return true;
    }
    if path.len() > MAX_PATH_BYTES {
        return false;
    }
    let parts = components(path);
    parts.len() <= MAX_DEPTH
        && parts.iter().all(|p| !p.is_empty() && *p != "." && *p != ".." && p.len() <= MAX_EXISTING_COMPONENT_BYTES && !p.chars().any(|c| (c as u32) < 0x20 || c as u32 == 0x7f))
}

/// One existing name (a single component).
pub fn is_existing_name(name: &str) -> bool {
    !name.is_empty() && !name.contains('/') && is_existing_path(name)
}

/// "a/b" from "a" and "b"; the name alone under "".
pub fn join_path(parent: &str, name: &str) -> String {
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{parent}/{name}")
    }
}

pub fn parent(path: &str) -> &str {
    path.rfind('/').map(|i| &path[..i]).unwrap_or("")
}

pub fn leaf(path: &str) -> &str {
    path.rfind('/').map(|i| &path[i + 1..]).unwrap_or(path)
}

/// Manifest order: depth-first pre-order, siblings by the UTF-8 bytes of their names.
pub fn precedes(a: &str, b: &str) -> bool {
    let (left, right) = (components(a), components(b));
    for (l, r) in left.iter().zip(right.iter()) {
        if l != r {
            return l.as_bytes() < r.as_bytes();
        }
    }
    left.len() < right.len()
}

/// "Photos (1)" for folders, "name (1).ext" for files.
pub fn numbered(name: &str, number: u32, dir: bool) -> String {
    if dir {
        return format!("{name} ({number})");
    }
    match name.rfind('.') {
        Some(dot) if dot > 0 => format!("{} ({number}){}", &name[..dot], &name[dot..]),
        _ => format!("{name} ({number})"),
    }
}

/// `name` when free, else the first free numbered name. `taken` gets case keys.
pub fn first_free(name: &str, dir: bool, taken: impl Fn(&str) -> bool) -> String {
    if !taken(&case_key(name)) {
        return name.to_string();
    }
    for n in 1..10_000 {
        let candidate = numbered(name, n, dir);
        if !taken(&case_key(&candidate)) {
            return candidate;
        }
    }
    numbered(name, 10_000 + (crate::crypto::random::<2>()[0] as u32), dir)
}

/// The sender's rule for siblings whose names clash ignoring case: in UTF-8 byte order, each later one is renamed with
/// the smallest free number. Returns (original index, final name) in that order.
pub fn resolve_siblings(names: &[(String, bool)]) -> Vec<(usize, String)> {
    let mut order: Vec<usize> = (0..names.len()).collect();
    order.sort_by(|a, b| names[*a].0.as_bytes().cmp(names[*b].0.as_bytes()));
    let originals: std::collections::HashSet<String> = names.iter().map(|(n, _)| case_key(n)).collect();
    let mut assigned = std::collections::HashSet::new();
    order
        .into_iter()
        .map(|i| {
            let (name, dir) = &names[i];
            let chosen = if assigned.contains(&case_key(name)) { first_free(name, *dir, |k| assigned.contains(k) || originals.contains(k)) } else { name.clone() };
            assigned.insert(case_key(&chosen));
            (i, chosen)
        })
        .collect()
}

/// One manifest entry: a folder, or a file with its size and base64 SHA-256.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub dir: bool,
    pub path: String,
    pub size: u64,
    pub sha256: String,
    pub modified: Option<i64>,
}

impl Entry {
    pub fn to_json(&self) -> Value {
        if self.dir {
            return json!({"type": "dir", "path": self.path});
        }
        let mut v = json!({"type": "file", "path": self.path, "size": self.size, "sha256": self.sha256});
        if let Some(m) = self.modified {
            v["modified"] = json!(m);
        }
        v
    }

    /// An entry of a page, or None when it is malformed.
    pub fn from_json(v: &Value) -> Option<Entry> {
        let o = v.as_object()?;
        let path = o.get("path")?.as_str()?.to_string();
        match o.get("type")?.as_str()? {
            "dir" => Some(Entry { dir: true, path, size: 0, sha256: String::new(), modified: None }),
            "file" => {
                let size = o.get("size")?.as_u64()?;
                let sha256 = o.get("sha256")?.as_str()?.to_string();
                let modified = o.get("modified").and_then(Value::as_i64);
                Some(Entry { dir: false, path, size, sha256, modified })
            }
            _ => None,
        }
    }
}

/// SHA-256 over "folder-manifest-v1\n" + rootName + "\n", then `type \0 path \0 size \0 sha256 \n` per entry, base64.
pub fn manifest_digest(root_name: &str, entries: &[Entry]) -> String {
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    ctx.update(format!("folder-manifest-v1\n{root_name}\n").as_bytes());
    for e in entries {
        let (kind, size, sha) = if e.dir { ("dir", "0".to_string(), "") } else { ("file", e.size.to_string(), e.sha256.as_str()) };
        ctx.update(format!("{kind}\0{}\0{size}\0{sha}\n", e.path).as_bytes());
    }
    crate::crypto::b64(ctx.finish().as_ref())
}

/// Splits a manifest into pages of at most 256 entries and 32 KiB of plaintext. None when it needs more than 128 pages
/// or 4 MiB.
pub fn pages(folder_transfer_id: &str, entries: &[Entry]) -> Option<Vec<Value>> {
    let overhead = json!({"version": 1, "folderTransferId": folder_transfer_id, "page": MAX_PAGES, "entries": []}).to_string().len() + 16;
    let (mut pages, mut current, mut bytes, mut total) = (Vec::new(), Vec::new(), 0usize, 0usize);
    let flush = |pages: &mut Vec<Value>, current: &mut Vec<Value>, bytes: &mut usize, total: &mut usize| {
        if current.is_empty() {
            return;
        }
        pages.push(json!({"version": 1, "folderTransferId": folder_transfer_id, "page": pages.len(), "entries": std::mem::take(current)}));
        *total += *bytes + overhead;
        *bytes = 0;
    };
    for e in entries {
        let v = e.to_json();
        let size = v.to_string().len() + 1;
        if current.len() == MAX_ENTRIES_PER_PAGE || overhead + bytes + size > MAX_PAGE_BYTES {
            flush(&mut pages, &mut current, &mut bytes, &mut total);
        }
        current.push(v);
        bytes += size;
    }
    flush(&mut pages, &mut current, &mut bytes, &mut total);
    (pages.len() <= MAX_PAGES && total <= MAX_MANIFEST_BYTES).then_some(pages)
}

/// What a receiver knows of a folder offer, for checking its manifest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Offer {
    pub folder_transfer_id: String,
    pub root_name: String,
    pub file_count: usize,
    pub folder_count: usize,
    pub total_size: u64,
    pub page_count: usize,
    pub manifest_sha256: String,
}

/// The receiver's side of a manifest: pages in order, each entry checked against the offer and the order rules.
#[derive(Debug)]
pub struct Assembler {
    offer: Offer,
    pub entries: Vec<Entry>,
    directories: std::collections::HashSet<String>,
    siblings: std::collections::HashMap<String, std::collections::HashSet<String>>,
    next_page: usize,
    bytes: usize,
    files: usize,
    folders: usize,
    total: u64,
    finished: Option<Result<(), (String, Option<usize>)>>,
}

impl Assembler {
    pub fn new(offer: Offer) -> Assembler {
        Assembler { offer, entries: vec![], directories: Default::default(), siblings: Default::default(), next_page: 0, bytes: 0, files: 0, folders: 0, total: 0, finished: None }
    }

    /// An empty folder has no pages: complete at once when its digest matches.
    pub fn without_pages(&mut self) -> Option<Result<(), (String, Option<usize>)>> {
        if self.offer.page_count != 0 {
            return None;
        }
        let r = if manifest_digest(&self.offer.root_name, &[]) == self.offer.manifest_sha256 { Ok(()) } else { Err(("invalid_manifest".into(), None)) };
        self.finished = Some(r.clone());
        Some(r)
    }

    /// One page: None while more are to come, then the outcome (an error code and the entry at fault).
    pub fn add(&mut self, folder_transfer_id: &str, page: i64, entries: &[Value], page_bytes: usize) -> Option<Result<(), (String, Option<usize>)>> {
        if let Some(f) = &self.finished {
            return Some(f.clone());
        }
        let r = self.add_page(folder_transfer_id, page, entries, page_bytes);
        if r.is_some() {
            self.finished = r.clone();
        }
        r
    }

    fn add_page(&mut self, folder_transfer_id: &str, page: i64, entries: &[Value], page_bytes: usize) -> Option<Result<(), (String, Option<usize>)>> {
        let reject = |code: &str, entry: Option<usize>| Some(Err((code.to_string(), entry)));
        if folder_transfer_id != self.offer.folder_transfer_id || page != self.next_page as i64 {
            return reject("invalid_manifest", None);
        }
        self.bytes += page_bytes;
        if self.bytes > MAX_MANIFEST_BYTES {
            return reject("limit_exceeded", None);
        }
        let expected = self.offer.file_count + self.offer.folder_count;
        for v in entries {
            let index = self.entries.len();
            let Some(e) = Entry::from_json(v) else { return reject("invalid_manifest", Some(index)) };
            if index >= expected || !is_manifest_path(&e.path) {
                return reject("invalid_manifest", Some(index));
            }
            if self.entries.last().is_some_and(|p| !precedes(&p.path, &e.path)) {
                return reject("invalid_manifest", Some(index));
            }
            let p = parent(&e.path).to_string();
            if !p.is_empty() && !self.directories.contains(&p) {
                return reject("invalid_manifest", Some(index));
            }
            if !self.siblings.entry(p).or_default().insert(case_key(leaf(&e.path))) {
                return reject("invalid_manifest", Some(index));
            }
            if e.dir {
                self.directories.insert(e.path.clone());
                self.folders += 1;
                if self.folders > self.offer.folder_count {
                    return reject("invalid_manifest", Some(index));
                }
            } else {
                self.files += 1;
                let hash_ok = crate::crypto::unb64(&e.sha256).is_some_and(|h| h.len() == 32);
                if self.files > self.offer.file_count || e.size > MAX_FILE_SIZE || !hash_ok {
                    return reject("invalid_manifest", Some(index));
                }
                self.total += e.size;
                if self.total > self.offer.total_size {
                    return reject("invalid_manifest", Some(index));
                }
            }
            self.entries.push(e);
        }
        self.next_page += 1;
        if self.next_page < self.offer.page_count {
            return None;
        }
        if self.entries.len() != expected || self.files != self.offer.file_count || self.folders != self.offer.folder_count || self.total != self.offer.total_size {
            return reject("invalid_manifest", (self.entries.len() < expected).then_some(self.entries.len()));
        }
        if manifest_digest(&self.offer.root_name, &self.entries) != self.offer.manifest_sha256 {
            return reject("invalid_manifest", None);
        }
        Some(Ok(()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vectors() -> Value {
        serde_json::from_str(include_str!("../../../protocol/test-vectors/folders-v1.json")).unwrap()
    }

    /// A string, or {part, times, join, suffix}: join.join([part] * times) + suffix.
    fn text(v: &Value) -> String {
        match v {
            Value::String(s) => s.clone(),
            o => {
                let part = o["part"].as_str().unwrap();
                let times = o["times"].as_u64().unwrap() as usize;
                let join = o.get("join").and_then(Value::as_str).unwrap_or("");
                format!("{}{}", vec![part; times].join(join), o.get("suffix").and_then(Value::as_str).unwrap_or(""))
            }
        }
    }

    /// Names that need NFC composition, which this crate leaves to the host (see the module note).
    fn needs_nfc(s: &str) -> bool {
        s.chars().any(|c| ('\u{300}'..='\u{36f}').contains(&c))
    }

    #[test]
    fn portable_names() {
        let v = vectors();
        for case in v["portableNames"].as_array().unwrap() {
            let input = text(&case["input"]);
            if needs_nfc(&input) {
                continue;
            }
            assert_eq!(portable_name(&input), text(&case["portable"]), "{input:?}");
        }
        for case in v["notPortable"].as_array().unwrap() {
            let name = text(case);
            if needs_nfc(&name) {
                continue;
            }
            assert!(!is_portable(&name), "{name:?}");
        }
    }

    #[test]
    fn paths() {
        let v = vectors();
        for p in v["manifestPaths"]["valid"].as_array().unwrap() {
            assert!(is_manifest_path(&text(p)), "{p}");
        }
        for p in v["manifestPaths"]["invalid"].as_array().unwrap() {
            assert!(!is_manifest_path(&text(p)), "{p}");
        }
        for p in v["existingPaths"]["valid"].as_array().unwrap() {
            assert!(is_existing_path(&text(p)), "{p}");
        }
        for p in v["existingPaths"]["invalid"].as_array().unwrap() {
            assert!(!is_existing_path(&text(p)), "{p}");
        }
    }

    #[test]
    fn conflict_names() {
        let v = vectors();
        for case in v["conflictNames"].as_array().unwrap() {
            let taken: Vec<String> = case["taken"].as_array().unwrap().iter().map(|t| case_key(t.as_str().unwrap())).collect();
            let got = first_free(case["name"].as_str().unwrap(), case["dir"].as_bool().unwrap(), |k| taken.iter().any(|t| t == k));
            assert_eq!(got, case["result"].as_str().unwrap());
        }
        for case in v["caseClashes"].as_array().unwrap() {
            let names: Vec<(String, bool)> = case["siblings"].as_array().unwrap().iter().map(|s| (s["name"].as_str().unwrap().to_string(), s["dir"].as_bool().unwrap())).collect();
            if names.iter().any(|(n, _)| needs_nfc(n)) {
                continue;
            }
            // A clash that differs only in composition is NFC's (É and é compose alike here, so this one still runs).
            let resolved = resolve_siblings(&names).into_iter().map(|(_, n)| n).collect::<Vec<_>>();
            let expected: Vec<String> = case["resolved"].as_array().unwrap().iter().map(|r| r.as_str().unwrap().to_string()).collect();
            assert_eq!(resolved, expected);
        }
    }

    #[test]
    fn manifest_digest_and_pages() {
        let v = vectors();
        let d = &v["manifestDigest"];
        let entries: Vec<Entry> = d["entries"].as_array().unwrap().iter().map(|e| Entry::from_json(e).unwrap()).collect();
        assert_eq!(manifest_digest(d["rootName"].as_str().unwrap(), &entries), d["sha256"].as_str().unwrap());
        // The offer in the vectors' messages names this manifest.
        assert_eq!(v["messages"]["folders.offer"]["manifestSha256"], d["sha256"]);
        let pages = pages("4b0c9d5e-1b2c-4d5e-8f90-0a1b2c3d4e5f", &entries).unwrap();
        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0]["entries"].as_array().unwrap().len(), 4);
        // Round trip: the receiver accepts what the sender wrote.
        let offer = Offer {
            folder_transfer_id: "4b0c9d5e-1b2c-4d5e-8f90-0a1b2c3d4e5f".into(),
            root_name: "Photos".into(),
            file_count: 2,
            folder_count: 2,
            total_size: 2_481_128,
            page_count: 1,
            manifest_sha256: d["sha256"].as_str().unwrap().into(),
        };
        let mut a = Assembler::new(offer.clone());
        let page = &pages[0];
        assert_eq!(a.add(&offer.folder_transfer_id, 0, page["entries"].as_array().unwrap(), page.to_string().len()), Some(Ok(())));
        assert_eq!(a.entries, entries);
        // A wrong digest, a file outside its folder, an order out of place.
        let mut bad = Assembler::new(Offer { manifest_sha256: "AAAA".into(), ..offer.clone() });
        assert!(matches!(bad.add(&offer.folder_transfer_id, 0, page["entries"].as_array().unwrap(), 10), Some(Err(_))));
        let mut orphan = Assembler::new(Offer { file_count: 1, folder_count: 0, total_size: 5, ..offer.clone() });
        let e = [json!({"type": "file", "path": "x/notes.txt", "size": 5, "sha256": "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="})];
        assert_eq!(orphan.add(&offer.folder_transfer_id, 0, &e, 10), Some(Err(("invalid_manifest".into(), Some(0)))));
        let mut order = Assembler::new(offer.clone());
        let mut reversed = page["entries"].as_array().unwrap().clone();
        reversed.swap(0, 1);
        assert!(matches!(order.add(&offer.folder_transfer_id, 0, &reversed, 10), Some(Err(_))));
        // An empty folder has no pages.
        let empty = Offer { file_count: 0, folder_count: 0, total_size: 0, page_count: 0, manifest_sha256: manifest_digest("Empty", &[]), root_name: "Empty".into(), ..offer };
        assert_eq!(Assembler::new(empty).without_pages(), Some(Ok(())));
    }
}
