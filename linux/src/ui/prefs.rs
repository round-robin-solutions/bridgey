//! Settings in the six groups the Mac and Android use (Devices, Sharing, Phone, Control, Privacy, App), with search.
//! Every setting has one home; per-device switches live with each paired device.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};

use super::widgets::text_button;
use crate::app::{App, UpdateStatus};
use crate::edition;
use crate::i18n::{t, tf};
use crate::platform::clipboard::Mode;
use crate::settings::{AppSettings, Theme};

struct Prefs {
    dialog: adw::PreferencesDialog,
    devices_group: adw::PreferencesGroup,
    device_rows: RefCell<Vec<gtk::Widget>>,
    devices_drawn: RefCell<String>,
    connect_status: adw::ActionRow,
    update_status: adw::ActionRow,
    update_button: gtk::Button,
    tray_row: adw::ActionRow,
    clipboard_row: adw::ActionRow,
}

thread_local! {
    static OPEN: RefCell<Option<Rc<Prefs>>> = const { RefCell::new(None) };
}

fn esc(s: &str) -> String {
    glib::markup_escape_text(s).to_string()
}

fn switch(app: &Rc<App>, title: &str, subtitle: &str, get: fn(&AppSettings) -> bool, set: fn(&mut AppSettings, bool)) -> adw::SwitchRow {
    let row = adw::SwitchRow::builder().title(esc(title)).active(get(&app.settings.borrow())).build();
    if !subtitle.is_empty() {
        row.set_subtitle(&esc(subtitle));
    }
    let me = app.clone();
    row.connect_active_notify(move |r| {
        let on = r.is_active();
        if get(&me.settings.borrow()) != on {
            me.update_settings(|s| set(s, on));
        }
    });
    row
}

fn group(title: &str, description: &str) -> adw::PreferencesGroup {
    let g = adw::PreferencesGroup::builder().title(esc(title)).build();
    if !description.is_empty() {
        g.set_description(Some(&esc(description)));
    }
    g
}

fn page(title: &str, icon: &str, name: &str) -> adw::PreferencesPage {
    adw::PreferencesPage::builder().title(title).icon_name(icon).name(name).build()
}

pub fn clipboard_text(mode: Mode) -> &'static str {
    match mode {
        Mode::DataControl => t("clipboard.mode.datacontrol"),
        Mode::X11 => t("clipboard.mode.x11"),
        Mode::XWayland => t("clipboard.mode.xwayland"),
        Mode::Foreground => t("clipboard.mode.foreground"),
    }
}

fn connect_text(state: &str) -> &'static str {
    match state {
        "online" => t("connect.online"),
        "connecting" => t("connect.connecting"),
        "unreachable" => t("connect.unreachable"),
        "disabled" => t("connect.disabled"),
        "unavailable" => t("connect.unavailable"),
        _ => t("connect.off"),
    }
}

pub fn open(app: &Rc<App>, device: Option<String>) {
    if let Some(p) = OPEN.with(|o| o.borrow().clone()) {
        p.dialog.present(app.window().as_ref());
        if device.is_some() {
            p.dialog.set_visible_page_name("devices");
        }
        return;
    }
    let dialog = adw::PreferencesDialog::builder().title(t("settings.title")).search_enabled(true).build();

    // ---- Devices ----
    let devices = page(t("settings.devices"), "phone-symbolic", "devices");
    let this = group(t("settings.this_computer"), "");
    let name = adw::EntryRow::builder().title(t("settings.name")).text(crate::core::device_name(&app.settings.borrow())).show_apply_button(true).build();
    let me = app.clone();
    name.connect_apply(move |e| {
        let v = e.text().trim().to_string();
        me.update_settings(|s| s.device_name = v);
    });
    this.add(&name);
    devices.add(&this);
    let devices_group = group(t("settings.paired"), t("settings.paired_detail"));
    devices.add(&devices_group);
    let pair_group = group(t("pair.title"), "");
    let pair_row = adw::ActionRow::builder().title(t("pair.title")).subtitle(t("settings.pair_detail")).activatable(true).build();
    pair_row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
    let me = app.clone();
    pair_row.connect_activated(move |_| super::pair::open(&me));
    pair_group.add(&pair_row);
    devices.add(&pair_group);
    let away = group(t("settings.away"), t("settings.away_detail"));
    away.add(&switch(app, t("settings.away"), "", |s| s.connect_away, |s, v| s.connect_away = v));
    let connect_status = adw::ActionRow::builder().title(t("settings.status")).build();
    connect_status.add_css_class("property");
    away.add(&connect_status);
    devices.add(&away);
    let more = group(t("settings.device_features"), "");
    more.add(&switch(app, t("settings.battery"), t("settings.battery_detail"), |s| s.battery, |s, v| s.battery = v));
    more.add(&switch(app, t("settings.find"), t("settings.find_detail"), |s| s.find_device, |s, v| s.find_device = v));
    more.add(&switch(app, t("settings.ping"), "", |s| s.ping, |s, v| s.ping = v));
    devices.add(&more);
    dialog.add(&devices);

    // ---- Sharing ----
    let sharing = page(t("settings.sharing"), "send-to-symbolic", "sharing");
    let clip = group(t("settings.clipboard"), "");
    clip.add(&switch(app, t("settings.clipboard"), t("settings.clipboard_detail"), |s| s.clipboard, |s, v| s.clipboard = v));
    clip.add(&switch(app, t("settings.auto_clipboard"), t("settings.auto_clipboard_detail"), |s| s.automatic_clipboard, |s, v| s.automatic_clipboard = v));
    clip.add(&switch(app, t("settings.background_clipboard"), t("settings.background_clipboard_detail"), |s| s.background_clipboard, |s, v| s.background_clipboard = v));
    let clipboard_row = adw::ActionRow::builder().title(t("settings.clipboard_here")).build();
    clipboard_row.add_css_class("property");
    clip.add(&clipboard_row);
    sharing.add(&clip);
    let files = group(t("settings.files"), "");
    files.add(&switch(app, t("settings.files"), t("settings.files_detail"), |s| s.files, |s, v| s.files = v));
    let folder = adw::ActionRow::builder().title(t("settings.receive_folder")).subtitle(esc(&app.settings.borrow().receive_dir().to_string_lossy())).build();
    let change = text_button(t("settings.change"));
    change.update_property(&[gtk::accessible::Property::Label(t("settings.change_folder"))]);
    let (me, row) = (app.clone(), folder.clone());
    change.connect_clicked(move |_| {
        let dialog = gtk::FileDialog::builder().title(t("settings.receive_folder")).modal(true).build();
        dialog.set_initial_folder(Some(&gio::File::for_path(me.settings.borrow().receive_dir())));
        let (me2, row2) = (me.clone(), row.clone());
        dialog.select_folder(me.window().as_ref(), None::<&gio::Cancellable>, move |res| {
            if let Some(path) = res.ok().and_then(|f| f.path()) {
                let p = path.to_string_lossy().to_string();
                row2.set_subtitle(&esc(&p));
                me2.update_settings(|s| s.receive_folder = p);
            }
        });
    });
    folder.add_suffix(&change);
    files.add(&folder);
    files.add(&switch(app, t("settings.file_notifications"), "", |s| s.file_notifications, |s, v| s.file_notifications = v));
    files.add(&switch(app, t("settings.file_manager"), t("settings.file_manager_detail"), |s| s.file_manager_actions, |s, v| s.file_manager_actions = v));
    sharing.add(&files);
    let links = group(t("settings.links"), "");
    links.add(&switch(app, t("settings.links"), t("settings.links_detail"), |s| s.links, |s, v| s.links = v));
    links.add(&switch(app, t("settings.open_links"), t("settings.open_links_detail"), |s| s.open_links_right_away, |s, v| s.open_links_right_away = v));
    sharing.add(&links);
    dialog.add(&sharing);

    // ---- Phone ----
    let phone = page(t("settings.phone"), "preferences-system-notifications-symbolic", "phone");
    let notes = group(t("settings.notifications"), "");
    notes.add(&switch(app, t("settings.notifications"), t("settings.notifications_detail"), |s| s.notifications, |s, v| s.notifications = v));
    notes.add(&switch(app, t("settings.banners"), t("settings.banners_detail"), |s| s.notification_banners, |s, v| s.notification_banners = v));
    let muted = adw::ExpanderRow::builder().title(t("settings.muted")).subtitle(t("settings.muted_detail")).build();
    for package in app.settings.borrow().muted_apps.clone() {
        let row = adw::ActionRow::builder().title(esc(&package)).build();
        let unmute = super::widgets::icon_button("list-remove-symbolic", &tf("settings.unmute", &[&package]));
        let (me, p, r) = (app.clone(), package.clone(), row.clone());
        unmute.connect_clicked(move |_| {
            me.update_settings(|s| s.muted_apps.retain(|m| m != &p));
            r.set_visible(false);
        });
        row.add_suffix(&unmute);
        muted.add_row(&row);
    }
    notes.add(&muted);
    notes.add(&switch(app, t("settings.history"), t("settings.history_detail"), |s| s.notification_history, |s, v| s.notification_history = v));
    phone.add(&notes);
    let codes = group(t("settings.codes"), t("settings.codes_detail"));
    codes.add(&switch(app, t("settings.codes"), "", |s| s.codes_from_messages, |s, v| s.codes_from_messages = v));
    codes.add(&switch(app, t("settings.codes_email"), "", |s| s.codes_from_email, |s, v| s.codes_from_email = v));
    codes.add(&switch(app, t("settings.copy_codes"), "", |s| s.copy_codes, |s, v| s.copy_codes = v));
    phone.add(&codes);
    dialog.add(&phone);

    // ---- Control ----
    let control = page(t("settings.control"), "input-mouse-symbolic", "control");
    let media = group(t("settings.media"), "");
    media.add(&switch(app, t("settings.media"), t("settings.media_detail"), |s| s.media, |s, v| s.media = v));
    control.add(&media);
    dialog.add(&control);

    // ---- Privacy ----
    let privacy = page(t("settings.privacy"), "security-high-symbolic", "privacy");
    let activity = group(t("settings.activity"), "");
    activity.add(&switch(app, t("settings.previews"), t("settings.previews_detail"), |s| s.show_previews, |s, v| s.show_previews = v));
    activity.add(&switch(app, t("settings.presence"), t("settings.presence_detail"), |s| s.share_activity, |s, v| s.share_activity = v));
    let clear = adw::ActionRow::builder().title(t("settings.clear_activity")).build();
    let clear_button = text_button(t("settings.clear"));
    let me = app.clone();
    clear_button.connect_clicked(move |_| {
        me.state.borrow_mut().activity.clear();
        me.state.borrow_mut().notifications.clear();
        crate::history::clear();
        me.toast(t("settings.cleared"));
        me.queue_render();
    });
    clear.add_suffix(&clear_button);
    activity.add(&clear);
    privacy.add(&activity);
    let data = group(t("settings.data"), t("settings.data_detail"));
    let data_row = adw::ActionRow::builder().title(t("settings.data_folder")).subtitle(esc(&crate::paths::data_dir().to_string_lossy())).build();
    data.add(&data_row);
    privacy.add(&data);
    dialog.add(&privacy);

    // ---- App ----
    let app_page = page(t("settings.app"), "emblem-system-symbolic", "app");
    let updates = group(t("settings.updates"), "");
    let channels = gtk::StringList::new(&[t("channel.stable"), t("channel.beta"), t("channel.nightly")]);
    let current = match app.settings.borrow().channel(edition::VERSION_NAME) {
        "stable" => 0,
        "nightly" => 2,
        _ => 1,
    };
    let channel = adw::ComboRow::builder().title(t("settings.channel")).model(&channels).selected(current).build();
    let me = app.clone();
    channel.connect_selected_notify(move |c| {
        let v = ["stable", "beta", "nightly"][c.selected().min(2) as usize].to_string();
        me.update_settings(|s| s.update_channel = v);
        me.check_updates(true);
    });
    updates.add(&channel);
    updates.add(&switch(app, t("settings.auto_update"), t("settings.auto_update_detail"), |s| s.auto_update_check, |s, v| s.auto_update_check = v));
    let update_status = adw::ActionRow::builder().title(t("settings.version")).build();
    let update_button = text_button(t("update.check"));
    let me = app.clone();
    update_button.connect_clicked(move |_| {
        if matches!(*me.update.borrow(), UpdateStatus::Available(_)) {
            confirm_install(&me);
        } else {
            me.check_updates(true);
        }
    });
    update_status.add_suffix(&update_button);
    updates.add(&update_status);
    app_page.add(&updates);
    let general = group(t("settings.general"), "");
    general.add(&switch(app, t("settings.autostart"), t("settings.autostart_detail"), |s| s.start_at_sign_in, |s, v| s.start_at_sign_in = v));
    general.add(&switch(app, t("settings.keep_running"), t("settings.keep_running_detail"), |s| s.keep_running, |s, v| s.keep_running = v));
    general.add(&switch(app, t("settings.app_menu"), t("settings.app_menu_detail"), |s| s.app_menu_entry, |s, v| s.app_menu_entry = v));
    let themes = gtk::StringList::new(&[t("theme.system"), t("theme.light"), t("theme.dark")]);
    let theme = adw::ComboRow::builder()
        .title(t("settings.appearance"))
        .model(&themes)
        .selected(match app.settings.borrow().theme {
            Theme::System => 0,
            Theme::Light => 1,
            Theme::Dark => 2,
        })
        .build();
    let me = app.clone();
    theme.connect_selected_notify(move |c| {
        let v = [Theme::System, Theme::Light, Theme::Dark][c.selected().min(2) as usize];
        me.update_settings(|s| s.theme = v);
    });
    general.add(&theme);
    general.add(&switch(app, t("settings.reduce_motion"), t("settings.reduce_motion_detail"), |s| s.reduce_motion, |s, v| s.reduce_motion = v));
    let tray_row = adw::ActionRow::builder().title(t("settings.tray")).build();
    tray_row.add_css_class("property");
    general.add(&tray_row);
    app_page.add(&general);
    dialog.add(&app_page);

    let p = Rc::new(Prefs {
        dialog: dialog.clone(),
        devices_group,
        device_rows: RefCell::new(vec![]),
        devices_drawn: RefCell::new(String::new()),
        connect_status,
        update_status,
        update_button,
        tray_row,
        clipboard_row,
    });
    OPEN.with(|o| *o.borrow_mut() = Some(p));
    super::widgets::keep_after_close(&dialog);
    dialog.connect_closed(|_| OPEN.with(|o| o.borrow_mut().take()).map(|_| ()).unwrap_or(()));
    render(app);
    if device.is_some() {
        dialog.set_visible_page_name("devices");
    }
    dialog.present(app.window().as_ref());
}

/// The person confirms before an update replaces this AppImage.
pub fn confirm_install(app: &Rc<App>) {
    let UpdateStatus::Available(offer) = app.update.borrow().clone() else { return };
    let installable = crate::update::installable().is_some();
    let body = if installable { tf("update.confirm_body", &[&crate::ui::widgets::size(offer.size)]) } else { t("update.manual_body").to_string() };
    let dialog = adw::AlertDialog::new(Some(&tf("update.confirm_title", &[&offer.version])), Some(&body));
    super::widgets::keep_after_close(&dialog);
    dialog.add_response("cancel", t("common.not_now"));
    dialog.add_response("install", if installable { t("update.install") } else { t("update.open_releases") });
    dialog.set_response_appearance("install", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("install"));
    let me = app.clone();
    dialog.connect_response(None, move |_, r| {
        if r == "install" {
            me.install_update();
        }
    });
    dialog.present(app.window().as_ref());
}

const PER_DEVICE: [(&str, &str); 8] = [
    ("clipboard", "settings.clipboard"),
    ("files", "settings.files"),
    ("battery", "settings.battery"),
    ("find_device", "settings.find"),
    ("ping", "settings.ping"),
    ("notifications", "settings.notifications"),
    ("links", "settings.links"),
    ("media", "settings.media"),
];

pub fn render(app: &Rc<App>) {
    let Some(p) = OPEN.with(|o| o.borrow().clone()) else { return };
    let st = app.state.borrow();
    p.connect_status.set_subtitle(connect_text(&st.connect_state));
    p.clipboard_row.set_subtitle(clipboard_text(app.clip_mode.get()));
    p.tray_row.set_subtitle(if app.tray_shown.get() { t("settings.tray_shown") } else { t("settings.tray_missing") });
    let (status, button, sensitive) = match &*app.update.borrow() {
        UpdateStatus::Idle => (tf("update.current", &[edition::VERSION_NAME]), t("update.check"), true),
        UpdateStatus::Checking => (t("update.checking").to_string(), t("update.check"), false),
        UpdateStatus::UpToDate => (tf("update.up_to_date", &[edition::VERSION_NAME]), t("update.check"), true),
        UpdateStatus::Available(o) => (tf("update.ready", &[&o.version]), t("update.install"), true),
        UpdateStatus::Downloading(g, total) => (tf("update.downloading", &[&crate::ui::widgets::size(*g), &crate::ui::widgets::size(*total)]), t("update.install"), false),
        UpdateStatus::Failed(e) => (tf("update.failed", &[e]), t("update.check"), true),
    };
    p.update_status.set_subtitle(&esc(&status));
    p.update_button.set_label(button);
    p.update_button.set_sensitive(sensitive);

    let signature = format!("{:?}", st.devices.iter().map(|d| (&d.id, &d.name, d.connected, &d.local)).collect::<Vec<_>>());
    if *p.devices_drawn.borrow() == signature {
        return;
    }
    *p.devices_drawn.borrow_mut() = signature;
    for w in p.device_rows.borrow_mut().drain(..) {
        p.devices_group.remove(&w);
    }
    if st.devices.is_empty() {
        let row = adw::ActionRow::builder().title(t("settings.no_devices")).build();
        p.devices_group.add(&row);
        p.device_rows.borrow_mut().push(row.upcast());
    }
    for d in &st.devices {
        let row = adw::ExpanderRow::builder().title(esc(&d.name)).subtitle(if d.connected { t("device.connected") } else { t("device.not_connected") }).build();
        for (key, title) in PER_DEVICE {
            let s = adw::SwitchRow::builder().title(t(title)).active(d.local_on(key)).build();
            let (me, id) = (app.clone(), d.id.clone());
            s.connect_active_notify(move |r| {
                let _ = me.core.client.set_feature(Some(&id), key, r.is_active());
                me.refresh();
            });
            row.add_row(&s);
        }
        let forget = adw::ActionRow::builder().title(t("device.forget")).build();
        let b = text_button(t("device.forget"));
        b.add_css_class("destructive-action");
        b.update_property(&[gtk::accessible::Property::Label(&tf("forget.title", &[&d.name]))]);
        let (me, id) = (app.clone(), d.id.clone());
        b.connect_clicked(move |_| {
            let _ = me.core.client.forget(&id);
            me.refresh();
        });
        forget.add_suffix(&b);
        row.add_row(&forget);
        p.devices_group.add(&row);
        p.device_rows.borrow_mut().push(row.upcast());
    }
}

pub fn close() {
    if let Some(p) = OPEN.with(|o| o.borrow().clone()) {
        p.dialog.close();
    }
}

pub fn show(name: &str) {
    if let Some(p) = OPEN.with(|o| o.borrow().clone()) {
        p.dialog.set_visible_page_name(name);
    }
}
