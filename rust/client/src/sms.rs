//! Text messages (`sms_draft1`, docs/protocol.md "Text messages"): the phone's conversations on this device, as the
//! Mac shows them (macos/Sources/BridgeyMac/SmsProtocol.swift, TextMessages.swift, SmsStore.swift). The pattern every
//! area follows is in `phone.rs`.
//!
//! - The wire: the phone's payloads decoded as strictly as protocol/test-vectors/protocol-v1.json pins them, and the
//!   requests this device writes, which the phone's decoders accept.
//! - Sync, with as little traffic as it can: without a cache, the phone's cursor from `sms.status` is the starting
//!   point (the history is never copied in bulk) and the newest 30 conversations load; with one, `sms.sync` from the
//!   cursor on connect and after each `sms.changed`, following `more` for at most 10 pages. Older conversations and
//!   messages load when scrolled to; an open conversation's newest page refreshes after a change, at most every 2 s.
//! - The cache: at most 200 conversations and the newest 200 messages of each, per phone, in the host's storage
//!   (`sms-<device>`, DPAPI on Windows), written at most once a second. It goes when Text messages is turned off here
//!   or on the phone, and when the phone is forgotten. MMS images stay in the host's memory.
//! - Read state is this device's own (it read up to a message), except Mark as read, which asks the phone to run the
//!   messaging app's own action (`sms.mark_read`).
//!
//! Host commands (`bridgey_phone`, area 1), each answered at once:
//!   status | threads {filter: all or unread} | refresh | older_threads | open {threadId} | close
//!   | messages {threadId} | older_messages {threadId} | send {body, threadId or address or notificationId, subId?}
//!   | retry {requestId} | discard {requestId} | image {partId} | contacts {query} | mark_read {threadIds}
//!   | mark_unread {threadIds} | block {address?} | forget | keep {on}
//! Events (`BRIDGEY_EVENT_KIND_SMS`): `changed` (the list or a conversation: ask again), `status`, `send` (an
//! outgoing message's state), `image` (`partId`, `data` base64, `width`, `height`, or `failed`), `contacts`,
//! `notice` (what Mark as read or Block on phone did), `reply_failed` (a notification reply did not go).
//!
//! Message bodies, numbers and names are never logged.

use crate::client::Inner;
use crate::phone::{self, boolean, integer, non_negative, request_id, utf16_len, Area, Incoming};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

pub(crate) const FEATURE: &str = "sms_draft1";

const PAGE: usize = 40_960;
const STATUS: usize = 2_048;
const CHANGED: usize = 256;
const CONTACTS_RESULT: usize = 16_384;
const MARK_READ_RESULT: usize = 4_096;
const SMALL: usize = 1_024;
/// One send's body, in UTF-16 units.
const BODY: usize = 2_000;
/// A message body on the wire, in UTF-16 units.
const MESSAGE_BODY: usize = 4_000;
const ATTACHMENT_BYTES: usize = 28_672;
const THREADS_PER_PAGE: i64 = 50;
const MESSAGES_PER_PAGE: i64 = 100;
const SYNC_PER_PAGE: i64 = 200;
const MARK_READ_PER_REQUEST: usize = 50;

const MAX_THREADS: usize = 200;
const MAX_MESSAGES_PER_THREAD: usize = 200;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_SYNC_PAGES: u32 = 10;
const MAX_OPEN_ATTACHMENTS: usize = 4;
const REFRESH_SPACING: Duration = Duration::from_secs(2);
const THREADS_REFRESH_SPACING: Duration = Duration::from_secs(3);
/// What the newest-conversations page asks for.
const FIRST_THREADS: i64 = 30;

pub fn incoming(kind: &str) -> Option<Incoming> {
    let (kind, max): (&'static str, usize) = match kind {
        "sms.status" => ("sms.status", STATUS),
        "sms.changed" => ("sms.changed", CHANGED),
        "sms.threads_page" => ("sms.threads_page", PAGE),
        "sms.messages_page" => ("sms.messages_page", PAGE),
        "sms.sync_page" => ("sms.sync_page", PAGE),
        "sms.send_status" => ("sms.send_status", SMALL),
        "sms.attachment_data" => ("sms.attachment_data", PAGE),
        "sms.contacts_result" => ("sms.contacts_result", CONTACTS_RESULT),
        "sms.mark_read_result" => ("sms.mark_read_result", MARK_READ_RESULT),
        "sms.blocked_numbers_result" => ("sms.blocked_numbers_result", SMALL),
        _ => return None,
    };
    Some(Incoming { area: Area::Sms, kind, feature: FEATURE, max, with_message_id: false })
}

// MARK: - Model

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cursor {
    pub sms: i64,
    pub mms: i64,
}

impl Cursor {
    /// `other` has something this cursor has not seen.
    pub fn is_behind(&self, other: &Cursor) -> bool {
        other.sms > self.sms || other.mms > self.mms
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sim {
    pub sub_id: i64,
    pub slot: i64,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Status {
    pub read: bool,
    pub send: bool,
    pub contacts: bool,
    pub sims: Vec<Sim>,
    pub cursor: Cursor,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Part {
    pub part_id: String,
    pub mime_type: String,
    #[serde(default)]
    pub size: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub thread_id: i64,
    /// `in` or `out`.
    pub direction: String,
    /// received, pending, sent, delivered or failed.
    pub status: String,
    pub date: i64,
    pub address: String,
    pub body: String,
    #[serde(default)]
    pub truncated: bool,
    #[serde(default)]
    pub sub_id: Option<i64>,
    #[serde(default = "yes")]
    pub read: bool,
    #[serde(default)]
    pub parts: Vec<Part>,
}

fn yes() -> bool {
    true
}

impl Message {
    pub fn incoming(&self) -> bool {
        self.direction == "in"
    }
}

/// Newest first: by date, then by ID, as the phone orders pages.
fn newer_first(a: &Message, b: &Message) -> std::cmp::Ordering {
    b.date.cmp(&a.date).then_with(|| b.id.cmp(&a.id))
}

/// `a` comes before `b` newest first.
fn is_newer(a: &Message, b: &Message) -> bool {
    newer_first(a, b) == std::cmp::Ordering::Less
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Participant {
    pub address: String,
    #[serde(default)]
    pub name: Option<String>,
}

impl Participant {
    pub fn display(&self) -> &str {
        self.name.as_deref().filter(|n| !n.is_empty()).unwrap_or(&self.address)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Thread {
    pub thread_id: i64,
    pub participants: Vec<Participant>,
    pub snippet: String,
    pub date: i64,
    pub unread: i64,
    #[serde(default)]
    pub sub_id: Option<i64>,
}

impl Thread {
    pub fn title(&self) -> String {
        self.participants.iter().map(Participant::display).collect::<Vec<_>>().join(", ")
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Contact {
    pub name: String,
    pub address: String,
    pub label: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SendStatus {
    pub request_id: String,
    /// sending, sent, delivered, failed or refused.
    pub status: String,
    pub reason: Option<String>,
    pub via: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThreadsPage {
    pub request_id: String,
    pub threads: Vec<Thread>,
    pub more: bool,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MessagesPage {
    pub request_id: String,
    pub thread_id: i64,
    pub messages: Vec<Message>,
    pub more: bool,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncPage {
    pub request_id: String,
    pub messages: Vec<Message>,
    pub cursor: Cursor,
    pub more: bool,
    pub reset: bool,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Attachment {
    pub request_id: String,
    pub part_id: String,
    pub data: Option<Vec<u8>>,
    pub width: i64,
    pub height: i64,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContactsResult {
    pub request_id: String,
    pub contacts: Vec<Contact>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MarkReadResult {
    pub request_id: String,
    /// Thread and marked, not_shown, no_action or failed.
    pub results: Vec<(i64, String)>,
    pub error: Option<String>,
}

// MARK: - Decoding (phone to this device)

fn object(plain: &[u8], limit: usize) -> Option<Map<String, Value>> {
    phone::versioned(plain, limit)
}

fn is_message_id(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() >= 2 && b.len() <= 20 && (b[0] == b's' || b[0] == b'm') && b[1..].iter().all(u8::is_ascii_digit)
}

fn is_part_id(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() >= 2 && b.len() <= 20 && b[0] == b'p' && b[1..].iter().all(u8::is_ascii_digit)
}

fn decode_cursor(value: Option<&Value>) -> Option<Cursor> {
    let o = value?.as_object()?;
    Some(Cursor { sms: non_negative(o.get("sms"))?, mms: non_negative(o.get("mms"))? })
}

/// `sms.status`: permissions and cursor are required; more than 4 SIMs is malformed; an invalid SIM is dropped.
pub fn decode_status(plain: &[u8]) -> Option<Status> {
    let o = object(plain, STATUS)?;
    let (read, send, contacts) = (boolean(o.get("read"))?, boolean(o.get("send"))?, boolean(o.get("contacts"))?);
    let cursor = decode_cursor(o.get("cursor"))?;
    let mut sims = Vec::new();
    match o.get("sims") {
        None | Some(Value::Null) => {}
        Some(Value::Array(list)) => {
            if list.len() > 4 {
                return None;
            }
            for entry in list {
                let Some(sim) = entry.as_object() else { continue };
                let (Some(sub_id), Some(slot), Some(label)) = (non_negative(sim.get("subId")), integer(sim.get("slot")), sim.get("label").and_then(Value::as_str)) else { continue };
                if sub_id > i64::from(i32::MAX) || !(0..=3).contains(&slot) || utf16_len(label) > 64 {
                    continue;
                }
                sims.push(Sim { sub_id, slot, label: label.to_string() });
            }
        }
        Some(_) => return None,
    }
    Some(Status { read, send, contacts, sims, cursor })
}

/// `sms.changed`: the phone's cursor.
pub fn decode_changed(plain: &[u8]) -> Option<Cursor> {
    decode_cursor(object(plain, CHANGED)?.get("cursor"))
}

/// One message object of a page, or None (the message is dropped).
pub fn decode_message(value: &Value) -> Option<Message> {
    let o = value.as_object()?;
    let id = o.get("id")?.as_str().filter(|i| is_message_id(i))?;
    let thread_id = integer(o.get("threadId")).filter(|t| *t >= 1)?;
    let direction = o.get("direction")?.as_str().filter(|d| *d == "in" || *d == "out")?;
    let date = non_negative(o.get("date"))?;
    let address = o.get("address")?.as_str().filter(|a| utf16_len(a) <= 64)?;
    let body = o.get("body")?.as_str().filter(|b| utf16_len(b) <= MESSAGE_BODY)?;
    let fallback = if direction == "in" { "received" } else { "sent" };
    let status = o.get("status").and_then(Value::as_str).filter(|s| matches!(*s, "received" | "pending" | "sent" | "delivered" | "failed")).unwrap_or(fallback);
    let mut parts = Vec::new();
    if let Some(Value::Array(list)) = o.get("parts") {
        for entry in list {
            if parts.len() >= 8 {
                break;
            }
            let Some(part) = entry.as_object() else { continue };
            let (Some(part_id), Some(mime)) = (part.get("partId").and_then(Value::as_str), part.get("mimeType").and_then(Value::as_str)) else { continue };
            if !is_part_id(part_id) || !mime.starts_with("image/") || utf16_len(mime) > 64 {
                continue;
            }
            parts.push(Part { part_id: part_id.to_string(), mime_type: mime.to_string(), size: non_negative(part.get("size")) });
        }
    }
    Some(Message {
        id: id.to_string(),
        thread_id,
        direction: direction.to_string(),
        status: status.to_string(),
        date,
        address: address.to_string(),
        body: body.to_string(),
        truncated: boolean(o.get("truncated")) == Some(true),
        sub_id: non_negative(o.get("subId")),
        read: boolean(o.get("read")) != Some(false),
        parts,
    })
}

fn decode_messages(value: Option<&Value>) -> Option<Vec<Message>> {
    Some(value?.as_array()?.iter().filter_map(decode_message).collect())
}

fn page_error(value: Option<&Value>) -> Option<String> {
    value?.as_str().filter(|t| !t.is_empty() && t.chars().count() <= 32).map(str::to_string)
}

pub fn decode_thread(value: &Value) -> Option<Thread> {
    let o = value.as_object()?;
    let thread_id = integer(o.get("threadId")).filter(|t| *t >= 1)?;
    let list = o.get("participants")?.as_array().filter(|l| (1..=10).contains(&l.len()))?;
    let date = non_negative(o.get("date"))?;
    let mut participants = Vec::new();
    for entry in list {
        let p = entry.as_object()?;
        let address = p.get("address")?.as_str().filter(|a| utf16_len(a) <= 64)?;
        let name = p.get("name").and_then(Value::as_str).filter(|n| !n.is_empty() && utf16_len(n) <= 128).map(str::to_string);
        participants.push(Participant { address: address.to_string(), name });
    }
    let snippet = o.get("snippet").and_then(Value::as_str).map(|s| s.chars().take(160).collect()).unwrap_or_default();
    Some(Thread { thread_id, participants, snippet, date, unread: non_negative(o.get("unread")).unwrap_or(0), sub_id: non_negative(o.get("subId")) })
}

pub fn decode_threads_page(plain: &[u8]) -> Option<ThreadsPage> {
    let o = object(plain, PAGE)?;
    let request_id = request_id(o.get("requestId"))?;
    let list = o.get("threads")?.as_array()?;
    Some(ThreadsPage { request_id, threads: list.iter().filter_map(decode_thread).collect(), more: boolean(o.get("more")) == Some(true), error: page_error(o.get("error")) })
}

pub fn decode_messages_page(plain: &[u8]) -> Option<MessagesPage> {
    let o = object(plain, PAGE)?;
    let request_id = request_id(o.get("requestId"))?;
    let thread_id = integer(o.get("threadId"))?;
    // A message of another conversation is not this page's.
    let messages = decode_messages(o.get("messages"))?.into_iter().filter(|m| m.thread_id == thread_id).collect();
    Some(MessagesPage { request_id, thread_id, messages, more: boolean(o.get("more")) == Some(true), error: page_error(o.get("error")) })
}

pub fn decode_sync_page(plain: &[u8]) -> Option<SyncPage> {
    let o = object(plain, PAGE)?;
    let request_id = request_id(o.get("requestId"))?;
    let cursor = decode_cursor(o.get("cursor"))?;
    Some(SyncPage {
        request_id,
        messages: decode_messages(o.get("messages")).unwrap_or_default(),
        cursor,
        more: boolean(o.get("more")) == Some(true),
        reset: boolean(o.get("reset")) == Some(true),
        error: page_error(o.get("error")),
    })
}

/// `sms.send_status`: an unknown status is dropped; a failed or refused status without a known reason reads as failed.
pub fn decode_send_status(plain: &[u8]) -> Option<SendStatus> {
    let o = object(plain, SMALL)?;
    let request_id = request_id(o.get("requestId"))?;
    let status = o.get("status")?.as_str().filter(|s| matches!(*s, "sending" | "sent" | "delivered" | "failed" | "refused"))?;
    let reason = (status == "failed" || status == "refused").then(|| {
        o.get("reason")
            .and_then(Value::as_str)
            .filter(|r| matches!(*r, "disabled" | "permission" | "invalid" | "group" | "no_sim" | "rate_limited" | "not_found" | "radio_off" | "no_service" | "failed"))
            .unwrap_or("failed")
            .to_string()
    });
    let via = o.get("via").and_then(Value::as_str).filter(|v| *v == "sms" || *v == "app").map(str::to_string);
    Some(SendStatus { request_id, status: status.to_string(), reason, via })
}

pub fn decode_attachment(plain: &[u8]) -> Option<Attachment> {
    use base64::Engine;
    let o = object(plain, PAGE)?;
    let request_id = request_id(o.get("requestId"))?;
    let part_id = o.get("partId")?.as_str().filter(|p| is_part_id(p))?.to_string();
    if let Some(error) = page_error(o.get("error")) {
        return Some(Attachment { request_id, part_id, data: None, width: 0, height: 0, error: Some(error) });
    }
    let data = base64::engine::general_purpose::STANDARD.decode(o.get("data")?.as_str()?).ok().filter(|d| !d.is_empty() && d.len() <= ATTACHMENT_BYTES)?;
    Some(Attachment { request_id, part_id, data: Some(data), width: non_negative(o.get("width")).unwrap_or(0), height: non_negative(o.get("height")).unwrap_or(0), error: None })
}

pub fn decode_contacts_result(plain: &[u8]) -> Option<ContactsResult> {
    let o = object(plain, CONTACTS_RESULT)?;
    let request_id = request_id(o.get("requestId"))?;
    let mut contacts = Vec::new();
    for entry in o.get("contacts").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default() {
        if contacts.len() >= 20 {
            break;
        }
        let Some(c) = entry.as_object() else { continue };
        let (Some(name), Some(address)) = (c.get("name").and_then(Value::as_str), c.get("address").and_then(Value::as_str)) else { continue };
        if utf16_len(name) > 128 || address.is_empty() || utf16_len(address) > 64 {
            continue;
        }
        let label = c.get("label").and_then(Value::as_str).filter(|l| !l.is_empty() && utf16_len(l) <= 32).map(str::to_string);
        contacts.push(Contact { name: name.to_string(), address: address.to_string(), label });
    }
    Some(ContactsResult { request_id, contacts, error: page_error(o.get("error")) })
}

/// `sms.mark_read_result`: missing results read as none; an invalid entry is dropped; more than 50 is malformed.
pub fn decode_mark_read_result(plain: &[u8]) -> Option<MarkReadResult> {
    let o = object(plain, MARK_READ_RESULT)?;
    let request_id = request_id(o.get("requestId"))?;
    let mut results = Vec::new();
    match o.get("results") {
        None | Some(Value::Null) => {}
        Some(Value::Array(list)) => {
            if list.len() > MARK_READ_PER_REQUEST {
                return None;
            }
            for entry in list {
                let Some(item) = entry.as_object() else { continue };
                let (Some(thread), Some(raw)) = (integer(item.get("threadId")).filter(|t| *t >= 1), item.get("result").and_then(Value::as_str)) else { continue };
                let outcome = if matches!(raw, "marked" | "not_shown" | "no_action" | "failed") { raw } else { "failed" };
                results.push((thread, outcome.to_string()));
            }
        }
        Some(_) => return None,
    }
    Some(MarkReadResult { request_id, results, error: page_error(o.get("error")) })
}

/// `sms.blocked_numbers_result`: an unknown result reads as unavailable.
pub fn decode_blocked_numbers_result(plain: &[u8]) -> Option<(String, String)> {
    let o = object(plain, SMALL)?;
    let request_id = request_id(o.get("requestId"))?;
    let raw = o.get("result")?.as_str()?;
    let outcome = if matches!(raw, "opened" | "notified" | "unavailable") { raw } else { "unavailable" };
    Some((request_id, outcome.to_string()))
}

// MARK: - Requests (this device to the phone)

/// Where a send goes: a conversation, a new number, or the SMS notification it answers.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Target {
    Thread(i64),
    Address(String),
    Notification(String),
}

pub fn threads_request(id: &str, before: Option<i64>, limit: i64) -> Value {
    let mut v = json!({"version": 1, "requestId": id, "limit": limit.clamp(1, THREADS_PER_PAGE)});
    if let Some(before) = before {
        v["before"] = json!(before);
    }
    v
}

pub fn messages_request(id: &str, thread_id: i64, before: Option<(i64, &str)>, limit: i64) -> Value {
    let mut v = json!({"version": 1, "requestId": id, "threadId": thread_id, "limit": limit.clamp(1, MESSAGES_PER_PAGE)});
    if let Some((date, message)) = before {
        v["before"] = json!({"date": date, "id": message});
    }
    v
}

pub fn sync_request(id: &str, since: Cursor, limit: i64) -> Value {
    json!({"version": 1, "requestId": id, "since": {"sms": since.sms, "mms": since.mms}, "limit": limit.clamp(1, SYNC_PER_PAGE)})
}

pub fn attachment_request(id: &str, part_id: &str) -> Value {
    json!({"version": 1, "requestId": id, "partId": part_id})
}

pub fn contacts_request(id: &str, query: &str) -> Option<Value> {
    let trimmed = query.trim();
    (!trimmed.is_empty() && utf16_len(trimmed) <= 64).then(|| json!({"version": 1, "requestId": id, "query": trimmed}))
}

/// Conversations read here (1 to 50, each once); None when there are none.
pub fn mark_read_request(id: &str, thread_ids: &[i64]) -> Option<Value> {
    let mut seen = HashSet::new();
    let ids: Vec<i64> = thread_ids.iter().copied().filter(|t| *t >= 1 && seen.insert(*t)).collect();
    (!ids.is_empty() && ids.len() <= MARK_READ_PER_REQUEST).then(|| json!({"version": 1, "requestId": id, "threadIds": ids}))
}

/// Opens Blocked numbers on the phone, with the number to add when it is one.
pub fn blocked_numbers_request(id: &str, address: Option<&str>) -> Value {
    let mut v = json!({"version": 1, "requestId": id});
    if let Some(number) = address.and_then(normalized_address) {
        v["address"] = json!(number);
    }
    v
}

pub fn is_sendable_body(body: &str) -> bool {
    let n = utf16_len(body);
    (1..=BODY).contains(&n) && !body.trim().is_empty()
}

/// `sms.send`, or None when the phone would refuse it as malformed (empty or too long, a bad number).
pub fn send_request(id: &str, body: &str, target: &Target, sub_id: Option<i64>) -> Option<Value> {
    if !is_sendable_body(body) {
        return None;
    }
    let mut v = json!({"version": 1, "requestId": id, "body": body});
    match target {
        Target::Thread(t) if *t >= 1 => v["threadId"] = json!(t),
        Target::Address(raw) => v["address"] = json!(normalized_address(raw)?),
        Target::Notification(n) if !n.is_empty() && n.chars().count() <= 512 => v["notificationId"] = json!(n),
        _ => return None,
    }
    if let Some(sub) = sub_id.filter(|s| *s >= 0) {
        v["subId"] = json!(sub);
    }
    Some(v)
}

/// A phone number as the phone accepts it: spaces, dashes, dots and brackets removed, then + and 2 to 20 digits.
pub fn normalized_address(raw: &str) -> Option<String> {
    let stripped: String = raw.chars().filter(|c| !" -.()".contains(*c)).collect();
    let digits = stripped.strip_prefix('+').unwrap_or(&stripped);
    ((2..=20).contains(&digits.len()) && digits.bytes().all(|b| b.is_ascii_digit())).then_some(stripped)
}

/// The same phone number, written differently: the last 10 digits match (or all of them when shorter).
pub fn same_number(a: &str, b: &str) -> bool {
    let left: Vec<char> = a.chars().filter(char::is_ascii_digit).collect();
    let right: Vec<char> = b.chars().filter(char::is_ascii_digit).collect();
    if left.is_empty() || right.is_empty() {
        return a == b;
    }
    let length = 10.min(left.len()).min(right.len());
    left[left.len() - length..] == right[right.len() - length..] && (length == 10 || left == right)
}

// MARK: - The cache

/// What this device keeps of one phone's conversations (SmsStore.swift's SmsCache), plus its own read state.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cache {
    pub version: u32,
    /// Where the next sms.sync starts; None until the phone's first sms.status (the baseline).
    pub cursor: Option<Cursor>,
    /// Newest first.
    pub threads: Vec<Thread>,
    /// The phone has older conversations than the last one here.
    pub threads_more: bool,
    /// Newest first, per conversation.
    pub messages: BTreeMap<i64, Vec<Message>>,
    /// The phone has older messages in that conversation than the oldest one here.
    pub older_more: BTreeMap<i64, bool>,
    /// Read on this device up to this incoming message date (this device's own; the phone's count is kept).
    #[serde(default)]
    pub read_through: BTreeMap<i64, i64>,
    /// Marked unread on this device.
    #[serde(default)]
    pub marked_unread: BTreeSet<i64>,
}

fn sort_threads(threads: &mut [Thread]) {
    threads.sort_by(|a, b| b.date.cmp(&a.date).then_with(|| b.thread_id.cmp(&a.thread_id)));
}

/// The one line a conversation shows for its newest message.
fn snippet(message: &Message) -> String {
    let text = message.body.trim();
    if text.is_empty() && !message.parts.is_empty() {
        return "Image".into();
    }
    text.chars().take(160).collect()
}

impl Cache {
    pub fn thread(&self, id: i64) -> Option<&Thread> {
        self.threads.iter().find(|t| t.thread_id == id)
    }

    pub fn messages_in(&self, thread: i64) -> &[Message] {
        self.messages.get(&thread).map(Vec::as_slice).unwrap_or_default()
    }

    pub fn has_older(&self, thread: i64) -> bool {
        self.older_more.get(&thread).copied().unwrap_or(true)
    }

    fn drop_threads(&mut self, ids: &[i64]) {
        let set: HashSet<i64> = ids.iter().copied().collect();
        self.threads.retain(|t| !set.contains(&t.thread_id));
        for id in set {
            self.messages.remove(&id);
            self.older_more.remove(&id);
            self.read_through.remove(&id);
            self.marked_unread.remove(&id);
        }
    }

    /// The newest page (`first`) replaces every cached conversation at least as new as its oldest entry, so a
    /// conversation deleted on the phone goes; an older page only adds.
    pub fn apply_threads(&mut self, page: &[Thread], first: bool, more: bool) {
        if first {
            let ids: HashSet<i64> = page.iter().map(|t| t.thread_id).collect();
            if let Some(oldest) = page.iter().map(|t| t.date).min() {
                let gone: Vec<i64> = self.threads.iter().filter(|t| t.date >= oldest && !ids.contains(&t.thread_id)).map(|t| t.thread_id).collect();
                self.drop_threads(&gone);
            } else if !more {
                let all: Vec<i64> = self.threads.iter().map(|t| t.thread_id).collect();
                self.drop_threads(&all);
            }
        }
        for thread in page {
            match self.threads.iter_mut().find(|t| t.thread_id == thread.thread_id) {
                Some(t) => *t = thread.clone(),
                None => self.threads.push(thread.clone()),
            }
        }
        sort_threads(&mut self.threads);
        if self.threads.len() > MAX_THREADS {
            let extra: Vec<i64> = self.threads[MAX_THREADS..].iter().map(|t| t.thread_id).collect();
            self.drop_threads(&extra);
            self.threads_more = true;
        } else if !first || self.threads.len() <= page.len() {
            self.threads_more = more;
        }
    }

    /// One conversation's page. The span it covers (from its oldest message up to `before`, or to the newest when
    /// `before` is None) is replaced, so messages deleted on the phone go.
    pub fn apply_messages(&mut self, page: &[Message], thread: i64, before: Option<&Message>, more: bool) {
        let mut list = self.messages.remove(&thread).unwrap_or_default();
        let known: HashSet<String> = list.iter().map(|m| m.id.clone()).collect();
        let ids: HashSet<&str> = page.iter().map(|m| m.id.as_str()).collect();
        if let Some(oldest) = page.iter().max_by(|a, b| newer_first(a, b)) {
            list.retain(|m| {
                if ids.contains(m.id.as_str()) {
                    return true;
                }
                let at_least_oldest = !is_newer(oldest, m);
                let below_upper = before.map(|b| is_newer(b, m)).unwrap_or(true);
                !(at_least_oldest && below_upper)
            });
        } else if before.is_none() {
            list.clear();
        }
        for m in page {
            match list.iter_mut().find(|x| x.id == m.id) {
                Some(x) => *x = m.clone(),
                None => list.push(m.clone()),
            }
        }
        list.sort_by(newer_first);
        // An open conversation's refresh can bring a new message before the sync does: the conversation's line and
        // unread count follow, as sync would have done, so it is counted once.
        if before.is_none() {
            if let Some(t) = self.threads.iter_mut().find(|t| t.thread_id == thread) {
                let mut fresh: Vec<&Message> = page.iter().filter(|m| !known.contains(&m.id) && m.date > t.date).collect();
                fresh.sort_by(|a, b| newer_first(b, a));
                for m in fresh {
                    t.date = m.date;
                    t.snippet = snippet(m);
                    if m.sub_id.is_some() {
                        t.sub_id = m.sub_id;
                    }
                    if m.incoming() && !m.read {
                        t.unread += 1;
                    }
                }
                sort_threads(&mut self.threads);
            }
        }
        let page_len = page.len();
        if list.len() > MAX_MESSAGES_PER_THREAD {
            list.truncate(MAX_MESSAGES_PER_THREAD);
            self.older_more.insert(thread, true);
        } else if before.is_some() || list.len() <= page_len {
            // This page reached the oldest message kept here: the phone says whether there are more.
            self.older_more.insert(thread, more);
        }
        self.messages.insert(thread, list);
    }

    /// Messages from sms.sync, newer than the cursor. Updates each conversation's summary and returns the conversations
    /// this cache does not know yet (their summaries come with the next threads page).
    pub fn apply_sync(&mut self, page: &[Message]) -> HashSet<i64> {
        let mut unknown = HashSet::new();
        let mut ordered: Vec<&Message> = page.iter().collect();
        ordered.sort_by(|a, b| newer_first(b, a));
        for m in ordered {
            let list = self.messages.entry(m.thread_id).or_default();
            let is_new = !list.iter().any(|x| x.id == m.id);
            match list.iter_mut().find(|x| x.id == m.id) {
                Some(x) => *x = m.clone(),
                None => list.push(m.clone()),
            }
            list.sort_by(newer_first);
            if list.len() > MAX_MESSAGES_PER_THREAD {
                list.truncate(MAX_MESSAGES_PER_THREAD);
                self.older_more.insert(m.thread_id, true);
            }
            let Some(t) = self.threads.iter_mut().find(|t| t.thread_id == m.thread_id) else {
                unknown.insert(m.thread_id);
                continue;
            };
            if m.date >= t.date {
                t.date = m.date;
                t.snippet = snippet(m);
                if m.sub_id.is_some() {
                    t.sub_id = m.sub_id;
                }
            }
            if is_new && m.incoming() && !m.read {
                t.unread += 1;
            }
        }
        sort_threads(&mut self.threads);
        unknown
    }

    /// The newest incoming message's date in a conversation, else its own date.
    pub fn newest_incoming_date(&self, thread: &Thread) -> i64 {
        self.messages_in(thread.thread_id).iter().find(|m| m.incoming()).map(|m| m.date).unwrap_or(thread.date)
    }

    /// Unread as this device shows it: the phone's count, unless this device read up to the newest incoming message
    /// since; at least 1 when marked unread here (SmsManagement.swift `unread`).
    pub fn unread(&self, thread: &Thread) -> i64 {
        if self.marked_unread.contains(&thread.thread_id) {
            return thread.unread.max(1);
        }
        if thread.unread <= 0 {
            return 0;
        }
        let Some(&read) = self.read_through.get(&thread.thread_id) else { return thread.unread };
        let incoming: Vec<&Message> = self.messages_in(thread.thread_id).iter().filter(|m| m.incoming()).collect();
        if incoming.is_empty() {
            return if thread.date > read { thread.unread } else { 0 };
        }
        let newer = incoming.iter().filter(|m| m.date > read).count() as i64;
        if newer == 0 {
            0
        } else {
            thread.unread.min(newer)
        }
    }

    pub fn mark_read(&mut self, thread: i64, through: i64) {
        self.marked_unread.remove(&thread);
        let entry = self.read_through.entry(thread).or_insert(0);
        *entry = (*entry).max(through);
    }

    pub fn mark_unread(&mut self, thread: i64) {
        self.marked_unread.insert(thread);
        self.read_through.remove(&thread);
    }

    /// Read points the phone caught up with go.
    pub fn reconcile(&mut self) {
        let caught_up: Vec<i64> = self.threads.iter().filter(|t| t.unread == 0).map(|t| t.thread_id).collect();
        for id in caught_up {
            self.read_through.remove(&id);
        }
    }

    /// The conversation list as the window shows it: unread first, then newest (`filter` `unread` shows only those,
    /// and `holding` keeps one there while it is open).
    pub fn rows(&self, unread_only: bool, holding: Option<i64>) -> Vec<(Thread, i64)> {
        let mut rows: Vec<(Thread, i64)> = self.threads.iter().map(|t| (t.clone(), self.unread(t))).filter(|(t, u)| !unread_only || *u > 0 || Some(t.thread_id) == holding).collect();
        // The cache is newest first already; a stable sort keeps that order inside each group.
        rows.sort_by_key(|(t, u)| if *u > 0 || Some(t.thread_id) == holding { 0 } else { 1 });
        rows
    }

    pub fn unread_total(&self) -> i64 {
        self.threads.iter().map(|t| self.unread(t)).sum()
    }
}

// MARK: - The engine

/// A send from this device, until the phone's provider has the message (or it failed).
#[derive(Clone, Debug)]
struct Outgoing {
    id: String,
    target: Target,
    body: String,
    sub_id: Option<i64>,
    created_ms: i64,
    state: String,
    reason: Option<String>,
    via: Option<String>,
}

impl Outgoing {
    fn failed(&self) -> bool {
        self.state == "failed" || self.state == "refused"
    }
    fn is_final(&self) -> bool {
        self.failed() || self.state == "delivered"
    }
    fn notification_reply(&self) -> bool {
        matches!(self.target, Target::Notification(_))
    }
    fn to_json(&self) -> Value {
        let mut v = json!({"requestId": self.id, "body": self.body, "state": self.state, "reason": self.reason, "via": self.via, "date": self.created_ms});
        match &self.target {
            Target::Thread(t) => v["threadId"] = json!(t),
            Target::Address(a) => v["address"] = json!(a),
            Target::Notification(n) => v["notificationId"] = json!(n),
        }
        v
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Pending {
    Threads { first: bool },
    Messages { thread: i64, before: Option<Message> },
    Sync,
    Attachment { part: String },
    Contacts,
    Send,
    MarkRead { threads: Vec<i64> },
    Blocked { address: Option<String> },
}

/// One phone's conversations and requests.
#[derive(Default)]
struct PhoneData {
    loaded: bool,
    status: Option<Status>,
    cache: Cache,
    loading_threads: bool,
    loading_messages: HashSet<i64>,
    syncing: bool,
    sync_pages: u32,
    problem: Option<String>,
    pending: HashMap<String, Pending>,
    outgoing: Vec<Outgoing>,
    open: Option<i64>,
    last_refresh: Option<Instant>,
    last_threads_refresh: Option<Instant>,
    images: VecDeque<String>,
    failed_images: HashSet<String>,
    contacts_request: Option<String>,
    save_scheduled: bool,
}

/// Every phone's conversations, by device ID.
#[derive(Default)]
pub struct State {
    phones: HashMap<String, PhoneData>,
    /// Keep conversations on this device turned off (`keep` command): nothing is written and stored caches go.
    no_keep: bool,
}

fn storage_key(device_id: &str) -> String {
    let safe: String = device_id.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').take(64).collect();
    format!("sms-{}", if safe.is_empty() { "phone" } else { &safe })
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// Text messages is on here and on the phone, and the phone is connected.
fn available(inner: &Inner, device_id: &str) -> bool {
    inner.policy_for(device_id).get(FEATURE) && inner.remote_features(device_id).is_some_and(|r| r.get(FEATURE))
}

fn with<R>(inner: &Inner, device_id: &str, f: impl FnOnce(&mut PhoneData) -> R) -> R {
    let mut st = inner.phone.sms.lock().unwrap();
    let keep = !st.no_keep;
    let phone = st.phones.entry(device_id.to_string()).or_default();
    if !phone.loaded {
        phone.loaded = true;
        if let Ok(Some(bytes)) = if keep { inner.storage.load(&storage_key(device_id)) } else { Ok(None) } {
            if let Ok(cache) = serde_json::from_slice::<Cache>(&bytes) {
                if cache.version == 1 {
                    phone.cache = cache;
                }
            }
        }
    }
    f(phone)
}

fn changed(inner: &Inner, device_id: &str, detail: Value) {
    phone::emit(inner, Area::Sms, device_id, "changed", 0, detail);
}

/// Sends a request and waits for its answer for 15 s; false when it could not go.
fn request(inner: &Inner, device_id: &str, kind: &'static str, payload: Value, id: &str, entry: Pending) -> bool {
    if !available(inner, device_id) {
        return false;
    }
    // Waiting before it goes: on a fast link the answer can come back before this thread runs again.
    with(inner, device_id, |p| p.pending.insert(id.to_string(), entry));
    if inner.encrypted_to(device_id, FEATURE, kind, payload.to_string()).is_err() {
        with(inner, device_id, |p| p.pending.remove(id));
        return false;
    }
    let (device, id) = (device_id.to_string(), id.to_string());
    phone::after(inner, REQUEST_TIMEOUT, move |inner| timed_out(inner, &device, &id));
    true
}

fn timed_out(inner: &Inner, device_id: &str, id: &str) {
    let Some(entry) = with(inner, device_id, |p| p.pending.remove(id)) else { return };
    match entry {
        Pending::Threads { .. } => with(inner, device_id, |p| p.loading_threads = false),
        Pending::Messages { thread, .. } => {
            with(inner, device_id, |p| p.loading_messages.remove(&thread));
        }
        Pending::Sync => with(inner, device_id, |p| {
            p.syncing = false;
            p.sync_pages = 0;
        }),
        Pending::Attachment { part } => {
            with(inner, device_id, |p| p.failed_images.insert(part.clone()));
            phone::emit(inner, Area::Sms, device_id, "image", 0, json!({"partId": part, "failed": true}));
            pump_images(inner, device_id);
        }
        Pending::Contacts => {
            with(inner, device_id, |p| p.contacts_request = None);
            phone::emit(inner, Area::Sms, device_id, "contacts", 0, json!({"contacts": [], "error": "timeout"}));
        }
        Pending::Send => {
            let failed = with(inner, device_id, |p| {
                p.outgoing.iter_mut().find(|o| o.id == id && o.state == "sending").map(|o| {
                    o.state = "failed".into();
                    o.reason = Some("failed".into());
                    o.clone()
                })
            });
            if let Some(o) = failed {
                send_changed(inner, device_id, &o);
            }
        }
        Pending::MarkRead { threads } => notice(inner, device_id, json!({"kind": "mark_read", "total": threads.len(), "noAnswer": true})),
        Pending::Blocked { address } => notice(inner, device_id, json!({"kind": "blocked", "result": null, "address": address})),
    }
    changed(inner, device_id, json!({}));
}

fn notice(inner: &Inner, device_id: &str, detail: Value) {
    phone::emit(inner, Area::Sms, device_id, "notice", 0, detail);
}

fn send_changed(inner: &Inner, device_id: &str, o: &Outgoing) {
    phone::emit(inner, Area::Sms, device_id, "send", 0, o.to_json());
    if o.failed() && o.notification_reply() {
        phone::emit(inner, Area::Sms, device_id, "reply_failed", 0, o.to_json());
    }
}

fn request_threads(inner: &Inner, device_id: &str, first: bool, limit: i64) {
    let (busy, before) = with(inner, device_id, |p| (p.loading_threads, if first { None } else { p.cache.threads.last().map(|t| t.date) }));
    if busy {
        return;
    }
    let id = crate::crypto::uuid4();
    if request(inner, device_id, "sms.threads", threads_request(&id, before, limit), &id, Pending::Threads { first }) {
        with(inner, device_id, |p| p.loading_threads = true);
    }
}

fn start_sync(inner: &Inner, device_id: &str) {
    let go = with(inner, device_id, |p| {
        if p.syncing {
            return false;
        }
        p.sync_pages = 0;
        true
    });
    if go {
        send_sync(inner, device_id);
    }
}

fn send_sync(inner: &Inner, device_id: &str) {
    let Some(cursor) = with(inner, device_id, |p| p.cache.cursor) else { return };
    let id = crate::crypto::uuid4();
    let sent = request(inner, device_id, "sms.sync", sync_request(&id, cursor, 100), &id, Pending::Sync);
    with(inner, device_id, |p| p.syncing = sent);
}

fn request_messages(inner: &Inner, device_id: &str, thread: i64, older: bool) {
    let (busy, before) = with(inner, device_id, |p| (p.loading_messages.contains(&thread), if older { p.cache.messages_in(thread).last().cloned() } else { None }));
    if busy {
        return;
    }
    let id = crate::crypto::uuid4();
    let payload = messages_request(&id, thread, before.as_ref().map(|m| (m.date, m.id.as_str())), 50);
    if request(inner, device_id, "sms.messages", payload, &id, Pending::Messages { thread, before }) {
        with(inner, device_id, |p| p.loading_messages.insert(thread));
    }
}

/// Writes the phone's cache at most once a second, while Keep conversations is on.
fn persist(inner: &Inner, device_id: &str) {
    if inner.phone.sms.lock().unwrap().no_keep {
        return;
    }
    let schedule = with(inner, device_id, |p| !std::mem::replace(&mut p.save_scheduled, true));
    if !schedule {
        return;
    }
    let device = device_id.to_string();
    phone::after(inner, Duration::from_secs(1), move |inner| flush(inner, &device));
}

fn flush(inner: &Inner, device_id: &str) {
    let data = {
        let mut st = inner.phone.sms.lock().unwrap();
        let Some(p) = st.phones.get_mut(device_id) else { return };
        if !std::mem::take(&mut p.save_scheduled) {
            return;
        }
        serde_json::to_vec(&p.cache).ok()
    };
    if let Some(bytes) = data.filter(|_| !inner.phone.sms.lock().unwrap().no_keep) {
        let _ = inner.storage.store(&storage_key(device_id), &bytes);
    }
}

/// Everything kept for the phone goes: memory and storage.
fn forget(inner: &Inner, device_id: &str) {
    let had = inner.phone.sms.lock().unwrap().phones.remove(device_id).is_some();
    let _ = inner.storage.remove(&storage_key(device_id));
    if had {
        changed(inner, device_id, json!({"forgotten": true}));
    }
}

fn pump_images(inner: &Inner, device_id: &str) {
    loop {
        let next = with(inner, device_id, |p| {
            let open = p.pending.values().filter(|e| matches!(e, Pending::Attachment { .. })).count();
            if open >= MAX_OPEN_ATTACHMENTS {
                return None;
            }
            p.images.pop_front()
        });
        let Some(part) = next else { return };
        let id = crate::crypto::uuid4();
        if !request(inner, device_id, "sms.attachment", attachment_request(&id, &part), &id, Pending::Attachment { part: part.clone() }) {
            with(inner, device_id, |p| p.failed_images.insert(part.clone()));
            phone::emit(inner, Area::Sms, device_id, "image", 0, json!({"partId": part, "failed": true}));
        }
    }
}

/// Messages the phone now has replace this device's pending bubbles for them.
fn reconcile_outgoing(p: &mut PhoneData, messages: &[Message]) {
    let sent: Vec<&Message> = messages.iter().filter(|m| !m.incoming()).collect();
    if sent.is_empty() || p.outgoing.is_empty() {
        return;
    }
    p.outgoing.retain(|o| {
        if o.failed() {
            return true;
        }
        !sent.iter().any(|m| {
            m.body == o.body
                && m.date >= o.created_ms - 120_000
                && match &o.target {
                    Target::Thread(t) => m.thread_id == *t,
                    Target::Address(a) => same_number(&m.address, a),
                    Target::Notification(_) => false,
                }
        })
    });
}

fn refresh_open(inner: &Inner, device_id: &str) {
    let due = with(inner, device_id, |p| {
        let open = p.open?;
        if p.last_refresh.is_some_and(|t| t.elapsed() < REFRESH_SPACING) {
            return Some((open, false));
        }
        p.last_refresh = Some(Instant::now());
        Some((open, true))
    });
    match due {
        Some((thread, true)) => request_messages(inner, device_id, thread, false),
        Some((_, false)) => {
            // Too soon: once more when the spacing is up.
            let device = device_id.to_string();
            phone::after(inner, REFRESH_SPACING, move |inner| {
                let go = with(inner, &device, |p| {
                    let open = p.open?;
                    if p.last_refresh.is_some_and(|t| t.elapsed() < REFRESH_SPACING) {
                        return None;
                    }
                    p.last_refresh = Some(Instant::now());
                    Some(open)
                });
                if let Some(thread) = go {
                    request_messages(inner, &device, thread, false);
                }
            });
        }
        None => {}
    }
}

pub(crate) fn receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) {
    match kind {
        "sms.status" => {
            let Some(status) = decode_status(plain) else { return };
            let read = status.read;
            let (no_cache, no_threads) = with(inner, device_id, |p| {
                p.status = Some(status.clone());
                if p.cache.cursor.is_none() {
                    p.cache.cursor = Some(status.cursor);
                    (true, true)
                } else {
                    (false, p.cache.threads.is_empty())
                }
            });
            phone::emit(inner, Area::Sms, device_id, "status", 0, status_json(inner, device_id));
            if !read {
                return;
            }
            if no_cache {
                // No cache: start from the phone's cursor; only the newest conversations load.
                request_threads(inner, device_id, true, FIRST_THREADS);
                persist(inner, device_id);
            } else {
                if no_threads {
                    request_threads(inner, device_id, true, FIRST_THREADS);
                }
                start_sync(inner, device_id);
            }
        }
        "sms.changed" => {
            let Some(cursor) = decode_changed(plain) else { return };
            let behind = with(inner, device_id, |p| {
                if let Some(s) = p.status.as_mut() {
                    s.cursor = cursor;
                }
                p.cache.cursor.map(|mine| mine.is_behind(&cursor))
            });
            match behind {
                None => return,
                Some(true) => start_sync(inner, device_id),
                Some(false) => {
                    // Nothing new, so something changed in place (read or deleted on the phone): the list carries the
                    // phone's unread counts. At most every 3 seconds.
                    let due = with(inner, device_id, |p| {
                        if p.last_threads_refresh.is_some_and(|t| t.elapsed() < THREADS_REFRESH_SPACING) {
                            return false;
                        }
                        p.last_threads_refresh = Some(Instant::now());
                        true
                    });
                    if due {
                        request_threads(inner, device_id, true, FIRST_THREADS);
                    }
                }
            }
            refresh_open(inner, device_id);
        }
        "sms.threads_page" => {
            let Some(page) = decode_threads_page(plain) else { return };
            let ok = with(inner, device_id, |p| {
                let Some(Pending::Threads { first }) = p.pending.get(&page.request_id).cloned() else { return false };
                p.pending.remove(&page.request_id);
                p.loading_threads = false;
                p.problem = page.error.clone();
                if page.error.is_none() {
                    p.cache.apply_threads(&page.threads, first, page.more);
                    p.cache.reconcile();
                }
                true
            });
            if ok {
                changed(inner, device_id, json!({"threads": true}));
                persist(inner, device_id);
            }
        }
        "sms.messages_page" => {
            let Some(page) = decode_messages_page(plain) else { return };
            let ok = with(inner, device_id, |p| {
                let Some(Pending::Messages { thread, before }) = p.pending.get(&page.request_id).cloned() else { return false };
                if thread != page.thread_id {
                    return false;
                }
                p.pending.remove(&page.request_id);
                p.loading_messages.remove(&thread);
                p.problem = page.error.clone();
                if page.error.is_none() {
                    p.cache.apply_messages(&page.messages, thread, before.as_ref(), page.more);
                    p.cache.reconcile();
                }
                reconcile_outgoing(p, &page.messages);
                true
            });
            if ok {
                changed(inner, device_id, json!({"threads": true, "threadId": page.thread_id}));
                persist(inner, device_id);
            }
        }
        "sms.sync_page" => {
            let Some(page) = decode_sync_page(plain) else { return };
            // None: not an answer this device waits for. Otherwise: start again, ask for more, ask for conversations.
            let outcome = with(inner, device_id, |p| {
                if p.pending.get(&page.request_id) != Some(&Pending::Sync) {
                    return None;
                }
                p.pending.remove(&page.request_id);
                if page.error.is_some() {
                    p.syncing = false;
                    p.sync_pages = 0;
                    p.problem = page.error.clone();
                    return Some((false, false, false));
                }
                if page.reset {
                    // The phone was restored or this device fell too far behind: start again from its cursor.
                    let (read_through, marked) = (std::mem::take(&mut p.cache.read_through), std::mem::take(&mut p.cache.marked_unread));
                    p.cache = Cache { version: 1, cursor: Some(page.cursor), read_through, marked_unread: marked, ..Default::default() };
                    p.syncing = false;
                    p.sync_pages = 0;
                    return Some((true, false, false));
                }
                let unknown = p.cache.apply_sync(&page.messages);
                p.cache.cursor = Some(page.cursor);
                p.cache.reconcile();
                reconcile_outgoing(p, &page.messages);
                p.sync_pages += 1;
                let more = page.more && p.sync_pages < MAX_SYNC_PAGES;
                if !more {
                    p.syncing = false;
                    p.sync_pages = 0;
                }
                Some((false, more, !unknown.is_empty() && !p.loading_threads))
            });
            let Some((reset, more, unknown)) = outcome else { return };
            if reset || unknown {
                request_threads(inner, device_id, true, FIRST_THREADS);
            }
            if more {
                send_sync(inner, device_id);
            }
            changed(inner, device_id, json!({"threads": true}));
            persist(inner, device_id);
        }
        "sms.send_status" => {
            let Some(status) = decode_send_status(plain) else { return };
            let updated = with(inner, device_id, |p| {
                let index = p.outgoing.iter().position(|o| o.id == status.request_id)?;
                p.pending.remove(&status.request_id);
                // A late "sent" never undoes "delivered".
                if p.outgoing[index].state == "delivered" && status.status == "sent" {
                    return None;
                }
                let o = &mut p.outgoing[index];
                o.state = status.status.clone();
                o.reason = status.reason.clone();
                if status.via.is_some() {
                    o.via = status.via.clone();
                }
                let copy = o.clone();
                if copy.notification_reply() && (copy.state == "sent" || copy.state == "delivered") {
                    p.outgoing.remove(index);
                }
                Some(copy)
            });
            if let Some(o) = updated {
                send_changed(inner, device_id, &o);
            }
        }
        "sms.attachment_data" => {
            use base64::Engine;
            let Some(a) = decode_attachment(plain) else { return };
            let ok = with(inner, device_id, |p| {
                if p.pending.get(&a.request_id) != Some(&Pending::Attachment { part: a.part_id.clone() }) {
                    return false;
                }
                p.pending.remove(&a.request_id);
                if a.data.is_none() {
                    p.failed_images.insert(a.part_id.clone());
                }
                true
            });
            if !ok {
                return;
            }
            let detail = match &a.data {
                Some(bytes) => json!({"partId": a.part_id, "data": base64::engine::general_purpose::STANDARD.encode(bytes), "width": a.width, "height": a.height}),
                None => json!({"partId": a.part_id, "failed": true, "error": a.error}),
            };
            phone::emit(inner, Area::Sms, device_id, "image", 0, detail);
            pump_images(inner, device_id);
        }
        "sms.contacts_result" => {
            let Some(r) = decode_contacts_result(plain) else { return };
            let ok = with(inner, device_id, |p| {
                if p.contacts_request.as_deref() != Some(r.request_id.as_str()) {
                    return false;
                }
                p.pending.remove(&r.request_id);
                p.contacts_request = None;
                true
            });
            if ok {
                let contacts: Vec<Value> = r.contacts.iter().map(|c| json!({"name": c.name, "address": c.address, "label": c.label})).collect();
                phone::emit(inner, Area::Sms, device_id, "contacts", 0, json!({"contacts": contacts, "error": r.error}));
            }
        }
        "sms.mark_read_result" => {
            let Some(r) = decode_mark_read_result(plain) else { return };
            let Some(Pending::MarkRead { threads }) = with(inner, device_id, |p| match p.pending.get(&r.request_id) {
                Some(Pending::MarkRead { .. }) => p.pending.remove(&r.request_id),
                _ => None,
            }) else {
                return;
            };
            let mut counts: BTreeMap<&str, usize> = BTreeMap::new();
            if r.error.is_none() {
                for t in &threads {
                    let outcome = r.results.iter().find(|(id, _)| id == t).map(|(_, o)| o.as_str()).unwrap_or("failed");
                    *counts.entry(outcome).or_default() += 1;
                }
            }
            let marked = counts.get("marked").copied().unwrap_or(0);
            notice(
                inner,
                device_id,
                json!({"kind": "mark_read", "total": threads.len(), "marked": marked, "notShown": counts.get("not_shown").copied().unwrap_or(0),
                       "noAction": counts.get("no_action").copied().unwrap_or(0), "failed": counts.get("failed").copied().unwrap_or(0), "disabled": r.error.is_some()}),
            );
            // The messaging app writes the read state a moment later; the list then carries the phone's counts.
            if marked > 0 {
                let device = device_id.to_string();
                phone::after(inner, Duration::from_millis(1_500), move |inner| request_threads(inner, &device, true, FIRST_THREADS));
            }
        }
        "sms.blocked_numbers_result" => {
            let Some((id, outcome)) = decode_blocked_numbers_result(plain) else { return };
            let Some(Pending::Blocked { address }) = with(inner, device_id, |p| match p.pending.get(&id) {
                Some(Pending::Blocked { .. }) => p.pending.remove(&id),
                _ => None,
            }) else {
                return;
            };
            notice(inner, device_id, json!({"kind": "blocked", "result": outcome, "address": address}));
        }
        _ => {}
    }
}

fn status_json(inner: &Inner, device_id: &str) -> Value {
    let on = available(inner, device_id);
    with(inner, device_id, |p| {
        json!({
            "available": on,
            "phone": p.status.as_ref().map(|s| json!({"read": s.read, "send": s.send, "contacts": s.contacts, "sims": s.sims})),
            "syncing": p.syncing,
            "loadingThreads": p.loading_threads,
            "problem": p.problem,
            "unread": p.cache.unread_total(),
            "cached": p.cache.cursor.is_some(),
        })
    })
}

fn thread_json(t: &Thread, unread: i64) -> Value {
    json!({
        "threadId": t.thread_id,
        "title": t.title(),
        "participants": t.participants,
        "snippet": t.snippet,
        "date": t.date,
        "unread": unread,
        "subId": t.sub_id,
        "group": t.participants.len() > 1,
    })
}

fn thread_ids(command: &Value) -> Vec<i64> {
    command.get("threadIds").and_then(Value::as_array).map(|l| l.iter().filter_map(Value::as_i64).filter(|t| *t >= 1).collect()).unwrap_or_default()
}

pub(crate) fn command(inner: &Inner, device_id: &str, command: &Value) -> Value {
    let thread = command.get("threadId").and_then(Value::as_i64);
    match phone::op(command) {
        Some("status") => phone::ok(status_json(inner, device_id)),
        Some("threads") => {
            let unread_only = command.get("filter").and_then(Value::as_str) == Some("unread");
            let holding = command.get("holding").and_then(Value::as_i64);
            with(inner, device_id, |p| {
                let rows: Vec<Value> = p.cache.rows(unread_only, holding).iter().map(|(t, u)| thread_json(t, *u)).collect();
                phone::ok(json!({"threads": rows, "more": p.cache.threads_more, "loading": p.loading_threads, "problem": p.problem}))
            })
        }
        Some("refresh") => {
            if !available(inner, device_id) {
                return phone::error("feature_off");
            }
            request_threads(inner, device_id, true, FIRST_THREADS);
            phone::ok(json!({}))
        }
        Some("older_threads") => {
            if with(inner, device_id, |p| p.cache.threads_more) {
                request_threads(inner, device_id, false, FIRST_THREADS);
            }
            phone::ok(json!({}))
        }
        Some("open") => {
            let Some(thread) = thread.filter(|t| *t >= 1) else { return phone::error("invalid") };
            with(inner, device_id, |p| {
                p.open = Some(thread);
                p.last_refresh = Some(Instant::now());
            });
            request_messages(inner, device_id, thread, false);
            messages_json(inner, device_id, thread)
        }
        Some("close") => {
            with(inner, device_id, |p| p.open = None);
            phone::ok(json!({}))
        }
        Some("messages") => match thread.filter(|t| *t >= 1) {
            Some(t) => messages_json(inner, device_id, t),
            None => phone::error("invalid"),
        },
        Some("older_messages") => {
            let Some(thread) = thread.filter(|t| *t >= 1) else { return phone::error("invalid") };
            if with(inner, device_id, |p| p.cache.has_older(thread) && !p.cache.messages_in(thread).is_empty()) {
                request_messages(inner, device_id, thread, true);
            }
            phone::ok(json!({}))
        }
        Some("send") => {
            let body = command.get("body").and_then(Value::as_str).unwrap_or("");
            let target = if let Some(t) = thread {
                Target::Thread(t)
            } else if let Some(a) = command.get("address").and_then(Value::as_str) {
                Target::Address(a.to_string())
            } else if let Some(n) = command.get("notificationId").and_then(Value::as_str) {
                Target::Notification(n.to_string())
            } else {
                return phone::error("invalid");
            };
            send(inner, device_id, body, target, command.get("subId").and_then(Value::as_i64))
        }
        Some("retry") => {
            let Some(id) = command.get("requestId").and_then(Value::as_str) else { return phone::error("invalid") };
            let Some(o) = with(inner, device_id, |p| p.outgoing.iter().find(|o| o.id == id && o.failed()).cloned()) else { return phone::error("invalid") };
            let answer = send(inner, device_id, &o.body, o.target.clone(), o.sub_id);
            if answer["ok"] == json!(true) {
                with(inner, device_id, |p| p.outgoing.retain(|x| x.id != id));
            }
            answer
        }
        Some("discard") => {
            let id = command.get("requestId").and_then(Value::as_str).unwrap_or("");
            with(inner, device_id, |p| p.outgoing.retain(|o| o.id != id));
            phone::ok(json!({}))
        }
        Some("image") => {
            let Some(part) = command.get("partId").and_then(Value::as_str).filter(|p| is_part_id(p)) else { return phone::error("invalid") };
            let queued = with(inner, device_id, |p| {
                if p.failed_images.contains(part) || p.images.iter().any(|x| x == part) || p.pending.values().any(|e| *e == Pending::Attachment { part: part.to_string() }) {
                    return false;
                }
                p.images.push_back(part.to_string());
                true
            });
            if queued {
                pump_images(inner, device_id);
            }
            phone::ok(json!({"queued": queued}))
        }
        Some("contacts") => {
            let id = crate::crypto::uuid4();
            if let Some(previous) = with(inner, device_id, |p| p.contacts_request.take()) {
                with(inner, device_id, |p| p.pending.remove(&previous));
            }
            let Some(payload) = contacts_request(&id, command.get("query").and_then(Value::as_str).unwrap_or("")) else { return phone::ok(json!({"searching": false})) };
            with(inner, device_id, |p| p.contacts_request = Some(id.clone()));
            if request(inner, device_id, "sms.contacts", payload, &id, Pending::Contacts) {
                return phone::ok(json!({"searching": true}));
            }
            with(inner, device_id, |p| p.contacts_request = None);
            phone::error("not_connected")
        }
        Some("mark_read") => {
            mark_read(inner, device_id, &thread_ids(command), command.get("report").and_then(Value::as_bool).unwrap_or(true));
            phone::ok(json!({}))
        }
        Some("mark_unread") => {
            with(inner, device_id, |p| thread_ids(command).into_iter().for_each(|t| p.cache.mark_unread(t)));
            persist(inner, device_id);
            changed(inner, device_id, json!({"threads": true}));
            phone::ok(json!({}))
        }
        Some("block") => {
            let address = command.get("address").and_then(Value::as_str).map(str::to_string);
            let id = crate::crypto::uuid4();
            if request(inner, device_id, "sms.blocked_numbers", blocked_numbers_request(&id, address.as_deref()), &id, Pending::Blocked { address: address.clone() }) {
                phone::ok(json!({}))
            } else {
                phone::error("not_connected")
            }
        }
        Some("forget") => {
            forget(inner, device_id);
            phone::ok(json!({}))
        }
        Some("keep") => {
            // Keep conversations on this device: off deletes what is stored (memory stays for this run).
            let on = command.get("on").and_then(Value::as_bool).unwrap_or(true);
            let phones: Vec<String> = {
                let mut st = inner.phone.sms.lock().unwrap();
                st.no_keep = !on;
                st.phones.keys().cloned().collect()
            };
            for id in phones {
                if on {
                    persist(inner, &id);
                } else {
                    let _ = inner.storage.remove(&storage_key(&id));
                }
            }
            phone::ok(json!({}))
        }
        _ => phone::error("invalid"),
    }
}

fn messages_json(inner: &Inner, device_id: &str, thread: i64) -> Value {
    with(inner, device_id, |p| {
        let summary = p.cache.thread(thread).map(|t| thread_json(t, p.cache.unread(t)));
        let messages: Vec<Value> = p.cache.messages_in(thread).iter().map(|m| serde_json::to_value(m).unwrap_or(Value::Null)).collect();
        let outgoing: Vec<Value> = p
            .outgoing
            .iter()
            .filter(|o| match &o.target {
                Target::Thread(t) => *t == thread,
                Target::Address(a) => summary.is_some() && p.cache.thread(thread).is_some_and(|t| t.participants.len() == 1 && same_number(&t.participants[0].address, a)),
                Target::Notification(_) => false,
            })
            .map(Outgoing::to_json)
            .collect();
        phone::ok(json!({
            "thread": summary,
            "messages": messages,
            "outgoing": outgoing,
            "older": p.cache.has_older(thread) && !p.cache.messages_in(thread).is_empty(),
            "loading": p.loading_messages.contains(&thread),
            "sims": p.status.as_ref().map(|s| s.sims.clone()).unwrap_or_default(),
            "canSend": p.status.as_ref().is_some_and(|s| s.send),
        }))
    })
}

fn send(inner: &Inner, device_id: &str, body: &str, target: Target, sub_id: Option<i64>) -> Value {
    let id = crate::crypto::uuid4();
    let Some(payload) = send_request(&id, body, &target, sub_id) else { return phone::error("invalid") };
    let o = Outgoing { id: id.clone(), target, body: body.to_string(), sub_id, created_ms: now_ms(), state: "sending".into(), reason: None, via: None };
    // Listed before it goes, so a quick answer finds it.
    with(inner, device_id, |p| {
        p.outgoing.push(o.clone());
        // Finished sends stay only while the phone's provider catches up.
        let now = now_ms();
        p.outgoing.retain(|x| !(x.is_final() && !x.failed() && now - x.created_ms > 600_000));
    });
    if !request(inner, device_id, "sms.send", payload, &id, Pending::Send) {
        with(inner, device_id, |p| p.outgoing.retain(|x| x.id != id));
        return phone::error("not_connected");
    }
    send_changed(inner, device_id, &o);
    phone::ok(json!({"requestId": id}))
}

/// Read here; for conversations the phone still counts unread, the phone runs the messaging app's own Mark as read.
fn mark_read(inner: &Inner, device_id: &str, threads: &[i64], report: bool) {
    let on_phone = with(inner, device_id, |p| {
        let mut on_phone = Vec::new();
        for id in threads {
            let Some(t) = p.cache.thread(*id).cloned() else { continue };
            let through = p.cache.newest_incoming_date(&t);
            p.cache.mark_read(*id, through);
            if t.unread > 0 {
                on_phone.push(*id);
            }
        }
        on_phone
    });
    persist(inner, device_id);
    changed(inner, device_id, json!({"threads": true}));
    for chunk in on_phone.chunks(MARK_READ_PER_REQUEST) {
        let id = crate::crypto::uuid4();
        let Some(payload) = mark_read_request(&id, chunk) else { continue };
        let entry = Pending::MarkRead { threads: chunk.to_vec() };
        if !request(inner, device_id, "sms.mark_read", payload, &id, entry) && report {
            notice(inner, device_id, json!({"kind": "mark_read", "total": chunk.len(), "noAnswer": true}));
        }
    }
}

pub(crate) fn features_changed(inner: &Inner, device_id: &str) {
    if inner.simulating.load(std::sync::atomic::Ordering::Relaxed) {
        sim_features(inner, device_id);
        return;
    }
    let local = inner.policy_for(device_id).get(FEATURE);
    let remote = inner.remote_features(device_id).map(|r| r.get(FEATURE));
    // Text messages off here, or the phone turned it off: what this device kept for the phone goes.
    if !local || remote == Some(false) {
        let kept = inner.phone.sms.lock().unwrap().phones.contains_key(device_id) || inner.storage.load(&storage_key(device_id)).ok().flatten().is_some();
        if kept {
            forget(inner, device_id);
        }
        return;
    }
    if remote == Some(true) {
        // The cache loads; the phone's sms.status (sent after each features.update) starts the sync.
        with(inner, device_id, |_| {});
        phone::emit(inner, Area::Sms, device_id, "status", 0, status_json(inner, device_id));
    }
}

pub(crate) fn disconnected(inner: &Inner, device_id: &str) {
    let failed = {
        let mut st = inner.phone.sms.lock().unwrap();
        let Some(p) = st.phones.get_mut(device_id) else { return };
        p.pending.clear();
        p.images.clear();
        p.status = None;
        p.loading_threads = false;
        p.loading_messages.clear();
        p.syncing = false;
        p.sync_pages = 0;
        p.contacts_request = None;
        let mut failed = Vec::new();
        for o in p.outgoing.iter_mut().filter(|o| o.state == "sending") {
            o.state = "failed".into();
            o.reason = Some("failed".into());
            failed.push(o.clone());
        }
        failed
    };
    flush(inner, device_id);
    for o in failed {
        send_changed(inner, device_id, &o);
    }
    phone::emit(inner, Area::Sms, device_id, "status", 0, status_json(inner, device_id));
}

pub(crate) fn forgotten(inner: &Inner, device_id: &str) {
    forget(inner, device_id);
}

// MARK: - A simulated phone (sim.rs): canned conversations for tests and the scripted peer

pub(crate) fn sim_incoming(kind: &str) -> Option<Incoming> {
    let (kind, max): (&'static str, usize) = match kind {
        "sms.threads" => ("sms.threads", SMALL),
        "sms.messages" => ("sms.messages", SMALL),
        "sms.sync" => ("sms.sync", SMALL),
        "sms.send" => ("sms.send", 8_192),
        "sms.attachment" => ("sms.attachment", SMALL),
        "sms.contacts" => ("sms.contacts", SMALL),
        "sms.mark_read" => ("sms.mark_read", MARK_READ_RESULT),
        "sms.blocked_numbers" => ("sms.blocked_numbers", SMALL),
        _ => return None,
    };
    Some(Incoming { area: Area::Sms, kind, feature: FEATURE, max, with_message_id: false })
}

/// The simulated phone's conversations (fixed, so tests know what to expect).
fn sim_threads() -> Vec<Value> {
    vec![
        json!({"threadId": 12, "participants": [{"address": "+447700900123", "name": "Asha"}], "snippet": "See you at 6", "date": 1_793_091_600_000i64, "unread": 2, "subId": 1}),
        json!({"threadId": 7, "participants": [{"address": "+447700900456", "name": "Ravi"}], "snippet": "Photo", "date": 1_793_091_500_000i64, "unread": 0}),
        json!({"threadId": 3, "participants": [{"address": "+447700900789"}, {"address": "+447700900790", "name": "Sam"}], "snippet": "Ok", "date": 1_793_091_400_000i64, "unread": 0}),
    ]
}

fn sim_messages(thread: i64) -> Vec<Value> {
    match thread {
        12 => vec![
            json!({"id": "s103", "threadId": 12, "direction": "in", "status": "received", "date": 1_793_091_600_000i64, "address": "+447700900123", "body": "See you at 6", "read": false}),
            json!({"id": "s102", "threadId": 12, "direction": "in", "status": "received", "date": 1_793_091_590_000i64, "address": "+447700900123", "body": "Are you coming?", "read": false}),
            json!({"id": "s101", "threadId": 12, "direction": "out", "status": "delivered", "date": 1_793_091_500_000i64, "address": "+447700900123", "body": "Running late"}),
        ],
        7 => vec![json!({"id": "m40", "threadId": 7, "direction": "in", "status": "received", "date": 1_793_091_500_000i64, "address": "+447700900456", "body": "", "parts": [{"partId": "p42", "mimeType": "image/png", "size": 70}]})],
        3 => vec![json!({"id": "s90", "threadId": 3, "direction": "in", "status": "received", "date": 1_793_091_400_000i64, "address": "+447700900790", "body": "Ok"})],
        _ => vec![],
    }
}

/// A 1 by 1 PNG.
const SIM_IMAGE: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

pub(crate) fn sim_receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) -> bool {
    let Some(spec) = sim_incoming(kind) else { return false };
    let Some(o) = phone::versioned(plain, spec.max) else { return true };
    let Some(id) = request_id(o.get("requestId")) else { return true };
    let reply = |kind: &'static str, v: Value| {
        let _ = inner.encrypted_to(device_id, FEATURE, kind, v.to_string());
    };
    match kind {
        "sms.threads" => {
            let before = integer(o.get("before"));
            let threads: Vec<Value> = sim_threads().into_iter().filter(|t| before.is_none_or(|b| t["date"].as_i64().unwrap_or(0) < b)).collect();
            reply("sms.threads_page", json!({"version": 1, "requestId": id, "threads": threads, "more": false}));
        }
        "sms.messages" => {
            let thread = integer(o.get("threadId")).unwrap_or(0);
            let messages = if o.get("before").is_some() { vec![] } else { sim_messages(thread) };
            reply("sms.messages_page", json!({"version": 1, "requestId": id, "threadId": thread, "messages": messages, "more": false}));
        }
        "sms.sync" => reply("sms.sync_page", json!({"version": 1, "requestId": id, "messages": [], "cursor": {"sms": 103, "mms": 40}, "more": false})),
        "sms.send" => {
            let refused = o.get("address").and_then(Value::as_str) == Some("112");
            if refused {
                reply("sms.send_status", json!({"version": 1, "requestId": id, "status": "refused", "reason": "invalid"}));
            } else {
                reply("sms.send_status", json!({"version": 1, "requestId": id, "status": "sent", "via": "sms"}));
                reply("sms.send_status", json!({"version": 1, "requestId": id, "status": "delivered", "via": "sms"}));
            }
        }
        "sms.attachment" => {
            let part = o.get("partId").and_then(Value::as_str).unwrap_or("");
            reply("sms.attachment_data", json!({"version": 1, "requestId": id, "partId": part, "mimeType": "image/png", "width": 1, "height": 1, "data": SIM_IMAGE}));
        }
        "sms.contacts" => reply("sms.contacts_result", json!({"version": 1, "requestId": id, "contacts": [{"name": "Asha", "address": "+447700900123", "label": "Mobile"}]})),
        "sms.mark_read" => {
            let results: Vec<Value> = o.get("threadIds").and_then(Value::as_array).map(|l| l.iter().map(|t| json!({"threadId": t, "result": "marked"})).collect()).unwrap_or_default();
            reply("sms.mark_read_result", json!({"version": 1, "requestId": id, "results": results}));
        }
        "sms.blocked_numbers" => reply("sms.blocked_numbers_result", json!({"version": 1, "requestId": id, "result": "notified"})),
        _ => return false,
    }
    true
}

/// The simulated phone tells a desktop that shows Text messages its status (after each features.update).
pub(crate) fn sim_features(inner: &Inner, device_id: &str) {
    if inner.policy_for(device_id).get(FEATURE) && inner.remote_features(device_id).is_some_and(|r| r.get(FEATURE)) {
        let status = json!({"version": 1, "read": true, "send": true, "contacts": true, "sims": [{"subId": 1, "slot": 0, "label": "EE"}], "cursor": {"sms": 103, "mms": 40}});
        let _ = inner.encrypted_to(device_id, FEATURE, "sms.status", status.to_string());
    }
}

#[cfg(test)]
mod tests;
