//! Two session clients on one machine: they pair with protocol 2 over TCP, exchange clipboard text both ways,
//! reconnect, and refuse what the apps refuse. Each client runs its own event pump, the way a host app does.

use bridgey_core::{Client, Config, Event, MemoryStorage, Next, SendStatus, Storage};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(20);

struct Peer {
    client: Arc<Client>,
    log: Arc<(Mutex<Vec<Event>>, Condvar)>,
    pump: Option<std::thread::JoinHandle<()>>,
}

#[derive(Clone, Copy, PartialEq)]
enum Codes {
    Accept,
    Reject,
}

impl Peer {
    fn start(name: &str, storage: Arc<dyn Storage>, port: u16, codes: Codes) -> Peer {
        let mut config = Config::new(name, "linux");
        config.port = port;
        config.discovery = false;
        let client = Arc::new(Client::start(config, storage).expect("client starts"));
        let log: Arc<(Mutex<Vec<Event>>, Condvar)> = Arc::default();
        let pump = {
            let (client, log) = (client.clone(), log.clone());
            std::thread::spawn(move || loop {
                match client.next_event(Duration::from_millis(200)) {
                    Next::Event(e) => {
                        if let Event::PairingCode { pairing, .. } = &e {
                            // The other end may have ended the pairing already; then there is nothing to answer.
                            let _ = client.confirm_pairing(*pairing, codes == Codes::Accept);
                        }
                        log.0.lock().unwrap().push(e);
                        log.1.notify_all();
                    }
                    Next::Timeout => {}
                    Next::Closed => return,
                }
            })
        };
        Peer { client, log, pump: Some(pump) }
    }

    fn new(name: &str) -> Peer {
        Peer::start(name, Arc::new(MemoryStorage::default()), 0, Codes::Accept)
    }

    fn id(&self) -> String {
        self.client.device_id().to_string()
    }

    /// Waits for an event matching `f` and returns it.
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

    fn saw(&self, f: impl Fn(&Event) -> bool) -> bool {
        self.log.0.lock().unwrap().iter().any(f)
    }

    fn clear(&self) {
        self.log.0.lock().unwrap().clear();
    }

    fn stop(mut self) {
        self.client.stop();
        if let Some(p) = self.pump.take() {
            p.join().unwrap();
        }
    }
}

fn connected(peer: &str) -> impl Fn(&Event) -> Option<()> + '_ {
    move |e| matches!(e, Event::Connected { device_id, .. } if device_id == peer).then_some(())
}

fn features(peer: &str) -> impl Fn(&Event) -> Option<()> + '_ {
    move |e| matches!(e, Event::Features { device_id, remote, .. } if device_id == peer && remote.get("clipboard")).then_some(())
}

fn pair(a: &Peer, b: &Peer) -> String {
    b.client.allow_pairing(Duration::from_secs(120));
    let pairing = a.client.pair(None, Some("127.0.0.1"), b.client.port()).unwrap();
    let code_a = a.wait("code on A", |e| match e {
        Event::PairingCode { pairing: p, code, .. } if *p == pairing => Some(code.clone()),
        _ => None,
    });
    let code_b = b.wait("code on B", |e| match e {
        Event::PairingCode { code, .. } => Some(code.clone()),
        _ => None,
    });
    assert_eq!(code_a, code_b, "both people see the same six digits");
    assert_eq!(code_a.len(), 6);
    a.wait("A paired", |e| matches!(e, Event::PairingFinished { pairing: p, ok: true, .. } if *p == pairing).then_some(()));
    b.wait("B paired", |e| matches!(e, Event::PairingFinished { ok: true, .. }).then_some(()));
    a.wait("A connected", connected(&b.id()));
    b.wait("B connected", connected(&a.id()));
    a.wait("B's features at A", features(&b.id()));
    b.wait("A's features at B", features(&a.id()));
    code_a
}

#[test]
fn two_clients_pair_and_exchange_clipboard_text_both_ways() {
    let (a, b) = (Peer::new("Rahul's PC"), Peer::new("Rahul's laptop"));
    pair(&a, &b);
    // A to B.
    let request = a.client.send_clipboard(&b.id(), "héllo from A ✓").unwrap();
    let text = b.wait("clipboard at B", |e| match e {
        Event::Clipboard { device_id, text, .. } if *device_id == a.id() => Some(text.clone()),
        _ => None,
    });
    assert_eq!(text, "héllo from A ✓");
    a.wait("delivered", |e| matches!(e, Event::ClipboardSent { request: r, status: SendStatus::Delivered, .. } if *r == request).then_some(()));
    // B to A, the largest text clipboard.update carries.
    let big = "x".repeat(32_768);
    b.client.send_clipboard(&a.id(), &big).unwrap();
    let got = a.wait("clipboard at A", |e| match e {
        Event::Clipboard { device_id, text, .. } if *device_id == b.id() => Some(text.len()),
        _ => None,
    });
    assert_eq!(got, 32_768);
    assert_eq!(b.client.send_clipboard(&a.id(), &"x".repeat(32_769)), Err(bridgey_core::ClientError::TooLarge));
    // Both trust each other now, pinned to the identity that confirmed.
    let snap = a.client.snapshot();
    assert_eq!(snap["devices"][0]["deviceId"], b.id());
    assert_eq!(snap["devices"][0]["connected"], true);
    // Ping both ways.
    let p = a.client.ping(&b.id()).unwrap();
    b.wait("ping at B", |e| matches!(e, Event::Ping { .. }).then_some(()));
    a.wait("ping answered", |e| matches!(e, Event::PingResult { request, status: SendStatus::Delivered, .. } if *request == p).then_some(()));
    a.stop();
    b.stop();
}

#[test]
fn switching_clipboard_off_is_told_to_the_other_device() {
    let (a, b) = (Peer::new("A"), Peer::new("B"));
    pair(&a, &b);
    a.clear();
    b.client.set_feature(Some(&a.id()), "clipboard", false).unwrap();
    a.wait("B's clipboard off at A", |e| matches!(e, Event::Features { remote, .. } if !remote.get("clipboard")).then_some(()));
    assert_eq!(a.client.send_clipboard(&b.id(), "x"), Err(bridgey_core::ClientError::FeatureOff));
    a.stop();
    b.stop();
}

#[test]
fn waiting_for_allow_pairing_then_pairing() {
    let (a, b) = (Peer::new("A"), Peer::new("B"));
    let pairing = a.client.pair(None, Some("127.0.0.1"), b.client.port()).unwrap();
    a.wait("waiting", |e| matches!(e, Event::PairingWaiting { pairing: p, .. } if *p == pairing).then_some(()));
    let asked = b.wait("wants to pair", |e| match e {
        Event::PairingRequest { device_id, .. } => Some(device_id.clone()),
        _ => None,
    });
    assert_eq!(asked, a.id());
    assert!(!b.saw(|e| matches!(e, Event::PairingCode { .. })), "no code before Allow pairing");
    b.client.allow_pairing(Duration::from_secs(120));
    a.wait("A paired", |e| matches!(e, Event::PairingFinished { pairing: p, ok: true, .. } if *p == pairing).then_some(()));
    b.wait("B connected", connected(&a.id()));
    a.stop();
    b.stop();
}

#[test]
fn a_rejected_code_pairs_nothing() {
    let a = Peer::new("A");
    let b = Peer::start("B", Arc::new(MemoryStorage::default()), 0, Codes::Reject);
    b.client.allow_pairing(Duration::from_secs(120));
    let pairing = a.client.pair(None, Some("127.0.0.1"), b.client.port()).unwrap();
    let reason = a.wait("not paired", |e| match e {
        Event::PairingFinished { pairing: p, ok: false, reason, .. } if *p == pairing => Some(reason.clone()),
        _ => None,
    });
    assert!(reason.contains("mismatch") || reason.contains("closed"), "{reason}");
    assert!(!a.saw(|e| matches!(e, Event::Connected { .. })) && !b.saw(|e| matches!(e, Event::Connected { .. })));
    assert_eq!(a.client.snapshot()["devices"].as_array().unwrap().len(), 0);
    assert_eq!(b.client.snapshot()["devices"].as_array().unwrap().len(), 0);
    a.stop();
    b.stop();
}

#[test]
fn reconnects_after_the_other_device_restarts() {
    let storage_b: Arc<dyn Storage> = Arc::new(MemoryStorage::default());
    let a = Peer::new("A");
    let b = Peer::start("B", storage_b.clone(), 0, Codes::Accept);
    pair(&a, &b);
    let port = b.client.port();
    let b_id = b.id();
    b.stop();
    a.wait("A sees B go", |e| matches!(e, Event::Disconnected { device_id, .. } if *device_id == b_id).then_some(()));
    a.clear();
    // Same identity and trust, same port: A redials on its schedule and B accepts the pinned identity.
    let b = Peer::start("B", storage_b, port, Codes::Accept);
    assert_eq!(b.id(), b_id);
    a.wait("A reconnected", connected(&b_id));
    b.wait("B reconnected", connected(&a.id()));
    assert!(!a.saw(|e| matches!(e, Event::PairingCode { .. })), "a reconnect shows no code");
    let r = b.client.send_clipboard(&a.id(), "after restart");
    assert!(r.is_ok() || r == Err(bridgey_core::ClientError::FeatureOff), "{r:?}");
    a.stop();
    b.stop();
}

#[test]
fn a_changed_identity_is_refused_on_reconnect() {
    let storage_b: Arc<dyn Storage> = Arc::new(MemoryStorage::default());
    let a = Peer::new("A");
    let b = Peer::start("B", storage_b.clone(), 0, Codes::Accept);
    pair(&a, &b);
    let port = b.client.port();
    let b_id = b.id();
    b.stop();
    // Same device ID, new signing key: an impostor that copied the ID.
    let raw = storage_b.load("identity").unwrap().unwrap();
    let mut record: serde_json::Value = serde_json::from_slice(&raw).unwrap();
    let fresh = MemoryStorage::default();
    bridgey_core::trust::Identity::load_or_create(&fresh).unwrap();
    let other: serde_json::Value = serde_json::from_slice(&fresh.load("identity").unwrap().unwrap()).unwrap();
    record["pkcs8"] = other["pkcs8"].clone();
    storage_b.store("identity", &serde_json::to_vec(&record).unwrap()).unwrap();
    a.clear();
    let b = Peer::start("B", storage_b, port, Codes::Accept);
    assert_eq!(b.id(), b_id);
    std::thread::sleep(Duration::from_secs(6));
    assert!(!a.saw(|e| matches!(e, Event::Connected { .. })), "the changed identity never connects");
    a.stop();
    b.stop();
}

#[test]
fn crossed_pairing_goes_on_with_one_dial() {
    let (a, b) = (Peer::new("A"), Peer::new("B"));
    // Each found the other (as DNS-SD would report it) and both people tap the other at once.
    a.client.add_discovered(Some(&b.id()), "B", Some("linux"), "127.0.0.1", b.client.port()).unwrap();
    b.client.add_discovered(Some(&a.id()), "A", Some("linux"), "127.0.0.1", a.client.port()).unwrap();
    let pa = a.client.pair(Some(&b.id()), None, 0).unwrap();
    let pb = b.client.pair(Some(&a.id()), None, 0).unwrap();
    a.wait("A paired", |e| matches!(e, Event::PairingFinished { pairing, ok: true, .. } if *pairing == pa).then_some(()));
    b.wait("B paired", |e| matches!(e, Event::PairingFinished { pairing, ok: true, .. } if *pairing == pb).then_some(()));
    a.wait("A connected", connected(&b.id()));
    b.wait("B connected", connected(&a.id()));
    assert!(!a.saw(|e| matches!(e, Event::PairingRequest { .. })) && !b.saw(|e| matches!(e, Event::PairingRequest { .. })), "no wants-to-pair cards");
    a.stop();
    b.stop();
}

#[test]
fn forgetting_closes_the_session_and_the_trust() {
    let (a, b) = (Peer::new("A"), Peer::new("B"));
    pair(&a, &b);
    a.client.forget(&b.id()).unwrap();
    a.wait("forgotten", |e| matches!(e, Event::TrustChanged { trusted: false, .. }).then_some(()));
    b.wait("B sees A go", |e| matches!(e, Event::Disconnected { .. }).then_some(()));
    assert_eq!(a.client.snapshot()["devices"].as_array().unwrap().len(), 0);
    a.stop();
    b.stop();
}

#[test]
fn stop_wakes_a_waiting_poll() {
    let c = Arc::new(Client::start({ let mut c = Config::new("x", "linux"); c.port = 0; c.discovery = false; c }, Arc::new(MemoryStorage::default())).unwrap());
    let waiter = {
        let c = c.clone();
        std::thread::spawn(move || matches!(c.next_event(Duration::from_secs(60)), Next::Closed))
    };
    std::thread::sleep(Duration::from_millis(100));
    c.stop();
    assert!(waiter.join().unwrap());
}
