//! The clipboard in the background on Wayland desktops that offer a data-control protocol: ext-data-control-v1
//! (KDE Plasma 6.4 and later, Sway 1.11, Hyprland, COSMIC, niri, labwc) or the older wlr-data-control-unstable-v1
//! (KDE Plasma 5.20 to 6.4, Sway, Hyprland, river, Wayfire). These let a clipboard manager see and set the clipboard
//! without focus. GNOME's Mutter offers neither; see x11clip.rs for what Bridgey does there.
//!
//! One thread owns its own Wayland connection: it watches the selection, reads new clips on helper threads (so a slow
//! source never blocks it) and serves Bridgey's own text when another app pastes. Our sources carry a private MIME
//! type, so our own selection is recognised and never read back.

use std::io::{Read, Write};
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::sync::mpsc;

use super::clipboard::{self, OWNER_MIME};
use super::{UiMsg, UiTx};

pub enum Cmd {
    SetText(String),
}

pub struct DataControl {
    cmds: mpsc::Sender<Cmd>,
    wake: OwnedFd,
}

impl DataControl {
    pub fn set_text(&self, text: &str) {
        if self.cmds.send(Cmd::SetText(text.to_string())).is_ok() {
            let _ = nix_write(&self.wake, b"x");
        }
    }
}

fn nix_write(fd: &OwnedFd, bytes: &[u8]) -> std::io::Result<()> {
    let n = unsafe { libc::write(fd.as_raw_fd(), bytes.as_ptr().cast(), bytes.len()) };
    if n < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

pub fn pipe() -> std::io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

/// Reads a pipe to its end, at most `cap` bytes, giving up after five seconds without data.
fn read_pipe(fd: OwnedFd, cap: usize) -> Option<Vec<u8>> {
    let mut file = std::fs::File::from(fd);
    let mut out = Vec::new();
    let mut buf = [0u8; 65536];
    loop {
        let mut pfd = libc::pollfd { fd: file.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        if unsafe { libc::poll(&mut pfd, 1, 5000) } <= 0 {
            return None;
        }
        match file.read(&mut buf) {
            Ok(0) => return Some(out),
            Ok(n) => {
                if out.len() + n > cap {
                    return None;
                }
                out.extend_from_slice(&buf[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
}

macro_rules! backend {
    ($name:ident, $label:expr, $names:ident) => {
        pub mod $name {
            use super::*;
            use std::collections::HashMap;
            use wayland_client::globals::{registry_queue_init, GlobalListContents};
            use wayland_client::protocol::{wl_registry, wl_seat};
            use wayland_client::{Connection, Dispatch, Proxy, QueueHandle};
            use super::$names::{dev, mgr, offer, src};

            struct State {
                tx: UiTx,
                offers: HashMap<wayland_client::backend::ObjectId, Vec<String>>,
                text: Option<String>,
                conn: Connection,
            }

            impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
                fn event(_: &mut Self, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
            }
            impl Dispatch<wl_seat::WlSeat, ()> for State {
                fn event(_: &mut Self, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
            }
            impl Dispatch<mgr::Manager, ()> for State {
                fn event(_: &mut Self, _: &mgr::Manager, _: <mgr::Manager as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
            }
            impl Dispatch<offer::Offer, ()> for State {
                fn event(state: &mut Self, o: &offer::Offer, event: <offer::Offer as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
                    if let offer::Ev::Offer { mime_type } = event {
                        state.offers.entry(o.id()).or_default().push(mime_type);
                    }
                }
            }
            impl Dispatch<dev::Device, ()> for State {
                fn event(state: &mut Self, _: &dev::Device, event: <dev::Device as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
                    match event {
                        dev::Ev::DataOffer { id } => {
                            state.offers.insert(id.id(), Vec::new());
                        }
                        dev::Ev::Selection { id: Some(o) } => {
                            let mimes = state.offers.remove(&o.id()).unwrap_or_default();
                            state.offers.clear();
                            state.read(o, mimes);
                        }
                        dev::Ev::Selection { id: None } => state.offers.clear(),
                        dev::Ev::PrimarySelection { id: Some(o) } => {
                            state.offers.remove(&o.id());
                            o.destroy();
                        }
                        _ => {}
                    }
                }
                wayland_client::event_created_child!(State, dev::Device, [
                    dev::EVT_DATA_OFFER_OPCODE => (offer::Offer, ()),
                ]);
            }
            impl Dispatch<src::Source, ()> for State {
                fn event(state: &mut Self, s: &src::Source, event: <src::Source as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
                    match event {
                        src::Ev::Send { mime_type, fd } => {
                            let data = if mime_type == OWNER_MIME { Vec::new() } else { state.text.clone().unwrap_or_default().into_bytes() };
                            std::thread::spawn(move || {
                                let mut f = std::fs::File::from(fd);
                                let _ = f.write_all(&data);
                            });
                        }
                        src::Ev::Cancelled => s.destroy(),
                        _ => {}
                    }
                }
            }

            impl State {
                fn read(&mut self, o: offer::Offer, mimes: Vec<String>) {
                    let Some(plan) = clipboard::plan(&mimes) else {
                        o.destroy();
                        return;
                    };
                    let Ok((r, w)) = pipe() else {
                        o.destroy();
                        return;
                    };
                    o.receive(plan.mime.clone(), w.as_fd());
                    let _ = self.conn.flush();
                    drop(w);
                    o.destroy();
                    let tx = self.tx.clone();
                    std::thread::spawn(move || {
                        if let Some(bytes) = read_pipe(r, plan.cap) {
                            if let Some(clip) = clipboard::decode(&plan, bytes) {
                                let _ = tx.send_blocking(UiMsg::ClipboardChanged(clip));
                            }
                        }
                    });
                }
            }

            /// Connects and binds the protocol; Err when the compositor does not offer it.
            pub fn start(tx: UiTx) -> Result<DataControl, String> {
                let conn = Connection::connect_to_env().map_err(|e| e.to_string())?;
                let (globals, mut queue) = registry_queue_init::<State>(&conn).map_err(|e| e.to_string())?;
                let qh = queue.handle();
                let manager: mgr::Manager = globals.bind(&qh, 1..=1, ()).map_err(|e| e.to_string())?;
                let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=7, ()).map_err(|e| e.to_string())?;
                let device = manager.get_data_device(&seat, &qh, ());
                let (cmd_tx, cmd_rx) = mpsc::channel::<Cmd>();
                let (wake_r, wake_w) = pipe().map_err(|e| e.to_string())?;
                let mut state = State { tx, offers: HashMap::new(), text: None, conn: conn.clone() };
                std::thread::Builder::new()
                    .name("bridgey-clipboard".into())
                    .spawn(move || loop {
                        if queue.dispatch_pending(&mut state).is_err() {
                            return;
                        }
                        if conn.flush().is_err() {
                            return;
                        }
                        let Some(guard) = queue.prepare_read() else { continue };
                        let mut fds = [
                            libc::pollfd { fd: guard.connection_fd().as_raw_fd(), events: libc::POLLIN, revents: 0 },
                            libc::pollfd { fd: wake_r.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                        ];
                        let n = unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) };
                        if n < 0 {
                            drop(guard);
                            continue;
                        }
                        if fds[0].revents & libc::POLLIN != 0 {
                            if guard.read().is_err() {
                                return;
                            }
                        } else {
                            drop(guard);
                        }
                        if fds[1].revents & (libc::POLLIN | libc::POLLHUP) != 0 {
                            let mut sink = [0u8; 64];
                            let n = unsafe { libc::read(wake_r.as_raw_fd(), sink.as_mut_ptr().cast(), sink.len()) };
                            if n == 0 {
                                // The app dropped its handle (Work in the background turned off): this watcher ends.
                                return;
                            }
                            while let Ok(cmd) = cmd_rx.try_recv() {
                                match cmd {
                                    Cmd::SetText(text) => {
                                        state.text = Some(text);
                                        let source = manager.create_data_source(&qh, ());
                                        for m in clipboard::TEXT_MIMES {
                                            source.offer(m.to_string());
                                        }
                                        source.offer(OWNER_MIME.to_string());
                                        device.set_selection(Some(&source));
                                    }
                                }
                            }
                        }
                    })
                    .map_err(|e| e.to_string())?;
                let _ = $label;
                Ok(DataControl { cmds: cmd_tx, wake: wake_w })
            }
        }
    };
}

mod ext_names {
    pub mod mgr {
        pub use wayland_protocols::ext::data_control::v1::client::ext_data_control_manager_v1::ExtDataControlManagerV1 as Manager;
    }
    pub mod dev {
        pub use wayland_protocols::ext::data_control::v1::client::ext_data_control_device_v1::{Event as Ev, ExtDataControlDeviceV1 as Device, EVT_DATA_OFFER_OPCODE};
    }
    pub mod offer {
        pub use wayland_protocols::ext::data_control::v1::client::ext_data_control_offer_v1::{Event as Ev, ExtDataControlOfferV1 as Offer};
    }
    pub mod src {
        pub use wayland_protocols::ext::data_control::v1::client::ext_data_control_source_v1::{Event as Ev, ExtDataControlSourceV1 as Source};
    }
}

mod wlr_names {
    pub mod mgr {
        pub use wayland_protocols_wlr::data_control::v1::client::zwlr_data_control_manager_v1::ZwlrDataControlManagerV1 as Manager;
    }
    pub mod dev {
        pub use wayland_protocols_wlr::data_control::v1::client::zwlr_data_control_device_v1::{Event as Ev, ZwlrDataControlDeviceV1 as Device, EVT_DATA_OFFER_OPCODE};
    }
    pub mod offer {
        pub use wayland_protocols_wlr::data_control::v1::client::zwlr_data_control_offer_v1::{Event as Ev, ZwlrDataControlOfferV1 as Offer};
    }
    pub mod src {
        pub use wayland_protocols_wlr::data_control::v1::client::zwlr_data_control_source_v1::{Event as Ev, ZwlrDataControlSourceV1 as Source};
    }
}

backend!(ext, "ext-data-control-v1", ext_names);
backend!(wlr, "wlr-data-control-unstable-v1", wlr_names);

/// The newer protocol first, then the older one.
pub fn start(tx: UiTx) -> Option<DataControl> {
    if std::env::var("BRIDGEY_DATA_CONTROL").as_deref() == Ok("0") {
        return None;
    }
    ext::start(tx.clone()).or_else(|_| wlr::start(tx)).ok()
}
