//! The running app: the session client, the state, the window, and the desktop services, tied together on the GTK
//! main loop. Events from the client go through `State::apply`; what that returns is done here.

use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use adw::prelude::*;
use bridgey_core::Event;
use gtk::{gdk, gio, glib};

use crate::core::Core;
use crate::edition;
use crate::i18n::{t, tf};
use crate::paths;
use crate::platform::clipboard::{self, Background, Clip, Mode};
use crate::platform::notify::Notifier;
use crate::platform::sound::Ringer;
use crate::platform::tray::TrayIcon;
use crate::platform::{self, rt, NoticeKey, UiMsg, UiTx};
use crate::settings::{AppSettings, SettingsStore, Theme};
use crate::state::{Direction, Effect, PhoneNotice, State};
use crate::ui;
use crate::update;

/// Clipboard text Bridgey waits to set until its window is in front (GNOME on Wayland without XWayland).
#[derive(Clone)]
pub struct PendingClip {
    pub text: String,
    pub from: String,
}

#[derive(Clone, Debug, Default)]
pub enum UpdateStatus {
    #[default]
    Idle,
    Checking,
    UpToDate,
    Available(bridgey_core::update::Offer),
    Downloading(u64, u64),
    Failed(String),
}

pub struct App {
    pub gtk: adw::Application,
    pub core: Core,
    pub state: RefCell<State>,
    pub settings: RefCell<AppSettings>,
    store: SettingsStore,
    pub ui: RefCell<Option<ui::window::Ui>>,
    pub notifier: Notifier,
    tray: RefCell<Option<TrayIcon>>,
    pub tray_shown: Cell<bool>,
    pub clip_mode: Cell<Mode>,
    clip_bg: RefCell<Option<Background>>,
    /// The last clip seen in the background, for Send copied item.
    last_clip: RefCell<Option<Clip>>,
    last_sent: RefCell<Option<String>>,
    pending_clip: RefCell<Option<PendingClip>>,
    automatic_timer: RefCell<Option<glib::SourceId>>,
    /// When the background watcher started: what it reports in its first moments was on the clipboard already and is
    /// not sent by Automatic clipboard.
    clip_since: Cell<Option<std::time::Instant>>,
    gtk_clipboard_watched: Cell<bool>,
    ringer: Ringer,
    pub tx: UiTx,
    pub update: RefCell<UpdateStatus>,
    pub restart: RefCell<Option<PathBuf>>,
    render_queued: Cell<bool>,
    hold: RefCell<Option<gio::ApplicationHoldGuard>>,
    style: RefCell<Option<ui::style::Style>>,
    media_on: Arc<std::sync::atomic::AtomicBool>,
    presence_on: Arc<std::sync::atomic::AtomicBool>,
    /// Files from Send to Bridgey waiting for a device to connect (just after start).
    pending_send: RefCell<Vec<PathBuf>>,
    pub pairing_open: Cell<bool>,
    /// A notification's Reply that waits for the person in Bridgey.
    pub reply_to: RefCell<Option<(NoticeKey, usize)>>,
}

pub type AppRc = Rc<App>;

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl App {
    pub fn new(gtk: &adw::Application, core: Core, store: SettingsStore, settings: AppSettings, tx: UiTx) -> AppRc {
        Rc::new(App {
            gtk: gtk.clone(),
            core,
            state: RefCell::new(State::new()),
            settings: RefCell::new(settings),
            store,
            ui: RefCell::new(None),
            notifier: Notifier::new(tx.clone()),
            tray: RefCell::new(None),
            tray_shown: Cell::new(false),
            clip_mode: Cell::new(Mode::Foreground),
            clip_bg: RefCell::new(None),
            last_clip: RefCell::new(None),
            last_sent: RefCell::new(None),
            pending_clip: RefCell::new(None),
            automatic_timer: RefCell::new(None),
            clip_since: Cell::new(None),
            gtk_clipboard_watched: Cell::new(false),
            ringer: Ringer::default(),
            tx,
            update: RefCell::new(UpdateStatus::Idle),
            restart: RefCell::new(None),
            render_queued: Cell::new(false),
            hold: RefCell::new(None),
            style: RefCell::new(None),
            media_on: Arc::default(),
            presence_on: Arc::default(),
            pending_send: RefCell::new(Vec::new()),
            pairing_open: Cell::new(false),
            reply_to: RefCell::new(None),
        })
    }

    /// Everything after the client is up: the look, the window, the desktop services and the timers.
    pub fn start(self: &Rc<Self>, events: async_channel::Receiver<Event>, msgs: async_channel::Receiver<UiMsg>) {
        ui::style::load_fonts();
        *self.style.borrow_mut() = Some(ui::style::Style::install());
        self.apply_theme();
        let me = self.clone();
        adw::StyleManager::default().connect_dark_notify(move |sm| {
            if let Some(s) = me.style.borrow().as_ref() {
                s.follow(sm.is_dark());
            }
            me.queue_render();
        });
        self.apply_motion();

        let ui = ui::window::build(self);
        *self.ui.borrow_mut() = Some(ui);
        if self.settings.borrow().notification_history {
            self.state.borrow_mut().notifications = crate::history::to_notices(crate::history::load()).into();
        }
        self.refresh();

        // The status icon, with the icons that came with the app on its theme path.
        let icons = paths::resources().join("icons").to_string_lossy().to_string();
        *self.tray.borrow_mut() = Some(TrayIcon::start(self.tx.clone(), icons));

        self.start_clipboard();
        self.apply_feature_defaults();
        self.apply_connect();
        self.apply_integration();
        self.set_keep_running(self.settings.borrow().keep_running);
        self.start_timers();

        let me = self.clone();
        glib::spawn_future_local(async move {
            while let Ok(e) = events.recv().await {
                me.on_event(e);
            }
        });
        let me = self.clone();
        glib::spawn_future_local(async move {
            while let Ok(m) = msgs.recv().await {
                me.on_msg(m);
            }
        });
        crate::control::start(self);
        if self.settings.borrow().auto_update_check && update::due(self.settings.borrow().last_update_check, now_secs()) {
            self.check_updates(false);
        }
    }

    pub fn window(&self) -> Option<adw::ApplicationWindow> {
        self.ui.borrow().as_ref().map(|u| u.window.clone())
    }

    /// Shows the window, taking focus with the activation token the desktop gave (Wayland needs one).
    pub fn present(&self, token: Option<&str>) {
        if let Some(w) = self.window() {
            if let Some(t) = token {
                w.set_startup_id(t);
            }
            w.present();
        }
    }

    pub fn toast(&self, text: &str) {
        if let Some(u) = self.ui.borrow().as_ref() {
            let toast = adw::Toast::builder().title(glib::markup_escape_text(text)).timeout(4).build();
            // libadwaita's close button on a toast has no name a screen reader can read: give it one, on this toast
            // and on the next one shown after it.
            let overlay = u.toasts.clone();
            toast.connect_dismissed(move |_| {
                let o = overlay.clone();
                glib::timeout_add_local_once(Duration::from_millis(30), move || label_toast_buttons(&o.upcast()));
            });
            u.toasts.add_toast(toast);
            let overlay = u.toasts.clone();
            glib::timeout_add_local_once(Duration::from_millis(30), move || label_toast_buttons(&overlay.upcast()));
        }
    }

    pub fn save_settings(&self) {
        let _ = self.store.save(&self.settings.borrow());
    }

    /// Changes a setting, saves it and applies what depends on it.
    pub fn update_settings(self: &Rc<Self>, f: impl FnOnce(&mut AppSettings)) {
        let before = self.settings.borrow().clone();
        f(&mut self.settings.borrow_mut());
        self.save_settings();
        let after = self.settings.borrow().clone();
        let c = &self.core.client;
        for ((k, old), (_, new)) in before.feature_defaults().into_iter().zip(after.feature_defaults()) {
            if old != new {
                let _ = c.set_feature(None, k, new);
            }
        }
        if before.device_name != after.device_name {
            let _ = c.set_device_name(&crate::core::device_name(&after));
        }
        if before.receive_folder != after.receive_folder {
            let dir = after.receive_dir();
            let _ = std::fs::create_dir_all(&dir);
            c.set_receive_dir(Some(&dir));
        }
        if before.open_links_right_away != after.open_links_right_away {
            c.set_links_open(after.open_links_right_away);
        }
        if (before.codes_from_messages, before.codes_from_email) != (after.codes_from_messages, after.codes_from_email) {
            c.set_codes(after.codes_from_messages, after.codes_from_messages && after.codes_from_email);
        }
        if before.connect_away != after.connect_away {
            self.apply_connect();
        }
        if before.theme != after.theme {
            self.apply_theme();
        }
        if before.reduce_motion != after.reduce_motion {
            self.apply_motion();
        }
        if before.start_at_sign_in != after.start_at_sign_in || before.app_menu_entry != after.app_menu_entry || before.file_manager_actions != after.file_manager_actions {
            self.apply_integration();
        }
        if before.keep_running != after.keep_running {
            self.set_keep_running(after.keep_running);
        }
        if before.background_clipboard != after.background_clipboard {
            self.start_clipboard();
        }
        if before.fast_transfers != after.fast_transfers {
            c.set_fast_transfers(after.fast_transfers);
        }
        if before.notification_history != after.notification_history && !after.notification_history {
            crate::history::clear();
        }
        self.media_on.store(after.media, std::sync::atomic::Ordering::Relaxed);
        if !after.media && before.media {
            let _ = c.set_media_state(None);
        }
        self.presence_on.store(after.share_activity, std::sync::atomic::Ordering::Relaxed);
        if before.battery != after.battery {
            self.push_battery();
        }
        self.queue_render();
    }

    fn apply_theme(&self) {
        let scheme = match self.settings.borrow().theme {
            Theme::System => adw::ColorScheme::Default,
            Theme::Light => adw::ColorScheme::ForceLight,
            Theme::Dark => adw::ColorScheme::ForceDark,
        };
        adw::StyleManager::default().set_color_scheme(scheme);
    }

    /// Reduce motion turns GTK's animations off in this app; the desktop's own setting already does when it is set.
    fn apply_motion(&self) {
        if let Some(s) = gtk::Settings::default() {
            if self.settings.borrow().reduce_motion {
                s.set_gtk_enable_animations(false);
            } else {
                s.reset_property("gtk-enable-animations");
            }
        }
    }

    fn apply_feature_defaults(&self) {
        let s = self.settings.borrow();
        for (k, on) in s.feature_defaults() {
            let _ = self.core.client.set_feature(None, k, on);
        }
        self.media_on.store(s.media, std::sync::atomic::Ordering::Relaxed);
        self.presence_on.store(s.share_activity, std::sync::atomic::Ordering::Relaxed);
    }

    fn apply_connect(&self) {
        let on = self.settings.borrow().connect_away;
        let url = (!edition::CONNECT_CONTROL_URL.is_empty()).then_some(edition::CONNECT_CONTROL_URL);
        if std::env::var("BRIDGEY_CONNECT").as_deref() == Ok("0") {
            let _ = self.core.client.set_connect(false, url);
            return;
        }
        if let Err(e) = self.core.client.set_connect(on, url) {
            self.state.borrow_mut().connect_state = "unavailable".into();
            self.toast(&tf("connect.failed", &[&e.to_string()]));
        }
    }

    fn apply_integration(&self) {
        let s = self.settings.borrow();
        let _ = platform::autostart::apply(s.start_at_sign_in);
        let _ = platform::integration::apply(s.app_menu_entry, s.file_manager_actions);
    }

    fn set_keep_running(&self, on: bool) {
        if on {
            if self.hold.borrow().is_none() {
                *self.hold.borrow_mut() = Some(self.gtk.hold());
            }
        } else {
            self.hold.borrow_mut().take();
        }
    }

    fn start_timers(self: &Rc<Self>) {
        self.push_battery();
        let me = self.clone();
        glib::timeout_add_seconds_local(60, move || {
            me.push_battery();
            glib::ControlFlow::Continue
        });
        // Activity (presence) every ten seconds and media players every two, on the D-Bus runtime.
        let client = self.core.client.clone();
        let presence_on = self.presence_on.clone();
        let media_on = self.media_on.clone();
        let tx = self.tx.clone();
        rt().spawn(async move {
            let Ok(conn) = zbus::Connection::session().await else { return };
            let mut media = platform::media::Media::default();
            let mut last_media: Option<String> = None;
            let mut tick = 0u64;
            loop {
                if tick.is_multiple_of(5) {
                    let p = if presence_on.load(std::sync::atomic::Ordering::Relaxed) {
                        platform::presence::sample(&conn).await
                    } else {
                        bridgey_core::notifications::Presence::Unknown
                    };
                    client.set_presence(p);
                }
                if media_on.load(std::sync::atomic::Ordering::Relaxed) {
                    let state = media.state(&conn).await;
                    if state != last_media {
                        last_media = state.clone();
                        let _ = tx.send(UiMsg::MediaState(state)).await;
                    }
                } else {
                    last_media = None;
                }
                tick += 1;
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        });
    }

    fn push_battery(&self) {
        let level = if self.settings.borrow().battery { platform::battery::read() } else { None };
        self.core.client.set_battery(level);
    }

    // ---- Clipboard ----

    fn start_clipboard(self: &Rc<Self>) {
        let enabled = self.settings.borrow().background_clipboard;
        if self.clip_bg.borrow().is_some() && enabled {
            return;
        }
        self.clip_bg.borrow_mut().take();
        self.clip_since.set(Some(std::time::Instant::now()));
        let (mode, bg) = clipboard::start(self.tx.clone(), enabled);
        self.clip_mode.set(mode);
        *self.clip_bg.borrow_mut() = bg;
        // While the window is in front GTK sees every copy too; in the foreground mode that is the only way.
        if self.gtk_clipboard_watched.replace(true) {
            return;
        }
        if let Some(display) = gdk::Display::default() {
            let me = self.clone();
            display.clipboard().connect_changed(move |cb| {
                if me.clip_bg.borrow().is_some() || cb.is_local() {
                    return;
                }
                me.read_gtk_clipboard(false);
            });
        }
    }

    /// Reads the clipboard through GTK (works while Bridgey's window is in front, and always on X11).
    pub fn read_gtk_clipboard(self: &Rc<Self>, send_now: bool) {
        let Some(display) = gdk::Display::default() else { return };
        let cb = display.clipboard();
        let me = self.clone();
        glib::spawn_future_local(async move {
            let formats = cb.formats();
            let secret = formats.contain_mime_type(clipboard::SECRET_HINT);
            let clip = if formats.contains_type(gdk::FileList::static_type()) {
                match cb.read_value_future(gdk::FileList::static_type(), glib::Priority::DEFAULT).await {
                    Ok(v) => v.get::<gdk::FileList>().ok().map(|l| Clip::Files(l.files().iter().filter_map(|f| f.path()).collect())),
                    Err(_) => None,
                }
            } else if formats.contains_type(gdk::Texture::static_type()) && !formats.contain_mime_type("text/plain;charset=utf-8") {
                match cb.read_texture_future().await {
                    Ok(Some(tex)) => Some(Clip::Image { mime: "image/png".into(), data: tex.save_to_png_bytes().to_vec() }),
                    _ => None,
                }
            } else {
                match cb.read_text_future().await {
                    Ok(Some(text)) if !text.is_empty() => Some(Clip::Text { text: text.to_string(), secret }),
                    _ => None,
                }
            };
            if let Some(clip) = clip {
                if send_now {
                    me.send_clip(clip, None);
                } else {
                    me.clip_changed(clip);
                }
            }
        });
    }

    /// A copy on this computer.
    fn clip_changed(self: &Rc<Self>, clip: Clip) {
        *self.last_clip.borrow_mut() = Some(clip.clone());
        let Clip::Text { text, secret } = clip else { return };
        if !self.settings.borrow().automatic_clipboard || secret {
            return;
        }
        if self.clip_bg.borrow().is_some() && self.clip_since.get().is_some_and(|t| t.elapsed() < Duration::from_millis(1500)) {
            return;
        }
        if self.state.borrow().last_received.as_deref() == Some(text.as_str()) || self.last_sent.borrow().as_deref() == Some(text.as_str()) {
            return;
        }
        // A short pause, so a burst of copies sends only the last (as Windows).
        if let Some(id) = self.automatic_timer.borrow_mut().take() {
            id.remove();
        }
        let me = self.clone();
        let id = glib::timeout_add_local_once(Duration::from_millis(300), move || {
            me.automatic_timer.borrow_mut().take();
            let targets: Vec<String> = me.state.borrow().devices.iter().filter(|d| d.ready("clipboard")).map(|d| d.id.clone()).collect();
            for id in targets {
                me.send_text(&id, &text, true);
            }
        });
        *self.automatic_timer.borrow_mut() = Some(id);
    }

    /// Puts text from a device on this computer's clipboard, or waits for one click where the desktop does not allow it
    /// from the background.
    pub fn set_clipboard(self: &Rc<Self>, text: &str, from: &str) {
        *self.last_clip.borrow_mut() = Some(Clip::Text { text: text.to_string(), secret: false });
        if let Some(bg) = self.clip_bg.borrow().as_ref() {
            bg.set_text(text);
            return;
        }
        let active = self.window().is_some_and(|w| w.is_active());
        if active {
            if let Some(d) = gdk::Display::default() {
                d.clipboard().set_text(text);
            }
            return;
        }
        *self.pending_clip.borrow_mut() = Some(PendingClip { text: text.to_string(), from: from.to_string() });
        self.notifier.clipboard_waiting(from, &crate::state::preview(text));
    }

    /// The window came to the front: text waiting for it goes on the clipboard now.
    pub fn window_active(self: &Rc<Self>) {
        if let Some(p) = self.pending_clip.borrow_mut().take() {
            if let Some(d) = gdk::Display::default() {
                d.clipboard().set_text(&p.text);
            }
            self.notifier.clipboard_done();
            self.toast(&tf("clipboard.copied_from", &[&p.from]));
        }
    }

    pub fn send_text(self: &Rc<Self>, device: &str, text: &str, automatic: bool) {
        let name = self.state.borrow().name_of(device);
        match self.core.client.send_clipboard(device, text) {
            Ok(request) => {
                *self.last_sent.borrow_mut() = Some(text.to_string());
                let preview = if self.settings.borrow().show_previews { crate::state::preview(text) } else { String::new() };
                let title = if automatic { tf("activity.clipboard_auto_to", &[&name]) } else { tf("activity.clipboard_to", &[&name]) };
                let mut st = self.state.borrow_mut();
                let row = st.add_activity(Direction::Sent, title, preview, t("activity.sending").into());
                st.track(request, row);
            }
            Err(bridgey_core::ClientError::TooLarge) => {
                // Long text goes as a text file.
                let path = paths::cache_dir().join("clipboard").join(format!("{}.txt", t("clipboard.file_name")));
                let _ = std::fs::create_dir_all(path.parent().unwrap());
                if std::fs::write(&path, text).is_ok() {
                    self.send_files(device, &[path]);
                }
            }
            Err(e) => self.toast(&tf("send.failed", &[&e.to_string()])),
        }
        self.queue_render();
    }

    /// Send copied item: text as text, an image or files as files.
    pub fn send_clip(self: &Rc<Self>, clip: Clip, device: Option<String>) {
        let key = if matches!(clip, Clip::Text { .. }) { "clipboard" } else { "files" };
        let Some(device) = device.or_else(|| self.state.borrow().default_target(key)).or_else(|| self.state.borrow().connected().first().map(|d| d.id.clone())) else {
            self.toast(t("send.no_device"));
            return;
        };
        match clip {
            Clip::Text { text, .. } => self.send_text(&device, &text, false),
            Clip::Image { mime, data } => {
                let ext = mime.rsplit('/').next().unwrap_or("png");
                let stamp = glib::DateTime::now_local().ok().and_then(|d| d.format("%Y-%m-%d %H.%M.%S").ok()).map(|s| s.to_string()).unwrap_or_default();
                let path = paths::cache_dir().join("clipboard").join(format!("{} {stamp}.{ext}", t("clipboard.image_name")));
                let _ = std::fs::create_dir_all(path.parent().unwrap());
                if std::fs::write(&path, data).is_ok() {
                    self.send_files(&device, &[path]);
                }
            }
            Clip::Files(paths) => self.send_files(&device, &paths),
        }
    }

    /// Send copied item from a button, the tray or a shortcut.
    pub fn send_copied(self: &Rc<Self>, device: Option<String>) {
        if self.clip_bg.borrow().is_some() {
            if let Some(clip) = self.last_clip.borrow().clone() {
                self.send_clip(clip, device);
                return;
            }
        }
        let active = self.window().is_some_and(|w| w.is_active());
        if !active && self.clip_mode.get() == Mode::Foreground {
            // GNOME on Wayland gives the clipboard only to the app in front: come forward, then read it.
            self.present(None);
            let me = self.clone();
            glib::timeout_add_local_once(Duration::from_millis(250), move || me.read_gtk_clipboard(true));
            return;
        }
        let _ = device;
        self.read_gtk_clipboard(true);
    }

    // ---- Files ----

    pub fn send_files(self: &Rc<Self>, device: &str, files: &[PathBuf]) {
        let name = self.state.borrow().name_of(device);
        let mut skipped = 0;
        for f in files {
            if f.is_dir() {
                skipped += 1;
                continue;
            }
            match self.core.client.send_file(device, f, None, None) {
                Ok(transfer) => {
                    let file_name = f.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                    let mut st = self.state.borrow_mut();
                    let row = st.add_activity(Direction::Sent, tf("activity.file_to", &[&name]), file_name, t("activity.sending").into());
                    if let Some(a) = st.activity_mut(row) {
                        a.path = Some(f.clone());
                        a.progress = Some((0, std::fs::metadata(f).map(|m| m.len()).unwrap_or(0)));
                    }
                    st.track_transfer(transfer, row);
                }
                Err(e) => self.toast(&tf("send.failed", &[&e.to_string()])),
            }
        }
        if skipped > 0 {
            self.toast(t("send.no_folders"));
        }
        self.queue_render();
    }

    /// Files from the file manager or the command line: to the only connected device, or the first after a
    /// choice. Just after start no device is connected yet, so they wait up to 20 s.
    pub fn send_from_shell(self: &Rc<Self>, files: Vec<PathBuf>) {
        if files.is_empty() {
            return;
        }
        let ready: Vec<String> = self.state.borrow().devices.iter().filter(|d| d.ready("files")).map(|d| d.id.clone()).collect();
        match ready.len() {
            1 => self.send_files(&ready[0], &files),
            0 => {
                *self.pending_send.borrow_mut() = files;
                let me = self.clone();
                glib::timeout_add_seconds_local_once(20, move || {
                    let waiting = std::mem::take(&mut *me.pending_send.borrow_mut());
                    if !waiting.is_empty() {
                        me.present(None);
                        me.toast(t("send.no_device"));
                    }
                });
            }
            _ => ui::home::choose_device(self, files),
        }
    }

    fn try_pending_send(self: &Rc<Self>) {
        if self.pending_send.borrow().is_empty() {
            return;
        }
        let me = self.clone();
        // Features arrive just after the connection.
        glib::timeout_add_local_once(Duration::from_millis(1500), move || {
            let files = std::mem::take(&mut *me.pending_send.borrow_mut());
            if !files.is_empty() {
                me.send_from_shell(files);
            }
        });
    }

    pub fn choose_and_send(self: &Rc<Self>, device: Option<String>) {
        let dialog = gtk::FileDialog::builder().title(t("send.choose_files")).modal(true).build();
        let me = self.clone();
        let parent = self.window();
        dialog.open_multiple(parent.as_ref(), None::<&gio::Cancellable>, move |res| {
            let Ok(list) = res else { return };
            let files: Vec<PathBuf> = (0..list.n_items()).filter_map(|i| list.item(i).and_downcast::<gio::File>()).filter_map(|f| f.path()).collect();
            match &device {
                Some(d) => me.send_files(d, &files),
                None => me.send_from_shell(files),
            }
        });
    }

    pub fn open_path(&self, path: &Path, folder: bool) {
        if folder {
            platform::launch::show_in_folder(path);
        } else if !platform::launch::open_file(path) {
            self.toast(t("file.no_app"));
        }
    }

    pub fn open_link(&self, url: &str) {
        if std::env::var("BRIDGEY_NO_BROWSER").as_deref() == Ok("1") {
            eprintln!("bridgey: would open {url}");
            return;
        }
        if !platform::launch::open_uri(url) {
            self.toast(t("link.no_browser"));
        }
    }

    // ---- Events ----

    pub fn refresh(self: &Rc<Self>) {
        let snap = self.core.client.snapshot();
        self.state.borrow_mut().load_snapshot(&snap);
        self.queue_render();
    }

    pub fn on_event(self: &Rc<Self>, e: Event) {
        let connected = matches!(e, Event::Connected { .. } | Event::Features { .. });
        let fx = {
            let settings = self.settings.borrow().clone();
            self.state.borrow_mut().apply(e, &settings)
        };
        for f in fx {
            self.effect(f);
        }
        if connected {
            self.try_pending_send();
        }
        self.queue_render();
    }

    fn effect(self: &Rc<Self>, f: Effect) {
        match f {
            Effect::Refresh => self.refresh(),
            Effect::SetClipboard { text, from, .. } => self.set_clipboard(&text, &from),
            Effect::ShowNotification(n) => {
                let icon = n.n.icon.as_deref().and_then(icon_file);
                self.notifier.phone(&n, icon);
                if self.settings.borrow().notification_history {
                    crate::history::save(&self.state.borrow().notifications);
                }
            }
            Effect::RemoveNotification { device_id, notification_id } => self.notifier.remove_phone(&(device_id, notification_id)),
            Effect::CopyCode(code) => {
                self.set_clipboard(&code, edition::SHORT_NAME);
                self.toast(&tf("code.copied", &[&code]));
            }
            Effect::StartRinging { from } => {
                self.notifier.ring(&from);
                self.ringer.start();
            }
            Effect::StopRinging => {
                self.notifier.stop_ring();
                self.ringer.stop();
            }
            Effect::OpenLink(url) => self.open_link(&url),
            Effect::FileArrived { path, name, from } => {
                if self.settings.borrow().file_notifications {
                    self.notifier.file(&name, &from, &path);
                }
            }
            Effect::MediaCommand { device_id, request_id, action, value } => {
                if !self.settings.borrow().media {
                    let _ = self.core.client.media_result(&device_id, &request_id, false);
                    return;
                }
                let tx = self.tx.clone();
                rt().spawn(async move {
                    let ok = match zbus::Connection::session().await {
                        Ok(conn) => platform::media::Media::default().run(&conn, &action, value).await,
                        Err(_) => false,
                    };
                    let _ = tx.send(UiMsg::MediaDone { device_id, request_id, ok }).await;
                });
            }
            Effect::RefuseAdvertise { device_id, service_uuid } => {
                let _ = self.core.client.codes_advertise_result(&device_id, &service_uuid, false, Some("unsupported"));
            }
            Effect::Toast(text) => self.toast(&text),
            Effect::ShowPairing => {
                if !self.pairing_open.get() {
                    self.present(None);
                    ui::pair::open(self);
                }
            }
        }
    }

    pub fn on_msg(self: &Rc<Self>, m: UiMsg) {
        match m {
            UiMsg::ShowWindow { token } => self.present(token.as_deref()),
            UiMsg::Pair => {
                self.present(None);
                ui::pair::open(self);
            }
            UiMsg::Settings => {
                self.present(None);
                ui::prefs::open(self, None);
            }
            UiMsg::SendFiles => {
                self.present(None);
                self.choose_and_send(None);
            }
            UiMsg::SendClipboard => self.send_copied(None),
            UiMsg::AllowPairing => {
                self.core.client.allow_pairing(bridgey_core::client::ALLOW_DEFAULT);
                self.notifier.plain(t("pair.allowed_title"), t("pair.allowed_body"));
            }
            UiMsg::Quit => self.quit(),
            UiMsg::TrayAvailable(on) => {
                self.tray_shown.set(on);
                self.queue_render();
            }
            UiMsg::NoticeAction { key, action, token } => self.notice_action(&key, &action, token.as_deref()),
            UiMsg::NoticeReply { key, action, text } => self.reply(&key, action, &text),
            UiMsg::StopRinging => self.stop_ringing(),
            UiMsg::OpenPath { path, folder } => self.open_path(Path::new(&path), folder),
            UiMsg::ApplyClipboard { token } => {
                self.present(token.as_deref());
                let me = self.clone();
                glib::timeout_add_local_once(Duration::from_millis(150), move || {
                    if me.window().is_some_and(|w| w.is_active()) {
                        me.window_active();
                    }
                });
            }
            UiMsg::ClipboardChanged(clip) => self.clip_changed(clip),
            UiMsg::MediaState(state) => {
                if self.settings.borrow().media {
                    let _ = self.core.client.set_media_state(state.as_deref());
                }
            }
            UiMsg::MediaDone { device_id, request_id, ok } => {
                let _ = self.core.client.media_result(&device_id, &request_id, ok);
            }
        }
        self.queue_render();
    }

    pub fn find_notice(&self, key: &NoticeKey) -> Option<PhoneNotice> {
        self.state.borrow().notifications.iter().find(|n| &n.key() == key).cloned()
    }

    pub fn notice_action(self: &Rc<Self>, key: &NoticeKey, action: &str, token: Option<&str>) {
        let Some(notice) = self.find_notice(key) else {
            self.present(token);
            return;
        };
        let c = &self.core.client;
        if action == "default" {
            self.present(token);
            ui::window::show_page(self, "notifications");
        } else if action == "dismiss" {
            let _ = c.dismiss_notification(&key.0, &key.1);
            self.state.borrow_mut().remove_notification(&key.0, &key.1);
            self.notifier.remove_phone(key);
        } else if action == "copy" {
            if let Some(code) = &notice.n.code {
                self.set_clipboard(&code.code, &notice.device_name);
                self.toast(&tf("code.copied", &[&code.code]));
            }
        } else if let Some(i) = action.strip_prefix("reply").and_then(|i| i.parse::<usize>().ok()) {
            *self.reply_to.borrow_mut() = Some((key.clone(), i));
            self.present(token);
            ui::window::show_page(self, "notifications");
        } else if let Some(i) = action.strip_prefix('a').and_then(|i| i.parse::<usize>().ok()) {
            if let Some(a) = notice.n.actions.get(i) {
                let _ = c.notification_action(&key.0, &key.1, &a.token, None);
            }
        }
        self.queue_render();
    }

    pub fn reply(self: &Rc<Self>, key: &NoticeKey, action: usize, text: &str) {
        let Some(notice) = self.find_notice(key) else { return };
        let Some(a) = notice.n.actions.get(action) else { return };
        match self.core.client.notification_action(&key.0, &key.1, &a.token, Some(text)) {
            Ok(()) => self.toast(&tf("notice.replied", &[&notice.n.title])),
            Err(e) => self.toast(&tf("send.failed", &[&e.to_string()])),
        }
        self.reply_to.borrow_mut().take();
        self.queue_render();
    }

    pub fn stop_ringing(self: &Rc<Self>) {
        let from = self.state.borrow_mut().ringing_from.take();
        self.ringer.stop();
        self.notifier.stop_ring();
        if let Some(from) = from {
            let _ = self.core.client.find_stopped(&from);
        }
        self.queue_render();
    }

    // ---- Updates ----

    pub fn check_updates(self: &Rc<Self>, manual: bool) {
        if matches!(*self.update.borrow(), UpdateStatus::Checking | UpdateStatus::Downloading(..)) {
            return;
        }
        *self.update.borrow_mut() = UpdateStatus::Checking;
        self.update_settings(|s| s.last_update_check = now_secs());
        let channel = self.settings.borrow().channel(edition::VERSION_NAME).to_string();
        let src = update::source();
        let (tx, rx) = async_channel::bounded(1);
        std::thread::spawn(move || {
            let _ = tx.send_blocking(update::check(&src, &channel));
        });
        let me = self.clone();
        glib::spawn_future_local(async move {
            let result = rx.recv().await.unwrap_or(Err("no answer".into()));
            *me.update.borrow_mut() = match result {
                Ok(Some(offer)) => UpdateStatus::Available(offer),
                Ok(None) => UpdateStatus::UpToDate,
                Err(e) => {
                    if !manual {
                        UpdateStatus::Idle
                    } else {
                        UpdateStatus::Failed(e)
                    }
                }
            };
            me.queue_render();
        });
    }

    /// Install, after the person confirmed: download, check, replace the AppImage and restart from it.
    pub fn install_update(self: &Rc<Self>) {
        let UpdateStatus::Available(offer) = self.update.borrow().clone() else { return };
        let Some(target) = update::installable() else {
            self.open_link(&format!("https://github.com/{}/releases", edition::REPOSITORY));
            return;
        };
        *self.update.borrow_mut() = UpdateStatus::Downloading(0, offer.size);
        let src = update::source();
        let (tx, rx) = async_channel::unbounded::<Result<(u64, u64), Result<PathBuf, String>>>();
        let o = offer.clone();
        std::thread::spawn(move || {
            let ptx = tx.clone();
            let mut last = std::time::Instant::now();
            let progress = move |got: u64, total: u64| {
                if last.elapsed() > Duration::from_millis(250) {
                    last = std::time::Instant::now();
                    let _ = ptx.send_blocking(Ok((got, total)));
                }
            };
            let progress = std::sync::Mutex::new(progress);
            let result = update::download(&src, &o, &|g, t| (progress.lock().unwrap())(g, t)).and_then(|p| update::install(&p, &target).map(|_| target.clone()));
            let _ = tx.send_blocking(Err(result));
        });
        let me = self.clone();
        glib::spawn_future_local(async move {
            while let Ok(msg) = rx.recv().await {
                match msg {
                    Ok((got, total)) => {
                        *me.update.borrow_mut() = UpdateStatus::Downloading(got, total);
                        me.queue_render();
                    }
                    Err(Ok(path)) => {
                        *me.restart.borrow_mut() = Some(path);
                        me.quit();
                        return;
                    }
                    Err(Err(e)) => {
                        *me.update.borrow_mut() = UpdateStatus::Failed(e);
                        me.queue_render();
                        return;
                    }
                }
            }
        });
    }

    pub fn quit(&self) {
        self.ringer.stop();
        self.hold.borrow_mut().take();
        self.core.client.stop();
        self.gtk.quit();
    }

    // ---- Rendering ----

    /// Draws the window again once this turn of the main loop is done (many events can arrive at once).
    pub fn queue_render(self: &Rc<Self>) {
        if self.render_queued.replace(true) {
            return;
        }
        let me = self.clone();
        glib::idle_add_local_once(move || {
            me.render_queued.set(false);
            me.render();
        });
    }

    fn render(self: &Rc<Self>) {
        ui::window::render(self);
        if let Some(tray) = self.tray.borrow().as_ref() {
            let st = self.state.borrow();
            tray.update(st.status_text(), st.devices.iter().any(|d| d.ready("files") || d.ready("clipboard")));
        }
    }
}

fn label_toast_buttons(w: &gtk::Widget) {
    if w.type_().name() == "AdwToastWidget" {
        let mut c = w.first_child();
        while let Some(x) = c {
            if x.is::<gtk::Button>() && x.tooltip_text().is_none() && x.downcast_ref::<gtk::Button>().and_then(|b| b.label()).is_none() {
                x.set_tooltip_text(Some(t("common.dismiss")));
                x.update_property(&[gtk::accessible::Property::Label(t("common.dismiss"))]);
            }
            label_toast_buttons(&x);
            c = x.next_sibling();
        }
        return;
    }
    let mut c = w.first_child();
    while let Some(x) = c {
        label_toast_buttons(&x);
        c = x.next_sibling();
    }
}

/// A phone notification's icon (base64 PNG) as a file the notification server can read, kept in the cache by content.
fn icon_file(b64: &str) -> Option<PathBuf> {
    use std::hash::{Hash, Hasher};
    let bytes = bridgey_core::crypto::unb64(b64)?;
    if !bytes.starts_with(b"\x89PNG") {
        return None;
    }
    let mut h = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut h);
    let dir = paths::cache_dir().join("icons");
    let path = dir.join(format!("{:016x}.png", h.finish()));
    if !path.exists() {
        std::fs::create_dir_all(&dir).ok()?;
        // At most 200 icons are kept.
        if let Ok(entries) = std::fs::read_dir(&dir) {
            let mut files: Vec<_> = entries.flatten().filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path()))).collect();
            if files.len() >= 200 {
                files.sort();
                for (_, p) in files.iter().take(files.len() - 150) {
                    let _ = std::fs::remove_file(p);
                }
            }
        }
        std::fs::write(&path, bytes).ok()?;
    }
    Some(path)
}
