//! Which forwarded notifications the reader may look at, and which text it reads (Swift `codeCandidate`).

use crate::email::email_code_precheck;
use crate::text::{code_read_text, looks_like_code_text, readable};
use serde::{Deserialize, Serialize};

/// Android packages that are SMS apps, for phones that do not yet say which app is the default.
pub const KNOWN_SMS_PACKAGES: &[&str] = &[
    "com.google.android.apps.messaging",
    "com.android.mms",
    "com.android.messaging",
    "com.samsung.android.messaging",
    "com.oneplus.mms",
    "com.oplus.mms",
    "com.coloros.mms",
    "com.miui.mms",
    "com.motorola.messaging",
    "com.truecaller",
];

/// The four mail apps whose notifications may carry a code, and the wire name of each (codes.found `app`).
pub const KNOWN_MAIL_APPS: &[(&str, &str)] = &[
    ("com.google.android.gm", "gmail"),
    ("com.microsoft.office.outlook", "outlook"),
    ("ch.protonmail.android", "proton"),
    ("com.readdle.spark", "spark"),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Channel {
    Sms,
    Email,
}

impl Channel {
    pub fn wire(self) -> &'static str {
        match self {
            Channel::Sms => "sms",
            Channel::Email => "email",
        }
    }

    pub fn of(wire: &str) -> Option<Channel> {
        match wire {
            "sms" => Some(Channel::Sms),
            "email" => Some(Channel::Email),
            _ => None,
        }
    }
}

/// A message the reader may look at: its channel and the (joined) text it reads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Candidate {
    pub channel: Channel,
    pub text: String,
}

/// The fields of one forwarded notification the decision needs (notifications.post, sms_codes_draft1 and
/// email_codes_draft1).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationFields {
    pub package_name: String,
    pub sms_default_app: Option<bool>,
    pub redacted: Option<bool>,
    pub text: String,
    pub email_app: Option<bool>,
    pub preview: Option<String>,
    /// The reader's "Also read codes in email" switch.
    #[serde(default)]
    pub email_codes: bool,
}

/// The mail app's wire name (`gmail`, `outlook`, `proton`, `spark`), or `None` for another package.
pub fn mail_app(package_name: &str) -> Option<&'static str> {
    KNOWN_MAIL_APPS.iter().find(|(p, _)| *p == package_name).map(|(_, name)| *name)
}

/// The text to read, or `None` when the notification is not a code candidate. A mail notification counts only when
/// the phone marked it `emailApp` (only for the four mail apps, never a group summary) and, as a second check, its
/// package is one of them.
pub fn code_candidate(n: &NotificationFields) -> Option<Candidate> {
    if n.redacted == Some(true) {
        return None;
    }
    let from_sms_app = n.sms_default_app.unwrap_or_else(|| KNOWN_SMS_PACKAGES.contains(&n.package_name.as_str()));
    if from_sms_app {
        let joined = code_read_text(readable(&n.text)?);
        return looks_like_code_text(&joined).then_some(Candidate { channel: Channel::Sms, text: joined });
    }
    if !n.email_codes || n.email_app != Some(true) || mail_app(&n.package_name).is_none() {
        return None;
    }
    let preview = n.preview.as_deref().map(str::trim).filter(|p| !p.is_empty());
    let joined = code_read_text(readable(preview.unwrap_or(&n.text))?);
    email_code_precheck(&joined).then_some(Candidate { channel: Channel::Email, text: joined })
}
