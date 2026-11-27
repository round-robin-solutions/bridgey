//! Opening links, files and folders, and starting helper programs, with the desktop's own environment. The AppImage's
//! launcher (AppRun) points a few variables at the files it carries (GDK_PIXBUF_MODULE_FILE, XDG_DATA_DIRS) and keeps
//! the desktop's values in BRIDGEY_ORIG_<NAME> (BRIDGEY_UNSET_<NAME> when there was none); a browser or file manager
//! Bridgey starts gets those back, so nothing of the AppImage leaks into it.

use std::path::Path;
use std::process::Command;

use gtk::prelude::*;
use gtk::{gdk, gio};

/// (name, the desktop's value or None to unset) for every variable AppRun changed.
pub fn originals() -> Vec<(String, Option<String>)> {
    let names = std::env::var("BRIDGEY_APPIMAGE_ENV").unwrap_or_default();
    names
        .split_whitespace()
        .map(|n| {
            let value = if std::env::var_os(format!("BRIDGEY_UNSET_{n}")).is_some() { None } else { std::env::var(format!("BRIDGEY_ORIG_{n}")).ok() };
            (n.to_string(), value)
        })
        .collect()
}

pub fn command(program: &str) -> Command {
    let mut c = Command::new(program);
    for (k, v) in originals() {
        match v {
            Some(v) => c.env(&k, v),
            None => c.env_remove(&k),
        };
    }
    c
}

fn context() -> Option<gio::AppLaunchContext> {
    let display = gdk::Display::default()?;
    let ctx: gio::AppLaunchContext = display.app_launch_context().upcast();
    for (k, v) in originals() {
        match v {
            Some(v) => ctx.setenv(&k, &v),
            None => ctx.unsetenv(&k),
        }
    }
    Some(ctx)
}

/// Opens a link or a file with the desktop's default app.
pub fn open_uri(uri: &str) -> bool {
    gio::AppInfo::launch_default_for_uri(uri, context().as_ref()).is_ok()
}

pub fn open_file(path: &Path) -> bool {
    open_uri(&gio::File::for_path(path).uri())
}

#[zbus::proxy(interface = "org.freedesktop.FileManager1", default_service = "org.freedesktop.FileManager1", default_path = "/org/freedesktop/FileManager1")]
trait FileManager {
    fn show_items(&self, uris: &[&str], startup_id: &str) -> zbus::Result<()>;
}

/// Shows a file selected in the file manager (Files, Dolphin, Nemo and others answer org.freedesktop.FileManager1),
/// else opens its folder.
pub fn show_in_folder(path: &Path) {
    let uri = gio::File::for_path(path).uri().to_string();
    let folder = path.parent().map(|p| p.to_path_buf());
    let (tx, rx) = async_channel::bounded::<bool>(1);
    super::rt().spawn(async move {
        let ok = async {
            let conn = zbus::Connection::session().await.ok()?;
            let fm = FileManagerProxy::new(&conn).await.ok()?;
            fm.show_items(&[uri.as_str()], "").await.ok()
        }
        .await
        .is_some();
        let _ = tx.send(ok).await;
    });
    gtk::glib::spawn_future_local(async move {
        if !rx.recv().await.unwrap_or(false) {
            if let Some(f) = folder {
                open_file(&f);
            }
        }
    });
}
