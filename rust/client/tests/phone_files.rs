//! The phone's files between two session clients: a "PC" and a simulated phone that serves browsing, thumbnails and
//! downloads and takes uploads (Client::simulate_phone_for_tests), with real folder transfers both ways.

mod common;

use bridgey_core::phone::Area;
use bridgey_core::Event;
use common::{pair, Peer};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("bridgey-phone-files-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn setup(phone_inbox: &Path) -> (Peer, Peer) {
    let (pc, phone) = (Peer::new("Windows PC"), Peer::new("Test phone"));
    phone.client.simulate_phone_for_tests(true);
    phone.client.set_receive_dir(Some(phone_inbox));
    for p in [&pc, &phone] {
        p.client.set_feature(None, "files", true).unwrap();
    }
    phone.client.set_feature(None, "files_browse_draft1", true).unwrap();
    pc.client.set_feature(None, "folders_receive_draft1", true).unwrap();
    pair(&pc, &phone);
    let deadline = Instant::now() + Duration::from_secs(20);
    while files(&pc, &phone, json!({"op": "status"}))["available"] != json!(true) {
        assert!(Instant::now() < deadline, "the phone's files never became available");
        std::thread::sleep(Duration::from_millis(50));
    }
    (pc, phone)
}

fn files(pc: &Peer, phone: &Peer, command: Value) -> Value {
    pc.client.phone(Area::PhoneFiles, &phone.id(), &command)
}

fn ask(pc: &Peer, phone: &Peer, command: Value) -> String {
    let answer = files(pc, phone, command.clone());
    assert_eq!(answer["ok"], json!(true), "{command}: {answer}");
    answer["requestId"].as_str().or(answer["uploadId"].as_str()).unwrap().to_string()
}

/// A PhoneFiles event `what` matching `f`, with its detail.
fn wait_for(pc: &Peer, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    pc.wait(what, |e| match e {
        Event::Phone { area: Area::PhoneFiles, what: w, json, .. } if w == what => {
            let v: Value = serde_json::from_str(json).unwrap();
            f(&v).then_some(v)
        }
        _ => None,
    })
}

fn answer(pc: &Peer, what: &str, id: &str) -> Value {
    wait_for(pc, what, |v| v["requestId"] == json!(id))
}

fn names(list: &Value) -> Vec<String> {
    list["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap().to_string()).collect()
}

#[test]
fn browse_places_folders_photos_and_thumbnails() {
    let inbox = scratch("browse-inbox");
    let (pc, phone) = setup(&inbox);

    let id = ask(&pc, &phone, json!({"op": "places"}));
    let places = answer(&pc, "places", &id);
    assert_eq!(places["places"].as_array().unwrap().len(), 2);
    assert_eq!(places["writable"], json!(true));
    assert_eq!(places["media"], json!("full"));

    let id = ask(&pc, &phone, json!({"op": "list", "placeId": "default", "path": ""}));
    let root = answer(&pc, "list", &id);
    assert_eq!(names(&root), vec!["Trip", "notes.txt"], "folders first");
    assert_eq!(root["entries"][0]["dir"], json!(true));
    assert_eq!(root["entries"][0]["size"], Value::Null);

    let id = ask(&pc, &phone, json!({"op": "list", "placeId": "default", "path": "Trip", "sort": "name"}));
    let trip = answer(&pc, "list", &id);
    assert_eq!(names(&trip), vec!["Beach", "IMG_0001.jpg", "IMG_0002.jpg"]);
    assert_eq!(trip["entries"][1]["thumb"], json!(true));
    assert_eq!(trip["entries"][1]["size"], json!(300_000));

    let id = ask(&pc, &phone, json!({"op": "list", "placeId": "default", "path": "Nowhere"}));
    assert_eq!(answer(&pc, "list", &id)["error"], json!("not_found"));

    let id = ask(&pc, &phone, json!({"op": "media", "kind": "media"}));
    let media = answer(&pc, "media", &id);
    assert_eq!(media["items"].as_array().unwrap().len(), 2);
    assert_eq!(media["items"][0]["ref"], json!({"mediaId": "101"}));

    let items = json!([{"key": "a", "ref": {"mediaId": "101"}}, {"key": "b", "ref": {"placeId": "default", "path": "", "name": "notes.txt"}}]);
    let id = ask(&pc, &phone, json!({"op": "thumbnails", "items": items, "size": 128}));
    let thumbs = answer(&pc, "thumbnails", &id);
    assert_eq!(thumbs["thumbs"][0]["key"], json!("a"));
    assert!(thumbs["thumbs"][0]["data"].as_str().unwrap().starts_with("iVBOR"));
    assert_eq!(thumbs["missing"], json!(["b"]));
    assert_eq!(thumbs["done"], json!(true));

    // Bad requests never leave this device.
    assert_eq!(files(&pc, &phone, json!({"op": "list", "placeId": "nope", "path": ""}))["error"], json!("invalid"));
    assert_eq!(files(&pc, &phone, json!({"op": "list", "placeId": "default", "path": "../x"}))["error"], json!("invalid"));
    assert_eq!(files(&pc, &phone, json!({"op": "thumbnails", "items": []}))["error"], json!("invalid"));

    // Many requests at once wait their turn in the lane and all get answered.
    let ids: Vec<String> = (0..9).map(|_| ask(&pc, &phone, json!({"op": "list", "placeId": "default", "path": "Trip"}))).collect();
    for id in ids {
        assert_eq!(names(&answer(&pc, "list", &id)).len(), 3);
    }
    pc.stop();
    phone.stop();
}

#[test]
fn downloads_land_verified_and_never_overwrite() {
    let inbox = scratch("download-inbox");
    let folder = scratch("download-here");
    std::fs::write(folder.join("notes.txt"), b"mine").unwrap();
    let (pc, phone) = setup(&inbox);

    let items = json!([{"placeId": "default", "path": "", "name": "notes.txt"}, {"placeId": "default", "path": "", "name": "Trip"}]);
    let id = ask(&pc, &phone, json!({"op": "download", "items": items, "folder": folder.to_string_lossy()}));
    let started = wait_for(&pc, "download", |v| v["requestId"] == json!(id) && v["state"] == json!("started"));
    assert_eq!((started["files"].as_i64(), started["folders"].as_i64()), (Some(4), Some(2)));
    let done = wait_for(&pc, "download", |v| v["requestId"] == json!(id) && v["state"] != json!("started") && v["state"] != json!("receiving"));
    assert_eq!(done["state"], json!("done"), "{done}");
    assert_eq!(done["filesDone"], json!(4));
    assert_eq!(done["renamed"], json!(1));

    // The PC's own notes.txt is untouched; the phone's became "notes (1).txt".
    assert_eq!(std::fs::read(folder.join("notes.txt")).unwrap(), b"mine");
    assert_eq!(std::fs::read(folder.join("notes (1).txt")).unwrap(), b"Bring the charger.\n");
    let photo = std::fs::read(folder.join("Trip").join("IMG_0001.jpg")).unwrap();
    assert_eq!(photo.len(), 300_000);
    assert_eq!(photo[..4], [1, 32, 63, 94]);
    assert_eq!(std::fs::read(folder.join("Trip").join("Beach").join("sea.jpg")).unwrap().len(), 70_000);
    assert_eq!(std::fs::read(folder.join("Trip").join("IMG_0002.jpg")).unwrap().len(), 2_048);
    // No partial files are left behind, and the saved items are listed.
    let leftovers: Vec<_> = walk(&folder).into_iter().filter(|p| p.to_string_lossy().contains(".part")).collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");
    assert_eq!(done["saved"].as_array().unwrap().len(), 2);

    // A download of something that is not there fails in plain terms.
    let id = ask(&pc, &phone, json!({"op": "download", "items": [{"placeId": "default", "path": "", "name": "gone.txt"}], "folder": folder.to_string_lossy()}));
    assert_eq!(wait_for(&pc, "download", |v| v["requestId"] == json!(id))["error"], json!("not_found"));
    pc.stop();
    phone.stop();
}

#[test]
fn uploads_arrive_in_the_folder_being_browsed() {
    let inbox = scratch("upload-inbox");
    let source = scratch("upload-source");
    let report: Vec<u8> = (0..500_000u32).map(|i| (i % 251) as u8).collect();
    std::fs::write(source.join("Report: Q3.pdf"), &report).unwrap();
    std::fs::write(source.join("photo.jpg"), b"jpeg bytes").unwrap();
    let (pc, phone) = setup(&inbox);

    let files_to_send = json!([{"path": source.join("Report: Q3.pdf").to_string_lossy()}, {"path": source.join("photo.jpg").to_string_lossy()}]);
    let id = ask(&pc, &phone, json!({"op": "upload", "placeId": "default", "path": "", "files": files_to_send}));
    wait_for(&pc, "upload", |v| v["uploadId"] == json!(id) && v["state"] == json!("hashing"));
    let done = wait_for(&pc, "upload", |v| v["uploadId"] == json!(id) && matches!(v["state"].as_str(), Some("done" | "incomplete" | "failed" | "cancelled")));
    assert_eq!(done["state"], json!("done"), "{done}");
    assert_eq!(done["filesDone"], json!(2));
    assert_eq!(done["result"]["savedFiles"], json!(2));
    // The name is made portable on the way (":" is not allowed on the phone's storage).
    assert_eq!(std::fs::read(inbox.join("Report_ Q3.pdf")).unwrap(), report);
    assert_eq!(std::fs::read(inbox.join("photo.jpg")).unwrap(), b"jpeg bytes");

    // Uploading a file that is not there is refused at once.
    assert_eq!(files(&pc, &phone, json!({"op": "upload", "placeId": "default", "path": "", "files": [{"path": "/nonexistent/x"}]}))["error"], json!("invalid"));
    pc.stop();
    phone.stop();
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            out.extend(walk(&p));
        }
        out.push(p);
    }
    out
}
