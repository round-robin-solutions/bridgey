//! The desktop around the app: notifications, the status icon, the clipboard, battery, sound, media players, activity,
//! autostart, the app menu entry and the file manager actions. D-Bus work runs on one small tokio runtime; what comes
//! back for the UI goes through `UiMsg` on the GTK main loop.

pub mod autostart;
pub mod battery;
pub mod clipboard;
pub mod datacontrol;
pub mod integration;
pub mod media;
pub mod notify;
pub mod presence;
pub mod sound;
pub mod tray;
pub mod x11clip;

use std::sync::OnceLock;

/// One worker thread is plenty: D-Bus calls are small and rare.
pub fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(1).thread_name("bridgey-desktop").enable_all().build().expect("runtime"))
}

/// A phone notification here: the device and the phone's notification ID.
pub type NoticeKey = (String, String);

/// What the desktop tells the app.
#[derive(Clone, Debug)]
pub enum UiMsg {
    ShowWindow { token: Option<String> },
    Pair,
    Settings,
    SendFiles,
    SendClipboard,
    AllowPairing,
    Quit,
    /// The status icon is shown (a StatusNotifierItem host is there) or not.
    TrayAvailable(bool),
    /// A button on a phone notification's banner: the phone's own action (its index), Reply, Dismiss, Copy code, or the
    /// banner itself (open Bridgey).
    NoticeAction { key: NoticeKey, action: String, token: Option<String> },
    /// A reply typed into the banner (KDE Plasma's inline reply).
    NoticeReply { key: NoticeKey, action: usize, text: String },
    /// Stop on the ringing banner.
    StopRinging,
    /// Open or Show in folder on a "file received" banner.
    OpenPath { path: String, folder: bool },
    /// Copy on a clipboard banner (GNOME on Wayland, where Bridgey cannot set the clipboard from the background).
    ApplyClipboard { token: Option<String> },
    ClipboardChanged(clipboard::Clip),
    MediaState(Option<String>),
    MediaDone { device_id: String, request_id: String, ok: bool },
}

pub type UiTx = async_channel::Sender<UiMsg>;
