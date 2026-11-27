//! A simulated phone's files (sim.rs, tests and the scripted peer only): a few places, folders and files, thumbnails,
//! and downloads served as real folders through the same folder code a desktop uses.

use super::*;

pub(crate) fn sim_incoming(kind: &str) -> Option<Incoming> {
    let (kind, max): (&'static str, usize) = match kind {
        "places.list" => ("places.list", SMALL),
        "places.files" => ("places.files", SMALL),
        "media.list" => ("media.list", SMALL),
        "media.thumbnails" => ("media.thumbnails", SMALL),
        "media.cancel" => ("media.cancel", SMALL),
        "places.download" => ("places.download", SMALL),
        _ => return None,
    };
    Some(Incoming { area: Area::PhoneFiles, kind, feature: FILES, max, with_message_id: false })
}

/// The simulated phone's files: (place, folder path, name, folder or the file's bytes).
fn sim_tree() -> Vec<(&'static str, &'static str, &'static str, Option<Vec<u8>>)> {
    let photo = |seed: u8, size: usize| Some((0..size).map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed)).collect::<Vec<u8>>());
    vec![
        ("default", "", "Trip", None),
        ("default", "", "notes.txt", Some(b"Bring the charger.\n".to_vec())),
        ("default", "Trip", "Beach", None),
        ("default", "Trip", "IMG_0001.jpg", photo(1, 300_000)),
        ("default", "Trip", "IMG_0002.jpg", photo(2, 2_048)),
        ("default", "Trip/Beach", "sea.jpg", photo(3, 70_000)),
    ]
}

/// A 1 by 1 PNG.
const SIM_THUMB: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

pub(crate) fn sim_receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) -> bool {
    // As a phone, folder answers to a download it serves, uploads into its receive folder and its own requests'
    // answers go through the same folder code; only the requests below are the phone's to serve.
    let Some(spec) = sim_incoming(kind) else { return false };
    let Some(o) = phone::versioned(plain, spec.max) else { return true };
    let Some(id) = request_id(o.get("requestId")) else { return true };
    let reply = |kind: &'static str, v: Value| {
        send(inner, device_id, kind, &v);
    };
    let tree = sim_tree();
    match kind {
        "places.list" => reply(
            "places.listed",
            json!({"version": 1, "requestId": id, "mode": "sender_picks", "fixedLabel": null, "defaultFreeBytes": 10_000_000_000u64, "writable": true, "media": "full", "documents": true,
                   "places": [{"placeId": "default", "label": "Download/Bridgey", "available": true, "freeBytes": 10_000_000_000u64},
                              {"placeId": "q3Jx0bVv1eG7tq8Wm2l5wA", "label": "Pictures", "available": true, "freeBytes": null}]}),
        ),
        "places.files" => {
            let place = o.get("placeId").and_then(Value::as_str).unwrap_or("");
            let path = o.get("path").and_then(Value::as_str).unwrap_or("");
            let known = place == "q3Jx0bVv1eG7tq8Wm2l5wA" && path.is_empty() || tree.iter().any(|(p, f, n, d)| *p == place && (path.is_empty() || (d.is_none() && folders::join_path(f, n) == path)));
            if !known {
                reply("places.error", json!({"version": 1, "requestId": id, "code": "not_found"}));
                return true;
            }
            let mut entries: Vec<Value> = tree
                .iter()
                .filter(|(p, f, ..)| *p == place && *f == path)
                .map(|(_, _, n, d)| match d {
                    None => json!({"name": n, "dir": true, "size": null, "modified": 1_790_000_000_000i64, "mimeType": null, "thumb": false}),
                    Some(b) => json!({"name": n, "dir": false, "size": b.len(), "modified": 1_790_000_000_000i64, "mimeType": crate::transfer::mime_for(n), "thumb": n.ends_with(".jpg")}),
                })
                .collect();
            entries.sort_by_key(|e| (!e["dir"].as_bool().unwrap_or(false), e["name"].as_str().unwrap_or("").to_lowercase()));
            let (dirs, files) = (entries.iter().filter(|e| e["dir"] == true).count(), entries.iter().filter(|e| e["dir"] == false).count());
            reply(
                "places.files_page",
                json!({"version": 1, "requestId": id, "placeId": place, "path": path, "entries": entries, "folderCount": dirs, "fileCount": files, "nextCursor": null, "writable": true}),
            );
        }
        "media.list" => {
            let kind = o.get("kind").and_then(Value::as_str).unwrap_or("media");
            let photos = vec![
                json!({"ref": {"mediaId": "101"}, "name": "IMG_0001.jpg", "size": 300_000, "modified": 1_790_000_000_000i64, "mimeType": "image/jpeg", "width": 4000, "height": 3000, "durationMs": null, "thumb": true, "location": "Camera", "taken": 1_790_000_000_000i64}),
                json!({"ref": {"mediaId": "102"}, "name": "IMG_0002.jpg", "size": 2_048, "modified": 1_789_900_000_000i64, "mimeType": "image/jpeg", "width": 3000, "height": 4000, "durationMs": null, "thumb": true, "location": "Camera", "taken": 1_789_900_000_000i64}),
            ];
            let docs = vec![json!({"ref": {"placeId": "default", "path": "", "name": "notes.txt"}, "name": "notes.txt", "size": 19, "modified": 1_790_000_000_000i64, "mimeType": "text/plain", "width": null, "height": null, "durationMs": null, "thumb": false, "location": "Download/Bridgey"})];
            let items = match kind {
                "files" => docs,
                "recent" => photos.into_iter().chain(docs).collect(),
                _ => photos,
            };
            reply("media.page", json!({"version": 1, "requestId": id, "kind": kind, "items": items, "nextCursor": null, "access": "full", "indexing": false}));
        }
        "media.thumbnails" => {
            let items = o.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
            let (mut thumbs, mut missing) = (vec![], vec![]);
            for i in &items {
                let key = i.get("key").and_then(Value::as_str).unwrap_or("").to_string();
                let image = i["ref"].get("mediaId").is_some() || i["ref"].get("name").and_then(Value::as_str).is_some_and(|n| n.ends_with(".jpg"));
                if image {
                    thumbs.push(json!({"key": key, "mimeType": "image/png", "width": 1, "height": 1, "tint": "#336699", "data": SIM_THUMB}));
                } else {
                    missing.push(key);
                }
            }
            reply("media.thumbnails_batch", json!({"version": 1, "requestId": id, "thumbs": thumbs, "missing": missing, "done": true}));
        }
        "media.cancel" => {}
        "places.download" => sim_download(inner, device_id, &id, &o, &tree),
        _ => return false,
    }
    true
}

/// Serves a download: writes the items to a scratch folder, answers `places.download_started` and sends them as a
/// folder with `into`, the way the phone does.
fn sim_download(inner: &Inner, device_id: &str, id: &str, o: &Map<String, Value>, tree: &[(&str, &str, &str, Option<Vec<u8>>)]) {
    let scratch = std::env::temp_dir().join(format!("bridgey-sim-{}", crate::crypto::uuid4()));
    let mut items: Vec<(String, Option<PathBuf>)> = Vec::new();
    let refs = o.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
    for r in refs {
        let (place, path, name) = (r["placeId"].as_str().unwrap_or(""), r["path"].as_str().unwrap_or(""), r["name"].as_str().unwrap_or(""));
        let Some((_, _, _, data)) = tree.iter().find(|(p, f, n, _)| *p == place && *f == path && *n == name) else {
            send(inner, device_id, "places.error", &json!({"version": 1, "requestId": id, "code": "not_found"}));
            return;
        };
        let full = folders::join_path(path, name);
        let mut add = |rel: String, data: &Option<Vec<u8>>| match data {
            None => items.push((rel, None)),
            Some(bytes) => {
                let file = scratch.join(rel.replace('/', "_"));
                let _ = std::fs::create_dir_all(&scratch).and_then(|_| std::fs::write(&file, bytes));
                items.push((rel, Some(file)));
            }
        };
        add(name.to_string(), data);
        if data.is_none() {
            // The folder's subtree, by path relative to the folder's parent.
            for (p, f, n, d) in tree {
                let inside = folders::join_path(f, n);
                if *p == place && inside.starts_with(&format!("{full}/")) {
                    add(format!("{name}/{}", &inside[full.len() + 1..]), d);
                }
            }
        }
    }
    let folder_id = crate::crypto::uuid4();
    let files = items.iter().filter(|(_, p)| p.is_some()).count();
    let dirs = items.len() - files;
    let total: u64 = items.iter().filter_map(|(_, p)| p.as_ref()).filter_map(|p| std::fs::metadata(p).ok()).map(|m| m.len()).sum();
    let root = items.first().map(|(n, _)| n.split('/').next().unwrap_or("").to_string()).unwrap_or_default();
    send(
        inner,
        device_id,
        "places.download_started",
        &json!({"version": 1, "requestId": id, "folderTransferId": folder_id, "rootName": root, "fileCount": files, "folderCount": dirs, "totalSize": total}),
    );
    start_send(inner, device_id, &folder_id, Some(id.to_string()), None, items);
}

