//! The Calls window (`dialer_draft1`, docs/protocol.md "Draft: Calls window") and calls from this device
//! (`calls.request`, upstream `calls.v1`), as the Mac does them (macos/Sources/BridgeyMac/DialerProtocol.swift,
//! PhoneCalls.swift, CallRequest.swift). The pattern every area follows is in `phone.rs`.
//!
//! - The wire: the phone's answers decoded as strictly as protocol/test-vectors/dialer-v1.json pins them, the requests
//!   this device writes, and the number check the callsRequest vectors of protocol-v1.json pin.
//! - The phone places every call; call audio stays on the phone or its earbuds. Contacts and recent calls are asked for
//!   while the window is open and kept in memory only. A search goes a moment after typing stops, and an answer to an
//!   older search is dropped. One call at a time, at most one every 3 seconds (the phone's own limit). A call to a
//!   phone with the Calls window off on either end goes as `calls.request` when both ends show `calls`.
//! - Never for agent devices (a map with `agent_draft1`).
//!
//! Host commands (`bridgey_phone`, area 2), each answered at once:
//!   state | recents {limit} | search {query} | rows {query, limit} | call {address, subId?, prefer?}
//!   | whatsapp {dataId, video}
//! Events (`BRIDGEY_EVENT_KIND_CALLS`): `changed` (status, contacts or recent calls: ask `state` again) and `call`
//! (`requestId`, `result` started, confirm, refused or no_answer, `reason`, `via`).
//!
//! Names and numbers are never logged.

use crate::client::Inner;
use crate::phone::{self, boolean, integer, non_negative, request_id, utf16_len, Area, Incoming};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

pub(crate) const FEATURE: &str = "dialer_draft1";
/// Upstream calls (`calls.request`).
pub(crate) const CALLS: &str = "calls";

const STATUS: usize = 2_048;
const CONTACTS_RESULT: usize = 16_384;
const RECENTS_RESULT: usize = 40_960;
const SMALL: usize = 1_024;
const QUERY: usize = 64;
const MAX_CONTACTS: usize = 20;
const MAX_NUMBERS: usize = 8;
const MAX_WHATSAPP: usize = 4;
const MAX_RECENTS: usize = 50;
const NAME: usize = 128;
const ADDRESS: usize = 64;
const LABEL: usize = 32;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(12);
/// A search goes to the phone this long after the last key.
const SEARCH_DELAY: Duration = Duration::from_millis(120);
/// A second call waits this long (the phone allows one every 3 seconds).
const CALL_SPACING: Duration = Duration::from_secs(3);
/// After a call starts, the phone's call log has it about this much later.
const RECENTS_AFTER_CALL: Duration = Duration::from_secs(5);

pub fn incoming(kind: &str) -> Option<Incoming> {
    let (kind, feature, max): (&'static str, &'static str, usize) = match kind {
        "dialer.status" => ("dialer.status", FEATURE, STATUS),
        "dialer.contacts_result" => ("dialer.contacts_result", FEATURE, CONTACTS_RESULT),
        "dialer.recents_result" => ("dialer.recents_result", FEATURE, RECENTS_RESULT),
        "dialer.call_result" => ("dialer.call_result", FEATURE, SMALL),
        // Outer only (session.rs hands over the message ID they echo).
        "calls.started" => ("calls.started", CALLS, 128),
        "calls.confirmation_required" => ("calls.confirmation_required", CALLS, 128),
        "calls.rejected" => ("calls.rejected", CALLS, 128),
        _ => return None,
    };
    Some(Incoming { area: Area::Calls, kind, feature, max, with_message_id: false })
}

// MARK: - Model

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sim {
    pub sub_id: i64,
    pub slot: i64,
    pub label: String,
}

/// The phone's last dialer.status.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    /// CALL_PHONE: a call starts without a tap on the phone.
    pub place: bool,
    /// The phone's Ask on this phone first is on.
    pub confirm: bool,
    /// on, off or unavailable.
    pub contacts: String,
    pub recents: String,
    pub whatsapp: bool,
    pub sims: Vec<Sim>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Number {
    pub address: String,
    pub label: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WhatsApp {
    pub address: String,
    pub voice: Option<i64>,
    pub video: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Contact {
    pub id: i64,
    pub name: String,
    pub starred: bool,
    pub numbers: Vec<Number>,
    pub whatsapp: Vec<WhatsApp>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Recent {
    pub id: i64,
    pub address: String,
    pub name: Option<String>,
    /// incoming, outgoing, missed, rejected, blocked or voicemail.
    pub kind: String,
    pub date: i64,
    pub duration: i64,
    pub sub_id: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContactsResult {
    pub request_id: String,
    pub contacts: Vec<Contact>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecentsResult {
    pub request_id: String,
    pub calls: Vec<Recent>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CallResult {
    pub request_id: String,
    /// started, confirm or refused.
    pub result: String,
    pub reason: Option<String>,
}

// MARK: - Decoding (phone to this device)

/// An optional field: absent or null, a value, or present with the wrong type (the whole entry is malformed).
enum Field<T> {
    Absent,
    Value(T),
    Invalid,
}

fn optional_string(value: Option<&Value>, max: usize) -> Field<String> {
    match value {
        None | Some(Value::Null) => Field::Absent,
        Some(Value::String(t)) if utf16_len(t) <= max => Field::Value(t.clone()),
        _ => Field::Invalid,
    }
}

fn optional_id(value: Option<&Value>) -> Field<i64> {
    match value {
        None | Some(Value::Null) => Field::Absent,
        Some(v) => match integer(Some(v)) {
            Some(n) if n >= 1 => Field::Value(n),
            _ => Field::Invalid,
        },
    }
}

fn dialer_error(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?;
    Some(if matches!(text, "disabled" | "permission" | "unavailable" | "rate_limited") { text } else { "unavailable" }.to_string())
}

/// on, off or unavailable; an unknown value reads as off.
fn access(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?;
    Some(if matches!(text, "on" | "off" | "unavailable") { text } else { "off" }.to_string())
}

/// `dialer.status`: every flag is required; more than 4 SIMs is malformed; an invalid SIM is dropped.
pub fn decode_status(plain: &[u8]) -> Option<Status> {
    let o = phone::versioned(plain, STATUS)?;
    let (place, confirm) = (boolean(o.get("place"))?, boolean(o.get("confirm"))?);
    let (contacts, recents) = (access(o.get("contacts"))?, access(o.get("recents"))?);
    let whatsapp = boolean(o.get("whatsapp"))?;
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
    Some(Status { place, confirm, contacts, recents, whatsapp, sims })
}

pub fn decode_contact(value: &Value) -> Option<Contact> {
    let o = value.as_object()?;
    let id = integer(o.get("id")).filter(|i| *i >= 1)?;
    let name = o.get("name")?.as_str().filter(|n| (1..=NAME).contains(&utf16_len(n)))?;
    let starred = match o.get("starred") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => return None,
    };
    let mut numbers = Vec::new();
    match o.get("numbers") {
        None | Some(Value::Null) => {}
        Some(Value::Array(list)) if list.len() <= MAX_NUMBERS => {
            for entry in list {
                let n = entry.as_object()?;
                let address = n.get("address")?.as_str().filter(|a| (1..=ADDRESS).contains(&utf16_len(a)))?;
                let label = match optional_string(n.get("label"), LABEL) {
                    Field::Invalid => return None,
                    Field::Absent => None,
                    Field::Value(l) => (!l.is_empty()).then_some(l),
                };
                numbers.push(Number { address: address.to_string(), label });
            }
        }
        Some(_) => return None,
    }
    let mut whatsapp = Vec::new();
    match o.get("whatsapp") {
        None | Some(Value::Null) => {}
        Some(Value::Array(list)) if list.len() <= MAX_WHATSAPP => {
            for entry in list {
                let row = entry.as_object()?;
                let address = row.get("address")?.as_str().filter(|a| utf16_len(a) <= ADDRESS)?;
                let voice = match optional_id(row.get("voice")) {
                    Field::Invalid => return None,
                    Field::Value(v) => Some(v),
                    Field::Absent => None,
                };
                let video = match optional_id(row.get("video")) {
                    Field::Invalid => return None,
                    Field::Value(v) => Some(v),
                    Field::Absent => None,
                };
                if voice.is_none() && video.is_none() {
                    return None;
                }
                whatsapp.push(WhatsApp { address: address.to_string(), voice, video });
            }
        }
        Some(_) => return None,
    }
    if numbers.is_empty() && whatsapp.is_empty() {
        return None;
    }
    Some(Contact { id, name: name.to_string(), starred, numbers, whatsapp })
}

/// `dialer.contacts_result`: more than 20 is malformed; an invalid contact is dropped; an error empties the list.
pub fn decode_contacts_result(plain: &[u8]) -> Option<ContactsResult> {
    let o = phone::versioned(plain, CONTACTS_RESULT)?;
    let request_id = request_id(o.get("requestId"))?;
    let list = o.get("contacts")?.as_array().filter(|l| l.len() <= MAX_CONTACTS)?;
    if let Some(error) = dialer_error(o.get("error")) {
        return Some(ContactsResult { request_id, contacts: vec![], error: Some(error) });
    }
    Some(ContactsResult { request_id, contacts: list.iter().filter_map(decode_contact).collect(), error: None })
}

pub fn decode_recent(value: &Value) -> Option<Recent> {
    let o = value.as_object()?;
    let id = integer(o.get("id")).filter(|i| *i >= 1)?;
    let address = o.get("address")?.as_str().filter(|a| utf16_len(a) <= ADDRESS)?;
    let raw = o.get("type")?.as_str()?;
    let (date, duration) = (non_negative(o.get("date"))?, non_negative(o.get("duration"))?);
    let name = match optional_string(o.get("name"), NAME) {
        Field::Invalid => return None,
        Field::Value(n) => (!n.is_empty()).then_some(n),
        Field::Absent => None,
    };
    let sub_id = match o.get("subId") {
        None | Some(Value::Null) => None,
        v => Some(non_negative(v).filter(|s| *s <= i64::from(i32::MAX))?),
    };
    let kind = if matches!(raw, "incoming" | "outgoing" | "missed" | "rejected" | "blocked" | "voicemail") { raw } else { "incoming" };
    Some(Recent { id, address: address.to_string(), name, kind: kind.to_string(), date, duration, sub_id })
}

/// `dialer.recents_result`: more than 50 is malformed; an invalid call is dropped; an error empties the list.
pub fn decode_recents_result(plain: &[u8]) -> Option<RecentsResult> {
    let o = phone::versioned(plain, RECENTS_RESULT)?;
    let request_id = request_id(o.get("requestId"))?;
    let list = o.get("calls")?.as_array().filter(|l| l.len() <= MAX_RECENTS)?;
    if let Some(error) = dialer_error(o.get("error")) {
        return Some(RecentsResult { request_id, calls: vec![], error: Some(error) });
    }
    Some(RecentsResult { request_id, calls: list.iter().filter_map(decode_recent).collect(), error: None })
}

/// `dialer.call_result`: an unknown result reads as refused, an unknown or missing reason as failed.
pub fn decode_call_result(plain: &[u8]) -> Option<CallResult> {
    let o = phone::versioned(plain, SMALL)?;
    let request_id = request_id(o.get("requestId"))?;
    let raw = o.get("result")?.as_str()?;
    let result = if matches!(raw, "started" | "confirm") { raw } else { "refused" };
    let reason = (result == "refused").then(|| {
        o.get("reason")
            .and_then(Value::as_str)
            .filter(|r| matches!(*r, "disabled" | "permission" | "invalid" | "emergency" | "no_sim" | "rate_limited" | "not_found" | "unavailable" | "failed"))
            .unwrap_or("failed")
            .to_string()
    });
    Some(CallResult { request_id, result: result.to_string(), reason })
}

// MARK: - Requests (this device to the phone)

/// The query as the phone takes it: trimmed and cut to 64 UTF-16 units (never in the middle of a character).
fn cut_query(query: &str) -> String {
    let mut out = String::new();
    let mut units = 0;
    for c in query.trim().chars() {
        units += c.len_utf16();
        if units > QUERY {
            break;
        }
        out.push(c);
    }
    out.trim_end().to_string()
}

pub fn contacts_request(id: &str, query: &str) -> Option<Value> {
    let query = cut_query(query);
    (!query.is_empty()).then(|| json!({"version": 1, "requestId": id, "query": query}))
}

pub fn recents_request(id: &str, limit: i64) -> Value {
    json!({"version": 1, "requestId": id, "limit": limit.clamp(1, MAX_RECENTS as i64)})
}

/// A call through the phone: the number as typed (the phone normalises it) and the SIM, when chosen. None for a number
/// the phone would refuse.
pub fn call_request(id: &str, number: &str, sub_id: Option<i64>) -> Option<Value> {
    normalized_number(number)?;
    let mut v = json!({"version": 1, "requestId": id, "via": "phone", "address": number});
    if let Some(sub) = sub_id.filter(|s| (0..=i64::from(i32::MAX)).contains(s)) {
        v["subId"] = json!(sub);
    }
    Some(v)
}

pub fn whatsapp_request(id: &str, data_id: i64, video: bool) -> Option<Value> {
    (data_id >= 1).then(|| json!({"version": 1, "requestId": id, "via": if video { "whatsapp_video" } else { "whatsapp_voice" }, "dataId": data_id}))
}

/// `calls.request`: the number as a string.
pub fn upstream_request(number: &str) -> Option<Value> {
    normalized_number(number)?;
    Some(json!({"number": number}))
}

/// The number the phone dials, or None: 3 to 15 ASCII digits with an optional leading +; spaces, brackets, dots and
/// hyphens are removed (CallRequest.swift `normalizedPhoneNumber`, the callsRequest vectors).
pub fn normalized_number(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || !trimmed.chars().all(|c| "+-(). 0123456789".contains(c)) {
        return None;
    }
    let pluses = trimmed.matches('+').count();
    if pluses > 1 || (pluses == 1 && !trimmed.starts_with('+')) {
        return None;
    }
    let digits: String = trimmed.chars().filter(char::is_ascii_digit).collect();
    if !(3..=15).contains(&digits.len()) {
        return None;
    }
    Some(if trimmed.starts_with('+') { format!("+{digits}") } else { digits })
}

// MARK: - The window's list (DialerProtocol.swift "Search")

fn digits(text: &str) -> String {
    text.chars().filter(char::is_ascii_digit).collect()
}

/// A recent call matches a name word that starts with the query, or a number that contains its digits.
pub fn recent_matches(call: &Recent, query: &str) -> bool {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return true;
    }
    let d = digits(trimmed);
    let significant = trimmed.chars().filter(|c| !c.is_whitespace() && !"+-().".contains(*c)).count();
    if d.len() >= 2 && d.len() == significant && digits(&call.address).contains(&d) {
        return true;
    }
    let Some(name) = &call.name else { return false };
    let lower = name.to_lowercase();
    let needle = trimmed.to_lowercase();
    lower.starts_with(&needle) || lower.split(|c: char| c.is_whitespace() || c == '-').any(|w| w.starts_with(&needle))
}

/// One row of the list: call what was typed, a contact, or a recent call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Row {
    Number(String),
    Contact(Contact),
    Recent(Recent),
}

impl Row {
    pub fn id(&self) -> String {
        match self {
            Row::Number(n) => format!("n:{n}"),
            Row::Contact(c) => format!("c:{}", c.id),
            Row::Recent(r) => format!("r:{}", r.id),
        }
    }

    /// The number a plain Call on this row dials.
    pub fn number(&self) -> Option<String> {
        match self {
            Row::Number(n) => Some(n.clone()),
            Row::Contact(c) => c.numbers.first().map(|n| n.address.clone()),
            Row::Recent(r) => (!r.address.is_empty()).then(|| r.address.clone()),
        }
    }
}

/// The list for `query`: recent calls when nothing is typed (the newest per number); otherwise a row to call a typed
/// number, the phone's matching contacts, then matching recent calls that are not those contacts' numbers.
pub fn rows(query: &str, contacts: &[Contact], recents: &[Recent], limit: usize) -> Vec<Row> {
    let trimmed = query.trim();
    let mut seen = HashSet::new();
    let newest: Vec<&Recent> = recents.iter().filter(|c| seen.insert(if c.address.is_empty() { format!("id:{}", c.id) } else { digits(&c.address) })).collect();
    if trimmed.is_empty() {
        return newest.into_iter().take(limit).cloned().map(Row::Recent).collect();
    }
    let mut out = Vec::new();
    let mut shown: HashSet<String> = contacts.iter().flat_map(|c| c.numbers.iter().map(|n| digits(&n.address))).collect();
    if normalized_number(trimmed).is_some() {
        out.push(Row::Number(trimmed.to_string()));
        shown.insert(digits(trimmed));
    }
    out.extend(contacts.iter().cloned().map(Row::Contact));
    out.extend(newest.into_iter().filter(|r| recent_matches(r, trimmed) && !shown.contains(&digits(&r.address))).take(limit).cloned().map(Row::Recent));
    out
}

/// The SIM a call uses: one SIM (or none listed) is the phone's default; a pick that is still on the phone wins; then
/// the preferred slot (`sim1`, `sim2`); otherwise this device asks (DialerProtocol.swift `callsSimDecision`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SimDecision {
    PhoneDefault,
    Use(i64),
    Ask,
}

pub fn sim_decision(prefer: &str, sims: &[Sim], picked: Option<i64>) -> SimDecision {
    if sims.len() < 2 {
        return SimDecision::PhoneDefault;
    }
    if let Some(p) = picked.filter(|p| sims.iter().any(|s| s.sub_id == *p)) {
        return SimDecision::Use(p);
    }
    let slot = match prefer {
        "sim1" => Some(0),
        "sim2" => Some(1),
        _ => None,
    };
    match slot.and_then(|slot| sims.iter().find(|s| s.slot == slot)) {
        Some(s) => SimDecision::Use(s.sub_id),
        None => SimDecision::Ask,
    }
}

// MARK: - The engine

#[derive(Clone, Debug, PartialEq, Eq)]
enum Pending {
    Contacts { query: String },
    Recents,
    /// A call, by the way it went (phone, whatsapp_voice, whatsapp_video, or calls for calls.request).
    Call { via: String },
}

#[derive(Default)]
struct PhoneData {
    status: Option<Status>,
    recents: Vec<Recent>,
    recents_loaded: bool,
    recents_error: Option<String>,
    loading_recents: bool,
    recents_limit: i64,
    contacts: Vec<Contact>,
    contacts_query: String,
    contacts_error: Option<String>,
    searching: bool,
    search_generation: u64,
    pending: HashMap<String, Pending>,
    calling: bool,
    last_call: Option<Instant>,
}

/// Every phone's Calls window state, by device ID. Memory only.
#[derive(Default)]
pub struct State {
    phones: HashMap<String, PhoneData>,
}

fn with<R>(inner: &Inner, device_id: &str, f: impl FnOnce(&mut PhoneData) -> R) -> R {
    let mut st = inner.phone.calls.lock().unwrap();
    f(st.phones.entry(device_id.to_string()).or_insert_with(|| PhoneData { recents_limit: 20, ..Default::default() }))
}

/// Both ends show `key` for this device, and it is not an agent.
fn both(inner: &Inner, device_id: &str, key: &str) -> bool {
    let Some(remote) = inner.remote_features(device_id) else { return false };
    !remote.get("agent_draft1") && remote.get(key) && inner.policy_for(device_id).get(key)
}

/// The Calls window is on here and on the phone, and the phone is connected.
fn available(inner: &Inner, device_id: &str) -> bool {
    both(inner, device_id, FEATURE)
}

fn changed(inner: &Inner, device_id: &str) {
    phone::emit(inner, Area::Calls, device_id, "changed", 0, json!({}));
}

fn call_event(inner: &Inner, device_id: &str, request_id: &str, result: &str, reason: Option<&str>, via: &str) {
    phone::emit(inner, Area::Calls, device_id, "call", 0, json!({"requestId": request_id, "result": result, "reason": reason, "via": via}));
}

/// Sends a dialer request, waiting for its answer for 12 s; false when it could not go.
fn request(inner: &Inner, device_id: &str, kind: &'static str, payload: Value, id: &str, entry: Pending) -> bool {
    if !available(inner, device_id) {
        return false;
    }
    with(inner, device_id, |p| p.pending.insert(id.to_string(), entry));
    if inner.encrypted_to(device_id, FEATURE, kind, payload.to_string()).is_err() {
        with(inner, device_id, |p| p.pending.remove(id));
        return false;
    }
    expire(inner, device_id, id);
    true
}

fn expire(inner: &Inner, device_id: &str, id: &str) {
    let (device, id) = (device_id.to_string(), id.to_string());
    phone::after(inner, REQUEST_TIMEOUT, move |inner| {
        let Some(entry) = with(inner, &device, |p| p.pending.remove(&id)) else { return };
        match entry {
            Pending::Call { via } => {
                with(inner, &device, |p| p.calling = false);
                call_event(inner, &device, &id, "no_answer", None, &via);
            }
            Pending::Contacts { .. } => with(inner, &device, |p| p.searching = false),
            Pending::Recents => with(inner, &device, |p| p.loading_recents = false),
        }
        changed(inner, &device);
    });
}

fn load_recents(inner: &Inner, device_id: &str) {
    let (go, limit) = with(inner, device_id, |p| {
        let on = p.status.as_ref().is_some_and(|s| s.recents == "on") && !p.pending.values().any(|e| *e == Pending::Recents);
        (on, p.recents_limit)
    });
    if !go {
        return;
    }
    let id = crate::crypto::uuid4();
    if request(inner, device_id, "dialer.recents", recents_request(&id, limit), &id, Pending::Recents) {
        with(inner, device_id, |p| p.loading_recents = true);
    }
}

fn search(inner: &Inner, device_id: &str, query: &str) {
    let trimmed = query.trim().to_string();
    let contacts_on = with(inner, device_id, |p| p.status.as_ref().is_some_and(|s| s.contacts == "on"));
    let generation = with(inner, device_id, |p| {
        p.search_generation += 1;
        if trimmed.is_empty() || !contacts_on {
            p.contacts.clear();
            p.contacts_query = trimmed.clone();
            p.contacts_error = None;
            p.searching = false;
            return None;
        }
        p.searching = true;
        Some(p.search_generation)
    });
    let Some(generation) = generation.filter(|_| available(inner, device_id)) else {
        with(inner, device_id, |p| p.searching = false);
        changed(inner, device_id);
        return;
    };
    let device = device_id.to_string();
    phone::after(inner, SEARCH_DELAY, move |inner| {
        if with(inner, &device, |p| p.search_generation) != generation {
            return;
        }
        let id = crate::crypto::uuid4();
        let Some(payload) = contacts_request(&id, &trimmed) else { return };
        if !request(inner, &device, "dialer.contacts", payload, &id, Pending::Contacts { query: trimmed.clone() }) {
            with(inner, &device, |p| p.searching = false);
            changed(inner, &device);
        }
    });
}

/// One call at a time, at most one every 3 seconds.
fn may_call(inner: &Inner, device_id: &str) -> Result<(), &'static str> {
    with(inner, device_id, |p| {
        if p.calling {
            return Err("busy");
        }
        if p.last_call.is_some_and(|t| t.elapsed() < CALL_SPACING) {
            return Err("too_soon");
        }
        Ok(())
    })
}

/// A call is on its way: marked before it goes, so a quick answer finds it.
fn start_call(inner: &Inner, device_id: &str) {
    with(inner, device_id, |p| {
        p.calling = true;
        p.last_call = Some(Instant::now());
    });
}

fn call_failed_to_go(inner: &Inner, device_id: &str) {
    with(inner, device_id, |p| {
        p.calling = false;
        p.last_call = None;
    });
}

fn call_sent(inner: &Inner, device_id: &str, id: &str, via: &str) -> Value {
    phone::emit(inner, Area::Calls, device_id, "call", 0, json!({"requestId": id, "result": "sent", "via": via}));
    phone::ok(json!({"requestId": id}))
}

fn call(inner: &Inner, device_id: &str, command: &Value) -> Value {
    let Some(address) = command.get("address").and_then(Value::as_str) else { return phone::error("invalid") };
    if normalized_number(address).is_none() {
        return phone::error("invalid");
    }
    if let Err(e) = may_call(inner, device_id) {
        return phone::error(e);
    }
    let id = crate::crypto::uuid4();
    if available(inner, device_id) {
        let sims = with(inner, device_id, |p| p.status.as_ref().map(|s| s.sims.clone()).unwrap_or_default());
        let prefer = command.get("prefer").and_then(Value::as_str).unwrap_or("ask");
        let sub = match sim_decision(prefer, &sims, command.get("subId").and_then(Value::as_i64)) {
            SimDecision::PhoneDefault => None,
            SimDecision::Use(s) => Some(s),
            SimDecision::Ask => {
                let list: Vec<Value> = sims.iter().map(|s| json!({"subId": s.sub_id, "slot": s.slot, "label": s.label})).collect();
                return json!({"ok": false, "error": "choose_sim", "sims": list});
            }
        };
        let Some(payload) = call_request(&id, address, sub) else { return phone::error("invalid") };
        start_call(inner, device_id);
        if !request(inner, device_id, "dialer.call", payload, &id, Pending::Call { via: "phone".into() }) {
            call_failed_to_go(inner, device_id);
            return phone::error("not_connected");
        }
        return call_sent(inner, device_id, &id, "phone");
    }
    // No Calls window at one end: the upstream call request, answered with outer-only messages echoing its ID.
    if !both(inner, device_id, CALLS) {
        return phone::error("feature_off");
    }
    let Some(payload) = upstream_request(address) else { return phone::error("invalid") };
    let Ok((handle, _)) = inner.feature_session(device_id, CALLS) else { return phone::error("not_connected") };
    start_call(inner, device_id);
    with(inner, device_id, |p| p.pending.insert(id.clone(), Pending::Call { via: "calls".into() }));
    if !handle.send_encrypted("calls.request", payload.to_string().into_bytes(), id.clone()) {
        with(inner, device_id, |p| p.pending.remove(&id));
        call_failed_to_go(inner, device_id);
        return phone::error("not_connected");
    }
    expire(inner, device_id, &id);
    call_sent(inner, device_id, &id, "calls")
}

fn whatsapp(inner: &Inner, device_id: &str, command: &Value) -> Value {
    let video = command.get("video").and_then(Value::as_bool).unwrap_or(false);
    let id = crate::crypto::uuid4();
    let Some(payload) = whatsapp_request(&id, command.get("dataId").and_then(Value::as_i64).unwrap_or(0), video) else { return phone::error("invalid") };
    if !available(inner, device_id) {
        return phone::error("feature_off");
    }
    if let Err(e) = may_call(inner, device_id) {
        return phone::error(e);
    }
    let via = if video { "whatsapp_video" } else { "whatsapp_voice" };
    start_call(inner, device_id);
    if !request(inner, device_id, "dialer.call", payload, &id, Pending::Call { via: via.into() }) {
        call_failed_to_go(inner, device_id);
        return phone::error("not_connected");
    }
    call_sent(inner, device_id, &id, via)
}

fn call_answered(inner: &Inner, device_id: &str, request_id: &str, result: &str, reason: Option<&str>) {
    let Some(Pending::Call { via }) = with(inner, device_id, |p| match p.pending.get(request_id) {
        Some(Pending::Call { .. }) => {
            p.calling = false;
            p.pending.remove(request_id)
        }
        _ => None,
    }) else {
        return;
    };
    call_event(inner, device_id, request_id, result, reason, &via);
    // The new call shows in the phone's call log once it starts.
    if result != "refused" {
        let device = device_id.to_string();
        phone::after(inner, RECENTS_AFTER_CALL, move |inner| load_recents(inner, &device));
    }
}

pub(crate) fn receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) {
    match kind {
        "dialer.status" => {
            let Some(status) = decode_status(plain) else { return };
            let load = with(inner, device_id, |p| {
                let first = p.status.is_none();
                if status.recents != "on" {
                    p.recents.clear();
                    p.recents_loaded = false;
                }
                p.status = Some(status);
                first || !p.recents_loaded
            });
            if load {
                load_recents(inner, device_id);
            }
            changed(inner, device_id);
        }
        "dialer.contacts_result" => {
            let Some(r) = decode_contacts_result(plain) else { return };
            let ok = with(inner, device_id, |p| {
                let Some(Pending::Contacts { query }) = p.pending.get(&r.request_id).cloned() else { return false };
                p.pending.remove(&r.request_id);
                p.contacts = r.contacts.clone();
                p.contacts_query = query;
                p.contacts_error = r.error.clone();
                if !p.pending.values().any(|e| matches!(e, Pending::Contacts { .. })) {
                    p.searching = false;
                }
                true
            });
            if ok {
                changed(inner, device_id);
            }
        }
        "dialer.recents_result" => {
            let Some(r) = decode_recents_result(plain) else { return };
            let ok = with(inner, device_id, |p| {
                if p.pending.get(&r.request_id) != Some(&Pending::Recents) {
                    return false;
                }
                p.pending.remove(&r.request_id);
                p.loading_recents = false;
                p.recents_error = r.error.clone();
                if r.error.is_none() {
                    let mut calls = r.calls.clone();
                    calls.sort_by_key(|c| std::cmp::Reverse(c.date));
                    p.recents = calls;
                    p.recents_loaded = true;
                }
                true
            });
            if ok {
                changed(inner, device_id);
            }
        }
        "dialer.call_result" => {
            let Some(r) = decode_call_result(plain) else { return };
            call_answered(inner, device_id, &r.request_id, &r.result, r.reason.as_deref());
        }
        "calls.started" | "calls.confirmation_required" | "calls.rejected" => {
            let Ok(request_id) = std::str::from_utf8(plain) else { return };
            let (result, reason) = match kind {
                "calls.started" => ("started", None),
                "calls.confirmation_required" => ("confirm", None),
                _ => ("refused", Some("failed")),
            };
            call_answered(inner, device_id, request_id, result, reason);
        }
        _ => {}
    }
}

fn contact_json(c: &Contact) -> Value {
    json!({
        "id": c.id, "name": c.name, "starred": c.starred,
        "numbers": c.numbers.iter().map(|n| json!({"address": n.address, "label": n.label})).collect::<Vec<_>>(),
        "whatsapp": c.whatsapp.iter().map(|w| json!({"address": w.address, "voice": w.voice, "video": w.video})).collect::<Vec<_>>(),
    })
}

fn recent_json(r: &Recent) -> Value {
    json!({"id": r.id, "address": r.address, "name": r.name, "type": r.kind, "date": r.date, "duration": r.duration, "subId": r.sub_id})
}

fn row_json(row: &Row) -> Value {
    let mut v = match row {
        Row::Number(n) => json!({"kind": "number", "address": n}),
        Row::Contact(c) => {
            let mut v = contact_json(c);
            v["kind"] = json!("contact");
            v
        }
        Row::Recent(r) => {
            let mut v = recent_json(r);
            v["kind"] = json!("recent");
            v
        }
    };
    v["rowId"] = json!(row.id());
    v["number"] = json!(row.number());
    v
}

fn state_json(inner: &Inner, device_id: &str) -> Value {
    let (on, upstream) = (available(inner, device_id), both(inner, device_id, CALLS));
    with(inner, device_id, |p| {
        let mut o = Map::new();
        o.insert("available".into(), json!(on));
        o.insert("upstream".into(), json!(upstream));
        o.insert(
            "phone".into(),
            p.status.as_ref().map(|s| {
                json!({"place": s.place, "confirm": s.confirm, "contacts": s.contacts, "recents": s.recents, "whatsapp": s.whatsapp,
                       "sims": s.sims.iter().map(|x| json!({"subId": x.sub_id, "slot": x.slot, "label": x.label})).collect::<Vec<_>>()})
            }).unwrap_or(Value::Null),
        );
        o.insert("recents".into(), json!(p.recents.iter().map(recent_json).collect::<Vec<_>>()));
        o.insert("recentsLoaded".into(), json!(p.recents_loaded));
        o.insert("recentsError".into(), json!(p.recents_error));
        o.insert("loadingRecents".into(), json!(p.loading_recents));
        o.insert("contacts".into(), json!(p.contacts.iter().map(contact_json).collect::<Vec<_>>()));
        o.insert("contactsQuery".into(), json!(p.contacts_query));
        o.insert("contactsError".into(), json!(p.contacts_error));
        o.insert("searching".into(), json!(p.searching));
        o.insert("calling".into(), json!(p.calling));
        phone::ok(Value::Object(o))
    })
}

pub(crate) fn command(inner: &Inner, device_id: &str, command: &Value) -> Value {
    match phone::op(command) {
        Some("state") => state_json(inner, device_id),
        Some("recents") => {
            if let Some(limit) = command.get("limit").and_then(Value::as_i64) {
                with(inner, device_id, |p| p.recents_limit = limit.clamp(1, MAX_RECENTS as i64));
            }
            if !available(inner, device_id) {
                return phone::error("feature_off");
            }
            load_recents(inner, device_id);
            phone::ok(json!({}))
        }
        Some("search") => {
            search(inner, device_id, command.get("query").and_then(Value::as_str).unwrap_or(""));
            phone::ok(json!({}))
        }
        Some("rows") => {
            let query = command.get("query").and_then(Value::as_str).unwrap_or("");
            let limit = command.get("limit").and_then(Value::as_u64).unwrap_or(20).clamp(1, 50) as usize;
            with(inner, device_id, |p| {
                // Contacts only for the query they answered.
                let contacts = if p.contacts_query == query.trim() { p.contacts.clone() } else { vec![] };
                let list: Vec<Value> = rows(query, &contacts, &p.recents, limit).iter().map(row_json).collect();
                phone::ok(json!({"rows": list, "searching": p.searching}))
            })
        }
        Some("call") => call(inner, device_id, command),
        Some("whatsapp") => whatsapp(inner, device_id, command),
        _ => phone::error("invalid"),
    }
}

pub(crate) fn features_changed(inner: &Inner, device_id: &str) {
    if inner.simulating.load(std::sync::atomic::Ordering::Relaxed) {
        sim_features(inner, device_id);
        return;
    }
    // The Calls window off at either end, or an agent: what the window kept goes. A call already on its way as a
    // calls.request keeps waiting for its answer while calls stay on at both ends.
    if available(inner, device_id) {
        return;
    }
    let upstream = both(inner, device_id, CALLS);
    let had = {
        let mut st = inner.phone.calls.lock().unwrap();
        if !upstream {
            st.phones.remove(device_id).is_some()
        } else if let Some(p) = st.phones.get_mut(device_id) {
            p.status = None;
            p.recents.clear();
            p.recents_loaded = false;
            p.recents_error = None;
            p.loading_recents = false;
            p.contacts.clear();
            p.contacts_query.clear();
            p.contacts_error = None;
            p.searching = false;
            p.pending.retain(|_, e| matches!(e, Pending::Call { via } if via == "calls"));
            true
        } else {
            false
        }
    };
    if had {
        changed(inner, device_id);
    }
}

pub(crate) fn disconnected(inner: &Inner, device_id: &str) {
    let had = {
        let mut st = inner.phone.calls.lock().unwrap();
        match st.phones.get_mut(device_id) {
            Some(p) => {
                p.pending.clear();
                p.status = None;
                p.loading_recents = false;
                p.searching = false;
                p.calling = false;
                true
            }
            None => false,
        }
    };
    if had {
        changed(inner, device_id);
    }
}

pub(crate) fn forgotten(inner: &Inner, device_id: &str) {
    inner.phone.calls.lock().unwrap().phones.remove(device_id);
}

// MARK: - A simulated phone (sim.rs): a canned address book and call log for tests and the scripted peer

pub(crate) fn sim_incoming(kind: &str) -> Option<Incoming> {
    let (kind, feature, with_message_id): (&'static str, &'static str, bool) = match kind {
        "dialer.contacts" => ("dialer.contacts", FEATURE, false),
        "dialer.recents" => ("dialer.recents", FEATURE, false),
        "dialer.call" => ("dialer.call", FEATURE, false),
        "calls.request" => ("calls.request", CALLS, true),
        _ => return None,
    };
    Some(Incoming { area: Area::Calls, kind, feature, max: SMALL, with_message_id })
}

fn sim_contacts() -> Vec<Value> {
    vec![
        json!({"id": 7, "name": "Anna Kapoor", "starred": true, "numbers": [{"address": "+44 7700 900123", "label": "Mobile"}], "whatsapp": [{"address": "+447700900123", "voice": 4211, "video": 4212}]}),
        json!({"id": 9, "name": "Rohan Mehta", "numbers": [{"address": "+44 20 7946 0000", "label": "Work"}]}),
    ]
}

fn sim_recents() -> Vec<Value> {
    vec![
        json!({"id": 501, "address": "+447700900123", "name": "Anna Kapoor", "type": "outgoing", "date": 1_793_091_600_000i64, "duration": 184, "subId": 1}),
        json!({"id": 500, "address": "", "type": "missed", "date": 1_793_091_000_000i64, "duration": 0}),
        json!({"id": 499, "address": "+442079460000", "name": "Rohan Mehta", "type": "incoming", "date": 1_793_090_000_000i64, "duration": 45}),
    ]
}

pub(crate) fn sim_receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) -> bool {
    let Some(spec) = sim_incoming(kind) else { return false };
    if kind == "calls.request" {
        // The phone answers with the request's own message ID: 112 is refused, anything else waits for a tap.
        let Ok(Value::Object(o)) = serde_json::from_slice::<Value>(plain) else { return true };
        let (Some(id), Some(text)) = (o.get("messageId").and_then(Value::as_str), o.get("plaintext").and_then(Value::as_str)) else { return true };
        let number = serde_json::from_str::<Value>(text).ok().and_then(|v| v.get("number").and_then(Value::as_str).map(str::to_string));
        let answer = match number.as_deref().and_then(normalized_number) {
            Some(n) if n == "112" => "calls.rejected",
            Some(_) => "calls.confirmation_required",
            None => "calls.rejected",
        };
        // A phone answers whether or not this device's map has arrived yet.
        if let Ok(handle) = inner.connected_session(device_id) {
            handle.send_plain(answer, id.to_string());
        }
        return true;
    }
    let Some(o) = phone::versioned(plain, spec.max) else { return true };
    let Some(id) = request_id(o.get("requestId")) else { return true };
    let reply = |kind: &'static str, v: Value| {
        let _ = inner.encrypted_to(device_id, FEATURE, kind, v.to_string());
    };
    match kind {
        "dialer.contacts" => {
            let query = o.get("query").and_then(Value::as_str).unwrap_or("").to_lowercase();
            let found: Vec<Value> = sim_contacts().into_iter().filter(|c| c["name"].as_str().unwrap_or("").to_lowercase().split(' ').any(|w| w.starts_with(&query))).collect();
            reply("dialer.contacts_result", json!({"version": 1, "requestId": id, "contacts": found}));
        }
        "dialer.recents" => reply("dialer.recents_result", json!({"version": 1, "requestId": id, "calls": sim_recents()})),
        "dialer.call" => {
            let via = o.get("via").and_then(Value::as_str).unwrap_or("");
            let address = o.get("address").and_then(Value::as_str).and_then(normalized_number);
            let result = match (via, address.as_deref()) {
                ("phone", Some("112")) => json!({"version": 1, "requestId": id, "result": "refused", "reason": "emergency"}),
                ("phone", Some(_)) => json!({"version": 1, "requestId": id, "result": "started"}),
                ("whatsapp_voice" | "whatsapp_video", _) => json!({"version": 1, "requestId": id, "result": "confirm"}),
                _ => json!({"version": 1, "requestId": id, "result": "refused", "reason": "invalid"}),
            };
            reply("dialer.call_result", result);
        }
        _ => return false,
    }
    true
}

/// The simulated phone tells a desktop that shows the Calls window what it allows (after each features.update).
pub(crate) fn sim_features(inner: &Inner, device_id: &str) {
    if available(inner, device_id) {
        let status = json!({"version": 1, "place": true, "confirm": false, "contacts": "on", "recents": "on", "whatsapp": true,
                            "sims": [{"subId": 1, "slot": 0, "label": "EE"}, {"subId": 2, "slot": 1, "label": "Vodafone"}]});
        let _ = inner.encrypted_to(device_id, FEATURE, "dialer.status", status.to_string());
    }
}

#[cfg(test)]
mod tests;
