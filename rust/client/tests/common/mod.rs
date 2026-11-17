//! Helpers shared by the integration tests: a client with its own event pump, and a protocol 2 pairing.
#![allow(dead_code)]

use bridgey_core::{Client, Config, Event, MemoryStorage, Next, Storage};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub const WAIT: Duration = Duration::from_secs(20);

pub struct Peer {
    pub client: Arc<Client>,
    log: Arc<(Mutex<Vec<Event>>, Condvar)>,
    pump: Option<std::thread::JoinHandle<()>>,
}

#[derive(Clone, Copy, PartialEq)]
pub enum Codes {
    Accept,
    Reject,
}

impl Peer {
    pub fn start(name: &str, storage: Arc<dyn Storage>, port: u16, codes: Codes) -> Peer {
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

    pub fn new(name: &str) -> Peer {
        Peer::start(name, Arc::new(MemoryStorage::default()), 0, Codes::Accept)
    }

    pub fn id(&self) -> String {
        self.client.device_id().to_string()
    }

    /// Waits for an event matching `f` and returns it.
    pub fn wait<T>(&self, what: &str, f: impl Fn(&Event) -> Option<T>) -> T {
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

    pub fn saw(&self, f: impl Fn(&Event) -> bool) -> bool {
        self.log.0.lock().unwrap().iter().any(f)
    }

    pub fn clear(&self) {
        self.log.0.lock().unwrap().clear();
    }

    pub fn stop(mut self) {
        self.client.stop();
        if let Some(p) = self.pump.take() {
            p.join().unwrap();
        }
    }
}

pub fn connected(peer: &str) -> impl Fn(&Event) -> Option<()> + '_ {
    move |e| matches!(e, Event::Connected { device_id, .. } if device_id == peer).then_some(())
}

pub fn features(peer: &str) -> impl Fn(&Event) -> Option<()> + '_ {
    move |e| matches!(e, Event::Features { device_id, remote, .. } if device_id == peer && remote.get("clipboard")).then_some(())
}

pub fn pair(a: &Peer, b: &Peer) -> String {
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

