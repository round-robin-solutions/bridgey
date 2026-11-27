//! Pairing, as on Windows: devices nearby (DNS-SD) or an address typed in, then the same six digits on both screens,
//! confirmed on both. While this dialog is open other devices may pair with this computer too.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;

use super::widgets::{clear, label, text_button};
use crate::app::App;
use crate::i18n::{t, tf};
use crate::state::Pairing;

thread_local! {
    static OPEN: RefCell<Option<(adw::Dialog, gtk::Box, RefCell<String>)>> = const { RefCell::new(None) };
}

/// An address typed in: IPv4, IPv6 (in brackets with a port) or a host name, with an optional port (42458).
pub fn parse_address(text: &str) -> Option<(String, u16)> {
    let text = text.trim();
    if text.is_empty() || text.contains(char::is_whitespace) {
        return None;
    }
    let default = bridgey_core::client::DEFAULT_PORT;
    if let Some(rest) = text.strip_prefix('[') {
        let (host, tail) = rest.split_once(']')?;
        host.parse::<std::net::Ipv6Addr>().ok()?;
        let port = match tail.strip_prefix(':') {
            Some(p) => p.parse().ok().filter(|p| *p > 0)?,
            None if tail.is_empty() => default,
            None => return None,
        };
        return Some((host.to_string(), port));
    }
    if text.parse::<std::net::Ipv6Addr>().is_ok() {
        return Some((text.to_string(), default));
    }
    let (host, port) = match text.rsplit_once(':') {
        Some((h, p)) => (h, p.parse::<u16>().ok().filter(|p| *p > 0)?),
        None => (text, default),
    };
    let valid = !host.is_empty() && host.len() <= 253 && host.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-');
    valid.then(|| (host.to_string(), port))
}

pub fn format_code(code: &str) -> String {
    if code.len() == 6 && code.is_ascii() {
        format!("{} {}", &code[..3], &code[3..])
    } else {
        code.to_string()
    }
}

pub fn open(app: &Rc<App>) {
    if let Some(d) = OPEN.with(|o| o.borrow().as_ref().map(|(d, ..)| d.clone())) {
        d.present(app.window().as_ref());
        return;
    }
    {
        let mut st = app.state.borrow_mut();
        if matches!(st.pairing, Some(Pairing::Done { .. }) | Some(Pairing::Failed { .. })) {
            st.pairing = None;
        }
        st.pairing_request = None;
    }
    app.core.client.allow_pairing(std::time::Duration::from_secs(600));
    app.pairing_open.set(true);
    let content = gtk::Box::builder().orientation(gtk::Orientation::Vertical).spacing(16).margin_top(12).margin_bottom(24).margin_start(24).margin_end(24).build();
    let view = adw::ToolbarView::new();
    view.add_top_bar(&adw::HeaderBar::new());
    let scroll = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).propagate_natural_height(true).child(&content).build();
    view.set_content(Some(&scroll));
    let dialog = adw::Dialog::builder().title(t("pair.title")).content_width(440).follows_content_size(true).child(&view).build();
    let me = app.clone();
    super::widgets::keep_after_close(&dialog);
    dialog.connect_closed(move |_| {
        OPEN.with(|o| o.borrow_mut().take());
        me.pairing_open.set(false);
        me.core.client.allow_pairing(std::time::Duration::ZERO);
        let waiting = match me.state.borrow().pairing {
            Some(Pairing::Waiting { pairing, .. }) => Some(pairing),
            Some(Pairing::Code { pairing, .. }) => Some(pairing),
            _ => None,
        };
        if let Some(id) = waiting {
            let _ = me.core.client.cancel_pairing(id);
        }
        me.state.borrow_mut().pairing = None;
    });
    OPEN.with(|o| *o.borrow_mut() = Some((dialog.clone(), content, RefCell::new(String::new()))));
    render(app);
    dialog.present(app.window().as_ref());
}

pub fn close() {
    if let Some(d) = OPEN.with(|o| o.borrow().as_ref().map(|(d, ..)| d.clone())) {
        d.close();
    }
}

fn choose(app: &Rc<App>, content: &gtk::Box) {
    content.append(&label(t("pair.intro"), &[]));
    let group = adw::PreferencesGroup::builder().title(t("pair.nearby")).build();
    let st = app.state.borrow();
    if st.nearby.is_empty() {
        let row = adw::ActionRow::builder().title(t("pair.looking")).build();
        let spinner = gtk::Spinner::builder().spinning(true).build();
        spinner.update_property(&[gtk::accessible::Property::Label(t("pair.looking"))]);
        row.add_prefix(&spinner);
        group.add(&row);
    }
    for n in &st.nearby {
        let subtitle = match n.platform.as_deref() {
            Some("android") => format!("Android · {}", n.host),
            Some("macos") => format!("Mac · {}", n.host),
            Some("windows") => format!("Windows · {}", n.host),
            Some("linux") => format!("Linux · {}", n.host),
            Some("ios") => format!("iPhone · {}", n.host),
            _ => n.host.clone(),
        };
        let row = adw::ActionRow::builder().title(glib_escape(&n.name)).subtitle(glib_escape(&subtitle)).build();
        let pair = text_button(t("pair.pair"));
        pair.add_css_class("suggested-action");
        pair.update_property(&[gtk::accessible::Property::Label(&tf("pair.pair_with", &[&n.name]))]);
        let (me, id, host, port, name) = (app.clone(), n.device_id.clone(), n.host.clone(), n.port, n.name.clone());
        pair.connect_clicked(move |_| start(&me, id.as_deref(), &host, port, &name));
        row.add_suffix(&pair);
        row.set_activatable_widget(Some(&pair));
        group.add(&row);
    }
    drop(st);
    content.append(&group);

    let manual = adw::PreferencesGroup::builder().title(t("pair.by_address")).description(t("pair.by_address_detail")).build();
    let entry = adw::EntryRow::builder().title(t("pair.address")).show_apply_button(true).build();
    let me = app.clone();
    entry.connect_apply(move |e| {
        match parse_address(&e.text()) {
            Some((host, port)) => start(&me, None, &host, port, &host.clone()),
            None => me.toast(t("pair.bad_address")),
        }
    });
    manual.add(&entry);
    content.append(&manual);
}

fn glib_escape(s: &str) -> String {
    gtk::glib::markup_escape_text(s).to_string()
}

fn start(app: &Rc<App>, id: Option<&str>, host: &str, port: u16, name: &str) {
    match app.core.client.pair(id, Some(host), port) {
        Ok(pairing) => {
            app.state.borrow_mut().pairing = Some(Pairing::Waiting { pairing, name: name.to_string() });
        }
        Err(e) => {
            app.state.borrow_mut().pairing = Some(Pairing::Failed { reason: e.to_string() });
        }
    }
    app.queue_render();
}

pub fn render(app: &Rc<App>) {
    let Some((content, drawn)) = OPEN.with(|o| o.borrow().as_ref().map(|(_, c, d)| (c.clone(), d.borrow().clone()))) else { return };
    let pairing = app.state.borrow().pairing.clone();
    let signature = format!("{:?}{:?}", pairing, app.state.borrow().nearby);
    if signature == drawn {
        return;
    }
    OPEN.with(|o| {
        if let Some((_, _, d)) = o.borrow().as_ref() {
            *d.borrow_mut() = signature;
        }
    });
    clear(&content);
    match pairing {
        None => choose(app, &content),
        Some(Pairing::Waiting { pairing, name }) => {
            let spinner = gtk::Spinner::builder().spinning(true).width_request(32).height_request(32).build();
            spinner.update_property(&[gtk::accessible::Property::Label(t("pair.waiting_label"))]);
            content.append(&spinner);
            let heading = label(&tf("pair.waiting", &[&name]), &["brand-heading"]);
            heading.set_xalign(0.5);
            heading.set_justify(gtk::Justification::Center);
            content.append(&heading);
            let body = label(&tf("pair.waiting_detail", &[&name]), &["brand-dim"]);
            body.set_xalign(0.5);
            body.set_justify(gtk::Justification::Center);
            content.append(&body);
            let cancel = text_button(t("common.cancel"));
            cancel.set_halign(gtk::Align::Center);
            let me = app.clone();
            cancel.connect_clicked(move |_| {
                let _ = me.core.client.cancel_pairing(pairing);
                me.state.borrow_mut().pairing = None;
                me.queue_render();
            });
            content.append(&cancel);
        }
        Some(Pairing::Code { pairing, name, code, .. }) => {
            let heading = label(&tf("pair.compare", &[&name]), &["brand-heading"]);
            heading.set_xalign(0.5);
            heading.set_justify(gtk::Justification::Center);
            content.append(&heading);
            let shown = format_code(&code);
            let code_label = gtk::Label::builder().label(&shown).selectable(true).build();
            code_label.add_css_class("code");
            code_label.update_property(&[gtk::accessible::Property::Label(&tf("pair.code_label", &[&code.chars().map(|c| c.to_string()).collect::<Vec<_>>().join(" ")]))]);
            content.append(&code_label);
            let buttons = gtk::Box::builder().spacing(12).halign(gtk::Align::Center).homogeneous(true).build();
            let no = text_button(t("pair.no_match"));
            let yes = text_button(t("pair.match"));
            yes.add_css_class("suggested-action");
            let me = app.clone();
            yes.connect_clicked(move |_| {
                let _ = me.core.client.confirm_pairing(pairing, true);
            });
            let me = app.clone();
            no.connect_clicked(move |_| {
                let _ = me.core.client.confirm_pairing(pairing, false);
            });
            buttons.append(&no);
            buttons.append(&yes);
            content.append(&buttons);
            let y = yes.clone();
            gtk::glib::idle_add_local_once(move || {
                y.grab_focus();
            });
        }
        Some(Pairing::Done { name }) => {
            let icon = gtk::Image::builder().icon_name("emblem-ok-symbolic").pixel_size(48).build();
            icon.add_css_class("success");
            icon.set_accessible_role(gtk::AccessibleRole::Presentation);
            content.append(&icon);
            let heading = label(&tf("pair.done", &[&name]), &["brand-heading"]);
            heading.set_xalign(0.5);
            heading.set_justify(gtk::Justification::Center);
            content.append(&heading);
            let close_button = text_button(t("common.done"));
            close_button.add_css_class("suggested-action");
            close_button.set_halign(gtk::Align::Center);
            close_button.connect_clicked(|_| close());
            content.append(&close_button);
        }
        Some(Pairing::Failed { reason }) => {
            let heading = label(t("pair.failed"), &["brand-heading"]);
            heading.set_xalign(0.5);
            content.append(&heading);
            let body = label(&reason, &[]);
            body.set_xalign(0.5);
            body.set_justify(gtk::Justification::Center);
            content.append(&body);
            let again = text_button(t("pair.try_again"));
            again.add_css_class("suggested-action");
            again.set_halign(gtk::Align::Center);
            let me = app.clone();
            again.connect_clicked(move |_| {
                me.state.borrow_mut().pairing = None;
                me.queue_render();
            });
            content.append(&again);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_parse_like_windows() {
        assert_eq!(parse_address("192.168.1.20"), Some(("192.168.1.20".into(), 42458)));
        assert_eq!(parse_address(" 192.168.1.20:42470 "), Some(("192.168.1.20".into(), 42470)));
        assert_eq!(parse_address("[fd7a::1]:5000"), Some(("fd7a::1".into(), 5000)));
        assert_eq!(parse_address("fd7a::1"), Some(("fd7a::1".into(), 42458)));
        assert_eq!(parse_address("work-laptop"), Some(("work-laptop".into(), 42458)));
        assert_eq!(parse_address("a b"), None);
        assert_eq!(parse_address("host:0"), None);
        assert_eq!(parse_address("host:99999"), None);
        assert_eq!(parse_address(""), None);
        assert_eq!(format_code("744419"), "744 419");
    }
}
