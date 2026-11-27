//! Whether this computer is in use, for phones that send alerts to the device in use (device_presence_draft1): only
//! whether there was input and how long ago, or that the screen is locked. Never keys, windows or apps.
//!
//! Sources, first that answers: the screen lock from org.gnome.ScreenSaver or org.freedesktop.ScreenSaver; the idle
//! time from GNOME's Mutter IdleMonitor, KDE's org.freedesktop.ScreenSaver.GetSessionIdleTime, or the X11
//! screensaver extension.

use bridgey_core::notifications::Presence;

#[zbus::proxy(interface = "org.gnome.Mutter.IdleMonitor", default_service = "org.gnome.Mutter.IdleMonitor", default_path = "/org/gnome/Mutter/IdleMonitor/Core")]
trait MutterIdle {
    fn get_idletime(&self) -> zbus::Result<u64>;
}

#[zbus::proxy(interface = "org.freedesktop.ScreenSaver", default_service = "org.freedesktop.ScreenSaver", default_path = "/org/freedesktop/ScreenSaver")]
trait FdoScreenSaver {
    fn get_active(&self) -> zbus::Result<bool>;
    fn get_session_idle_time(&self) -> zbus::Result<u32>;
}

#[zbus::proxy(interface = "org.gnome.ScreenSaver", default_service = "org.gnome.ScreenSaver", default_path = "/org/gnome/ScreenSaver")]
trait GnomeScreenSaver {
    fn get_active(&self) -> zbus::Result<bool>;
}

fn x11_idle_seconds() -> Option<u32> {
    use x11rb::connection::Connection;
    use x11rb::protocol::screensaver::ConnectionExt as _;
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        // XWayland only sees input to X11 windows.
        return None;
    }
    let (conn, screen) = x11rb::connect(None).ok()?;
    let root = conn.setup().roots[screen].root;
    let info = conn.screensaver_query_info(root).ok()?.reply().ok()?;
    Some(info.ms_since_user_input / 1000)
}

/// Asks the desktop once.
pub async fn sample(conn: &zbus::Connection) -> Presence {
    let locked = match GnomeScreenSaverProxy::new(conn).await {
        Ok(p) => p.get_active().await.ok(),
        Err(_) => None,
    };
    let fdo = FdoScreenSaverProxy::new(conn).await.ok();
    let locked = match (locked, &fdo) {
        (Some(l), _) => Some(l),
        (None, Some(p)) => p.get_active().await.ok(),
        _ => None,
    };
    if locked == Some(true) {
        return Presence::Locked;
    }
    if let Ok(p) = MutterIdleProxy::new(conn).await {
        if let Ok(ms) = p.get_idletime().await {
            return Presence::Input { idle: (ms / 1000).min(u32::MAX as u64) as u32 };
        }
    }
    if let Some(p) = &fdo {
        if let Ok(s) = p.get_session_idle_time().await {
            return Presence::Input { idle: s };
        }
    }
    if let Some(s) = tokio::task::spawn_blocking(x11_idle_seconds).await.ok().flatten() {
        return Presence::Input { idle: s };
    }
    Presence::Unknown
}
