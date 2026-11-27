//! Notifications: the phone's notifications, newest first, each with the phone's own buttons, a reply box where the
//! phone allows one, Copy code and Dismiss.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;

use super::widgets::{self, icon_button, label, text_button};
use crate::app::App;
use crate::i18n::{t, tf};
use crate::state::PhoneNotice;

pub struct Notices {
    pub root: gtk::Stack,
    list: gtk::Box,
    drawn: RefCell<String>,
}

pub fn build(app: &Rc<App>) -> Notices {
    let empty = adw::StatusPage::builder().icon_name("preferences-system-notifications-symbolic").title(t("notices.empty.title")).description(t("notices.empty.body")).build();
    let list = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(10).build();
    list.update_property(&[gtk::accessible::Property::Label(t("nav.notifications"))]);
    let head = gtk::Box::builder().spacing(6).build();
    let clear = text_button(t("notices.clear"));
    clear.add_css_class("flat");
    clear.set_halign(gtk::Align::End);
    clear.set_hexpand(true);
    head.append(&clear);
    let column = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(10).margin_top(12).margin_bottom(24).margin_start(12).margin_end(12).build();
    column.append(&head);
    column.append(&list);
    let clamp = adw::Clamp::builder().maximum_size(760).child(&column).build();
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).child(&clamp).build();
    let root = gtk::Stack::builder().transition_type(gtk::StackTransitionType::Crossfade).build();
    root.add_named(&empty, Some("empty"));
    root.add_named(&scroll, Some("list"));
    let me = app.clone();
    clear.connect_clicked(move |_| {
        me.state.borrow_mut().notifications.clear();
        if me.settings.borrow().notification_history {
            crate::history::clear();
        }
        me.queue_render();
    });
    Notices { root, list, drawn: RefCell::new(String::new()) }
}

fn card(app: &Rc<App>, n: &PhoneNotice, replying: Option<usize>) -> gtk::Box {
    let card = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(6).build();
    card.add_css_class("card");
    card.add_css_class("notice-card");
    card.set_accessible_role(gtk::AccessibleRole::Group);
    let app_name = if n.n.application_name.is_empty() { n.n.package_name.clone() } else { n.n.application_name.clone() };
    card.update_property(&[gtk::accessible::Property::Label(&format!("{app_name}: {} {}", n.n.title, n.n.text))]);

    let head = gtk::Box::builder().spacing(8).build();
    let source = label(&format!("{app_name} · {}", n.device_name), &["brand-dim", "caption"]);
    source.set_hexpand(true);
    head.append(&source);
    let when = label(&widgets::time(n.received_ms), &["brand-dim", "caption"]);
    when.set_wrap(false);
    head.append(&when);
    let dismiss = icon_button("window-close-symbolic", t("notice.dismiss"));
    let (me, key) = (app.clone(), n.key());
    dismiss.connect_clicked(move |_| me.notice_action(&key, "dismiss", None));
    head.append(&dismiss);
    card.append(&head);
    if !n.n.title.is_empty() {
        card.append(&label(&n.n.title, &["heading"]));
    }
    if !n.n.text.is_empty() {
        let body = label(&n.n.text, &[]);
        body.set_selectable(true);
        card.append(&body);
    }

    let buttons = gtk::FlowBox::builder().selection_mode(gtk::SelectionMode::None).column_spacing(6).row_spacing(6).max_children_per_line(4).build();
    if let Some(code) = &n.n.code {
        let b = text_button(&tf("notice.copy_code", &[&code.code]));
        b.add_css_class("suggested-action");
        let (me, key) = (app.clone(), n.key());
        b.connect_clicked(move |_| me.notice_action(&key, "copy", None));
        buttons.append(&b);
    }
    for (i, a) in n.n.actions.iter().enumerate() {
        let b = text_button(&a.title);
        let (me, key, reply) = (app.clone(), n.key(), a.allows_reply);
        b.connect_clicked(move |_| {
            if reply {
                *me.reply_to.borrow_mut() = Some((key.clone(), i));
                me.queue_render();
            } else {
                me.notice_action(&key, &format!("a{i}"), None);
            }
        });
        buttons.append(&b);
    }
    if buttons.first_child().is_some() {
        card.append(&buttons);
    }

    if let Some(i) = replying {
        let row = gtk::Box::builder().spacing(6).build();
        let entry = gtk::Entry::builder().placeholder_text(t("notice.reply_placeholder")).hexpand(true).build();
        entry.update_property(&[gtk::accessible::Property::Label(&tf("notice.reply_to", &[&n.n.title]))]);
        let send = text_button(t("notice.send_reply"));
        send.add_css_class("suggested-action");
        let cancel = icon_button("window-close-symbolic", t("common.cancel"));
        let go = {
            let (me, key, entry) = (app.clone(), n.key(), entry.clone());
            move || {
                let text = entry.text().to_string();
                if !text.trim().is_empty() {
                    me.reply(&key, i, &text);
                }
            }
        };
        let go2 = go.clone();
        send.connect_clicked(move |_| go());
        entry.connect_activate(move |_| go2());
        let me = app.clone();
        cancel.connect_clicked(move |_| {
            me.reply_to.borrow_mut().take();
            me.queue_render();
        });
        row.append(&entry);
        row.append(&send);
        row.append(&cancel);
        card.append(&row);
        let e = entry.clone();
        gtk::glib::idle_add_local_once(move || {
            e.grab_focus();
        });
    }
    card
}

pub fn render(app: &Rc<App>) {
    let ui = app.ui.borrow();
    let Some(ui) = ui.as_ref() else { return };
    let page = &ui.notices;
    let st = app.state.borrow();
    let replying = app.reply_to.borrow().clone();
    let signature = format!("{:?}{:?}{}", st.notifications.iter().map(|n| (&n.device_id, &n.n.notification_id, &n.n.title, &n.n.text, n.received_ms)).collect::<Vec<_>>(), replying, crate::i18n::lang_code());
    if *page.drawn.borrow() == signature {
        return;
    }
    *page.drawn.borrow_mut() = signature;
    widgets::clear(&page.list);
    for n in st.notifications.iter() {
        let reply = replying.as_ref().filter(|(k, _)| *k == n.key()).map(|(_, i)| *i);
        page.list.append(&card(app, n, reply));
    }
    page.root.set_visible_child_name(if st.notifications.is_empty() { "empty" } else { "list" });
}
