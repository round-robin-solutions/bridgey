//! The phone's screen on this device (`screen_draft1`) and control of the phone from it (`phone_control_draft1`,
//! docs/protocol.md "Phone screen to Mac" and "Mac controls the phone"), as the Mac does it (PhoneScreen*.swift,
//! PhoneControlProtocol.swift, PhoneControlSender.swift). The pattern every area follows is in `phone.rs`.
//!
//! - Asking: `screen.request`, one open request per phone, at most one every 3 s, expiring after 2 minutes; the
//!   phone's `screen.status` (with `needs` when it allows this device without asking but cannot share yet).
//! - A stream: `screen.start` checked as the golden vectors pin it, `screen.started` at once, the phone's messages in
//!   its own sequence (outside the shared messageId window), the last 1,024 ended stream IDs refused, frames put back
//!   together from their parts, every complete frame acknowledged once the host has taken it (frames dropped while
//!   waiting for a key frame at once), a key frame asked for at most once a second, `screen.stats`, `screen.stop` both
//!   ways, 6 s without a frame or stats ends it, a disconnect ends it here.
//! - Frames never go through the event queue: the host pulls each whole H.264 access unit (Annex B) with
//!   `bridgey_screen_frame`. A stream keeps at most 8 waiting; when the host falls behind they go and the stream waits
//!   for the next key frame.
//! - Control: `screen.control` begin and end, the phone's states, and `screen.input` packets of the shared contract
//!   (`bridgey_connect_proto::screen_control`) from host commands: numbered only when they go, motion and scrolling
//!   coalesced, transitions never dropped once numbered, a little under 120 motion, 20 discrete and 10 control packets
//!   a second, a heartbeat every 2 s, `geometry_ack` first and after every `screen.geometry`, which drops what has not
//!   gone. Stop is never rate limited.
//!
//! Host commands (`bridgey_phone`, area 4): status | request | stop | decoded {ms} | keyframe | control_begin
//!   | control_end | touch {contact, phase, x, y} | scroll {dx, dy, x, y} | navigate {action} | text {text}
//!   | key {key, down} | press {key, shift}. Positions are fractions of the phone's whole screen.
//! Events (`BRIDGEY_EVENT_KIND_SCREEN`, id = the stream): `status` (the phone's answer, or `expired`), `started`
//! (open a window and pull frames), `stats`, `geometry`, `control`, `stopped`.

use crate::client::Inner;
use crate::phone::{self, boolean, integer, request_id, Area, Incoming};
use bridgey_connect_proto::screen_control as sc;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub(crate) const FEATURE: &str = "screen_draft1";
pub(crate) const CONTROL: &str = "phone_control_draft1";

const MESSAGE: usize = 512;
const START: usize = 1_024;
const HEADER: usize = 40;
const PART: usize = 32_768;
const MAX_PARTS: u16 = 64;
const MAX_SEQUENCE: u64 = 9_007_199_254_740_991;
const REQUEST_LIFETIME: Duration = Duration::from_secs(120);
const REQUEST_SPACING: Duration = Duration::from_secs(3);
const STREAM_TIMEOUT: Duration = Duration::from_secs(6);
/// Ended streams stay refused, so a recorded stream replayed in the same connection is never shown as live (the Mac
/// keeps 1,024 since its 1.0 security review).
const REMEMBERED: usize = 1_024;
/// Frames waiting for the host; more and they go, and the stream waits for a key frame.
const QUEUED: usize = 8;
const KEY_SPACING: Duration = Duration::from_secs(1);
const FLUSH_EVERY: Duration = Duration::from_millis(16);

pub fn incoming(kind: &str) -> Option<Incoming> {
    let (kind, feature, max): (&'static str, &'static str, usize) = match kind {
        "screen.status" => ("screen.status", FEATURE, MESSAGE),
        "screen.start" => ("screen.start", FEATURE, START),
        "screen.frame" => ("screen.frame", FEATURE, HEADER + PART),
        "screen.stats" => ("screen.stats", FEATURE, MESSAGE),
        "screen.stop" => ("screen.stop", FEATURE, MESSAGE),
        "screen.geometry" => ("screen.geometry", CONTROL, MESSAGE),
        "screen.control" => ("screen.control", CONTROL, MESSAGE),
        _ => return None,
    };
    Some(Incoming { area: Area::Screen, kind, feature, max, with_message_id: false })
}

/// Stream messages: outside the shared messageId window, each side numbers its own per stream.
pub fn is_stream(kind: &str) -> bool {
    matches!(kind, "screen.start" | "screen.started" | "screen.frame" | "screen.ack" | "screen.stats" | "screen.stop" | "screen.geometry" | "screen.control" | "screen.input")
}

// MARK: - The wire

fn object(plain: &[u8], limit: usize) -> Option<Map<String, Value>> {
    phone::versioned(plain, limit)
}

fn ranged(o: &Map<String, Value>, key: &str, min: i64, max: i64) -> Option<i64> {
    integer(o.get(key)).filter(|v| (min..=max).contains(v))
}

/// A contract counter: 1 to 2^53-1.
fn counter(value: Option<&Value>) -> Option<u64> {
    integer(value).filter(|v| *v >= 1 && *v as u64 <= MAX_SEQUENCE).map(|v| v as u64)
}

/// The stream and the sender's sequence every stream message carries.
fn header(o: &Map<String, Value>) -> Option<(String, u64)> {
    Some((request_id(o.get("streamId"))?, counter(o.get("sequence"))?))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub request_id: String,
    /// waiting, declined, busy, disabled or failed.
    pub status: String,
    /// With `waiting` only: accessibility, android_11 or unlock.
    pub needs: Option<String>,
}

/// `screen.status`: at most 512 bytes, a UUID `requestId` and a known `status`; `needs` is read only with `waiting`
/// and an unknown value is ignored.
pub fn decode_status(plain: &[u8]) -> Option<Status> {
    let o = object(plain, MESSAGE)?;
    let request_id = request_id(o.get("requestId"))?;
    let status = o.get("status")?.as_str().filter(|s| matches!(*s, "waiting" | "declined" | "busy" | "disabled" | "failed"))?.to_string();
    let needs = (status == "waiting").then(|| o.get("needs").and_then(Value::as_str).filter(|n| matches!(*n, "accessibility" | "android_11" | "unlock")).map(str::to_string)).flatten();
    Some(Status { request_id, status, needs })
}

pub fn request_payload(id: &str) -> Value {
    json!({"version": 1, "requestId": id})
}

/// The control object of a control-capable `screen.start` (phone_control_draft1).
#[derive(Clone, Debug, PartialEq)]
pub struct Offer {
    pub stream: u64,
    pub transport: u64,
    pub geometry: sc::Geometry,
    pub capabilities: sc::Capabilities,
    /// Control may be asked for now (the phone's accessibility service is on).
    pub allowed: bool,
}

/// A geometry a phone stream may use: valid, a display, even sides of at least 16 pixels, unknown fields refused.
pub fn stream_geometry(value: Option<&Value>) -> Option<sc::Geometry> {
    let g: sc::Geometry = serde_json::from_value(value?.clone()).ok()?;
    (g.valid() && g.kind == sc::SourceKind::Display && g.width >= 16 && g.height >= 16 && g.width.is_multiple_of(2) && g.height.is_multiple_of(2)).then_some(g)
}

/// The contract's capabilities: missing flags false, unknown ones ignored, any `v` but 1 refused.
pub fn capabilities(value: Option<&Value>) -> Option<sc::Capabilities> {
    let c: sc::Capabilities = serde_json::from_value(value?.clone()).ok()?;
    (c.v == sc::VERSION).then_some(c)
}

/// None, so the stream is view only, when the object is missing or breaks any rule (its geometry is the stream's size).
pub fn decode_offer(value: Option<&Value>, width: u32, height: u32) -> Option<Offer> {
    let o = value?.as_object()?;
    let stream = counter(o.get("stream"))?;
    let transport = counter(o.get("transport"))?;
    let geometry = stream_geometry(o.get("geometry")).filter(|g| g.width == width && g.height == height)?;
    let capabilities = capabilities(o.get("capabilities"))?;
    let allowed = boolean(o.get("allowed"))?;
    Some(Offer { stream, transport, geometry, capabilities, allowed })
}

#[derive(Clone, Debug, PartialEq)]
pub struct Start {
    pub stream_id: String,
    pub sequence: u64,
    pub request_id: Option<String>,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub bitrate: u64,
    pub control: Option<Offer>,
    /// `mode: screenshots`: unattended access sends accessibility screenshots, about 3 a second ("Slower mode").
    pub screenshots: bool,
}

/// `screen.start`: at most 1,024 bytes; codec `h264`; even sizes from 16 to 4,096; 1 to 60 fps; 100 kb/s to 50 Mb/s.
pub fn decode_start(plain: &[u8]) -> Option<Start> {
    let o = object(plain, START)?;
    let (stream_id, sequence) = header(&o)?;
    if o.get("codec")?.as_str()? != "h264" {
        return None;
    }
    let width = ranged(&o, "width", 16, 4_096).filter(|w| w % 2 == 0)? as u32;
    let height = ranged(&o, "height", 16, 4_096).filter(|h| h % 2 == 0)? as u32;
    let fps = ranged(&o, "fps", 1, 60)? as u32;
    let bitrate = ranged(&o, "bitrate", 100_000, 50_000_000)? as u64;
    let request_id = match o.get("requestId") {
        None | Some(Value::Null) => None,
        Some(v) => Some(request_id(Some(v))?),
    };
    Some(Start {
        stream_id,
        sequence,
        request_id,
        width,
        height,
        fps,
        bitrate,
        control: decode_offer(o.get("control"), width, height),
        screenshots: o.get("mode").and_then(Value::as_str) == Some("screenshots"),
    })
}

/// The stream a start that failed its checks names, so this device can answer `invalid`.
pub fn start_stream_id(plain: &[u8]) -> Option<String> {
    if plain.len() > START {
        return None;
    }
    request_id(phone::strict(plain)?.get("streamId"))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stats {
    pub stream_id: String,
    pub sequence: u64,
    pub latency_ms: i64,
    pub rtt_ms: i64,
    pub bitrate: i64,
    pub sent_bitrate: i64,
    pub fps: i64,
    pub dropped: i64,
}

pub fn decode_stats(plain: &[u8]) -> Option<Stats> {
    let o = object(plain, MESSAGE)?;
    let (stream_id, sequence) = header(&o)?;
    Some(Stats {
        stream_id,
        sequence,
        latency_ms: ranged(&o, "latencyMs", 0, 60_000)?,
        rtt_ms: ranged(&o, "rttMs", 0, 60_000)?,
        bitrate: ranged(&o, "bitrate", 0, 50_000_000)?,
        sent_bitrate: ranged(&o, "sentBitrate", 0, 50_000_000)?,
        fps: ranged(&o, "fps", 0, 120)?,
        dropped: ranged(&o, "dropped", 0, 1_000)?,
    })
}

const STOP_REASONS: [&str; 8] = ["user", "closed", "ended", "screen_off", "disabled", "invalid", "timeout", "failed"];

/// `screen.stop`: an unknown or missing reason reads as `failed`.
pub fn decode_stop(plain: &[u8]) -> Option<(String, u64, String)> {
    let o = object(plain, MESSAGE)?;
    let (stream_id, sequence) = header(&o)?;
    let reason = o.get("reason").and_then(Value::as_str).filter(|r| STOP_REASONS.contains(r)).unwrap_or("failed");
    Some((stream_id, sequence, reason.to_string()))
}

pub fn started_payload(stream_id: &str, sequence: u64) -> Value {
    json!({"version": 1, "streamId": stream_id, "sequence": sequence})
}

/// `keyframe` is written only when true.
pub fn ack_payload(stream_id: &str, sequence: u64, frame: u32, decode_ms: u32, keyframe: bool) -> Value {
    let mut v = json!({"version": 1, "streamId": stream_id, "sequence": sequence, "frame": frame, "decodeMs": decode_ms.min(60_000)});
    if keyframe {
        v["keyframe"] = json!(true);
    }
    v
}

pub fn stop_payload(stream_id: &str, sequence: u64, reason: &str) -> Value {
    json!({"version": 1, "streamId": stream_id, "sequence": sequence, "reason": reason})
}

/// What this device can do as a viewer and controller of a phone: H.264 decoding, touch, a pointer (scrolling), keys,
/// text and navigation. Support, never permission.
pub fn controller_capabilities() -> sc::Capabilities {
    sc::Capabilities {
        v: sc::VERSION,
        screen_viewer: true,
        h264_decode: true,
        input_controller: sc::InputCapabilities { pointer: true, touch: true, keys: true, text: true, navigation: true },
        ..Default::default()
    }
}

pub fn control_begin_payload(stream_id: &str, sequence: u64) -> Value {
    json!({"version": 1, "streamId": stream_id, "sequence": sequence, "action": "begin", "capabilities": controller_capabilities()})
}

pub fn control_end_payload(stream_id: &str, sequence: u64) -> Value {
    json!({"version": 1, "streamId": stream_id, "sequence": sequence, "action": "end"})
}

/// `screen.geometry`: a new generation of the phone's display (it rotated or changed size).
pub fn decode_geometry(plain: &[u8]) -> Option<(String, u64, sc::Geometry)> {
    let o = object(plain, MESSAGE)?;
    let (stream_id, sequence) = header(&o)?;
    Some((stream_id, sequence, stream_geometry(o.get("geometry"))?))
}

const CONTROL_REASONS: [&str; 12] = ["user", "local_stop", "declined", "disabled", "permission", "locked", "focus", "timeout", "rate", "invalid", "source_changed", "failed"];

/// What the phone says about control.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlState {
    Waiting,
    Active { session: u64, input: sc::InputCapabilities },
    Ended(String),
    Refused(String),
    Available(bool),
}

/// `screen.control` from the phone; None for anything malformed or an unknown state (dropped, never answered).
pub fn decode_control(plain: &[u8]) -> Option<(String, u64, ControlState)> {
    let o = object(plain, MESSAGE)?;
    let (stream_id, sequence) = header(&o)?;
    let state = match o.get("state")?.as_str()? {
        "waiting" => ControlState::Waiting,
        "active" => ControlState::Active { session: counter(o.get("session"))?, input: serde_json::from_value(o.get("input")?.clone()).ok()? },
        s @ ("ended" | "refused") => {
            let reason = o.get("reason").and_then(Value::as_str).filter(|r| CONTROL_REASONS.contains(r)).unwrap_or("failed").to_string();
            if s == "ended" {
                ControlState::Ended(reason)
            } else {
                ControlState::Refused(reason)
            }
        }
        "available" => ControlState::Available(boolean(o.get("allowed"))?),
        _ => return None,
    };
    Some((stream_id, sequence, state))
}

// MARK: - Frames

/// One `screen.frame` plaintext: the 40-byte header and its H.264 Annex B bytes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Part {
    pub stream_id: String,
    pub sequence: u64,
    pub frame: u32,
    pub part: u16,
    pub key: bool,
    pub parameter_sets: bool,
    pub last: bool,
    pub capture_micros: i64,
    pub payload: Vec<u8>,
}

/// Starts with 00 00 01 or 00 00 00 01.
pub fn starts_with_start_code(data: &[u8]) -> bool {
    data.starts_with(&[0, 0, 1]) || data.starts_with(&[0, 0, 0, 1])
}

fn be(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0u64, |v, b| v << 8 | u64::from(*b))
}

/// None when shorter than the header plus one byte, over 32,808 bytes, version not 1, part over 63, sequence or frame
/// out of range, a capture time over 2^63-1, or a part 0 without a start code.
pub fn decode_part(data: &[u8]) -> Option<Part> {
    if data.len() <= HEADER || data.len() > HEADER + PART || data[0] != 1 {
        return None;
    }
    let flags = data[1];
    let part = be(&data[2..4]) as u16;
    let sequence = be(&data[20..28]);
    let frame = be(&data[28..32]);
    let capture = be(&data[32..40]);
    if part >= MAX_PARTS || !(1..=MAX_SEQUENCE).contains(&sequence) || frame == 0 || capture > i64::MAX as u64 {
        return None;
    }
    let payload = data[HEADER..].to_vec();
    if part == 0 && !starts_with_start_code(&payload) {
        return None;
    }
    let mut id = [0u8; 16];
    id.copy_from_slice(&data[4..20]);
    Some(Part {
        stream_id: crate::crypto::format_uuid(&id),
        sequence,
        frame: frame as u32,
        part,
        key: flags & 1 != 0,
        parameter_sets: flags & 2 != 0,
        last: flags & 4 != 0,
        capture_micros: capture as i64,
        payload,
    })
}

/// The plaintext a phone writes (the simulated phone and tests).
pub fn encode_part(p: &Part) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER + p.payload.len());
    out.push(1);
    out.push(u8::from(p.key) | u8::from(p.parameter_sets) << 1 | u8::from(p.last) << 2);
    out.extend_from_slice(&p.part.to_be_bytes());
    out.extend_from_slice(&uuid_bytes(&p.stream_id));
    out.extend_from_slice(&p.sequence.to_be_bytes());
    out.extend_from_slice(&p.frame.to_be_bytes());
    out.extend_from_slice(&(p.capture_micros as u64).to_be_bytes());
    out.extend_from_slice(&p.payload);
    out
}

fn uuid_bytes(id: &str) -> [u8; 16] {
    let hex: String = id.chars().filter(|c| *c != '-').collect();
    let mut out = [0u8; 16];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(hex.get(i * 2..i * 2 + 2).unwrap_or("00"), 16).unwrap_or(0);
    }
    out
}

/// A whole access unit, ready to decode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub frame: u32,
    pub key: bool,
    pub parameter_sets: bool,
    pub capture_micros: i64,
    pub data: Vec<u8>,
}

/// What a part did to the frame being put together.
#[derive(Debug, PartialEq, Eq)]
pub enum Assembled {
    Pending,
    Complete(Frame),
    /// A frame was lost: the newest frame number seen.
    Lost(u32),
    /// A part of a frame already finished or given up.
    Ignored,
}

/// Puts the parts of each frame back together. Keeps one unfinished frame; a part out of order, a missing part 0 or a
/// later frame arriving first loses the frame (the stream then waits for a key frame). PhoneScreenProtocol.swift.
#[derive(Default)]
pub struct Assembler {
    partial: Option<(Frame, u16)>,
    newest: u32,
}

impl Assembler {
    pub fn newest(&self) -> u32 {
        self.newest
    }

    pub fn add(&mut self, part: Part) -> Assembled {
        if part.frame <= self.newest {
            return Assembled::Ignored;
        }
        let mut lost = false;
        if self.partial.as_ref().is_some_and(|(f, _)| f.frame != part.frame) {
            // A later frame started before this one finished.
            self.partial = None;
            lost = true;
        }
        match self.partial.as_mut() {
            Some((frame, next)) => {
                if part.part != *next {
                    return self.give_up(part.frame);
                }
                frame.data.extend_from_slice(&part.payload);
                *next += 1;
            }
            None => {
                if part.part != 0 {
                    return self.give_up(part.frame);
                }
                let frame = Frame { frame: part.frame, key: part.key, parameter_sets: part.parameter_sets, capture_micros: part.capture_micros, data: part.payload };
                self.partial = Some((frame, 1));
            }
        }
        if part.last {
            let (done, _) = self.partial.take().unwrap();
            self.newest = done.frame;
            // A lost earlier frame still means the decoder needs a key frame, unless this one is one.
            if lost && !done.key {
                return Assembled::Lost(done.frame);
            }
            return Assembled::Complete(done);
        }
        if lost {
            Assembled::Lost(part.frame)
        } else {
            Assembled::Pending
        }
    }

    fn give_up(&mut self, frame: u32) -> Assembled {
        self.partial = None;
        self.newest = self.newest.max(frame);
        Assembled::Lost(frame)
    }
}

/// Frames waiting for the host, pulled with `bridgey_screen_frame`.
#[derive(Default)]
pub(crate) struct FrameQueue {
    q: Mutex<(VecDeque<Frame>, bool)>,
    cv: Condvar,
}

impl FrameQueue {
    /// Adds a frame; when the host has fallen behind, the waiting ones go and their numbers come back (to acknowledge).
    pub(crate) fn push(&self, frame: Frame) -> Vec<u32> {
        let mut q = self.q.lock().unwrap();
        let mut dropped = Vec::new();
        if q.0.len() >= QUEUED {
            dropped = q.0.drain(..).map(|f| f.frame).collect();
        }
        q.0.push_back(frame);
        drop(q);
        self.cv.notify_all();
        dropped
    }

    pub(crate) fn close(&self) {
        self.q.lock().unwrap().1 = true;
        self.cv.notify_all();
    }

    /// The next frame, None after the timeout, Err once the stream ended and nothing is left.
    pub(crate) fn take(&self, timeout: Duration) -> Result<Option<Frame>, ()> {
        let deadline = Instant::now() + timeout;
        let mut q = self.q.lock().unwrap();
        loop {
            if let Some(f) = q.0.pop_front() {
                return Ok(Some(f));
            }
            if q.1 {
                return Err(());
            }
            let now = Instant::now();
            if now >= deadline {
                return Ok(None);
            }
            q = self.cv.wait_timeout(q, deadline - now).unwrap().0;
        }
    }

    pub(crate) fn put_back(&self, frame: Frame) {
        self.q.lock().unwrap().0.push_front(frame);
    }
}

// MARK: - Control input (PhoneControlSender.swift)

/// What the host asks the phone to do, before it is numbered. Positions are fractions of the phone's whole stream.
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    Touch { contact: u8, phase: sc::TouchPhase, x: f64, y: f64 },
    /// The pointer moved (a Mac's screen, display.rs): coalesced as a finger's movement is.
    Pointer { x: f64, y: f64 },
    /// A mouse button pressed or released where it is (a Mac's screen, display.rs).
    Button { button: sc::Button, down: bool, x: f64, y: f64 },
    /// Stream pixels the content moves, positive right and down (the content follows the fingers).
    Scroll { dx: i64, dy: i64, x: f64, y: f64 },
    Navigate(sc::Navigation),
    Text(String),
    Key { key: sc::Key, down: bool },
}

#[derive(Clone, Debug, PartialEq)]
enum Entry {
    Move { contact: u8, x: f64, y: f64 },
    Pointer { x: f64, y: f64 },
    Scroll { dx: i64, dy: i64, x: f64, y: f64 },
    Discrete(sc::Input),
}

#[derive(Clone, Copy, Debug)]
struct Bucket {
    rate: u64,
    tokens: u64,
    updated: u64,
}

impl Bucket {
    fn new(rate: u64, now: u64) -> Bucket {
        Bucket { rate, tokens: rate * 1_000, updated: now }
    }
    fn take(&mut self, now: u64) -> bool {
        let elapsed = now.saturating_sub(self.updated).min(1_000);
        self.tokens = (self.tokens + elapsed * self.rate).min(self.rate * 1_000);
        self.updated = self.updated.max(now);
        if self.tokens < 1_000 {
            return false;
        }
        self.tokens -= 1_000;
        true
    }
}

/// The contract packet's binding to this stream and session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Binding {
    pub transport: u64,
    pub connection: [u8; 16],
    pub stream: u64,
}

/// This device's side of one control session: the binding, the acknowledged geometry and the packet sequence. A little
/// under the phone's budgets: 100 motion, 16 discrete and 8 control packets a second.
pub struct Sender {
    session: u64,
    binding: Option<Binding>,
    geometry: u64,
    input: sc::InputCapabilities,
    sequence: u64,
    queue: VecDeque<Entry>,
    motion: Bucket,
    discrete: Bucket,
    control: Bucket,
    last_heartbeat: u64,
    contacts: std::collections::BTreeSet<u8>,
    keys: Vec<sc::Key>,
    buttons: Vec<sc::Button>,
    /// Refused here: unsupported, invalid, an unmatched transition or a full queue.
    pub dropped: u64,
}

const MAX_QUEUE: usize = 64;
const HEARTBEAT_MS: u64 = 2_000;
const RATES: (u64, u64, u64) = (100, 16, 8);

fn coordinate(v: f64) -> bool {
    v.is_finite() && (0.0..=1.0).contains(&v)
}

/// Typed text the phone takes: 1 to 256 scalars, at most 1,024 UTF-8 bytes, no control characters.
pub fn valid_text(text: &str) -> bool {
    !text.is_empty() && text.len() <= sc::MAX_TEXT_BYTES && text.chars().count() <= sc::MAX_TEXT_SCALARS && !text.chars().any(char::is_control)
}

/// The keys this device sends: the named keys and Shift; Control, Alt and Meta never go (they would end control).
pub fn sendable(key: sc::Key) -> bool {
    !matches!(key, sc::Key::Control | sc::Key::Alt | sc::Key::Meta)
}

impl Default for Sender {
    fn default() -> Self {
        Sender::new(0)
    }
}

impl Sender {
    pub fn new(now: u64) -> Sender {
        Sender {
            session: 0,
            binding: None,
            geometry: 0,
            input: sc::InputCapabilities::default(),
            sequence: 0,
            queue: VecDeque::new(),
            motion: Bucket::new(RATES.0, now),
            discrete: Bucket::new(RATES.1, now),
            control: Bucket::new(RATES.2, now),
            last_heartbeat: now,
            contacts: Default::default(),
            keys: vec![],
            buttons: vec![],
            dropped: 0,
        }
    }

    pub fn active(&self) -> bool {
        self.binding.is_some()
    }

    pub fn pending(&self) -> usize {
        self.queue.len()
    }

    pub fn input(&self) -> sc::InputCapabilities {
        self.input
    }

    /// The phone answered `active`: a new session, starting with geometry_ack for `generation`.
    pub fn begin(&mut self, session: u64, input: sc::InputCapabilities, binding: Binding, generation: u64, now: u64) -> Vec<sc::Packet> {
        self.clear();
        let valid = |v: u64| (1..=MAX_SEQUENCE).contains(&v);
        if !valid(session) || !valid(generation) || !valid(binding.transport) || !valid(binding.stream) || binding.connection == [0; 16] {
            return vec![];
        }
        self.session = session;
        self.binding = Some(binding);
        self.input = input;
        self.geometry = generation;
        self.motion = Bucket::new(RATES.0, now);
        self.discrete = Bucket::new(RATES.1, now);
        self.control = Bucket::new(RATES.2, now);
        self.last_heartbeat = now;
        self.packet(sc::Input::GeometryAck {}).into_iter().collect()
    }

    /// A new geometry generation: what has not gone is dropped (the phone already lifted its fingers) and the new
    /// generation is acknowledged before anything else.
    pub fn geometry_changed(&mut self, generation: u64, now: u64) -> Vec<sc::Packet> {
        if self.binding.is_none() || generation <= self.geometry {
            return vec![];
        }
        self.queue.clear();
        self.contacts.clear();
        self.keys.clear();
        self.buttons.clear();
        self.geometry = generation;
        self.last_heartbeat = now;
        self.packet(sc::Input::GeometryAck {}).into_iter().collect()
    }

    /// Queues one action; false when there is no session or it was refused. Nothing is numbered until `flush`.
    pub fn submit(&mut self, action: Action) -> bool {
        if self.binding.is_none() {
            return false;
        }
        let accepted = match action {
            Action::Touch { contact, phase, x, y } => self.input.touch && contact < 10 && coordinate(x) && coordinate(y) && self.touch(contact, phase, x, y),
            Action::Pointer { x, y } => self.input.pointer && coordinate(x) && coordinate(y) && self.pointer(x, y),
            Action::Button { button, down, x, y } => self.input.pointer && coordinate(x) && coordinate(y) && self.button(button, down, x, y),
            Action::Scroll { dx, dy, x, y } => self.input.pointer && coordinate(x) && coordinate(y) && (dx != 0 || dy != 0) && self.scroll(dx, dy, x, y),
            Action::Navigate(n) => self.input.navigation && self.queue.len() < MAX_QUEUE && {
                self.queue.push_back(Entry::Discrete(sc::Input::Navigate { action: n }));
                true
            },
            Action::Text(t) => self.input.text && self.text(t),
            Action::Key { key, down } => self.input.keys && sendable(key) && self.key(key, down),
        };
        if !accepted {
            self.dropped += 1;
        }
        accepted
    }

    /// One press and release of `key`, with Shift around it when asked.
    pub fn press(&mut self, key: sc::Key, shift: bool) -> bool {
        if self.binding.is_none() || !self.input.keys {
            return false;
        }
        if shift && !self.submit(Action::Key { key: sc::Key::Shift, down: true }) {
            return false;
        }
        let down = self.submit(Action::Key { key, down: true });
        if down {
            self.submit(Action::Key { key, down: false });
        }
        if shift {
            self.submit(Action::Key { key: sc::Key::Shift, down: false });
        }
        down
    }

    /// The packets that may go now, numbered in order; a heartbeat every 2 seconds.
    pub fn flush(&mut self, now: u64) -> Vec<sc::Packet> {
        let mut out = Vec::new();
        if self.binding.is_none() {
            return out;
        }
        while let Some(head) = self.queue.front().cloned() {
            let allowed = match head {
                Entry::Discrete(_) => self.discrete.take(now),
                _ => self.motion.take(now),
            };
            if !allowed {
                break;
            }
            let next = match head {
                Entry::Move { contact, x, y } => {
                    self.queue.pop_front();
                    sc::Input::Touch { contact, phase: sc::TouchPhase::Move, x, y }
                }
                Entry::Pointer { x, y } => {
                    self.queue.pop_front();
                    sc::Input::Pointer { x, y }
                }
                Entry::Discrete(input) => {
                    self.queue.pop_front();
                    input
                }
                Entry::Scroll { dx, dy, x, y } => {
                    // Within the contract's bounds per packet; the rest stays at the head for the next one.
                    let (sx, sy) = (dx.clamp(-1_000, 1_000), dy.clamp(-1_000, 1_000));
                    if dx == sx && dy == sy {
                        self.queue.pop_front();
                    } else {
                        self.queue[0] = Entry::Scroll { dx: dx - sx, dy: dy - sy, x, y };
                    }
                    if sx == 0 && sy == 0 {
                        continue;
                    }
                    sc::Input::Scroll { dx: sx as i32, dy: sy as i32, x, y }
                }
            };
            match self.packet(next) {
                Some(p) => out.push(p),
                None => return out,
            }
        }
        if now.saturating_sub(self.last_heartbeat) >= HEARTBEAT_MS && self.control.take(now) {
            self.last_heartbeat = now;
            out.extend(self.packet(sc::Input::Heartbeat {}));
        }
        out
    }

    /// The person ended control: the stop packet (never rate limited), then nothing more.
    pub fn stop(&mut self) -> Option<sc::Packet> {
        self.binding?;
        let stop = self.packet(sc::Input::Stop {});
        self.clear();
        stop
    }

    /// Control ended elsewhere: what has not gone is dropped.
    pub fn end(&mut self) {
        self.clear();
    }

    fn touch(&mut self, contact: u8, phase: sc::TouchPhase, x: f64, y: f64) -> bool {
        let held = self.contacts.contains(&contact);
        match phase {
            sc::TouchPhase::Down => {
                if held || self.queue.len() >= MAX_QUEUE {
                    return false;
                }
                self.contacts.insert(contact);
                self.queue.push_back(Entry::Discrete(sc::Input::Touch { contact, phase, x, y }));
                true
            }
            sc::TouchPhase::Up => {
                if !held {
                    return false;
                }
                self.contacts.remove(&contact);
                // An up always goes: dropping it would leave the phone's finger down.
                self.queue.push_back(Entry::Discrete(sc::Input::Touch { contact, phase, x, y }));
                true
            }
            sc::TouchPhase::Move => {
                if !held {
                    return false;
                }
                // The newest position of this finger replaces an older one not sent yet, unless a transition is between.
                for entry in self.queue.iter_mut().rev() {
                    match entry {
                        Entry::Discrete(_) => break,
                        Entry::Move { contact: other, .. } if *other == contact => {
                            *entry = Entry::Move { contact, x, y };
                            return true;
                        }
                        _ => continue,
                    }
                }
                if self.queue.len() >= MAX_QUEUE {
                    return false;
                }
                self.queue.push_back(Entry::Move { contact, x, y });
                true
            }
        }
    }

    /// The newest pointer position replaces one not sent yet, unless a transition is between.
    fn pointer(&mut self, x: f64, y: f64) -> bool {
        for entry in self.queue.iter_mut().rev() {
            match entry {
                Entry::Discrete(_) => break,
                Entry::Pointer { .. } => {
                    *entry = Entry::Pointer { x, y };
                    return true;
                }
                _ => continue,
            }
        }
        if self.queue.len() >= MAX_QUEUE {
            return false;
        }
        self.queue.push_back(Entry::Pointer { x, y });
        true
    }

    fn button(&mut self, button: sc::Button, down: bool, x: f64, y: f64) -> bool {
        let held = self.buttons.contains(&button);
        if held == down {
            return false;
        }
        if down {
            if self.queue.len() >= MAX_QUEUE {
                return false;
            }
            self.buttons.push(button);
        } else {
            self.buttons.retain(|b| *b != button);
        }
        // A release always goes: dropping it would leave the button held on the Mac.
        self.queue.push_back(Entry::Discrete(sc::Input::Button { button, down, x, y }));
        true
    }

    fn scroll(&mut self, dx: i64, dy: i64, x: f64, y: f64) -> bool {
        if let Some(Entry::Scroll { dx: ox, dy: oy, .. }) = self.queue.back().cloned() {
            *self.queue.back_mut().unwrap() = Entry::Scroll { dx: ox + dx, dy: oy + dy, x, y };
            return true;
        }
        if self.queue.len() >= MAX_QUEUE {
            return false;
        }
        self.queue.push_back(Entry::Scroll { dx, dy, x, y });
        true
    }

    fn text(&mut self, text: String) -> bool {
        if !valid_text(&text) {
            return false;
        }
        // Fast typing joins into one packet, so it stays within the discrete budget.
        if let Some(Entry::Discrete(sc::Input::Text { text: previous })) = self.queue.back() {
            let joined = format!("{previous}{text}");
            if valid_text(&joined) {
                *self.queue.back_mut().unwrap() = Entry::Discrete(sc::Input::Text { text: joined });
                return true;
            }
        }
        if self.queue.len() >= MAX_QUEUE {
            return false;
        }
        self.queue.push_back(Entry::Discrete(sc::Input::Text { text }));
        true
    }

    fn key(&mut self, key: sc::Key, down: bool) -> bool {
        let held = self.keys.contains(&key);
        if held == down {
            return false;
        }
        if down {
            if self.queue.len() >= MAX_QUEUE {
                return false;
            }
            self.keys.push(key);
        } else {
            self.keys.retain(|k| *k != key);
        }
        self.queue.push_back(Entry::Discrete(sc::Input::Key { key, down }));
        true
    }

    fn packet(&mut self, input: sc::Input) -> Option<sc::Packet> {
        let binding = self.binding?;
        if self.sequence >= MAX_SEQUENCE {
            // Exhausted: the session stops rather than wrapping.
            self.clear();
            return None;
        }
        self.sequence += 1;
        Some(sc::Packet { v: sc::VERSION, session: self.session, transport: binding.transport, connection: binding.connection, stream: binding.stream, geometry: self.geometry, seq: self.sequence, input })
    }

    fn clear(&mut self) {
        self.binding = None;
        self.session = 0;
        self.geometry = 0;
        self.sequence = 0;
        self.input = sc::InputCapabilities::default();
        self.queue.clear();
        self.contacts.clear();
        self.keys.clear();
        self.buttons.clear();
    }
}

// MARK: - The engine

/// What the window shows about controlling the phone.
#[derive(Clone, Debug, Default)]
struct ControlView {
    /// The stream is control-capable: the phone shows phone_control_draft1 and has a grant for this device.
    capable: bool,
    /// The phone said control may be asked for now (its accessibility service is on).
    allowed: bool,
    /// off, starting, waiting or active.
    phase: &'static str,
    input: sc::InputCapabilities,
    /// Why control ended or was refused, until it starts again.
    note: Option<String>,
}

struct Stream {
    handle: u64,
    stream_id: String,
    phone_seq: u64,
    my_seq: u64,
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u64,
    screenshots: bool,
    offer: Option<Offer>,
    geometry: Option<sc::Geometry>,
    connection: [u8; 16],
    assembler: Assembler,
    waiting_for_key: bool,
    last_key_request: Option<Instant>,
    last_activity: Instant,
    decode_ms: u32,
    queue: Arc<FrameQueue>,
    control: ControlView,
    sender: Option<Sender>,
}

impl Stream {
    fn next(&mut self) -> u64 {
        self.my_seq += 1;
        self.my_seq
    }

    fn json(&self) -> Value {
        json!({
            "stream": self.handle,
            "streamId": self.stream_id,
            "width": self.geometry.map(|g| g.width).unwrap_or(self.width),
            "height": self.geometry.map(|g| g.height).unwrap_or(self.height),
            "fps": self.fps,
            "bitrate": self.bitrate,
            "screenshots": self.screenshots,
            "control": self.control_json(),
        })
    }

    fn control_json(&self) -> Value {
        json!({
            "stream": self.handle,
            "capable": self.control.capable,
            "allowed": self.control.allowed,
            "phase": if self.control.phase.is_empty() { "off" } else { self.control.phase },
            "input": self.control.input,
            "note": self.control.note,
        })
    }
}

struct Request {
    id: String,
    at: Instant,
}

#[derive(Default)]
struct Phone {
    pending: Option<Request>,
    last_request: Option<Instant>,
    stream: Option<Stream>,
    ended: VecDeque<String>,
}

impl Phone {
    fn known(&self, stream_id: &str) -> bool {
        self.ended.iter().any(|s| s == stream_id) || self.stream.as_ref().is_some_and(|s| s.stream_id == stream_id)
    }
    fn remember(&mut self, stream_id: &str) {
        self.ended.retain(|s| s != stream_id);
        self.ended.push_back(stream_id.to_string());
        while self.ended.len() > REMEMBERED {
            self.ended.pop_front();
        }
    }
}

/// Every phone's screen, by device ID, and the frame queues the host pulls from, by stream.
#[derive(Default)]
pub struct State {
    phones: HashMap<String, Phone>,
    queues: HashMap<u64, Arc<FrameQueue>>,
    ticking: bool,
    flushing: bool,
    sim: HashMap<String, SimStream>,
}

/// What a change sends and tells the host, done after the state's lock is released.
#[derive(Default)]
struct Effects {
    sends: Vec<(&'static str, &'static str, String)>,
    events: Vec<(&'static str, u64, Value)>,
    /// Frame queues to list for the host (before it hears `started`) or to take away.
    opened: Vec<(u64, Arc<FrameQueue>)>,
    closed: Vec<u64>,
}

impl Effects {
    fn send(&mut self, kind: &'static str, v: Value) {
        let feature = if matches!(kind, "screen.control" | "screen.input") { CONTROL } else { FEATURE };
        self.sends.push((kind, feature, v.to_string()));
    }
    fn event(&mut self, what: &'static str, id: u64, v: Value) {
        self.events.push((what, id, v));
    }
    fn apply(self, inner: &Inner, device_id: &str) {
        if !self.opened.is_empty() || !self.closed.is_empty() {
            let mut st = inner.phone.screen.lock().unwrap();
            for (handle, queue) in self.opened {
                st.queues.insert(handle, queue);
            }
            for handle in self.closed {
                st.queues.remove(&handle);
            }
        }
        for (kind, feature, plain) in self.sends {
            // A stop goes whatever this device's switch now says: Show phone screens may have just been turned off.
            let _ = if kind == "screen.stop" { inner.encrypted_to_peer(device_id, feature, kind, plain.into_bytes(), true) } else { inner.encrypted_to(device_id, feature, kind, plain) };
        }
        for (what, id, v) in self.events {
            phone::emit(inner, Area::Screen, device_id, what, id, v);
        }
    }
}

fn with<R>(inner: &Inner, device_id: &str, f: impl FnOnce(&mut Phone, &mut Effects) -> R) -> R {
    let mut fx = Effects::default();
    let r = {
        let mut st = inner.phone.screen.lock().unwrap();
        let phone = st.phones.entry(device_id.to_string()).or_default();
        f(phone, &mut fx)
    };
    fx.apply(inner, device_id);
    r
}

/// Show phone screens is on here for the device, and the device shows the key.
fn available(inner: &Inner, device_id: &str) -> bool {
    inner.policy_for(device_id).get(FEATURE) && inner.remote_features(device_id).is_some_and(|r| r.get(FEATURE))
}

/// The device's stream may be controlled: phone_control_draft1 at both ends.
fn control_available(inner: &Inner, device_id: &str) -> bool {
    inner.policy_for(device_id).get(CONTROL) && inner.remote_features(device_id).is_some_and(|r| r.get(CONTROL))
}

/// Ends the stream here: the host's frames stop, it is remembered, the host is told.
fn end(inner: &Inner, phone: &mut Phone, fx: &mut Effects, reason: &str, by: &str) {
    let Some(stream) = phone.stream.take() else { return };
    let _ = inner;
    stream.queue.close();
    fx.closed.push(stream.handle);
    phone.remember(&stream.stream_id);
    fx.event("stopped", stream.handle, json!({"stream": stream.handle, "reason": reason, "by": by}));
}

/// Sends `screen.stop` and ends the stream.
fn stop(inner: &Inner, phone: &mut Phone, fx: &mut Effects, reason: &str) {
    if let Some(s) = phone.stream.as_mut() {
        let seq = s.next();
        fx.send("screen.stop", stop_payload(&s.stream_id, seq, reason));
        if s.control.phase == "active" {
            if let Some(p) = s.sender.as_mut().and_then(Sender::stop) {
                fx.send("screen.input", serde_json::to_value(&p).unwrap_or(Value::Null));
            }
        }
    }
    end(inner, phone, fx, reason, "here");
}

/// Acknowledges a frame; a key frame is asked for at most once a second.
fn ack(s: &mut Stream, fx: &mut Effects, frame: u32, decode_ms: u32, want_key: bool) {
    let keyframe = want_key && s.last_key_request.is_none_or(|t| t.elapsed() >= KEY_SPACING);
    if keyframe {
        s.last_key_request = Some(Instant::now());
    }
    let seq = s.next();
    fx.send("screen.ack", ack_payload(&s.stream_id, seq, frame, decode_ms, keyframe));
}

fn end_control(s: &mut Stream, fx: &mut Effects, note: Option<String>) {
    if let Some(sender) = s.sender.as_mut() {
        sender.end();
    }
    s.sender = None;
    if s.control.phase == "off" && note.is_none() {
        return;
    }
    s.control.phase = "off";
    s.control.note = note;
    fx.event("control", s.handle, s.control_json());
}

pub(crate) fn receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) {
    if inner.simulating.load(Ordering::Relaxed) {
        sim_receive(inner, device_id, kind, plain);
        return;
    }
    match kind {
        "screen.status" => {
            let Some(status) = decode_status(plain) else { return };
            with(inner, device_id, |p, fx| {
                if p.pending.as_ref().map(|r| r.id.as_str()) != Some(status.request_id.as_str()) {
                    return;
                }
                if status.status != "waiting" {
                    p.pending = None;
                }
                fx.event("status", 0, json!({"requestId": status.request_id, "status": status.status, "needs": status.needs}));
            });
        }
        "screen.start" => start(inner, device_id, plain),
        "screen.frame" => {
            let Some(part) = decode_part(plain) else { return };
            frame_part(inner, device_id, part);
        }
        "screen.stats" => {
            let Some(stats) = decode_stats(plain) else { return };
            with(inner, device_id, |p, fx| {
                let Some(s) = p.stream.as_mut().filter(|s| s.stream_id == stats.stream_id && stats.sequence > s.phone_seq) else { return };
                s.phone_seq = stats.sequence;
                s.last_activity = Instant::now();
                fx.event(
                    "stats",
                    s.handle,
                    json!({"stream": s.handle, "latencyMs": stats.latency_ms, "rttMs": stats.rtt_ms, "bitrate": stats.bitrate, "sentBitrate": stats.sent_bitrate, "fps": stats.fps, "dropped": stats.dropped}),
                );
            });
        }
        "screen.stop" => {
            let Some((stream_id, seq, reason)) = decode_stop(plain) else { return };
            with(inner, device_id, |p, fx| {
                if p.stream.as_ref().is_some_and(|s| s.stream_id == stream_id && seq > s.phone_seq) {
                    end(inner, p, fx, &reason, "phone");
                }
            });
        }
        "screen.geometry" => {
            let Some((stream_id, seq, geometry)) = decode_geometry(plain) else { return };
            let now = crate::session::clock_ms();
            with(inner, device_id, |p, fx| {
                let Some(s) = p.stream.as_mut().filter(|s| s.stream_id == stream_id && seq > s.phone_seq) else { return };
                s.phone_seq = seq;
                s.last_activity = Instant::now();
                let Some(current) = s.geometry.filter(|c| geometry.generation > c.generation && geometry.source == c.source) else { return };
                let _ = current;
                s.geometry = Some(geometry);
                // Input not sent yet is dropped and the new generation acknowledged before anything else.
                if let Some(sender) = s.sender.as_mut() {
                    for packet in sender.geometry_changed(geometry.generation, now) {
                        fx.send("screen.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
                    }
                }
                fx.event("geometry", s.handle, json!({"stream": s.handle, "generation": geometry.generation, "width": geometry.width, "height": geometry.height}));
            });
        }
        "screen.control" => {
            let Some((stream_id, seq, state)) = decode_control(plain) else { return };
            let now = crate::session::clock_ms();
            let started = with(inner, device_id, |p, fx| {
                let Some(s) = p.stream.as_mut().filter(|s| s.stream_id == stream_id && seq > s.phone_seq) else { return false };
                s.phone_seq = seq;
                s.last_activity = Instant::now();
                let Some(offer) = s.offer.clone() else { return false };
                match state {
                    ControlState::Waiting => {
                        if s.control.phase != "starting" {
                            return false;
                        }
                        s.control.phase = "waiting";
                    }
                    ControlState::Active { session, input } => {
                        let Some(geometry) = s.geometry.filter(|_| matches!(s.control.phase, "starting" | "waiting")) else { return false };
                        let mut sender = Sender::new(now);
                        let packets = sender.begin(session, input, Binding { transport: offer.transport, connection: s.connection, stream: offer.stream }, geometry.generation, now);
                        if packets.is_empty() {
                            end_control(s, fx, Some("failed".into()));
                            return false;
                        }
                        for packet in packets {
                            fx.send("screen.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
                        }
                        s.sender = Some(sender);
                        s.control.phase = "active";
                        s.control.input = input;
                        s.control.note = None;
                        fx.event("control", s.handle, s.control_json());
                        return true;
                    }
                    ControlState::Ended(reason) | ControlState::Refused(reason) => {
                        let note = (reason != "user").then_some(reason);
                        end_control(s, fx, note);
                        return false;
                    }
                    ControlState::Available(allowed) => s.control.allowed = allowed,
                }
                fx.event("control", s.handle, s.control_json());
                false
            });
            if started {
                ensure_flushing(inner);
            }
        }
        _ => {}
    }
}

fn start(inner: &Inner, device_id: &str, plain: &[u8]) {
    let Some(start) = decode_start(plain) else {
        // A start that names its stream is answered `invalid`, once.
        if let Some(stream_id) = start_stream_id(plain) {
            with(inner, device_id, |p, fx| {
                if !p.known(&stream_id) {
                    fx.send("screen.stop", stop_payload(&stream_id, 1, "invalid"));
                    p.remember(&stream_id);
                }
            });
        }
        return;
    };
    let controllable = control_available(inner, device_id);
    let connection = inner.screen_connection(device_id).unwrap_or([0; 16]);
    let handle = inner.next_id();
    let queue = Arc::new(FrameQueue::default());
    let fresh = with(inner, device_id, |p, fx| {
        if p.known(&start.stream_id) {
            return false;
        }
        // The phone started a new stream: the old one ends here without a message.
        end(inner, p, fx, "replaced", "phone");
        // A control-capable stream only from a phone that shows the key; a bad object means view only.
        let offer = if controllable { start.control.clone() } else { None };
        let control = match &offer {
            Some(o) => ControlView { capable: true, allowed: o.allowed, phase: "off", ..Default::default() },
            None => ControlView { phase: "off", ..Default::default() },
        };
        let mut s = Stream {
            handle,
            stream_id: start.stream_id.clone(),
            phone_seq: start.sequence,
            my_seq: 0,
            width: start.width,
            height: start.height,
            fps: start.fps,
            bitrate: start.bitrate,
            screenshots: start.screenshots,
            geometry: offer.as_ref().map(|o| o.geometry),
            offer,
            connection,
            assembler: Assembler::default(),
            waiting_for_key: true,
            last_key_request: None,
            last_activity: Instant::now(),
            decode_ms: 0,
            queue: queue.clone(),
            control,
            sender: None,
        };
        if p.pending.as_ref().is_some_and(|r| start.request_id.is_none() || start.request_id.as_deref() == Some(r.id.as_str())) {
            p.pending = None;
        }
        let seq = s.next();
        fx.send("screen.started", started_payload(&s.stream_id, seq));
        fx.opened.push((handle, queue.clone()));
        fx.event("started", handle, s.json());
        p.stream = Some(s);
        true
    });
    if fresh {
        ensure_ticking(inner);
    }
}

fn frame_part(inner: &Inner, device_id: &str, part: Part) {
    with(inner, device_id, |p, fx| {
        let Some(s) = p.stream.as_mut().filter(|s| s.stream_id == part.stream_id && part.sequence > s.phone_seq) else { return };
        s.phone_seq = part.sequence;
        s.last_activity = Instant::now();
        match s.assembler.add(part) {
            Assembled::Pending | Assembled::Ignored => {}
            Assembled::Lost(frame) => {
                s.waiting_for_key = true;
                ack(s, fx, frame, 0, true);
            }
            Assembled::Complete(frame) => {
                if s.waiting_for_key && !frame.key {
                    // Dropped while waiting for a key frame: acknowledged so the phone's count drains.
                    ack(s, fx, frame.frame, 0, true);
                    return;
                }
                s.waiting_for_key = false;
                let dropped = s.queue.push(frame);
                if let Some(newest) = dropped.last() {
                    // The host fell behind: those frames went, and the next ones wait for a key frame.
                    s.waiting_for_key = true;
                    let _ = newest;
                    for f in &dropped {
                        ack(s, fx, *f, 0, true);
                    }
                }
            }
        }
    });
}

/// The next whole frame of a stream for the host: Ok(None) after the timeout, Err(true) once the stream has ended,
/// Err(false) with the size needed when `capacity` is too small (the frame stays first).
pub(crate) fn take(inner: &Inner, stream: u64, timeout: Duration, capacity: usize) -> Result<Option<Frame>, Option<usize>> {
    let Some(queue) = inner.phone.screen.lock().unwrap().queues.get(&stream).cloned() else { return Err(None) };
    let frame = match queue.take(timeout) {
        Ok(Some(f)) => f,
        Ok(None) => return Ok(None),
        Err(()) => return Err(None),
    };
    if frame.data.len() > capacity {
        let needed = frame.data.len();
        queue.put_back(frame);
        return Err(Some(needed));
    }
    // Handed to the host's decoder: acknowledged now, with the host's latest decode time.
    let device = {
        let st = inner.phone.screen.lock().unwrap();
        st.phones.iter().find(|(_, p)| p.stream.as_ref().is_some_and(|s| s.handle == stream)).map(|(d, _)| d.clone())
    };
    if let Some(device) = device {
        let number = frame.frame;
        with(inner, &device, |p, fx| {
            if let Some(s) = p.stream.as_mut().filter(|s| s.handle == stream) {
                let ms = s.decode_ms;
                ack(s, fx, number, ms, false);
            }
        });
    }
    Ok(Some(frame))
}

/// Request expiry and stream timeouts, once a second while anything is open.
fn ensure_ticking(inner: &Inner) {
    {
        let mut st = inner.phone.screen.lock().unwrap();
        if st.ticking {
            return;
        }
        st.ticking = true;
    }
    phone::after(inner, Duration::from_secs(1), tick);
}

fn tick(inner: &Inner) {
    let devices: Vec<String> = inner.phone.screen.lock().unwrap().phones.keys().cloned().collect();
    let mut busy = false;
    for d in devices {
        busy |= with(inner, &d, |p, fx| {
            if p.pending.as_ref().is_some_and(|r| r.at.elapsed() >= REQUEST_LIFETIME) {
                let r = p.pending.take().unwrap();
                fx.event("status", 0, json!({"requestId": r.id, "status": "expired"}));
            }
            if p.stream.as_ref().is_some_and(|s| s.last_activity.elapsed() >= STREAM_TIMEOUT) {
                stop(inner, p, fx, "timeout");
            }
            p.pending.is_some() || p.stream.is_some()
        });
    }
    let again = {
        let mut st = inner.phone.screen.lock().unwrap();
        st.ticking = busy;
        busy
    };
    if again {
        phone::after(inner, Duration::from_secs(1), tick);
    }
}

/// Motion, scrolling and heartbeats go about 60 times a second while any phone is controlled.
fn ensure_flushing(inner: &Inner) {
    {
        let mut st = inner.phone.screen.lock().unwrap();
        if st.flushing {
            return;
        }
        st.flushing = true;
    }
    phone::after(inner, FLUSH_EVERY, flush_all);
}

fn flush_all(inner: &Inner) {
    let devices: Vec<String> = inner.phone.screen.lock().unwrap().phones.keys().cloned().collect();
    let now = crate::session::clock_ms();
    let mut active = false;
    for d in devices {
        active |= with(inner, &d, |p, fx| {
            let Some(sender) = p.stream.as_mut().and_then(|s| s.sender.as_mut()).filter(|s| s.active()) else { return false };
            for packet in sender.flush(now) {
                fx.send("screen.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
            }
            true
        });
    }
    let again = {
        let mut st = inner.phone.screen.lock().unwrap();
        st.flushing = active;
        active
    };
    if again {
        phone::after(inner, FLUSH_EVERY, flush_all);
    }
}

fn f(command: &Value, key: &str) -> Option<f64> {
    command.get(key).and_then(Value::as_f64)
}

fn key_of(name: &str) -> Option<sc::Key> {
    serde_json::from_value(json!(name)).ok()
}

pub(crate) fn command(inner: &Inner, device_id: &str, command: &Value) -> Value {
    match phone::op(command) {
        Some("status") => {
            let (on, controls) = (available(inner, device_id), control_available(inner, device_id));
            let enabled = inner.policy_for(device_id).get(FEATURE);
            with(inner, device_id, |p, _| {
                phone::ok(json!({
                    "enabled": enabled,
                    "available": on,
                    "controlAvailable": controls,
                    "pending": p.pending.as_ref().map(|r| r.id.clone()),
                    "stream": p.stream.as_ref().map(Stream::json),
                }))
            })
        }
        Some("request") => {
            if !available(inner, device_id) {
                return phone::error("feature_off");
            }
            let id = crate::crypto::uuid4();
            let answer = with(inner, device_id, |p, _| {
                if let Some(s) = &p.stream {
                    return Err(phone::ok(json!({"showing": true, "stream": s.handle})));
                }
                if let Some(r) = &p.pending {
                    return Err(phone::ok(json!({"requestId": r.id, "waiting": true})));
                }
                if p.last_request.is_some_and(|t| t.elapsed() < REQUEST_SPACING) {
                    return Err(phone::error("too_soon"));
                }
                p.last_request = Some(Instant::now());
                p.pending = Some(Request { id: id.clone(), at: Instant::now() });
                Ok(())
            });
            if let Err(answer) = answer {
                return answer;
            }
            if inner.encrypted_to(device_id, FEATURE, "screen.request", request_payload(&id).to_string()).is_err() {
                with(inner, device_id, |p, _| p.pending = None);
                return phone::error("not_connected");
            }
            ensure_ticking(inner);
            phone::ok(json!({"requestId": id}))
        }
        Some("stop") => {
            with(inner, device_id, |p, fx| {
                p.pending = None;
                stop(inner, p, fx, "closed");
            });
            phone::ok(json!({}))
        }
        Some("decoded") => {
            let ms = command.get("ms").and_then(Value::as_u64).unwrap_or(0).min(60_000) as u32;
            with(inner, device_id, |p, _| {
                if let Some(s) = p.stream.as_mut() {
                    s.decode_ms = ms;
                }
            });
            phone::ok(json!({}))
        }
        Some("keyframe") => {
            // The host's decoder failed: frames wait for the next key frame, which is asked for now.
            with(inner, device_id, |p, fx| {
                if let Some(s) = p.stream.as_mut() {
                    s.waiting_for_key = true;
                    let newest = s.assembler.newest();
                    if newest > 0 {
                        ack(s, fx, newest, 0, true);
                    }
                }
            });
            phone::ok(json!({}))
        }
        Some("control_begin") => with(inner, device_id, |p, fx| {
            let Some(s) = p.stream.as_mut().filter(|s| s.offer.is_some() && s.control.allowed && s.control.phase == "off") else { return phone::error("unavailable") };
            s.control.phase = "starting";
            s.control.note = None;
            let seq = s.next();
            fx.send("screen.control", control_begin_payload(&s.stream_id, seq));
            fx.event("control", s.handle, s.control_json());
            phone::ok(json!({}))
        }),
        Some("control_end") => with(inner, device_id, |p, fx| {
            let Some(s) = p.stream.as_mut() else { return phone::ok(json!({})) };
            match s.control.phase {
                "starting" | "waiting" => {
                    let seq = s.next();
                    fx.send("screen.control", control_end_payload(&s.stream_id, seq));
                }
                "active" => {
                    if let Some(packet) = s.sender.as_mut().and_then(Sender::stop) {
                        fx.send("screen.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
                    }
                }
                _ => return phone::ok(json!({})),
            }
            end_control(s, fx, None);
            phone::ok(json!({}))
        }),
        Some(op @ ("touch" | "scroll" | "navigate" | "text" | "key" | "press")) => {
            let action = match op {
                "touch" => {
                    let phase = match command.get("phase").and_then(Value::as_str) {
                        Some("down") => sc::TouchPhase::Down,
                        Some("move") => sc::TouchPhase::Move,
                        Some("up") => sc::TouchPhase::Up,
                        _ => return phone::error("invalid"),
                    };
                    let contact = command.get("contact").and_then(Value::as_u64).unwrap_or(0).min(255) as u8;
                    let (Some(x), Some(y)) = (f(command, "x"), f(command, "y")) else { return phone::error("invalid") };
                    Some(Action::Touch { contact, phase, x, y })
                }
                "scroll" => {
                    let (Some(x), Some(y)) = (f(command, "x"), f(command, "y")) else { return phone::error("invalid") };
                    let dx = command.get("dx").and_then(Value::as_f64).unwrap_or(0.0).round() as i64;
                    let dy = command.get("dy").and_then(Value::as_f64).unwrap_or(0.0).round() as i64;
                    Some(Action::Scroll { dx, dy, x, y })
                }
                "navigate" => match command.get("action").and_then(Value::as_str) {
                    Some("back") => Some(Action::Navigate(sc::Navigation::Back)),
                    Some("home") => Some(Action::Navigate(sc::Navigation::Home)),
                    Some("recents") => Some(Action::Navigate(sc::Navigation::Recents)),
                    _ => return phone::error("invalid"),
                },
                "text" => Some(Action::Text(command.get("text").and_then(Value::as_str).unwrap_or("").to_string())),
                "key" => {
                    let Some(key) = command.get("key").and_then(Value::as_str).and_then(key_of) else { return phone::error("invalid") };
                    Some(Action::Key { key, down: command.get("down").and_then(Value::as_bool).unwrap_or(true) })
                }
                _ => None,
            };
            let press = (op == "press").then(|| command.get("key").and_then(Value::as_str).and_then(key_of)).flatten();
            if op == "press" && press.is_none() {
                return phone::error("invalid");
            }
            let now = crate::session::clock_ms();
            with(inner, device_id, |p, fx| {
                let Some(sender) = p.stream.as_mut().filter(|s| s.control.phase == "active").and_then(|s| s.sender.as_mut()) else { return phone::ok(json!({"taken": false})) };
                let taken = match (&action, press) {
                    (_, Some(key)) => sender.press(key, command.get("shift").and_then(Value::as_bool).unwrap_or(false)),
                    (Some(a), None) => sender.submit(a.clone()),
                    _ => false,
                };
                // Transitions go at once when the budget allows; motion and scrolling wait for the next flush.
                let motion = matches!(action, Some(Action::Scroll { .. }) | Some(Action::Touch { phase: sc::TouchPhase::Move, .. }));
                if taken && !motion {
                    for packet in sender.flush(now) {
                        fx.send("screen.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
                    }
                }
                phone::ok(json!({"taken": taken}))
            })
        }
        _ => phone::error("invalid"),
    }
}

pub(crate) fn features_changed(inner: &Inner, device_id: &str) {
    if inner.simulating.load(Ordering::Relaxed) {
        return;
    }
    let local = inner.policy_for(device_id).get(FEATURE);
    let remote = inner.remote_features(device_id).map(|r| r.get(FEATURE));
    let controls = control_available(inner, device_id);
    with(inner, device_id, |p, fx| {
        if !local {
            // Show phone screens turned off here.
            p.pending = None;
            stop(inner, p, fx, "disabled");
            return;
        }
        if remote == Some(false) {
            p.pending = None;
            end(inner, p, fx, "disabled", "phone");
            return;
        }
        // Without phone_control_draft1 nothing more may be sent: control ends here as turned off on the phone.
        let Some(s) = p.stream.as_mut().filter(|s| s.offer.is_some()) else { return };
        if controls {
            if !s.control.allowed {
                s.control.allowed = true;
                fx.event("control", s.handle, s.control_json());
            }
            return;
        }
        s.control.allowed = false;
        if s.control.phase == "off" {
            fx.event("control", s.handle, s.control_json());
        } else {
            end_control(s, fx, Some("disabled".into()));
        }
    });
}

pub(crate) fn disconnected(inner: &Inner, device_id: &str) {
    with(inner, device_id, |p, fx| {
        p.pending = None;
        end(inner, p, fx, "disconnected", "here");
    });
    sim_stop(inner, device_id);
}

pub(crate) fn forgotten(inner: &Inner, device_id: &str) {
    disconnected(inner, device_id);
    inner.phone.screen.lock().unwrap().phones.remove(device_id);
}

// MARK: - A simulated phone (sim.rs): a synthetic test clip, stats, control and the input it gets

/// A 96 by 160 testsrc2 clip from ffmpeg (10 frames, key frames 1 and 6, SPS and PPS repeated), never a real screen.
pub(crate) const SIM_CLIP: &[u8] = include_bytes!("../tests/fixtures/screen.h264");

/// The clip's access units: NAL units up to and including each picture slice.
pub(crate) fn sim_frames() -> Vec<(bool, bool, Vec<u8>)> {
    let data = SIM_CLIP;
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i..i + 3] == [0, 0, 1] {
            let at = if i > 0 && data[i - 1] == 0 { i - 1 } else { i };
            starts.push((at, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut frames = Vec::new();
    let mut current = Vec::new();
    let (mut key, mut sets) = (false, false);
    for (n, (at, body)) in starts.iter().enumerate() {
        let end = starts.get(n + 1).map(|s| s.0).unwrap_or(data.len());
        let kind = data[*body] & 0x1f;
        if current.is_empty() && kind == 7 {
            sets = true;
        }
        current.extend_from_slice(&data[*at..end]);
        if kind == 5 {
            key = true;
        }
        if kind == 1 || kind == 5 {
            frames.push((key, sets, std::mem::take(&mut current)));
            key = false;
            sets = false;
        }
    }
    frames
}

struct SimStream {
    stream_id: String,
    running: Arc<std::sync::atomic::AtomicBool>,
    sequence: Arc<std::sync::atomic::AtomicU64>,
    session: u64,
}

pub(crate) fn sim_incoming(kind: &str) -> Option<Incoming> {
    let (kind, feature, max): (&'static str, &'static str, usize) = match kind {
        "screen.request" => ("screen.request", FEATURE, MESSAGE),
        "screen.started" => ("screen.started", FEATURE, MESSAGE),
        "screen.ack" => ("screen.ack", FEATURE, MESSAGE),
        "screen.input" => ("screen.input", CONTROL, sc::MAX_PACKET_BYTES),
        _ => return None,
    };
    Some(Incoming { area: Area::Screen, kind, feature, max, with_message_id: false })
}

/// The simulated phone's capabilities: an Android 13 phone with Bridgey control on.
fn sim_capabilities() -> Value {
    json!({"v": 1, "screenSource": true, "fullDisplaySource": true, "h264Encode": true, "captureRequiresPrompt": true,
           "inputHost": {"pointer": true, "touch": true, "keys": true, "text": true, "navigation": true}})
}

fn sim_send(inner: &Inner, device_id: &str, kind: &'static str, v: &Value) {
    let feature = if matches!(kind, "screen.control" | "screen.geometry") { CONTROL } else { FEATURE };
    let _ = inner.encrypted_to(device_id, feature, kind, v.to_string());
}

fn sim_stop(inner: &Inner, device_id: &str) {
    if let Some(s) = inner.phone.screen.lock().unwrap().sim.remove(device_id) {
        s.running.store(false, Ordering::Relaxed);
    }
}

pub(crate) fn sim_receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) -> bool {
    use std::sync::atomic::{AtomicBool, AtomicU64};
    let next = |device: &str| -> Option<(String, u64)> {
        let st = inner.phone.screen.lock().unwrap();
        let s = st.sim.get(device)?;
        Some((s.stream_id.clone(), s.sequence.fetch_add(1, Ordering::Relaxed) + 1))
    };
    match kind {
        "screen.request" => {
            let Some(o) = phone::versioned(plain, MESSAGE) else { return true };
            let Some(request) = request_id(o.get("requestId")) else { return true };
            // As a phone with unattended access: a moment of waiting, then screenshots at once.
            sim_send(inner, device_id, "screen.status", &json!({"version": 1, "requestId": request, "status": "waiting"}));
            sim_stop(inner, device_id);
            let stream_id = crate::crypto::uuid4();
            let running = Arc::new(AtomicBool::new(true));
            let sequence = Arc::new(AtomicU64::new(1));
            inner.phone.screen.lock().unwrap().sim.insert(device_id.to_string(), SimStream { stream_id: stream_id.clone(), running: running.clone(), sequence: sequence.clone(), session: 0 });
            let device = device_id.to_string();
            phone::after(inner, Duration::from_millis(300), move |inner| {
                let start = json!({"version": 1, "streamId": stream_id, "sequence": 1, "requestId": request, "codec": "h264", "width": 96, "height": 160,
                                   "fps": 10, "bitrate": 300_000, "mode": "screenshots",
                                   "control": {"stream": 1, "transport": 1, "geometry": {"generation": 1, "source": 1, "kind": "display", "width": 96, "height": 160},
                                               "capabilities": sim_capabilities(), "allowed": true}});
                sim_send(inner, &device, "screen.start", &start);
                sim_frames_loop(inner, device, stream_id, running, sequence, 0);
            });
        }
        "screen.started" => {}
        "screen.ack" => {
            if let Some(o) = phone::versioned(plain, MESSAGE) {
                phone::emit(inner, Area::Screen, device_id, "sim_ack", 0, json!({"frame": o.get("frame"), "keyframe": o.get("keyframe")}));
            }
        }
        "screen.stop" => {
            let reason = decode_stop(plain).map(|s| s.2);
            sim_stop(inner, device_id);
            phone::emit(inner, Area::Screen, device_id, "sim_stop", 0, json!({"reason": reason}));
        }
        "screen.control" => {
            let Some(o) = phone::versioned(plain, MESSAGE) else { return true };
            let Some((stream_id, seq)) = next(device_id) else { return true };
            match o.get("action").and_then(Value::as_str) {
                Some("begin") => {
                    if let Some(s) = inner.phone.screen.lock().unwrap().sim.get_mut(device_id) {
                        s.session += 1;
                    }
                    sim_send(inner, device_id, "screen.control", &json!({"version": 1, "streamId": stream_id, "sequence": seq, "state": "active", "session": 1,
                                                                        "input": {"pointer": true, "touch": true, "keys": true, "text": true, "navigation": true}}));
                }
                Some("end") => sim_send(inner, device_id, "screen.control", &json!({"version": 1, "streamId": stream_id, "sequence": seq, "state": "ended", "reason": "user"})),
                _ => {}
            }
        }
        "screen.input" => {
            let Ok(packet) = sc::Packet::decode(plain) else { return true };
            let ours = inner.screen_connection(device_id).is_some_and(|c| c == packet.connection);
            let op = serde_json::to_value(&packet.input).ok().and_then(|v| v.get("op").and_then(Value::as_str).map(str::to_string)).unwrap_or_default();
            phone::emit(inner, Area::Screen, device_id, "sim_input", 0, json!({"op": op, "seq": packet.seq, "geometry": packet.geometry, "connection": ours}));
            if op == "navigate" {
                // A rotation, so tests see a new geometry generation.
                if let Some((stream_id, seq)) = next(device_id) {
                    sim_send(inner, device_id, "screen.geometry", &json!({"version": 1, "streamId": stream_id, "sequence": seq,
                                                                           "geometry": {"generation": 2, "source": 1, "kind": "display", "width": 160, "height": 96}}));
                }
            }
        }
        _ => return false,
    }
    true
}

/// Frames at about 10 a second, and stats once a second, while the simulated stream runs.
fn sim_frames_loop(inner: &Inner, device: String, stream_id: String, running: Arc<std::sync::atomic::AtomicBool>, sequence: Arc<std::sync::atomic::AtomicU64>, n: u64) {
    if !running.load(Ordering::Relaxed) {
        return;
    }
    let frames = sim_frames();
    let (key, sets, data) = &frames[(n as usize) % frames.len()];
    let seq = sequence.fetch_add(1, Ordering::Relaxed) + 1;
    let part = Part { stream_id: stream_id.clone(), sequence: seq, frame: (n + 1) as u32, part: 0, key: *key, parameter_sets: *sets, last: true, capture_micros: (n * 100_000) as i64, payload: data.clone() };
    let plain = encode_part(&part);
    let _ = inner.encrypted_to_peer(&device, FEATURE, "screen.frame", plain, false);
    if n % 10 == 9 {
        let seq = sequence.fetch_add(1, Ordering::Relaxed) + 1;
        sim_send(inner, &device, "screen.stats", &json!({"version": 1, "streamId": stream_id, "sequence": seq, "latencyMs": 40, "rttMs": 5, "bitrate": 300_000, "sentBitrate": 280_000, "fps": 10, "dropped": 0}));
    }
    phone::after(inner, Duration::from_millis(100), move |inner| sim_frames_loop(inner, device, stream_id, running, sequence, n + 1));
}

#[cfg(test)]
mod tests;
