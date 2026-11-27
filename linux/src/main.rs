//! Bridgey by Round Robin for Linux: GTK4 and libadwaita on the shared Rust session client (rust/client), linked as a
//! crate. See linux/README.md.

mod app;
mod cli;
mod control;
mod core;
mod history;
mod i18n;
mod paths;
mod platform;
mod settings;
mod state;
mod ui;
mod update;

pub mod edition {
    include!(concat!(env!("OUT_DIR"), "/edition.rs"));
}

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};

/// The D-Bus name GApplication keeps one instance under. A test profile (BRIDGEY_DATA_DIR) runs as its own instance.
fn application_id() -> String {
    match paths::separate_profile() {
        None => edition::APP_ID.to_string(),
        Some(dir) => {
            use std::hash::{Hash, Hasher};
            let mut h = std::collections::hash_map::DefaultHasher::new();
            dir.hash(&mut h);
            format!("{}.Test{:08x}", edition::APP_ID, h.finish() as u32)
        }
    }
}

/// Bridgey could not start its session (most often another Bridgey already listens on 42458): say so in a window.
fn startup_error(gapp: &adw::Application, error: &str) {
    let page = adw::StatusPage::builder().icon_name("dialog-warning-symbolic").title(i18n::t("error.start")).description(glib::markup_escape_text(&i18n::tf("error.start_detail", &[error]))).build();
    let view = adw::ToolbarView::new();
    view.add_top_bar(&adw::HeaderBar::new());
    view.set_content(Some(&page));
    let w = adw::ApplicationWindow::builder().application(gapp).title(edition::SHORT_NAME).default_width(480).default_height(360).content(&view).build();
    w.present();
}

fn main() -> glib::ExitCode {
    i18n::init();
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version") {
        println!("{} {} (build {})", edition::DISPLAY_NAME, edition::VERSION_NAME, edition::BUILD_NUMBER);
        return glib::ExitCode::SUCCESS;
    }
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("{}", cli::HELP);
        return glib::ExitCode::SUCCESS;
    }
    if let Some(flag) = cli::parse(&args[1..], None).unknown {
        eprintln!("bridgey-linux: unknown option {flag}\n{}", cli::HELP);
        return glib::ExitCode::from(2);
    }
    glib::set_application_name(edition::DISPLAY_NAME);
    glib::set_prgname(Some(edition::APP_ID));

    let gapp = adw::Application::builder().application_id(application_id()).flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE).build();
    let running: Rc<RefCell<Option<app::AppRc>>> = Rc::default();
    let failed = Rc::new(std::cell::Cell::new(false));

    let slot = running.clone();
    gapp.connect_command_line(move |gapp, cmd| {
        let args: Vec<String> = cmd.arguments().iter().skip(1).map(|a| a.to_string_lossy().to_string()).collect();
        let parsed = cli::parse(&args, cmd.cwd().as_deref());
        if failed.get() {
            return glib::ExitCode::FAILURE;
        }
        let first = slot.borrow().is_none();
        if first {
            if parsed.quit {
                return glib::ExitCode::SUCCESS;
            }
            let store = settings::SettingsStore::new(&paths::data_dir());
            let s = store.load();
            match core::Core::start(&s) {
                Ok(core) => {
                    let (etx, erx) = async_channel::unbounded();
                    let (mtx, mrx) = async_channel::unbounded();
                    core.pump(etx);
                    let a = app::App::new(gapp, core, store, s, mtx);
                    a.start(erx, mrx);
                    *slot.borrow_mut() = Some(a);
                }
                Err(e) => {
                    failed.set(true);
                    startup_error(gapp, &e);
                    return glib::ExitCode::FAILURE;
                }
            }
        }
        let a = slot.borrow().clone().expect("started");
        if parsed.quit {
            a.quit();
            return glib::ExitCode::SUCCESS;
        }
        // Send to Bridgey and the sign-in start work without the window; anything else brings it forward.
        let show = (parsed.send.is_empty() && !(first && parsed.background)) || (first && !a.settings.borrow().setup_done);
        if show {
            a.present(cmd.platform_data().and_then(|d| glib::VariantDict::new(Some(&d)).lookup_value("activation-token", None)).and_then(|v| v.str().map(str::to_string)).as_deref());
            if first && !a.settings.borrow().setup_done {
                a.update_settings(|s| s.setup_done = true);
            }
        }
        if parsed.pair {
            a.present(None);
            ui::pair::open(&a);
        }
        if parsed.settings {
            a.present(None);
            ui::prefs::open(&a, None);
        }
        if parsed.send_dialog {
            a.present(None);
            a.choose_and_send(None);
        }
        if !parsed.send.is_empty() {
            a.send_from_shell(parsed.send.clone());
        }
        glib::ExitCode::SUCCESS
    });
    let code = gapp.run();
    let restart = running.borrow().as_ref().and_then(|a| a.restart.borrow().clone());
    drop(running);
    if let Some(path) = restart {
        if std::env::var("BRIDGEY_UPDATE_NO_RELAUNCH").as_deref() != Ok("1") {
            use std::os::unix::process::CommandExt;
            let err = std::process::Command::new(&path).arg("--show").exec();
            eprintln!("bridgey: could not restart from {}: {err}", path.display());
        }
    }
    code
}
