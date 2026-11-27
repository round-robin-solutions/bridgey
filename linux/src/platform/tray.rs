//! The status icon, through the StatusNotifierItem protocol (KDE Plasma, Cinnamon, Xfce, Budgie, waybar and the
//! AppIndicator extension Ubuntu turns on in GNOME). Vanilla GNOME has no host for it: there, Bridgey keeps running in
//! the background and opening it again from the app grid (or Send to Bridgey) brings the window back.

use std::sync::{Arc, Mutex};

use super::{rt, UiMsg, UiTx};
use crate::edition;
use crate::i18n::t;

struct Tray {
    tx: UiTx,
    status: Arc<Mutex<String>>,
    theme_path: String,
    can_send: Arc<Mutex<bool>>,
}

fn token() -> Option<String> {
    ksni::current_xdg_activation_token().or_else(|| {
        std::thread::sleep(std::time::Duration::from_millis(1));
        ksni::current_xdg_activation_token()
    })
}

impl ksni::Tray for Tray {
    fn id(&self) -> String {
        edition::APP_ID.into()
    }

    fn title(&self) -> String {
        edition::DISPLAY_NAME.into()
    }

    fn icon_name(&self) -> String {
        format!("{}-symbolic", edition::APP_ID)
    }

    fn icon_theme_path(&self) -> String {
        self.theme_path.clone()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: edition::SHORT_NAME.into(), description: self.status.lock().unwrap().clone(), ..Default::default() }
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        let _ = self.tx.send_blocking(UiMsg::ShowWindow { token: token() });
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::StandardItem;
        let can_send = *self.can_send.lock().unwrap();
        let item = |label: &str, enabled: bool, msg: fn(Option<String>) -> UiMsg| -> ksni::MenuItem<Self> {
            StandardItem { label: label.replace('_', "__"), enabled, activate: Box::new(move |t: &mut Self| { let _ = t.tx.send_blocking(msg(token())); }), ..Default::default() }.into()
        };
        vec![
            StandardItem { label: self.status.lock().unwrap().clone(), enabled: false, ..Default::default() }.into(),
            ksni::MenuItem::Separator,
            item(t("tray.open"), true, |token| UiMsg::ShowWindow { token }),
            item(t("tray.send_files"), can_send, |_| UiMsg::SendFiles),
            item(t("tray.send_clipboard"), can_send, |_| UiMsg::SendClipboard),
            ksni::MenuItem::Separator,
            item(t("tray.pair"), true, |_| UiMsg::Pair),
            item(t("tray.allow_pairing"), true, |_| UiMsg::AllowPairing),
            item(t("tray.settings"), true, |_| UiMsg::Settings),
            ksni::MenuItem::Separator,
            item(t("tray.quit"), true, |_| UiMsg::Quit),
        ]
    }

    fn watcher_online(&self) {
        let _ = self.tx.send_blocking(UiMsg::TrayAvailable(true));
    }

    fn watcher_offline(&self, _reason: ksni::OfflineReason) -> bool {
        let _ = self.tx.send_blocking(UiMsg::TrayAvailable(false));
        true
    }
}

pub struct TrayIcon {
    handle: Arc<Mutex<Option<ksni::Handle<Tray>>>>,
    status: Arc<Mutex<String>>,
    can_send: Arc<Mutex<bool>>,
}

impl TrayIcon {
    pub fn start(tx: UiTx, icons: String) -> TrayIcon {
        let status = Arc::new(Mutex::new(String::new()));
        let can_send = Arc::new(Mutex::new(false));
        let handle = Arc::new(Mutex::new(None));
        let tray = Tray { tx: tx.clone(), status: status.clone(), theme_path: icons, can_send: can_send.clone() };
        let slot = handle.clone();
        rt().spawn(async move {
            use ksni::TrayMethods;
            // assume_sni_available: a host that starts after Bridgey (Bridgey starts at sign-in) still gets the icon.
            match tray.assume_sni_available(true).spawn().await {
                Ok(h) => *slot.lock().unwrap() = Some(h),
                Err(_) => {
                    let _ = tx.send(UiMsg::TrayAvailable(false)).await;
                }
            }
        });
        TrayIcon { handle, status, can_send }
    }

    pub fn update(&self, status: String, can_send: bool) {
        let changed = {
            let mut s = self.status.lock().unwrap();
            let mut c = self.can_send.lock().unwrap();
            let changed = *s != status || *c != can_send;
            *s = status;
            *c = can_send;
            changed
        };
        if !changed {
            return;
        }
        let handle = self.handle.lock().unwrap().clone();
        if let Some(h) = handle {
            rt().spawn(async move {
                h.update(|_| {}).await;
            });
        }
    }
}
