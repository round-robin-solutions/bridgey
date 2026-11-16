//! What the client tells its host, through one bounded queue the host drains with a blocking poll.
//!
//! When the queue is full, the oldest event that a snapshot can replace (a discovery or feature change) makes
//! room; if there is none, the new event is dropped and counted, and the host is told how many were lost so it
//! can refresh from `bridgey_snapshot`.

use crate::features::FeatureMap;
use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum SendStatus {
    Delivered = 0,
    Rejected = 1,
    TimedOut = 2,
    Failed = 3,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// A device on the network (DNS-SD or the host's own discovery). `device_id` is an unauthenticated hint.
    Found { device_id: Option<String>, name: String, platform: Option<String>, host: String, port: u16 },
    Lost { device_id: Option<String>, host: String, port: u16 },
    /// A device asked to pair while pairing was not allowed here; Allow pairing answers its next try.
    PairingRequest { device_id: String, name: String },
    /// The other device has not allowed pairing yet; this end tries again every 3 s for two minutes.
    PairingWaiting { pairing: u64, name: String },
    /// Compare this code with the other device and answer with `confirm_pairing`.
    PairingCode { pairing: u64, device_id: String, name: String, code: String },
    PairingFinished { pairing: u64, device_id: Option<String>, name: Option<String>, ok: bool, reason: String },
    Connected { device_id: String, name: String },
    Disconnected { device_id: String, reason: String },
    /// This device's switches for that device and the device's own; a feature works when both are on.
    Features { device_id: String, local: FeatureMap, remote: FeatureMap },
    Clipboard { device_id: String, text: String, html: Option<String> },
    ClipboardSent { request: u64, device_id: String, status: SendStatus },
    Ping { device_id: String },
    PingResult { request: u64, device_id: String, status: SendStatus },
    TrustChanged { device_id: String, name: String, trusted: bool },
    /// A file is coming in from a device (Files on at both ends); it is saved in the receive folder.
    FileIncoming { transfer: u64, device_id: String, name: String, size: u64, mime: String },
    /// How far a transfer has got, at most four times a second. `incoming` tells the two directions apart.
    FileProgress { transfer: u64, device_id: String, incoming: bool, bytes: u64, total: u64 },
    /// Saved at `path` (incoming), or saved by the other device (outgoing). `name` is the name it was saved under.
    FileDone { transfer: u64, device_id: String, incoming: bool, name: String, path: Option<String>, size: u64 },
    /// `reason`: rejected (Files is off there), cancelled, cancelled_remote, not_accepted, not_confirmed, stalled,
    /// verification_failed, unreadable, changed, storage, invalid, not_connected, interrupted, stopped.
    FileFailed { transfer: u64, device_id: String, incoming: bool, name: String, reason: String },
    /// A link from a device, for the person to open or dismiss. Never opened by the library.
    Link { device_id: String, url: String },
    /// The answer to `send_link`: delivered (queued or opened there), rejected (Links is off there or the link was
    /// refused), timed out or failed. `opened` when the other device opened it at once.
    LinkSent { request: u64, device_id: String, status: SendStatus, opened: bool },
    /// A connected device's battery (`battery.update`, Battery on at both ends).
    Battery { device_id: String, level: u8, charging: bool },
    /// The other device asks this one to ring (`ring`) or stop. The host plays a sound until the person stops it,
    /// then calls `find_stopped`.
    FindRequested { device_id: String, ring: bool },
    /// The other device says it is ringing, or has stopped (after `find`).
    FindState { device_id: String, ringing: bool },
    /// A phone notification (with the code found in it, when Codes from messages is on).
    Notification { device_id: String, notification: Box<crate::notifications::Notification> },
    /// The phone's notification went away (read, dismissed there, or the call ended).
    NotificationRemoved { device_id: String, notification_id: String, call_ended: bool },
    /// Whether the phone shows Bridgey the text of code messages: allowed, hidden or not_linked.
    CodesStatus { device_id: String, status: String },
    /// The phone asks this device to advertise a Bluetooth LE service for 60 seconds (`start`), or to stop
    /// (`linked` says whether the link was made). Answer a start with `codes_advertise_result`.
    CodesAdvertise { device_id: String, service_uuid: String, start: bool, linked: bool },
    Dropped { count: u64 },
    Error { text: String },
}

impl Event {
    /// Events a snapshot or a later event can replace.
    fn replaceable(&self) -> bool {
        matches!(self, Event::Found { .. } | Event::Lost { .. } | Event::Features { .. } | Event::FileProgress { .. })
    }
}

struct Queue {
    items: VecDeque<Event>,
    dropped: u64,
    closed: bool,
}

pub struct EventQueue {
    q: Mutex<Queue>,
    cv: Condvar,
    capacity: usize,
}

pub enum Next {
    Event(Event),
    Timeout,
    Closed,
}

impl EventQueue {
    pub fn new(capacity: usize) -> EventQueue {
        EventQueue { q: Mutex::new(Queue { items: VecDeque::new(), dropped: 0, closed: false }), cv: Condvar::new(), capacity: capacity.clamp(16, 65_536) }
    }

    pub fn push(&self, event: Event) {
        let mut q = self.q.lock().unwrap();
        if q.closed {
            return;
        }
        if q.items.len() >= self.capacity {
            match q.items.iter().position(Event::replaceable) {
                Some(i) => {
                    q.items.remove(i);
                    q.dropped += 1;
                }
                None => {
                    q.dropped += 1;
                    drop(q);
                    self.cv.notify_one();
                    return;
                }
            }
        }
        q.items.push_back(event);
        drop(q);
        self.cv.notify_one();
    }

    pub fn next(&self, timeout: Duration) -> Next {
        let deadline = Instant::now() + timeout;
        let mut q = self.q.lock().unwrap();
        loop {
            if q.dropped > 0 {
                let count = std::mem::take(&mut q.dropped);
                return Next::Event(Event::Dropped { count });
            }
            if let Some(e) = q.items.pop_front() {
                return Next::Event(e);
            }
            if q.closed {
                return Next::Closed;
            }
            let now = Instant::now();
            if now >= deadline {
                return Next::Timeout;
            }
            q = self.cv.wait_timeout(q, deadline - now).unwrap().0;
        }
    }

    /// Wakes every waiter; later polls return `Closed` once the queue is empty.
    pub fn close(&self) {
        self.q.lock().unwrap().closed = true;
        self.cv.notify_all();
    }

    pub fn len(&self) -> usize {
        self.q.lock().unwrap().items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(i: u16) -> Event {
        Event::Found { device_id: None, name: String::new(), platform: None, host: "h".into(), port: i }
    }

    #[test]
    fn bounded_and_replaceable_first() {
        let q = EventQueue::new(16);
        for i in 0..16 {
            q.push(found(i));
        }
        q.push(Event::Clipboard { device_id: "d".into(), text: "t".into(), html: None });
        assert_eq!(q.len(), 16);
        match q.next(Duration::ZERO) {
            Next::Event(Event::Dropped { count: 1 }) => {}
            _ => panic!("the host hears about the dropped event first"),
        }
        let mut last = None;
        while let Next::Event(e) = q.next(Duration::ZERO) {
            last = Some(e);
        }
        assert!(matches!(last, Some(Event::Clipboard { .. })), "the clipboard event survived");
    }

    #[test]
    fn full_of_important_events_drops_new_ones_and_counts() {
        let q = EventQueue::new(16);
        for _ in 0..20 {
            q.push(Event::Ping { device_id: "d".into() });
        }
        assert_eq!(q.len(), 16);
        assert!(matches!(q.next(Duration::ZERO), Next::Event(Event::Dropped { count: 4 })));
    }

    #[test]
    fn close_wakes_waiters() {
        let q = std::sync::Arc::new(EventQueue::new(16));
        let waiter = {
            let q = q.clone();
            std::thread::spawn(move || matches!(q.next(Duration::from_secs(30)), Next::Closed))
        };
        std::thread::sleep(Duration::from_millis(50));
        q.close();
        assert!(waiter.join().unwrap());
    }
}
