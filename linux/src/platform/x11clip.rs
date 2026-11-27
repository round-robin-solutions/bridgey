//! The X11 clipboard (CLIPBOARD selection), watched with XFixes and served from an invisible window. On an X11
//! session this is the clipboard itself; on GNOME's Wayland session it is XWayland's, which Mutter keeps in step with
//! the Wayland clipboard in both directions, so Bridgey can follow copies and set the clipboard without its window in
//! front (as spice-vdagent does).
//!
//! One thread reads events: a change of owner starts a read (TARGETS, then the chosen target, INCR for large data);
//! requests from other apps are answered with Bridgey's text. `set_text` may be called from any thread.

use std::os::fd::AsRawFd;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use x11rb::connection::{Connection, RequestConnection};
use x11rb::protocol::xfixes::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{self, Atom, AtomEnum, ConnectionExt as _, CreateWindowAux, EventMask, PropMode, Window, WindowClass};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

use super::clipboard::{self, Kind, Plan, OWNER_MIME};
use super::{UiMsg, UiTx};

struct Atoms {
    clipboard: Atom,
    targets: Atom,
    utf8: Atom,
    text_plain_utf8: Atom,
    text_plain: Atom,
    text: Atom,
    incr: Atom,
    prop: Atom,
    owner: Atom,
}

fn intern(conn: &RustConnection, name: &str) -> Result<Atom, String> {
    conn.intern_atom(false, name.as_bytes()).map_err(|e| e.to_string())?.reply().map(|r| r.atom).map_err(|e| e.to_string())
}

pub struct X11Clipboard {
    conn: Arc<RustConnection>,
    window: Window,
    atoms: Arc<Atoms>,
    text: Arc<Mutex<Option<Vec<u8>>>>,
    stop: Arc<std::sync::atomic::AtomicBool>,
}

impl Drop for X11Clipboard {
    /// The app dropped its handle (Work in the background turned off): the watcher ends within a second.
    fn drop(&mut self) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
    }
}

impl X11Clipboard {
    pub fn set_text(&self, text: &str) {
        *self.text.lock().unwrap() = Some(text.as_bytes().to_vec());
        let _ = self.conn.set_selection_owner(self.window, self.atoms.clipboard, x11rb::CURRENT_TIME);
        let _ = self.conn.flush();
    }
}

enum Reading {
    Idle,
    Targets { since: Instant },
    Data { plan: Plan, since: Instant, incr: Option<Vec<u8>> },
}

pub fn start(tx: UiTx) -> Result<X11Clipboard, String> {
    let (conn, screen) = x11rb::connect(None).map_err(|e| e.to_string())?;
    let conn = Arc::new(conn);
    conn.xfixes_query_version(5, 0).map_err(|e| e.to_string())?.reply().map_err(|e| e.to_string())?;
    let root = conn.setup().roots[screen].root;
    let window = conn.generate_id().map_err(|e| e.to_string())?;
    conn.create_window(x11rb::COPY_DEPTH_FROM_PARENT, window, root, 0, 0, 1, 1, 0, WindowClass::INPUT_OUTPUT, x11rb::COPY_FROM_PARENT, &CreateWindowAux::new().event_mask(EventMask::PROPERTY_CHANGE))
        .map_err(|e| e.to_string())?;
    let atoms = Arc::new(Atoms {
        clipboard: intern(&conn, "CLIPBOARD")?,
        targets: intern(&conn, "TARGETS")?,
        utf8: intern(&conn, "UTF8_STRING")?,
        text_plain_utf8: intern(&conn, "text/plain;charset=utf-8")?,
        text_plain: intern(&conn, "text/plain")?,
        text: intern(&conn, "TEXT")?,
        incr: intern(&conn, "INCR")?,
        prop: intern(&conn, "BRIDGEY_CLIPBOARD")?,
        owner: intern(&conn, OWNER_MIME)?,
    });
    conn.xfixes_select_selection_input(window, atoms.clipboard, xfixes::SelectionEventMask::SET_SELECTION_OWNER).map_err(|e| e.to_string())?;
    conn.flush().map_err(|e| e.to_string())?;
    let text = Arc::new(Mutex::new(None::<Vec<u8>>));
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let me = X11Clipboard { conn: conn.clone(), window, atoms: atoms.clone(), text: text.clone(), stop: stop.clone() };
    std::thread::Builder::new()
        .name("bridgey-x11-clipboard".into())
        .spawn(move || run(conn, window, atoms, text, tx, stop))
        .map_err(|e| e.to_string())?;
    Ok(me)
}

fn names(conn: &RustConnection, atoms: &[Atom]) -> Vec<String> {
    let cookies: Vec<_> = atoms.iter().filter_map(|a| conn.get_atom_name(*a).ok()).collect();
    cookies.into_iter().filter_map(|c| c.reply().ok()).map(|r| String::from_utf8_lossy(&r.name).to_string()).collect()
}

fn run(conn: Arc<RustConnection>, window: Window, atoms: Arc<Atoms>, text: Arc<Mutex<Option<Vec<u8>>>>, tx: UiTx, stop: Arc<std::sync::atomic::AtomicBool>) {
    let fd = conn.stream().as_raw_fd();
    let mut reading = Reading::Idle;
    // What is on the clipboard already, so Send copied item has it (Automatic clipboard sends only later copies).
    if conn.get_selection_owner(atoms.clipboard).ok().and_then(|c| c.reply().ok()).is_some_and(|r| r.owner != x11rb::NONE && r.owner != window) {
        let _ = conn.convert_selection(window, atoms.clipboard, atoms.targets, atoms.prop, x11rb::CURRENT_TIME);
        let _ = conn.flush();
        reading = Reading::Targets { since: Instant::now() };
    }
    loop {
        if stop.load(std::sync::atomic::Ordering::Relaxed) {
            let _ = conn.destroy_window(window);
            let _ = conn.flush();
            return;
        }
        let event = match conn.poll_for_event() {
            Ok(Some(e)) => e,
            Ok(None) => {
                let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
                unsafe { libc::poll(&mut pfd, 1, 1000) };
                // A read that got no answer in five seconds is dropped.
                let stale = match &reading {
                    Reading::Targets { since } | Reading::Data { since, .. } => since.elapsed() > Duration::from_secs(5),
                    Reading::Idle => false,
                };
                if stale {
                    reading = Reading::Idle;
                }
                continue;
            }
            Err(_) => return,
        };
        match event {
            Event::XfixesSelectionNotify(ev) if ev.selection == atoms.clipboard => {
                if ev.owner == window || ev.owner == x11rb::NONE {
                    continue;
                }
                let _ = conn.convert_selection(window, atoms.clipboard, atoms.targets, atoms.prop, ev.timestamp);
                let _ = conn.flush();
                reading = Reading::Targets { since: Instant::now() };
            }
            Event::SelectionNotify(ev) if ev.requestor == window => {
                if ev.property == x11rb::NONE {
                    reading = Reading::Idle;
                    continue;
                }
                let Ok(Ok(reply)) = conn.get_property(true, window, atoms.prop, AtomEnum::ANY, 0, u32::MAX / 4).map(|c| c.reply()) else {
                    reading = Reading::Idle;
                    continue;
                };
                match std::mem::replace(&mut reading, Reading::Idle) {
                    Reading::Targets { .. } => {
                        let list: Vec<Atom> = reply.value32().map(|v| v.collect()).unwrap_or_default();
                        let mimes = names(&conn, &list);
                        let Some(plan) = clipboard::plan(&mimes) else { continue };
                        let target = match plan.kind {
                            Kind::Text => intern(&conn, &plan.mime).unwrap_or(atoms.utf8),
                            _ => match intern(&conn, &plan.mime) {
                                Ok(a) => a,
                                Err(_) => continue,
                            },
                        };
                        let _ = conn.convert_selection(window, atoms.clipboard, target, atoms.prop, x11rb::CURRENT_TIME);
                        let _ = conn.flush();
                        reading = Reading::Data { plan, since: Instant::now(), incr: None };
                    }
                    Reading::Data { plan, .. } => {
                        if reply.type_ == atoms.incr {
                            // Deleting the property (done by get_property) asks for the first chunk.
                            let _ = conn.flush();
                            reading = Reading::Data { plan, since: Instant::now(), incr: Some(Vec::new()) };
                        } else if let Some(clip) = clipboard::decode(&plan, reply.value) {
                            let _ = tx.send_blocking(UiMsg::ClipboardChanged(clip));
                        }
                    }
                    Reading::Idle => {}
                }
            }
            Event::PropertyNotify(ev) if ev.window == window && ev.atom == atoms.prop && ev.state == xproto::Property::NEW_VALUE => {
                if let Reading::Data { plan, incr: Some(buf), .. } = &mut reading {
                    let Ok(Ok(reply)) = conn.get_property(true, window, atoms.prop, AtomEnum::ANY, 0, u32::MAX / 4).map(|c| c.reply()) else {
                        reading = Reading::Idle;
                        continue;
                    };
                    let _ = conn.flush();
                    if reply.value.is_empty() {
                        let data = std::mem::take(buf);
                        let plan = plan.clone();
                        reading = Reading::Idle;
                        if let Some(clip) = clipboard::decode(&plan, data) {
                            let _ = tx.send_blocking(UiMsg::ClipboardChanged(clip));
                        }
                    } else if buf.len() + reply.value.len() > plan.cap {
                        reading = Reading::Idle;
                    } else {
                        buf.extend_from_slice(&reply.value);
                    }
                }
            }
            Event::SelectionRequest(ev) if ev.owner == window && ev.selection == atoms.clipboard => {
                let property = if ev.property == x11rb::NONE { ev.target } else { ev.property };
                let data = text.lock().unwrap().clone();
                let mut answered = x11rb::NONE;
                if let Some(data) = data {
                    if ev.target == atoms.targets {
                        let list = [atoms.targets, atoms.utf8, atoms.text_plain_utf8, atoms.text_plain, atoms.text, xproto::AtomEnum::STRING.into(), atoms.owner];
                        if conn.change_property32(PropMode::REPLACE, ev.requestor, property, AtomEnum::ATOM, &list).is_ok() {
                            answered = property;
                        }
                    } else if ev.target == atoms.owner {
                        if conn.change_property8(PropMode::REPLACE, ev.requestor, property, ev.target, &[]).is_ok() {
                            answered = property;
                        }
                    } else if [atoms.utf8, atoms.text_plain_utf8, atoms.text_plain, atoms.text, xproto::AtomEnum::STRING.into()].contains(&ev.target) {
                        // Text up to a request's size; Bridgey's text is at most a few hundred KiB.
                        let max = conn.maximum_request_bytes().saturating_sub(64);
                        if data.len() <= max && conn.change_property8(PropMode::REPLACE, ev.requestor, property, ev.target, &data).is_ok() {
                            answered = property;
                        }
                    }
                }
                let notify = xproto::SelectionNotifyEvent {
                    response_type: xproto::SELECTION_NOTIFY_EVENT,
                    sequence: 0,
                    time: ev.time,
                    requestor: ev.requestor,
                    selection: ev.selection,
                    target: ev.target,
                    property: answered,
                };
                let _ = conn.send_event(false, ev.requestor, EventMask::NO_EVENT, notify);
                let _ = conn.flush();
            }
            Event::SelectionClear(ev) if ev.owner == window => {
                *text.lock().unwrap() = None;
            }
            _ => {}
        }
    }
}
