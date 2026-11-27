//! Desktop notifications through org.freedesktop.Notifications, the service GNOME Shell, KDE Plasma, Xfce, Cinnamon
//! and the tiling desktops' daemons (mako, dunst, swaync) all provide.
//!
//! - Buttons: the phone's own actions, Reply and Dismiss, Copy code. GNOME shows at most three buttons, so the phone's
//!   actions come first and the rest is one click away in Bridgey.
//! - Reply: KDE Plasma types the reply in the banner (its `inline-reply` capability); elsewhere Reply opens the
//!   notification in Bridgey with the reply box ready.
//! - Clicking a banner raises Bridgey with the activation token the server sends (needed to take focus on Wayland).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use zbus::zvariant::Value;

use super::{rt, NoticeKey, UiMsg, UiTx};
use crate::edition;
use crate::i18n::{t, tf};
use crate::state::PhoneNotice;

#[zbus::proxy(interface = "org.freedesktop.Notifications", default_service = "org.freedesktop.Notifications", default_path = "/org/freedesktop/Notifications")]
trait Notifications {
    #[allow(clippy::too_many_arguments)]
    fn notify(&self, app_name: &str, replaces_id: u32, app_icon: &str, summary: &str, body: &str, actions: &[&str], hints: HashMap<&str, Value<'_>>, expire_timeout: i32) -> zbus::Result<u32>;
    fn close_notification(&self, id: u32) -> zbus::Result<()>;
    fn get_capabilities(&self) -> zbus::Result<Vec<String>>;
    #[zbus(signal)]
    fn action_invoked(&self, id: u32, action_key: String) -> zbus::Result<()>;
    #[zbus(signal)]
    fn notification_closed(&self, id: u32, reason: u32) -> zbus::Result<()>;
    #[zbus(signal)]
    fn notification_replied(&self, id: u32, text: String) -> zbus::Result<()>;
    #[zbus(signal)]
    fn activation_token(&self, id: u32, activation_token: String) -> zbus::Result<()>;
}

#[derive(Clone, Debug, PartialEq)]
enum Kind {
    Phone { key: NoticeKey, reply_action: Option<usize> },
    Ring,
    File { path: String },
    Clipboard,
    Plain,
}

#[derive(Default)]
struct Book {
    kinds: HashMap<u32, Kind>,
    tokens: HashMap<u32, String>,
    phone: HashMap<NoticeKey, u32>,
    ring: Option<u32>,
    clipboard: Option<u32>,
}

#[derive(Clone)]
pub struct Notifier {
    proxy: Arc<tokio::sync::OnceCell<Option<NotificationsProxy<'static>>>>,
    caps: Arc<Mutex<Vec<String>>>,
    book: Arc<Mutex<Book>>,
    tx: UiTx,
}

/// One button: its key and label.
pub type Button = (String, String);

/// The buttons a phone notification's banner gets, at most three: the phone's actions (a reply action becomes the
/// inline reply on servers that have it), then Copy code, then Dismiss.
pub fn phone_buttons(notice: &PhoneNotice, inline_reply: bool) -> (Vec<Button>, Option<usize>) {
    let mut buttons: Vec<Button> = Vec::new();
    let mut reply = None;
    if let Some(code) = &notice.n.code {
        buttons.push(("copy".into(), tf("notice.copy_code", &[&code.code])));
    }
    for (i, a) in notice.n.actions.iter().enumerate() {
        if a.allows_reply {
            if inline_reply && reply.is_none() {
                reply = Some(i);
                continue;
            }
            buttons.push((format!("reply{i}"), a.title.clone()));
        } else {
            buttons.push((format!("a{i}"), a.title.clone()));
        }
    }
    if notice.n.call_type.is_none() {
        buttons.push(("dismiss".into(), t("notice.dismiss").into()));
    }
    buttons.truncate(3);
    (buttons, reply)
}

/// Body text for servers that read markup: the spec's subset, so &, < and > are escaped.
pub fn escape(text: &str, markup: bool) -> String {
    if !markup {
        return text.to_string();
    }
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

impl Notifier {
    pub fn new(tx: UiTx) -> Notifier {
        let n = Notifier { proxy: Arc::new(tokio::sync::OnceCell::new()), caps: Arc::default(), book: Arc::default(), tx };
        let me = n.clone();
        rt().spawn(async move {
            me.connection().await;
        });
        n
    }

    async fn connection(&self) -> Option<NotificationsProxy<'static>> {
        let me = self.clone();
        self.proxy
            .get_or_init(|| async move {
                let conn = zbus::Connection::session().await.ok()?;
                let proxy = NotificationsProxy::new(&conn).await.ok()?;
                if let Ok(caps) = proxy.get_capabilities().await {
                    *me.caps.lock().unwrap() = caps;
                }
                me.listen(proxy.clone()).await;
                Some(proxy)
            })
            .await
            .clone()
    }

    async fn listen(&self, proxy: NotificationsProxy<'static>) {
        use futures_util::StreamExt;
        let (Ok(mut actions), Ok(mut replies), Ok(mut tokens), Ok(mut closed)) =
            (proxy.receive_action_invoked().await, proxy.receive_notification_replied().await, proxy.receive_activation_token().await, proxy.receive_notification_closed().await)
        else {
            return;
        };
        let me = self.clone();
        rt().spawn(async move {
            while let Some(signal) = tokens.next().await {
                if let Ok(args) = signal.args() {
                    me.book.lock().unwrap().tokens.insert(args.id, args.activation_token.clone());
                }
            }
        });
        let me = self.clone();
        rt().spawn(async move {
            while let Some(signal) = actions.next().await {
                let Ok(args) = signal.args() else { continue };
                // The token, when the server sends one, comes just before the action.
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                me.action(args.id, &args.action_key);
            }
        });
        let me = self.clone();
        rt().spawn(async move {
            while let Some(signal) = replies.next().await {
                let Ok(args) = signal.args() else { continue };
                let kind = me.book.lock().unwrap().kinds.get(&args.id).cloned();
                if let Some(Kind::Phone { key, reply_action: Some(i) }) = kind {
                    let _ = me.tx.send(UiMsg::NoticeReply { key, action: i, text: args.text.clone() }).await;
                }
            }
        });
        let me = self.clone();
        rt().spawn(async move {
            while let Some(signal) = closed.next().await {
                let Ok(args) = signal.args() else { continue };
                me.forget(args.id);
            }
        });
    }

    fn forget(&self, id: u32) {
        let mut book = self.book.lock().unwrap();
        if let Some(kind) = book.kinds.remove(&id) {
            match kind {
                Kind::Phone { key, .. } => {
                    if book.phone.get(&key) == Some(&id) {
                        book.phone.remove(&key);
                    }
                }
                Kind::Ring => book.ring = None,
                Kind::Clipboard => book.clipboard = None,
                _ => {}
            }
        }
        book.tokens.remove(&id);
    }

    fn action(&self, id: u32, key: &str) {
        let (kind, token) = {
            let book = self.book.lock().unwrap();
            (book.kinds.get(&id).cloned(), book.tokens.get(&id).cloned())
        };
        let msg = match (kind, key) {
            (Some(Kind::Phone { key: notice, .. }), action) => UiMsg::NoticeAction { key: notice, action: action.to_string(), token },
            (Some(Kind::Ring), _) => UiMsg::StopRinging,
            (Some(Kind::File { path }), "folder") => UiMsg::OpenPath { path, folder: true },
            (Some(Kind::File { path }), _) => UiMsg::OpenPath { path, folder: false },
            (Some(Kind::Clipboard), _) => UiMsg::ApplyClipboard { token },
            _ => UiMsg::ShowWindow { token },
        };
        let _ = self.tx.send_blocking(msg);
    }

    pub fn has(&self, cap: &str) -> bool {
        self.caps.lock().unwrap().iter().any(|c| c == cap)
    }

    #[allow(clippy::too_many_arguments)]
    fn send(&self, kind: Kind, replaces: u32, summary: String, body: String, buttons: Vec<Button>, mut hints: HashMap<&'static str, Value<'static>>, icon: Option<PathBuf>, timeout: i32) {
        let me = self.clone();
        rt().spawn(async move {
            let Some(proxy) = me.connection().await else { return };
            let markup = me.has("body-markup");
            hints.insert("desktop-entry", Value::from(edition::APP_ID));
            if let Some(path) = icon.as_ref().and_then(|p| p.to_str()) {
                hints.insert("image-path", Value::from(format!("file://{path}")));
            }
            let mut actions: Vec<String> = vec!["default".into(), String::new()];
            for (k, label) in &buttons {
                actions.push(k.clone());
                actions.push(label.clone());
            }
            let refs: Vec<&str> = actions.iter().map(String::as_str).collect();
            let body = escape(&body, markup);
            if let Ok(id) = proxy.notify(edition::SHORT_NAME, replaces, edition::APP_ID, &summary, &body, &refs, hints, timeout).await {
                let mut book = me.book.lock().unwrap();
                match &kind {
                    Kind::Phone { key, .. } => {
                        book.phone.insert(key.clone(), id);
                    }
                    Kind::Ring => book.ring = Some(id),
                    Kind::Clipboard => book.clipboard = Some(id),
                    _ => {}
                }
                book.kinds.insert(id, kind);
            }
        });
    }

    fn close(&self, id: u32) {
        let me = self.clone();
        rt().spawn(async move {
            if let Some(proxy) = me.connection().await {
                let _ = proxy.close_notification(id).await;
            }
            me.forget(id);
        });
    }

    /// A phone notification as a banner.
    pub fn phone(&self, notice: &PhoneNotice, icon: Option<PathBuf>) {
        let key = notice.key();
        let inline = self.has("inline-reply");
        let (buttons, reply) = phone_buttons(notice, inline);
        let mut hints: HashMap<&'static str, Value<'static>> = HashMap::new();
        hints.insert("x-kde-origin-name", Value::from(notice.device_name.clone()));
        if reply.is_some() {
            hints.insert("x-kde-reply-placeholder-text", Value::from(t("notice.reply_placeholder").to_string()));
        }
        let call = notice.n.call_type.as_deref() == Some("incoming");
        hints.insert("urgency", Value::from(if call { 2u8 } else { 1u8 }));
        if call {
            hints.insert("category", Value::from("call.incoming"));
        } else {
            hints.insert("category", Value::from("im.received"));
        }
        let app = notice.n.application_name.trim();
        let summary = match (app.is_empty(), notice.n.title.trim().is_empty()) {
            (false, false) => format!("{app}: {}", notice.n.title.trim()),
            (false, true) => app.to_string(),
            _ => notice.n.title.trim().to_string(),
        };
        let mut buttons = buttons;
        if let Some(i) = reply {
            buttons.insert(0, ("inline-reply".into(), notice.n.actions[i].title.clone()));
        }
        let replaces = self.book.lock().unwrap().phone.get(&key).copied().unwrap_or(0);
        self.send(Kind::Phone { key, reply_action: reply }, replaces, summary, notice.n.text.clone(), buttons, hints, icon, -1);
    }

    pub fn remove_phone(&self, key: &NoticeKey) {
        let id = self.book.lock().unwrap().phone.get(key).copied();
        if let Some(id) = id {
            self.close(id);
        }
    }

    /// Another device is ringing this computer: a banner with Stop that stays until stopped.
    pub fn ring(&self, from: &str) {
        let mut hints: HashMap<&'static str, Value<'static>> = HashMap::new();
        hints.insert("urgency", Value::from(2u8));
        hints.insert("resident", Value::from(true));
        self.send(Kind::Ring, 0, tf("ring.title", &[from]), String::new(), vec![("stop".into(), t("ring.stop").into())], hints, None, 0);
    }

    pub fn stop_ring(&self) {
        let id = self.book.lock().unwrap().ring.take();
        if let Some(id) = id {
            self.close(id);
        }
    }

    pub fn file(&self, name: &str, from: &str, path: &Path) {
        let path = path.to_string_lossy().to_string();
        let buttons = vec![("open".into(), t("file.open").into()), ("folder".into(), t("file.show_in_folder").into())];
        let mut hints: HashMap<&'static str, Value<'static>> = HashMap::new();
        hints.insert("category", Value::from("transfer.complete"));
        self.send(Kind::File { path }, 0, tf("file.received_from", &[from]), name.to_string(), buttons, hints, None, -1);
    }

    /// Text from a device waits for one click, where the desktop does not let a background app set the clipboard.
    pub fn clipboard_waiting(&self, from: &str, preview: &str) {
        let replaces = self.book.lock().unwrap().clipboard.unwrap_or(0);
        let buttons = vec![("paste".into(), t("clipboard.copy_here").into())];
        self.send(Kind::Clipboard, replaces, tf("clipboard.waiting", &[from]), preview.to_string(), buttons, HashMap::new(), None, -1);
    }

    pub fn clipboard_done(&self) {
        let id = self.book.lock().unwrap().clipboard.take();
        if let Some(id) = id {
            self.close(id);
        }
    }

    pub fn plain(&self, summary: &str, body: &str) {
        self.send(Kind::Plain, 0, summary.to_string(), body.to_string(), vec![], HashMap::new(), None, -1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn notice(actions: serde_json::Value, call: Option<&str>) -> PhoneNotice {
        let mut payload = json!({"notificationId": "n1", "packageName": "com.chat", "applicationName": "Chat", "title": "Ana", "text": "Hi <b>", "timestamp": 1, "actions": actions});
        if let Some(c) = call {
            payload["callType"] = json!(c);
        }
        let n = bridgey_core::notifications::decode_post(payload.to_string().as_bytes(), false).unwrap();
        PhoneNotice { device_id: "p1".into(), device_name: "Pixel".into(), n, received_ms: 0 }
    }

    #[test]
    fn buttons_put_the_phones_actions_first_and_stop_at_three() {
        let token = "a".repeat(64);
        let n = notice(json!([{"actionToken": token, "title": "Reply", "allowsReply": true}, {"actionToken": "b".repeat(64), "title": "Mark as read"}]), None);
        let (buttons, reply) = phone_buttons(&n, false);
        assert_eq!(buttons.iter().map(|b| b.0.as_str()).collect::<Vec<_>>(), vec!["reply0", "a1", "dismiss"]);
        assert_eq!(reply, None);
        let (buttons, reply) = phone_buttons(&n, true);
        assert_eq!(reply, Some(0), "KDE types the reply in the banner");
        assert_eq!(buttons.iter().map(|b| b.0.as_str()).collect::<Vec<_>>(), vec!["a1", "dismiss"]);
        let many = notice(json!([{"actionToken": "c".repeat(64), "title": "A"}, {"actionToken": "d".repeat(64), "title": "B"}, {"actionToken": "e".repeat(64), "title": "C"}]), None);
        assert_eq!(phone_buttons(&many, false).0.len(), 3);
        let call = notice(json!([{"actionToken": "f".repeat(64), "title": "Answer"}]), Some("incoming"));
        assert!(phone_buttons(&call, false).0.iter().all(|b| b.0 != "dismiss"), "a call is answered or declined, not dismissed");
    }

    #[test]
    fn markup_is_escaped_only_for_servers_that_read_it() {
        assert_eq!(escape("a < b & c", true), "a &lt; b &amp; c");
        assert_eq!(escape("a < b", false), "a < b");
    }
}
