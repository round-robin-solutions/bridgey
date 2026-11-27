//! The phone's files against the golden vectors in protocol/test-vectors/browse-v1.json: what this device reads from the
//! phone (pages, download answers, thumbnails, previews, ranges) and what it writes (media.list, media.cancel).

use super::*;

fn vectors(group: &str) -> Vec<Value> {
    let all: Value = serde_json::from_str(include_str!("../../../../protocol/test-vectors/browse-v1.json")).unwrap();
    let list = all[group].as_array().unwrap_or_else(|| panic!("{group}")).clone();
    assert!(!list.is_empty(), "{group}");
    list
}

fn plaintext(v: &Value) -> Vec<u8> {
    match v.get("plaintextString").and_then(Value::as_str) {
        Some(raw) => raw.as_bytes().to_vec(),
        None => serde_json::to_vec(&v["plaintext"]).unwrap(),
    }
}

fn reads(group: &str, decode: impl Fn(&[u8]) -> Option<Value>) {
    let failed: Vec<String> = vectors(group)
        .iter()
        .filter(|v| decode(&plaintext(v)).unwrap_or(json!("reject")) != v["expect"])
        .map(|v| format!("{}: {}", v["name"], decode(&plaintext(v)).unwrap_or(json!("reject"))))
        .collect();
    assert!(failed.is_empty(), "{group} vectors this device reads differently: {failed:#?}");
}

/// The vectors of `group` marked write: from the plaintext's values, this device writes exactly that plaintext.
fn writes(group: &str, encode: impl Fn(&Value) -> Value) {
    let list: Vec<Value> = vectors(group).into_iter().filter(|v| v["write"] == json!(true)).collect();
    assert!(!list.is_empty());
    for v in list {
        assert_eq!(encode(&v["plaintext"]), v["plaintext"], "{}", v["name"]);
    }
}

#[test]
fn files_page() {
    reads("placesFilesPage", |p| {
        decode_files_page(p).map(|page| {
            json!({"entries": page.entries.iter().map(FileEntry::to_json).collect::<Vec<_>>(), "folderCount": page.folder_count, "fileCount": page.file_count,
                   "nextCursor": page.next_cursor, "writable": page.writable})
        })
    });
}

#[test]
fn download_started() {
    reads("placesDownloadStarted", |p| {
        decode_download_started(p).map(|s| json!({"folderTransferId": s.folder_transfer_id, "rootName": s.root_name, "fileCount": s.file_count, "folderCount": s.folder_count, "totalSize": s.total_size}))
    });
}

#[test]
fn thumbnails_batch() {
    reads("mediaThumbnailsBatch", |p| {
        decode_thumbnails_batch(p).map(|b| {
            json!({"thumbs": b.thumbs.iter().map(|t| json!({"key": t.key, "mimeType": t.mime_type, "width": t.width, "height": t.height, "tint": t.tint})).collect::<Vec<_>>(),
                   "missing": b.missing, "done": b.done})
        })
    });
}

#[test]
fn preview_and_range_parts() {
    reads("mediaPreviewPart", |p| decode_preview_part(p).map(|(v, _)| v));
    reads("mediaRangePart", |p| decode_range_part(p).map(|(v, _)| v));
}

#[test]
fn requests_as_this_device_writes_them() {
    writes("mediaList", |p| media_list_request(p["requestId"].as_str().unwrap(), p["kind"].as_str().unwrap(), p.get("cursor").and_then(Value::as_str), p["limit"].as_i64().unwrap()));
    writes("mediaCancel", |p| media_cancel_request(p["requestId"].as_str().unwrap()));
}

#[test]
fn refs_and_places() {
    assert!(is_place_id("default"));
    assert!(is_place_id("q3Jx0bVv1eG7tq8Wm2l5wA"));
    assert!(!is_place_id("q3Jx0bVv1eG7tq8Wm2l5w"));
    assert!(valid_ref(&json!({"placeId": "default", "path": "Trip", "name": "IMG_0001.jpg"})));
    assert!(valid_ref(&json!({"mediaId": "1234"})));
    assert!(!valid_ref(&json!({"mediaId": "12a"})));
    assert!(!valid_ref(&json!({"mediaId": "99999999999999999999"})));
    assert!(!valid_ref(&json!({"placeId": "default", "path": "../x", "name": "a"})));
    assert!(!valid_ref(&json!({"placeId": "default", "path": "", "name": "a/b"})));
    // browse-v1.json's own refs, as the golden vectors give them.
    let all: Value = serde_json::from_str(include_str!("../../../../protocol/test-vectors/protocol-v1.json")).unwrap();
    for v in all["browseRef"].as_array().unwrap() {
        let r = v.get("ref").or(v.get("plaintext")).unwrap();
        let accepted = v["expect"] != json!("reject");
        assert_eq!(valid_ref(r), accepted, "{}", v["name"]);
    }
}
