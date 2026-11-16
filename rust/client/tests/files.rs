//! Files and links between two session clients: both ways, refused when the switch is off, cancelled, and a
//! changed file is never sent as the one offered. The wire is the apps' (docs/protocol.md "Files (`files.v1`)",
//! "Quick actions"); the iOS app is the first host to use it.

use bridgey_core::{Client, Config, Event, MemoryStorage, Next, SendStatus};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(30);

struct Peer {
    client: Arc<Client>,
    log: Arc<(Mutex<Vec<Event>>, Condvar)>,
    pump: Option<std::thread::JoinHandle<()>>,
    dir: PathBuf,
}

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("bridgey-files-{tag}-{}", std::process::id())).join(format!("{:?}", Instant::now()).replace(['.', ' '], ""));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

impl Peer {
    fn new(name: &str, files: bool) -> Peer {
        let dir = temp_dir(name);
        let mut config = Config::new(name, "ios");
        config.port = 0;
        config.discovery = false;
        config.receive_dir = Some(dir.join("received"));
        config.defaults.set("files", files);
        config.defaults.set("links", true);
        let client = Arc::new(Client::start(config, Arc::new(MemoryStorage::default())).expect("client starts"));
        let log: Arc<(Mutex<Vec<Event>>, Condvar)> = Arc::default();
        let pump = {
            let (client, log) = (client.clone(), log.clone());
            std::thread::spawn(move || loop {
                match client.next_event(Duration::from_millis(200)) {
                    Next::Event(e) => {
                        if let Event::PairingCode { pairing, .. } = &e {
                            let _ = client.confirm_pairing(*pairing, true);
                        }
                        log.0.lock().unwrap().push(e);
                        log.1.notify_all();
                    }
                    Next::Timeout => {}
                    Next::Closed => return,
                }
            })
        };
        Peer { client, log, pump: Some(pump), dir }
    }

    fn id(&self) -> String {
        self.client.device_id().to_string()
    }

    fn wait<T>(&self, what: &str, f: impl Fn(&Event) -> Option<T>) -> T {
        let deadline = Instant::now() + WAIT;
        let mut events = self.log.0.lock().unwrap();
        loop {
            if let Some(found) = events.iter().find_map(&f) {
                return found;
            }
            let now = Instant::now();
            assert!(now < deadline, "{what}: not seen; events: {:#?}", *events);
            events = self.log.1.wait_timeout(events, deadline - now).unwrap().0;
        }
    }

    fn write(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.dir.join(name);
        std::fs::write(&path, bytes).unwrap();
        path
    }

    fn stop(mut self) {
        self.client.stop();
        if let Some(p) = self.pump.take() {
            p.join().unwrap();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn pair(a: &Peer, b: &Peer) {
    b.client.allow_pairing(Duration::from_secs(120));
    a.client.pair(None, Some("127.0.0.1"), b.client.port()).unwrap();
    a.wait("connected", |e| matches!(e, Event::Connected { .. }).then_some(()));
    b.wait("connected", |e| matches!(e, Event::Connected { .. }).then_some(()));
    a.wait("features", |e| matches!(e, Event::Features { remote, .. } if remote.get("clipboard")).then_some(()));
    b.wait("features", |e| matches!(e, Event::Features { remote, .. } if remote.get("clipboard")).then_some(()));
}

/// Bytes that are not all the same, so a misplaced chunk would change the hash.
fn pattern(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i * 31 % 251) as u8).collect()
}

fn done_path(p: &Peer, transfer: Option<u64>) -> PathBuf {
    p.wait("file saved", |e| match e {
        Event::FileDone { transfer: t, incoming: true, path: Some(path), .. } if transfer.is_none_or(|x| x == *t) => Some(PathBuf::from(path)),
        _ => None,
    })
}

#[test]
fn files_go_both_ways_and_are_verified() {
    let (a, b) = (Peer::new("A", true), Peer::new("B", true));
    pair(&a, &b);
    // A to B: several chunks, one byte past a chunk boundary.
    let big = pattern(24 * 1024 * 5 + 1);
    let path = a.write("photo.jpg", &big);
    let t = a.client.send_file(&b.id(), &path, None, None).unwrap();
    let incoming = b.wait("offer at B", |e| match e {
        Event::FileIncoming { transfer, name, size, mime, .. } => Some((*transfer, name.clone(), *size, mime.clone())),
        _ => None,
    });
    assert_eq!((incoming.1.as_str(), incoming.2, incoming.3.as_str()), ("photo.jpg", big.len() as u64, "image/jpeg"));
    let saved = done_path(&b, Some(incoming.0));
    assert_eq!(std::fs::read(&saved).unwrap(), big);
    assert_eq!(saved.file_name().unwrap(), "photo.jpg");
    a.wait("A told it was saved", |e| matches!(e, Event::FileDone { transfer, incoming: false, .. } if *transfer == t).then_some(()));
    // B to A: an empty file, and the same name twice, which never overwrites.
    let empty = b.write("empty.txt", b"");
    b.client.send_file(&a.id(), &empty, Some("notes.txt"), None).unwrap();
    let first = done_path(&a, None);
    assert_eq!(first.file_name().unwrap(), "notes.txt");
    assert_eq!(std::fs::read(&first).unwrap(), b"");
    let second_src = b.write("second.txt", b"second");
    let t2 = b.client.send_file(&a.id(), &second_src, Some("notes.txt"), None).unwrap();
    b.wait("second saved", |e| matches!(e, Event::FileDone { transfer, incoming: false, .. } if *transfer == t2).then_some(()));
    assert_eq!(std::fs::read(first.with_file_name("notes 2.txt")).unwrap(), b"second");
    // No partial files are left behind.
    let leftovers: Vec<_> = std::fs::read_dir(first.parent().unwrap()).unwrap().filter_map(|e| e.ok()).filter(|e| e.file_name().to_string_lossy().ends_with(".part")).collect();
    assert!(leftovers.is_empty());
    a.stop();
    b.stop();
}

#[test]
fn files_go_one_at_a_time_in_order() {
    let (a, b) = (Peer::new("A", true), Peer::new("B", true));
    pair(&a, &b);
    let names = ["one.bin", "two.bin", "three.bin"];
    for (i, n) in names.iter().enumerate() {
        // The first is the largest, so it would be overtaken if files were hashed side by side.
        let p = a.write(n, &pattern(if i == 0 { 4_000_000 } else { 10 + i }));
        a.client.send_file(&b.id(), &p, None, None).unwrap();
    }
    for n in names {
        b.wait(n, |e| matches!(e, Event::FileDone { name, incoming: true, .. } if name == n).then_some(()));
    }
    let order: Vec<String> = b.log.0.lock().unwrap().iter().filter_map(|e| match e {
        Event::FileIncoming { name, .. } => Some(name.clone()),
        _ => None,
    }).collect();
    assert_eq!(order, names);
    a.stop();
    b.stop();
}

#[test]
fn files_off_is_refused_and_the_sender_told() {
    let (a, b) = (Peer::new("A", true), Peer::new("B", false));
    pair(&a, &b);
    // B's map says files off, so A refuses before offering.
    let p = a.write("x.txt", b"x");
    assert_eq!(a.client.send_file(&b.id(), &p, None, None), Err(bridgey_core::ClientError::FeatureOff));
    a.stop();
    b.stop();
}

#[test]
fn files_off_after_the_offer_rejects_it() {
    let (a, b) = (Peer::new("A", true), Peer::new("B", true));
    pair(&a, &b);
    // B has no receive folder: an offer that reaches it is refused (files.rejected), as a stale switch would be.
    b.client.set_receive_dir(None);
    let p = a.write("x.txt", b"hello");
    let t = a.client.send_file(&b.id(), &p, None, None).unwrap();
    let reason = a.wait("refused", |e| match e {
        Event::FileFailed { transfer, reason, .. } if *transfer == t => Some(reason.clone()),
        _ => None,
    });
    assert_eq!(reason, "rejected");
    a.stop();
    b.stop();
}

#[test]
fn a_cancelled_file_leaves_nothing_behind() {
    let (a, b) = (Peer::new("A", true), Peer::new("B", true));
    pair(&a, &b);
    let p = a.write("big.bin", &pattern(24 * 1024 * 400));
    let t = a.client.send_file(&b.id(), &p, None, None).unwrap();
    b.wait("receiving", |e| matches!(e, Event::FileProgress { incoming: true, bytes, .. } if *bytes > 0).then_some(()));
    a.client.cancel_file(t).unwrap();
    a.wait("cancelled here", |e| matches!(e, Event::FileFailed { transfer, reason, .. } if *transfer == t && reason == "cancelled").then_some(()));
    b.wait("cancelled there", |e| matches!(e, Event::FileFailed { incoming: true, reason, .. } if reason == "cancelled_remote").then_some(()));
    let received = b.dir.join("received");
    let left: Vec<_> = std::fs::read_dir(&received).unwrap().filter_map(|e| e.ok()).collect();
    assert!(left.is_empty(), "{left:?}");
    // The session is still usable.
    a.client.send_clipboard(&b.id(), "still here").unwrap();
    b.wait("text after cancel", |e| matches!(e, Event::Clipboard { text, .. } if text == "still here").then_some(()));
    a.stop();
    b.stop();
}

#[test]
fn a_file_that_changes_after_hashing_is_not_sent_as_the_original() {
    let (a, b) = (Peer::new("A", true), Peer::new("B", true));
    pair(&a, &b);
    let p = a.write("grows.txt", b"short");
    // Hashing is quick for five bytes, so make the file longer once the offer is out.
    let t = a.client.send_file(&b.id(), &p, None, None).unwrap();
    b.wait("offered", |e| matches!(e, Event::FileIncoming { .. }).then_some(()));
    std::fs::write(&p, pattern(100_000)).unwrap();
    let outcome = a.wait("outcome", |e| match e {
        Event::FileDone { transfer, incoming: false, .. } if *transfer == t => Some(None),
        Event::FileFailed { transfer, reason, .. } if *transfer == t => Some(Some(reason.clone())),
        _ => None,
    });
    // Either the original five bytes went (read before the change) or it failed; never the changed bytes.
    if outcome.is_none() {
        let saved = done_path(&b, None);
        assert_eq!(std::fs::read(saved).unwrap(), b"short");
    }
    a.stop();
    b.stop();
}

#[test]
fn links_go_both_ways_and_are_never_opened_by_the_library() {
    let (a, b) = (Peer::new("A", true), Peer::new("B", true));
    pair(&a, &b);
    let r = a.client.send_link(&b.id(), "https://roundrobin.in/bridgey?x=1").unwrap();
    let url = b.wait("link at B", |e| match e {
        Event::Link { url, .. } => Some(url.clone()),
        _ => None,
    });
    assert_eq!(url, "https://roundrobin.in/bridgey?x=1");
    a.wait("accepted", |e| matches!(e, Event::LinkSent { request, status: SendStatus::Delivered, opened: false, .. } if *request == r).then_some(()));
    b.client.send_link(&a.id(), "http://192.168.1.10:8080/").unwrap();
    a.wait("link at A", |e| matches!(e, Event::Link { url, .. } if url == "http://192.168.1.10:8080/").then_some(()));
    for bad in ["javascript:alert(1)", "file:///etc/passwd", "https://user:pw@example.com", ""] {
        assert!(matches!(a.client.send_link(&b.id(), bad), Err(bridgey_core::ClientError::InvalidArgument(_))), "{bad}");
    }
    // Links off at B: the next link is refused.
    b.client.set_feature(Some(&a.id()), "links", false).unwrap();
    a.wait("B's links off", |e| matches!(e, Event::Features { remote, .. } if !remote.get("links")).then_some(()));
    assert_eq!(a.client.send_link(&b.id(), "https://example.com"), Err(bridgey_core::ClientError::FeatureOff));
    a.stop();
    b.stop();
}

#[test]
fn manual_connect_reaches_only_the_devices_asked_for() {
    let storage: Arc<dyn bridgey_core::Storage> = Arc::new(MemoryStorage::default());
    let b = Peer::new("B", true);
    // Pair once as a normal app, then start again as a share extension with the same identity and trust.
    let a_id = {
        let mut config = Config::new("A", "ios");
        config.port = 0;
        config.discovery = false;
        let a = Client::start(config, storage.clone()).unwrap();
        b.client.allow_pairing(Duration::from_secs(60));
        let p = a.pair(None, Some("127.0.0.1"), b.client.port()).unwrap();
        let deadline = Instant::now() + WAIT;
        loop {
            assert!(Instant::now() < deadline, "pairing for the extension test");
            match a.next_event(Duration::from_millis(200)) {
                Next::Event(Event::PairingCode { pairing, .. }) => a.confirm_pairing(pairing, true).unwrap(),
                Next::Event(Event::PairingFinished { pairing, ok: true, .. }) if pairing == p => break,
                _ => {}
            }
        }
        let id = a.device_id().to_string();
        a.stop();
        id
    };
    b.wait("B saw A go", |e| matches!(e, Event::Disconnected { device_id, .. } if *device_id == a_id).then_some(()));
    let mut config = Config::new("A", "ios");
    config.port = 0;
    config.listen = false;
    config.discovery = false;
    config.manual_connect = true;
    let ext = Client::start(config, storage).unwrap();
    std::thread::sleep(Duration::from_secs(3));
    assert_eq!(ext.snapshot()["devices"][0]["connected"], false, "nothing connects on its own");
    ext.connect(&b.id()).unwrap();
    let deadline = Instant::now() + WAIT;
    loop {
        assert!(Instant::now() < deadline, "the extension connects when asked");
        if let Next::Event(Event::Connected { .. }) = ext.next_event(Duration::from_millis(200)) {
            break;
        }
    }
    ext.stop();
    b.stop();
}

#[test]
fn devices_the_host_finds_come_and_go() {
    let mut config = Config::new("host discovery", "ios");
    config.port = 0;
    config.listen = false;
    config.discovery = false;
    let c = Client::start(config, Arc::new(MemoryStorage::default())).unwrap();
    let id = "0b9e3f5c-1d2a-4b6c-8e7f-9a0b1c2d3e4f";
    c.add_discovered(Some(id), "Rahul's Mac", Some("macos"), "192.168.1.20", 42458).unwrap();
    assert_eq!(c.snapshot()["nearby"][0]["deviceId"], id);
    c.remove_discovered("192.168.1.20", 42458).unwrap();
    assert_eq!(c.snapshot()["nearby"].as_array().unwrap().len(), 0);
    assert!(c.remove_discovered("not an address", 1).is_err());
    c.stop();
}
