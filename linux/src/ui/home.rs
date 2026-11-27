//! Home: what needs an answer (ringing, a pairing request, a link, an update), each paired device with what it can do
//! now, a box to send text or a link, and the activity list.

use std::cell::RefCell;
use std::collections::HashSet;
use std::path::PathBuf;
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;

use super::widgets::{self, clear, icon_button, label, labelled_button, text_button};
use crate::app::{App, UpdateStatus};
use crate::i18n::{t, tf};
use crate::state::{Device, Direction};

pub struct Home {
    pub root: gtk::ScrolledWindow,
    banners: gtk::Box,
    devices: gtk::Box,
    empty: adw::StatusPage,
    send: gtk::Box,
    entry: gtk::Entry,
    target: gtk::DropDown,
    target_ids: RefCell<Vec<String>>,
    send_button: gtk::Button,
    link_button: gtk::Button,
    activity_box: gtk::Box,
    activity: gtk::ListBox,
    shown: RefCell<HashSet<String>>,
    /// What the device cards were drawn from: they are drawn again only when it changes, so an open menu stays open
    /// while a transfer reports progress.
    drawn: RefCell<String>,
}

pub fn build(app: &Rc<App>) -> Home {
    let column = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(18).margin_top(18).margin_bottom(24).margin_start(12).margin_end(12).build();
    let banners = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(8).build();
    let devices = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).build();
    devices.update_property(&[gtk::accessible::Property::Label(t("home.devices"))]);

    let pair = text_button(t("pair.title"));
    pair.add_css_class("suggested-action");
    pair.add_css_class("pill");
    pair.set_halign(gtk::Align::Center);
    pair.set_action_name(Some("app.pair"));
    let empty = adw::StatusPage::builder().icon_name(crate::edition::APP_ID).title(t("home.empty.title")).description(t("home.empty.body")).child(&pair).build();
    empty.add_css_class("compact");

    // The send box: text goes as clipboard text, a web link can go as a link.
    let entry = gtk::Entry::builder().placeholder_text(t("send.placeholder")).hexpand(true).build();
    entry.update_property(&[gtk::accessible::Property::Label(t("send.label"))]);
    let target = gtk::DropDown::from_strings(&[]);
    target.update_property(&[gtk::accessible::Property::Label(t("send.to"))]);
    target.set_tooltip_text(Some(t("send.to")));
    let send_button = text_button(t("send.send"));
    send_button.add_css_class("suggested-action");
    let link_button = text_button(t("send.send_link"));
    let send = gtk::Box::builder().spacing(6).build();
    send.add_css_class("card");
    send.add_css_class("send-box");
    send.append(&entry);
    send.append(&target);
    send.append(&link_button);
    send.append(&send_button);

    let activity = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::None).build();
    activity.add_css_class("boxed-list");
    activity.update_property(&[gtk::accessible::Property::Label(t("activity.title"))]);
    let activity_head = gtk::Box::builder().spacing(6).build();
    let heading = label(t("activity.title"), &["brand-heading"]);
    heading.set_hexpand(true);
    let clear_button = widgets::icon_button("edit-clear-all-symbolic", t("activity.clear"));
    activity_head.append(&heading);
    activity_head.append(&clear_button);
    let activity_box = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(8).build();
    activity_box.append(&activity_head);
    activity_box.append(&activity);

    column.append(&banners);
    column.append(&empty);
    column.append(&devices);
    column.append(&send);
    column.append(&activity_box);
    let clamp = adw::Clamp::builder().maximum_size(760).tightening_threshold(560).child(&column).build();
    let root = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&clamp).build();

    let home = Home { root, banners, devices, empty, send, entry, target, target_ids: RefCell::new(vec![]), send_button, link_button, activity_box, activity, shown: RefCell::new(HashSet::new()), drawn: RefCell::new(String::new()) };

    let me = app.clone();
    clear_button.connect_clicked(move |_| {
        me.state.borrow_mut().activity.clear();
        me.queue_render();
    });
    let me = app.clone();
    home.entry.connect_changed(move |_| me.queue_render());
    let me = app.clone();
    home.entry.connect_activate(move |_| send_draft(&me, false));
    let me = app.clone();
    home.send_button.connect_clicked(move |_| send_draft(&me, false));
    let me = app.clone();
    home.link_button.connect_clicked(move |_| send_draft(&me, true));
    home
}

fn selected_target(app: &Rc<App>) -> Option<String> {
    let ui = app.ui.borrow();
    let h = &ui.as_ref()?.home;
    let ids = h.target_ids.borrow();
    ids.get(h.target.selected() as usize).cloned()
}

fn send_draft(app: &Rc<App>, as_link: bool) {
    let (text, entry) = {
        let ui = app.ui.borrow();
        let Some(u) = ui.as_ref() else { return };
        (u.home.entry.text().to_string(), u.home.entry.clone())
    };
    if text.trim().is_empty() {
        return;
    }
    let Some(device) = selected_target(app) else {
        app.toast(t("send.no_device"));
        return;
    };
    if as_link {
        let url = text.trim().to_string();
        match app.core.client.send_link(&device, &url) {
            Ok(request) => {
                let name = app.state.borrow().name_of(&device);
                let mut st = app.state.borrow_mut();
                let row = st.add_activity(Direction::Sent, tf("activity.link_to", &[&name]), url, t("activity.sending").into());
                st.track(request, row);
            }
            Err(e) => app.toast(&tf("send.failed", &[&e.to_string()])),
        }
    } else {
        app.send_text(&device, &text, false);
    }
    entry.set_text("");
    app.queue_render();
}

fn banner(text: &str, warn: bool, buttons: Vec<gtk::Button>) -> gtk::Box {
    let b = gtk::Box::builder().spacing(10).build();
    b.add_css_class("card");
    b.add_css_class("banner-card");
    if warn {
        b.add_css_class("warn");
    }
    let l = label(text, &[]);
    l.set_hexpand(true);
    b.append(&l);
    for btn in buttons {
        b.append(&btn);
    }
    b.update_property(&[gtk::accessible::Property::Label(text)]);
    b
}

fn status_line(d: &Device) -> String {
    let mut parts = vec![if d.connected { t("device.connected").to_string() } else { t("device.not_connected").to_string() }];
    if let Some((level, charging)) = d.battery {
        parts.push(if charging { tf("device.battery_charging", &[&level.to_string()]) } else { tf("device.battery", &[&level.to_string()]) });
    }
    if d.ringing {
        parts.push(t("device.ringing").into());
    }
    parts.join(" · ")
}

fn device_icon(d: &Device) -> &'static str {
    match d.platform.as_deref() {
        Some("android") | Some("ios") => "phone-symbolic",
        Some("macos") | Some("windows") | Some("linux") => "computer-symbolic",
        Some("cli") => "network-server-symbolic",
        // Discovery tells the platform; a device paired by address may not have said: most are phones.
        _ => "phone-symbolic",
    }
}

fn device_card(app: &Rc<App>, d: &Device) -> gtk::Box {
    let card = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(12).build();
    card.add_css_class("card");
    card.add_css_class("device-card");
    card.set_accessible_role(gtk::AccessibleRole::Group);
    card.update_property(&[gtk::accessible::Property::Label(&format!("{}, {}", d.name, status_line(d)))]);

    let top = gtk::Box::builder().spacing(12).build();
    // The device's ring: the aurora when connected, as on the Mac and Windows.
    let ring = gtk::Box::builder().valign(gtk::Align::Center).halign(gtk::Align::Start).hexpand(false).vexpand(false).build();
    ring.add_css_class("ring");
    if d.connected {
        ring.add_css_class("connected");
    }
    let inner = gtk::Box::builder().halign(gtk::Align::Center).valign(gtk::Align::Center).hexpand(false).build();
    inner.add_css_class("ring-inner");
    let icon = gtk::Image::builder().icon_name(device_icon(d)).pixel_size(20).halign(gtk::Align::Center).valign(gtk::Align::Center).hexpand(true).vexpand(true).build();
    icon.set_accessible_role(gtk::AccessibleRole::Presentation);
    inner.append(&icon);
    ring.append(&inner);
    let text = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(2).hexpand(true).valign(gtk::Align::Center).build();
    text.append(&label(&d.name, &["brand-heading"]));
    text.append(&label(&status_line(d), &["brand-dim"]));
    top.append(&ring);
    top.append(&text);
    if d.away {
        let chip = gtk::Label::builder().label(t("device.away_chip")).valign(gtk::Align::Center).build();
        chip.add_css_class("chip");
        chip.add_css_class("purple");
        chip.set_tooltip_text(Some(t("device.away_tip")));
        top.append(&chip);
    }

    // More: Ping, this device's settings, Forget.
    let more = gtk::MenuButton::builder().icon_name("view-more-symbolic").tooltip_text(t("device.more")).valign(gtk::Align::Center).build();
    more.update_property(&[gtk::accessible::Property::Label(&tf("device.more_for", &[&d.name]))]);
    more.add_css_class("flat");
    let pop = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(2).margin_top(6).margin_bottom(6).margin_start(6).margin_end(6).build();
    let popover = gtk::Popover::builder().child(&pop).build();
    more.set_popover(Some(&popover));
    let item = |text: &str, f: Box<dyn Fn()>| {
        let b = gtk::Button::builder().label(text).build();
        b.add_css_class("flat");
        if let Some(l) = b.child().and_downcast::<gtk::Label>() {
            l.set_xalign(0.0);
        }
        let p = popover.clone();
        b.connect_clicked(move |_| {
            p.popdown();
            f();
        });
        pop.append(&b);
    };
    if d.ready("ping") {
        let (me, id) = (app.clone(), d.id.clone());
        item(t("device.ping"), Box::new(move || {
            if let Ok(request) = me.core.client.ping(&id) {
                let name = me.state.borrow().name_of(&id);
                let mut st = me.state.borrow_mut();
                let row = st.add_activity(Direction::Sent, tf("activity.ping_to", &[&name]), String::new(), t("activity.sending").into());
                st.track(request, row);
            }
            me.queue_render();
        }));
    }
    let (me, id) = (app.clone(), d.id.clone());
    item(t("device.settings"), Box::new(move || super::prefs::open(&me, Some(id.clone()))));
    let (me, id, name) = (app.clone(), d.id.clone(), d.name.clone());
    item(t("device.forget"), Box::new(move || forget(&me, &id, &name)));
    top.append(&more);
    card.append(&top);

    if d.connected {
        let actions = gtk::FlowBox::builder().selection_mode(gtk::SelectionMode::None).column_spacing(6).row_spacing(6).max_children_per_line(4).homogeneous(false).build();
        if d.ready("files") {
            let b = labelled_button("document-send-symbolic", t("device.send_files"));
            let (me, id) = (app.clone(), d.id.clone());
            b.connect_clicked(move |_| me.choose_and_send(Some(id.clone())));
            actions.append(&b);
        }
        if d.ready("clipboard") || d.ready("files") {
            let b = labelled_button("edit-paste-symbolic", t("device.send_clipboard"));
            let (me, id) = (app.clone(), d.id.clone());
            b.connect_clicked(move |_| me.send_copied(Some(id.clone())));
            actions.append(&b);
        }
        if d.ready("find_device") {
            let ringing = d.ringing;
            let b = labelled_button("audio-volume-high-symbolic", if ringing { t("device.stop_ring") } else { t("device.ring") });
            let (me, id) = (app.clone(), d.id.clone());
            b.connect_clicked(move |_| {
                let _ = me.core.client.find(&id, !ringing);
            });
            actions.append(&b);
        }
        if actions.first_child().is_some() {
            card.append(&actions);
        }
    }

    // Files dropped on a card go to that device.
    if d.ready("files") {
        let drop = gtk::DropTarget::new(gtk::gdk::FileList::static_type(), gtk::gdk::DragAction::COPY);
        let (me, id) = (app.clone(), d.id.clone());
        drop.connect_drop(move |_, value, _, _| {
            let Ok(list) = value.get::<gtk::gdk::FileList>() else { return false };
            let files: Vec<PathBuf> = list.files().iter().filter_map(|f| f.path()).collect();
            me.send_files(&id, &files);
            true
        });
        card.add_controller(drop);
    }
    card
}

fn forget(app: &Rc<App>, id: &str, name: &str) {
    let dialog = adw::AlertDialog::new(Some(&tf("forget.title", &[name])), Some(t("forget.body")));
    super::widgets::keep_after_close(&dialog);
    dialog.add_response("cancel", t("common.cancel"));
    dialog.add_response("forget", t("device.forget"));
    dialog.set_response_appearance("forget", adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some("cancel"));
    let (me, id) = (app.clone(), id.to_string());
    dialog.connect_response(None, move |_, r| {
        if r == "forget" {
            let _ = me.core.client.forget(&id);
            me.refresh();
        }
    });
    dialog.present(app.window().as_ref());
}

/// Several devices could take the files: the person picks one.
pub fn choose_device(app: &Rc<App>, files: Vec<PathBuf>) {
    let ready: Vec<(String, String)> = app.state.borrow().devices.iter().filter(|d| d.ready("files")).map(|d| (d.id.clone(), d.name.clone())).collect();
    app.present(None);
    let dialog = adw::AlertDialog::new(Some(t("send.choose_device")), Some(&tf("send.file_count", &[&files.len().to_string()])));
    super::widgets::keep_after_close(&dialog);
    for (id, name) in &ready {
        dialog.add_response(id, name);
    }
    dialog.add_response("cancel", t("common.cancel"));
    dialog.set_close_response("cancel");
    let me = app.clone();
    dialog.connect_response(None, move |_, r| {
        if r != "cancel" {
            me.send_files(r, &files);
        }
    });
    dialog.present(app.window().as_ref());
}

fn activity_row(app: &Rc<App>, a: &crate::state::Activity) -> gtk::ListBoxRow {
    let row = gtk::Box::builder().spacing(12).build();
    row.add_css_class("activity-row");
    let icon = gtk::Image::from_icon_name(if a.direction == Direction::Sent { "go-up-symbolic" } else { "go-down-symbolic" });
    icon.update_property(&[gtk::accessible::Property::Label(if a.direction == Direction::Sent { t("activity.sent") } else { t("activity.received") })]);
    let text = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(2).hexpand(true).build();
    text.append(&label(&a.title, &[]));
    if !a.preview.is_empty() {
        let p = label(&a.preview, &["brand-dim"]);
        p.set_wrap(false);
        p.set_ellipsize(gtk::pango::EllipsizeMode::End);
        text.append(&p);
    }
    if let Some((bytes, total)) = a.progress {
        let bar = gtk::ProgressBar::builder().fraction(if total > 0 { bytes as f64 / total as f64 } else { 0.0 }).build();
        bar.update_property(&[gtk::accessible::Property::Label(&tf("activity.progress", &[&widgets::size(bytes), &widgets::size(total)]))]);
        text.append(&bar);
    }
    let side = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(2).valign(gtk::Align::Center).build();
    let mut meta = widgets::time(a.at_ms);
    if !a.status.is_empty() {
        meta = format!("{} · {meta}", a.status);
    }
    let meta_label = label(&meta, &["brand-dim", "caption"]);
    meta_label.set_wrap(false);
    meta_label.set_xalign(1.0);
    side.append(&meta_label);
    row.append(&icon);
    row.append(&text);
    row.append(&side);
    if let Some(path) = a.path.clone().filter(|p| p.exists() && a.direction == Direction::Received) {
        let open = icon_button("document-open-symbolic", t("file.open"));
        let folder = icon_button("folder-open-symbolic", t("file.show_in_folder"));
        let (me, p) = (app.clone(), path.clone());
        open.connect_clicked(move |_| me.open_path(&p, false));
        let (me, p) = (app.clone(), path);
        folder.connect_clicked(move |_| me.open_path(&p, true));
        row.append(&open);
        row.append(&folder);
    }
    gtk::ListBoxRow::builder().child(&row).activatable(false).build()
}

pub fn render(app: &Rc<App>) {
    let ui = app.ui.borrow();
    let Some(ui) = ui.as_ref() else { return };
    let h = &ui.home;
    let st = app.state.borrow();

    // Banners: what is waiting for an answer.
    clear(&h.banners);
    if let Some(from) = &st.ringing_from {
        let stop = text_button(t("ring.stop"));
        stop.add_css_class("destructive-action");
        let me = app.clone();
        stop.connect_clicked(move |_| me.stop_ringing());
        h.banners.append(&banner(&tf("ring.title", &[&st.name_of(from)]), true, vec![stop]));
    }
    if let Some((id, name)) = &st.pairing_request {
        let allow = text_button(t("pair.allow"));
        allow.add_css_class("suggested-action");
        let dismiss = text_button(t("common.dismiss"));
        let me = app.clone();
        allow.connect_clicked(move |_| {
            me.state.borrow_mut().pairing_request = None;
            me.core.client.allow_pairing(bridgey_core::client::ALLOW_DEFAULT);
            super::pair::open(&me);
        });
        let me = app.clone();
        dismiss.connect_clicked(move |_| {
            me.state.borrow_mut().pairing_request = None;
            me.queue_render();
        });
        let _ = id;
        h.banners.append(&banner(&tf("pair.request", &[name]), false, vec![dismiss, allow]));
    }
    if let Some((id, url)) = &st.pending_link {
        let open = text_button(t("link.open"));
        open.add_css_class("suggested-action");
        let dismiss = text_button(t("common.dismiss"));
        let (me, u) = (app.clone(), url.clone());
        open.connect_clicked(move |_| {
            me.open_link(&u);
            me.state.borrow_mut().pending_link = None;
            me.queue_render();
        });
        let me = app.clone();
        dismiss.connect_clicked(move |_| {
            me.state.borrow_mut().pending_link = None;
            me.queue_render();
        });
        h.banners.append(&banner(&tf("link.sent", &[&st.name_of(id), url]), false, vec![dismiss, open]));
    }
    match &*app.update.borrow() {
        UpdateStatus::Available(offer) => {
            let install = text_button(t("update.install"));
            install.add_css_class("suggested-action");
            let me = app.clone();
            install.connect_clicked(move |_| super::prefs::confirm_install(&me));
            h.banners.append(&banner(&tf("update.ready", &[&offer.version]), false, vec![install]));
        }
        UpdateStatus::Downloading(got, total) => {
            h.banners.append(&banner(&tf("update.downloading", &[&widgets::size(*got), &widgets::size(*total)]), false, vec![]));
        }
        _ => {}
    }
    h.banners.set_visible(h.banners.first_child().is_some());

    // Devices.
    h.empty.set_visible(st.devices.is_empty());
    let signature = format!("{:?}{}", st.devices, crate::i18n::lang_code());
    let mut shown = h.shown.borrow_mut();
    if *h.drawn.borrow() != signature {
        *h.drawn.borrow_mut() = signature;
        clear(&h.devices);
        for d in &st.devices {
            let card = device_card(app, d);
            if !shown.contains(&d.id) {
                widgets::arrive(&card);
                shown.insert(d.id.clone());
            }
            h.devices.append(&card);
        }
    }
    h.devices.set_visible(!st.devices.is_empty());

    // The send box: only with a device that takes text or links.
    let targets: Vec<&Device> = st.devices.iter().filter(|d| d.ready("clipboard") || d.ready("links")).collect();
    h.send.set_visible(!targets.is_empty());
    let ids: Vec<String> = targets.iter().map(|d| d.id.clone()).collect();
    if *h.target_ids.borrow() != ids {
        let names: Vec<&str> = targets.iter().map(|d| d.name.as_str()).collect();
        h.target.set_model(Some(&gtk::StringList::new(&names)));
        *h.target_ids.borrow_mut() = ids;
    }
    h.target.set_visible(targets.len() > 1);
    let draft = h.entry.text().to_string();
    let target = h.target_ids.borrow().get(h.target.selected() as usize).and_then(|id| st.device(id)).cloned();
    let is_link = bridgey_core::quick::validated_web_link(draft.trim()).is_some() && !draft.trim().contains(char::is_whitespace);
    h.link_button.set_visible(is_link && target.as_ref().is_some_and(|d| d.ready("links")));
    h.send_button.set_sensitive(!draft.is_empty() && target.as_ref().is_some_and(|d| d.ready("clipboard")));

    // Activity.
    widgets::clear_list(&h.activity);
    for a in st.activity.iter().take(50) {
        h.activity.append(&activity_row(app, a));
    }
    h.activity_box.set_visible(!st.activity.is_empty());
    drop(shown);
    let _ = glib::ControlFlow::Continue;
}
