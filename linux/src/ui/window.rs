//! The main window: Home (devices, the send box and activity) and Notifications (the phone's), switched in the header,
//! or at the bottom when the window is narrow. Settings, pairing and About are dialogs on top.

use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};

use super::{home, notices, pair, prefs, widgets};
use crate::app::App;
use crate::edition;
use crate::i18n::{t, tf};

pub struct Ui {
    pub window: adw::ApplicationWindow,
    pub toasts: adw::ToastOverlay,
    pub stack: adw::ViewStack,
    pub notices_page: adw::ViewStackPage,
    pub home: home::Home,
    pub notices: notices::Notices,
}

fn action(app: &Rc<App>, name: &str, accels: &[&str], f: impl Fn(&Rc<App>) + 'static) {
    let a = gio::SimpleAction::new(name, None);
    let me = app.clone();
    a.connect_activate(move |_, _| f(&me));
    app.gtk.add_action(&a);
    if !accels.is_empty() {
        app.gtk.set_accels_for_action(&format!("app.{name}"), accels);
    }
}

pub fn build(app: &Rc<App>) -> Ui {
    action(app, "pair", &["<Control>n"], pair::open);
    action(app, "settings", &["<Control>comma"], |a| prefs::open(a, None));
    action(app, "send-files", &["<Control>o"], |a| a.choose_and_send(None));
    action(app, "send-clipboard", &["<Control><Shift>v"], |a| a.send_copied(None));
    action(app, "allow-pairing", &[], |a| {
        a.core.client.allow_pairing(bridgey_core::client::ALLOW_DEFAULT);
        a.toast(t("pair.allowed_body"));
    });
    action(app, "about", &[], about);
    action(app, "quit", &["<Control>q"], |a| a.quit());
    action(app, "close-window", &["<Control>w"], |a| {
        if let Some(w) = a.window() {
            w.close();
        }
    });

    let window = adw::ApplicationWindow::builder().application(&app.gtk).title(edition::SHORT_NAME).default_width(760).default_height(720).width_request(360).height_request(420).build();
    window.set_icon_name(Some(edition::APP_ID));

    let stack = adw::ViewStack::new();
    let home = home::build(app);
    let notices = notices::build(app);
    stack.add_titled_with_icon(&home.root, Some("home"), t("nav.home"), "go-home-symbolic");
    let notices_page = stack.add_titled_with_icon(&notices.root, Some("notifications"), t("nav.notifications"), "preferences-system-notifications-symbolic");

    let header = adw::HeaderBar::new();
    let switcher = adw::ViewSwitcher::builder().stack(&stack).policy(adw::ViewSwitcherPolicy::Wide).build();
    header.set_title_widget(Some(&switcher));
    let pair_button = widgets::icon_button("list-add-symbolic", t("pair.title"));
    pair_button.set_action_name(Some("app.pair"));
    header.pack_start(&pair_button);

    let menu = gio::Menu::new();
    let main = gio::Menu::new();
    main.append(Some(t("menu.send_files")), Some("app.send-files"));
    main.append(Some(t("menu.send_clipboard")), Some("app.send-clipboard"));
    main.append(Some(t("menu.allow_pairing")), Some("app.allow-pairing"));
    menu.append_section(None, &main);
    let more = gio::Menu::new();
    more.append(Some(t("menu.settings")), Some("app.settings"));
    more.append(Some(t("menu.about")), Some("app.about"));
    more.append(Some(t("menu.quit")), Some("app.quit"));
    menu.append_section(None, &more);
    let menu_button = gtk::MenuButton::builder().icon_name("open-menu-symbolic").menu_model(&menu).primary(true).tooltip_text(t("menu.main")).build();
    menu_button.update_property(&[gtk::accessible::Property::Label(t("menu.main"))]);
    header.pack_end(&menu_button);

    let toasts = adw::ToastOverlay::new();
    toasts.set_child(Some(&stack));
    let bar = adw::ViewSwitcherBar::builder().stack(&stack).build();
    let view = adw::ToolbarView::new();
    view.add_top_bar(&header);
    view.set_content(Some(&toasts));
    view.add_bottom_bar(&bar);
    window.set_content(Some(&view));

    // Narrow windows: the switcher moves to the bottom. (Not an AdwBreakpoint: libadwaita 1.5.0, the AppImage's floor,
    // can crash in a breakpoint transition while a dialog is open; this follows the window's width instead.)
    let narrow = {
        let (bar, switcher) = (bar.clone(), switcher.clone());
        move |w: &adw::ApplicationWindow| {
            let width = if w.is_maximized() || w.is_fullscreen() { w.width() } else { w.default_width() };
            let narrow = width < 560;
            bar.set_reveal(narrow);
            switcher.set_visible(!narrow);
        }
    };
    let n = narrow.clone();
    window.connect_default_width_notify(move |w| {
        let (w, n) = (w.clone(), n.clone());
        glib::idle_add_local_once(move || n(&w));
    });
    let n = narrow.clone();
    window.connect_maximized_notify(move |w| {
        let (w, n) = (w.clone(), n.clone());
        glib::timeout_add_local_once(std::time::Duration::from_millis(100), move || n(&w));
    });
    narrow(&window);

    // Files dropped anywhere on the window go to the only connected device (or the person picks one).
    let drop = gtk::DropTarget::new(gtk::gdk::FileList::static_type(), gtk::gdk::DragAction::COPY);
    let me = app.clone();
    drop.connect_drop(move |_, value, _, _| {
        let Ok(list) = value.get::<gtk::gdk::FileList>() else { return false };
        let files: Vec<_> = list.files().iter().filter_map(|f| f.path()).collect();
        me.send_from_shell(files);
        true
    });
    window.add_controller(drop);

    let me = app.clone();
    window.connect_is_active_notify(move |w| {
        if w.is_active() {
            me.window_active();
            // A copy made elsewhere while Bridgey was in the background is seen now (GNOME on Wayland).
            if me.clip_mode.get() == crate::platform::clipboard::Mode::Foreground {
                me.read_gtk_clipboard(false);
            }
        }
    });
    let me = app.clone();
    window.connect_close_request(move |w| {
        if me.settings.borrow().keep_running {
            w.set_visible(false);
            glib::Propagation::Stop
        } else {
            me.quit();
            glib::Propagation::Proceed
        }
    });

    Ui { window, toasts, stack, notices_page, home, notices }
}

pub fn show_page(app: &Rc<App>, name: &str) {
    if let Some(u) = app.ui.borrow().as_ref() {
        u.stack.set_visible_child_name(name);
    }
}

pub fn render(app: &Rc<App>) {
    let Some(ui) = app.ui.borrow().as_ref().map(|u| (u.notices_page.clone(), u.window.clone())) else { return };
    home::render(app);
    notices::render(app);
    pair::render(app);
    prefs::render(app);
    let count = app.state.borrow().notifications.len() as u32;
    ui.0.set_badge_number(count);
    ui.1.set_title(Some(&format!("{} · {}", edition::SHORT_NAME, app.state.borrow().status_text())));
}

fn about(app: &Rc<App>) {
    let about = adw::AboutDialog::builder()
        .application_name(edition::DISPLAY_NAME)
        .application_icon(edition::APP_ID)
        .developer_name("Round Robin")
        .version(edition::VERSION_NAME)
        .website(format!("https://github.com/{}", edition::REPOSITORY))
        .issue_url(format!("https://github.com/{}/issues", edition::REPOSITORY))
        .license_type(gtk::License::MitX11)
        .comments(tf("about.comments", &[edition::UPSTREAM_BASE]))
        .build();
    widgets::keep_after_close(&about);
    about.add_credit_section(Some(t("about.upstream")), &["Semyon Mikhailov https://github.com/singeol/bridgey"]);
    about.present(app.window().as_ref());
}
