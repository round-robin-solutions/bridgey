//! Test hook (BRIDGEY_TEST_CONTROL=<socket path>, test profiles only): a Unix socket that takes one command per line
//! and answers one JSON line, so the UI smoke tests can drive the real app under a headless display, take screenshots
//! and read its state. A normal install never opens it.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;
use serde_json::{json, Value};

use crate::app::{App, UpdateStatus};
use crate::platform::NoticeKey;
use crate::state::Pairing;
use crate::ui;

pub fn start(app: &Rc<App>) {
    let Some(path) = std::env::var_os("BRIDGEY_TEST_CONTROL").filter(|_| crate::paths::is_separate_profile()) else { return };
    let _ = std::fs::remove_file(&path);
    let Ok(listener) = UnixListener::bind(&path) else { return };
    let (tx, rx) = async_channel::unbounded::<(String, std::sync::mpsc::Sender<String>)>();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let tx = tx.clone();
            std::thread::spawn(move || {
                let Ok(read) = stream.try_clone() else { return };
                let mut write = stream;
                for line in BufReader::new(read).lines().map_while(Result::ok) {
                    let (atx, arx) = std::sync::mpsc::channel();
                    if tx.send_blocking((line, atx)).is_err() {
                        return;
                    }
                    let answer = arx.recv_timeout(std::time::Duration::from_secs(60)).unwrap_or_else(|_| json!({"ok": false, "error": "timeout"}).to_string());
                    if writeln!(write, "{answer}").is_err() {
                        return;
                    }
                }
            });
        }
    });
    let me = app.clone();
    glib::spawn_future_local(async move {
        while let Ok((line, answer)) = rx.recv().await {
            let result = run(&me, &line).await;
            let _ = answer.send(result.to_string());
        }
    });
}

fn state(app: &Rc<App>) -> Value {
    let st = app.state.borrow();
    json!({
        "ok": true,
        "devices": st.devices.iter().map(|d| json!({
            "id": d.id, "name": d.name, "connected": d.connected, "battery": d.battery.map(|b| json!([b.0, b.1])),
            "ringing": d.ringing,
            "ready": (["clipboard", "files", "battery", "find_device", "ping", "notifications", "links", "media"].iter().filter(|k| d.ready(k)).collect::<Vec<_>>()),
        })).collect::<Vec<_>>(),
        "nearby": st.nearby.iter().map(|n| json!({"name": n.name, "host": n.host, "port": n.port})).collect::<Vec<_>>(),
        "activity": st.activity.iter().map(|a| json!({"title": a.title, "preview": a.preview, "status": a.status, "path": a.path})).collect::<Vec<_>>(),
        "notifications": st.notifications.iter().map(|n| json!({"title": n.n.title, "text": n.n.text, "code": n.n.code.as_ref().map(|c| c.code.clone()), "actions": n.n.actions.len()})).collect::<Vec<_>>(),
        "pairing": match &st.pairing {
            None => json!(null),
            Some(Pairing::Waiting { name, .. }) => json!({"state": "waiting", "name": name}),
            Some(Pairing::Code { code, name, .. }) => json!({"state": "code", "code": code, "name": name}),
            Some(Pairing::Done { name }) => json!({"state": "done", "name": name}),
            Some(Pairing::Failed { reason }) => json!({"state": "failed", "reason": reason}),
        },
        "pairingRequest": st.pairing_request.as_ref().map(|r| r.1.clone()),
        "ringingFrom": st.ringing_from,
        "pendingLink": st.pending_link.as_ref().map(|l| l.1.clone()),
        "connect": st.connect_state,
        "clipboardMode": format!("{:?}", app.clip_mode.get()),
        "tray": app.tray_shown.get(),
        "update": match &*app.update.borrow() {
            UpdateStatus::Available(o) => json!({"state": "available", "version": o.version}),
            UpdateStatus::Failed(e) => json!({"state": "failed", "error": e}),
            other => json!({"state": format!("{other:?}")}),
        },
        "windowVisible": app.window().is_some_and(|w| w.is_visible()),
        "status": st.status_text(),
    })
}

/// Renders the window (with any dialog over it) to a PNG, as it is on screen.
pub fn screenshot(window: &adw::ApplicationWindow, path: &str) -> Result<(), String> {
    let widget: gtk::Widget = window.clone().upcast();
    let (w, h) = (widget.width(), widget.height());
    if w <= 0 || h <= 0 {
        return Err("the window is not shown".into());
    }
    let paintable = gtk::WidgetPaintable::new(Some(&widget));
    let snapshot = gtk::Snapshot::new();
    paintable.snapshot(&snapshot, w as f64, h as f64);
    let node = snapshot.to_node().ok_or("nothing was drawn")?;
    let renderer = widget.native().and_then(|n| n.renderer()).ok_or("no renderer")?;
    let texture = renderer.render_texture(&node, Some(&gtk::graphene::Rect::new(0.0, 0.0, w as f32, h as f32)));
    texture.save_to_png(path).map_err(|e| e.to_string())
}

/// Buttons a screen reader could not name: no label, no text inside and no tooltip. GTK names its own window buttons
/// (the AT-SPI check in the smoke test reads those).
pub fn unlabelled(root: &gtk::Widget) -> Vec<String> {
    fn has_text(w: &gtk::Widget) -> bool {
        if w.downcast_ref::<gtk::Label>().is_some_and(|l| !l.label().is_empty()) || w.downcast_ref::<adw::ButtonContent>().is_some_and(|b| !b.label().is_empty()) {
            return true;
        }
        let mut c = w.first_child();
        while let Some(x) = c {
            if has_text(&x) {
                return true;
            }
            c = x.next_sibling();
        }
        false
    }
    fn walk(w: &gtk::Widget, out: &mut Vec<String>) {
        if !w.is_visible() || w.is::<gtk::WindowControls>() {
            return;
        }
        if w.is::<gtk::Button>() || w.is::<gtk::MenuButton>() {
            let tooltip = w.tooltip_text().is_some_and(|t| !t.is_empty());
            let in_menu_button = w.parent().is_some_and(|p| p.is::<gtk::MenuButton>() && p.tooltip_text().is_some());
            if !tooltip && !in_menu_button && !has_text(w) {
                let mut chain = Vec::new();
                let mut p = w.parent();
                while let Some(x) = p {
                    chain.push(x.type_().name().to_string());
                    p = x.parent();
                    if chain.len() > 4 {
                        break;
                    }
                }
                out.push(format!("{} in {}", w.type_().name(), chain.join(" < ")));
            }
        }
        let mut c = w.first_child();
        while let Some(x) = c {
            walk(&x, out);
            c = x.next_sibling();
        }
    }
    let mut out = Vec::new();
    walk(root, &mut out);
    out
}

async fn run(app: &Rc<App>, line: &str) -> Value {
    let mut parts = line.splitn(2, ' ');
    let cmd = parts.next().unwrap_or("");
    let arg = parts.next().unwrap_or("").trim().to_string();
    let c = &app.core.client;
    let first_device = || app.state.borrow().devices.iter().find(|d| d.connected).map(|d| d.id.clone());
    let notice = |i: usize| -> Option<NoticeKey> { app.state.borrow().notifications.get(i).map(|n| n.key()) };
    let ok = json!({"ok": true});
    match cmd {
        "state" => state(app),
        "show" => {
            app.present(None);
            ok
        }
        "hide" => {
            if let Some(w) = app.window() {
                w.set_visible(false);
            }
            ok
        }
        "pair" => {
            let (host, port) = arg.rsplit_once(' ').map(|(h, p)| (h.to_string(), p.parse().unwrap_or(42458))).unwrap_or((arg.clone(), 42458));
            ui::pair::open(app);
            match c.pair(None, Some(&host), port) {
                Ok(id) => {
                    app.state.borrow_mut().pairing = Some(Pairing::Waiting { pairing: id, name: host });
                    app.queue_render();
                    json!({"ok": true, "pairing": id})
                }
                Err(e) => json!({"ok": false, "error": e.to_string()}),
            }
        }
        "open-pair" => {
            ui::pair::open(app);
            ok
        }
        "confirm" => match app.state.borrow().pairing.clone() {
            Some(Pairing::Code { pairing, .. }) => {
                let _ = c.confirm_pairing(pairing, true);
                ok
            }
            _ => json!({"ok": false, "error": "no code"}),
        },
        "close-dialogs" => {
            ui::pair::close();
            ui::prefs::close();
            ok
        }
        "settings" => {
            ui::prefs::open(app, None);
            if !arg.is_empty() {
                ui::prefs::show(&arg);
            }
            ok
        }
        "page" => {
            ui::window::show_page(app, &arg);
            ok
        }
        "theme" => {
            let theme = match arg.as_str() {
                "dark" => crate::settings::Theme::Dark,
                "light" => crate::settings::Theme::Light,
                _ => crate::settings::Theme::System,
            };
            app.update_settings(|s| s.theme = theme);
            ok
        }
        "set" => {
            // set <settingsKey> <json value>: any setting, through the same path as the Settings dialog.
            let Some((key, value)) = arg.split_once(' ') else { return json!({"ok": false}) };
            let mut v = serde_json::to_value(&*app.settings.borrow()).unwrap_or_default();
            v[key] = serde_json::from_str(value).unwrap_or(Value::Null);
            match serde_json::from_value::<crate::settings::AppSettings>(v) {
                Ok(new) => {
                    app.update_settings(|s| *s = new);
                    ok
                }
                Err(e) => json!({"ok": false, "error": e.to_string()}),
            }
        }
        "resize" => {
            let (w, h) = arg.split_once(' ').map(|(w, h)| (w.parse().unwrap_or(760), h.parse().unwrap_or(720))).unwrap_or((760, 720));
            if let Some(win) = app.window() {
                win.set_default_size(w, h);
            }
            ok
        }
        "screenshot" => {
            // Let pending drawing and animations finish first.
            glib::timeout_future(std::time::Duration::from_millis(600)).await;
            match app.window() {
                Some(w) => match screenshot(&w, &arg) {
                    Ok(()) => ok,
                    Err(e) => json!({"ok": false, "error": e}),
                },
                None => json!({"ok": false, "error": "no window"}),
            }
        }
        "a11y" => match app.window() {
            Some(w) => json!({"ok": true, "unlabelled": unlabelled(&w.upcast())}),
            None => json!({"ok": false}),
        },
        "send-text" => match first_device() {
            Some(d) => {
                app.send_text(&d, &arg, false);
                ok
            }
            None => json!({"ok": false, "error": "no device"}),
        },
        "send-file" => match first_device() {
            Some(d) => {
                app.send_files(&d, &[std::path::PathBuf::from(&arg)]);
                ok
            }
            None => json!({"ok": false, "error": "no device"}),
        },
        "send-from-shell" => {
            app.send_from_shell(arg.split('\t').map(std::path::PathBuf::from).collect());
            ok
        }
        "send-copied" => {
            app.send_copied(None);
            ok
        }
        "ring" => match first_device() {
            Some(d) => json!({"ok": c.find(&d, arg != "stop").is_ok()}),
            None => json!({"ok": false}),
        },
        "stop-ring" => {
            app.stop_ringing();
            ok
        }
        "notice" => {
            // notice <index> <action>: default, dismiss, copy, a<i>, reply<i>
            let (i, action) = arg.split_once(' ').unwrap_or((&arg, "default"));
            match notice(i.parse().unwrap_or(0)) {
                Some(key) => {
                    app.notice_action(&key, action, None);
                    ok
                }
                None => json!({"ok": false, "error": "no notification"}),
            }
        }
        "reply" => {
            // reply <index> <action> <text>
            let mut p = arg.splitn(3, ' ');
            let (i, a, text) = (p.next().unwrap_or("0"), p.next().unwrap_or("0"), p.next().unwrap_or(""));
            match notice(i.parse().unwrap_or(0)) {
                Some(key) => {
                    app.reply(&key, a.parse().unwrap_or(0), text);
                    ok
                }
                None => json!({"ok": false}),
            }
        }
        "start-reply" => match notice(arg.split(' ').next().and_then(|i| i.parse().ok()).unwrap_or(0)) {
            Some(key) => {
                *app.reply_to.borrow_mut() = Some((key, arg.split(' ').nth(1).and_then(|i| i.parse().ok()).unwrap_or(0)));
                ui::window::show_page(app, "notifications");
                app.queue_render();
                ok
            }
            None => json!({"ok": false}),
        },
        "open-link" => {
            let pending = app.state.borrow_mut().pending_link.take();
            if let Some((_, url)) = pending {
                app.open_link(&url);
            }
            app.queue_render();
            ok
        }
        "update-check" => {
            app.check_updates(true);
            for _ in 0..100 {
                glib::timeout_future(std::time::Duration::from_millis(100)).await;
                if !matches!(*app.update.borrow(), UpdateStatus::Checking) {
                    break;
                }
            }
            state(app)["update"].clone()
        }
        "update-install" => {
            app.install_update();
            ok
        }
        "quit" => {
            app.quit();
            ok
        }
        _ => json!({"ok": false, "error": format!("unknown command {cmd}")}),
    }
}
