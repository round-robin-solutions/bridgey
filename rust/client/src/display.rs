//! A Mac's screen on this device and control of it (`screen_control_draft1`, docs/protocol.md "Mac screen to phone"):
//! the viewer and controller side, as the Android app does it (display/DisplayViewerHub.kt, DisplayProtocol.kt,
//! DisplayController.kt), so the iOS app, and later Windows and Linux, can see and control a Mac. The source side (this
//! device's own screen on another device) is not here. The pattern every area follows is in `phone.rs`; frames and the
//! control sender are screen.rs's.
//!
//! - Asking: `display.request` with this device's capabilities, one open request per Mac, at most one every 3 s,
//!   expiring after 2 minutes; the Mac's `display.status`.
//! - A stream: `display.start` checked as display-v1.json pins it; a start that does not answer this device's open
//!   request is refused (`left_screen`, the Mac must not stream to nobody), an invalid one `invalid`; `display.started`
//!   at once; the Mac's messages in its own sequence (outside the shared messageId window); the last 16 ended stream IDs
//!   refused; frames put back together from their parts and acknowledged once the host has taken them (frames dropped
//!   while waiting for a key frame at once), a key frame asked for at most once a second; 6 s without a frame or
//!   `display.stats` ends it (`timeout`); a disconnect ends it here.
//! - Frames never go through the event queue: the host pulls each whole H.264 access unit (Annex B) with
//!   `bridgey_screen_frame`, as for a phone's screen.
//! - Control: `display.control` begin and end, the Mac's `active`, `ended` and `refused`, and `display.input` packets of
//!   the shared contract from host commands: a pointer, buttons, scrolling, keys and text, numbered only when they go,
//!   pointer motion and scrolling coalesced, transitions never dropped once numbered, within the contract's budgets, a
//!   heartbeat every 2 s, `geometry_ack` first and after every `display.geometry`. Stop is never rate limited.
//!
//! Capabilities: this device says it is a viewer (H.264 decoding) and a controller (pointer, keys, text). It never says
//! it is a screen source or an input host: on iOS nothing may control the device (there is no public API for it), so
//! another app must never be offered this device as an input host.
//!
//! Host commands (`bridgey_phone`, area 5): status | request | stop {reason: user, left_screen or screen_off} |
//!   decoded {ms} | keyframe | control_begin | control_end | pointer {x, y} | button {button: primary, secondary or
//!   middle, down, x, y} | scroll {dx, dy, x, y} | key {key, down} | press {key, shift} | text {text}. Positions are
//!   fractions of the Mac's whole shared display, after the host has taken off its letterbox (`letterbox`). `touch` and
//!   `navigate` answer `unsupported`: a Mac takes a pointer.
//! Events (`BRIDGEY_EVENT_KIND_DISPLAY`, id = the stream): `status` (the Mac's answer, or `expired`), `started` (open a
//!   view and pull frames), `stats`, `geometry`, `control`, `stopped`.

use crate::client::Inner;
use crate::phone::{self, boolean, integer, request_id, Area, Incoming};
use crate::screen::{self, Action, Assembled, Assembler, Binding, Frame, FrameQueue, Part, Sender};
use bridgey_connect_proto::screen_control as sc;
use serde_json::{json, Map, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

pub(crate) const FEATURE: &str = "screen_control_draft1";

const MESSAGE: usize = 512;
const REQUEST: usize = 1_024;
const START: usize = 2_048;
const FRAME: usize = 40 + 32_768;
const DISPLAY_NAME: usize = 64;
const MAX_SEQUENCE: u64 = 9_007_199_254_740_991;
const REQUEST_LIFETIME: Duration = Duration::from_secs(120);
const REQUEST_SPACING: Duration = Duration::from_secs(3);
const STREAM_TIMEOUT: Duration = Duration::from_secs(6);
/// The viewer ignores a start that reuses one of the last 16 ended stream IDs (docs/protocol.md).
const REMEMBERED: usize = 16;
const KEY_SPACING: Duration = Duration::from_secs(1);
const FLUSH_EVERY: Duration = Duration::from_millis(16);

pub fn incoming(kind: &str) -> Option<Incoming> {
    let (kind, max): (&'static str, usize) = match kind {
        "display.status" => ("display.status", MESSAGE),
        "display.start" => ("display.start", START),
        "display.frame" => ("display.frame", FRAME),
        "display.stats" => ("display.stats", MESSAGE),
        "display.geometry" => ("display.geometry", MESSAGE),
        "display.control" => ("display.control", MESSAGE),
        "display.stop" => ("display.stop", MESSAGE),
        _ => return None,
    };
    Some(Incoming { area: Area::Display, kind, feature: FEATURE, max, with_message_id: false })
}

/// Stream messages: outside the shared messageId window, each side numbers its own per stream.
pub fn is_stream(kind: &str) -> bool {
    matches!(kind, "display.start" | "display.started" | "display.frame" | "display.ack" | "display.stats" | "display.geometry" | "display.control" | "display.input" | "display.stop")
}

// MARK: - The wire

fn object(plain: &[u8], limit: usize) -> Option<Map<String, Value>> {
    phone::versioned(plain, limit)
}

/// A contract counter: 1 to 2^53-1.
fn counter(value: Option<&Value>) -> Option<u64> {
    integer(value).filter(|v| *v >= 1 && *v as u64 <= MAX_SEQUENCE).map(|v| v as u64)
}

fn ranged(o: &Map<String, Value>, key: &str, min: i64, max: i64) -> Option<i64> {
    integer(o.get(key)).filter(|v| (min..=max).contains(v))
}

/// The stream and the sender's sequence every stream message carries.
fn header(o: &Map<String, Value>) -> Option<(String, u64)> {
    Some((request_id(o.get("streamId"))?, counter(o.get("sequence"))?))
}

const STATUSES: [&str; 7] = ["waiting", "declined", "busy", "disabled", "permission", "locked", "failed"];

/// `display.status`: at most 512 bytes, a UUID `requestId` and a known `status` (an unknown one is dropped).
pub fn decode_status(plain: &[u8]) -> Option<(String, String)> {
    let o = object(plain, MESSAGE)?;
    let request_id = request_id(o.get("requestId"))?;
    let status = o.get("status")?.as_str().filter(|s| STATUSES.contains(s))?.to_string();
    Some((request_id, status))
}

/// What this device can do with a Mac's screen: show it (H.264) and control it with a pointer, keys and text. Never a
/// source, never an input host. Support, never permission.
pub fn viewer_capabilities() -> sc::Capabilities {
    sc::Capabilities {
        v: sc::VERSION,
        screen_viewer: true,
        h264_decode: true,
        input_controller: sc::InputCapabilities { pointer: true, keys: true, text: true, ..Default::default() },
        ..Default::default()
    }
}

/// `display.request`, with the capabilities written as the Android app writes them (only the flags that are true).
pub fn request_payload(id: &str) -> Value {
    json!({"version": 1, "requestId": id, "capabilities": {"v": 1, "screenViewer": true, "h264Decode": true, "inputController": {"pointer": true, "keys": true, "text": true}}})
}

#[derive(Clone, Debug, PartialEq)]
pub struct Start {
    pub stream_id: String,
    pub sequence: u64,
    pub request_id: String,
    pub fps: u32,
    pub bitrate: u64,
    /// The contract's stream and transport counters for this stream's input packets.
    pub stream: u64,
    pub transport: u64,
    pub geometry: sc::Geometry,
    pub capabilities: sc::Capabilities,
    /// Control may be asked for now.
    pub control: bool,
    pub display_name: Option<String>,
}

/// `display.start`: at most 2,048 bytes; codec `h264`; 1 to 60 fps; 100 kb/s to 50 Mb/s; the contract's counters,
/// geometry (a display, even sides of at least 16) and capabilities (v 1); `control` a boolean; an optional display
/// name of at most 64 UTF-8 bytes.
pub fn decode_start(plain: &[u8]) -> Option<Start> {
    let o = object(plain, START)?;
    let (stream_id, sequence) = header(&o)?;
    let request_id = request_id(o.get("requestId"))?;
    if o.get("codec")?.as_str()? != "h264" {
        return None;
    }
    let fps = ranged(&o, "fps", 1, 60)? as u32;
    let bitrate = ranged(&o, "bitrate", 100_000, 50_000_000)? as u64;
    let stream = counter(o.get("stream"))?;
    let transport = counter(o.get("transport"))?;
    let geometry = screen::stream_geometry(o.get("geometry"))?;
    let capabilities = screen::capabilities(o.get("capabilities"))?;
    let control = boolean(o.get("control"))?;
    let display_name = match o.get("displayName") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.len() <= DISPLAY_NAME => Some(s.clone()),
        Some(_) => return None,
    };
    Some(Start { stream_id, sequence, request_id, fps, bitrate, stream, transport, geometry, capabilities, control, display_name })
}

/// The stream a start that failed its checks names, so this device can answer `invalid`.
pub fn start_stream_id(plain: &[u8]) -> Option<String> {
    if plain.len() > START {
        return None;
    }
    request_id(phone::strict(plain)?.get("streamId"))
}

const CONTROL_REASONS: [&str; 12] = ["user", "local_stop", "disabled", "permission", "locked", "busy", "focus", "timeout", "rate", "invalid", "source_changed", "failed"];

/// What the Mac says about control.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlState {
    Active { session: u64, input: sc::InputCapabilities },
    Ended(String),
    Refused(String),
}

/// The Mac's `display.control` (`state`; a viewer's `action` is not read here). An unknown reason reads as `failed`.
pub fn decode_control(plain: &[u8]) -> Option<(String, u64, ControlState)> {
    let o = object(plain, MESSAGE)?;
    let (stream_id, sequence) = header(&o)?;
    let reason = || o.get("reason").and_then(Value::as_str).filter(|r| CONTROL_REASONS.contains(r)).unwrap_or("failed").to_string();
    let state = match o.get("state")?.as_str()? {
        "active" => ControlState::Active { session: counter(o.get("session"))?, input: serde_json::from_value(o.get("input")?.clone()).ok()? },
        "ended" => ControlState::Ended(reason()),
        "refused" => ControlState::Refused(reason()),
        _ => return None,
    };
    Some((stream_id, sequence, state))
}

const STOP_REASONS: [&str; 11] = ["user", "left_screen", "screen_off", "local_stop", "disabled", "permission", "locked", "source_changed", "invalid", "timeout", "failed"];

/// `display.stop` from either side: an unknown or missing reason reads as `failed`.
pub fn decode_stop(plain: &[u8]) -> Option<(String, u64, String)> {
    let o = object(plain, MESSAGE)?;
    let (stream_id, sequence) = header(&o)?;
    let reason = o.get("reason").and_then(Value::as_str).filter(|r| STOP_REASONS.contains(r)).unwrap_or("failed");
    Some((stream_id, sequence, reason.to_string()))
}

pub fn started_payload(stream_id: &str, sequence: u64) -> Value {
    screen::started_payload(stream_id, sequence)
}

/// `keyframe` is written only when true.
pub fn ack_payload(stream_id: &str, sequence: u64, frame: u32, decode_ms: u32, keyframe: bool) -> Value {
    screen::ack_payload(stream_id, sequence, frame, decode_ms, keyframe)
}

pub fn stop_payload(stream_id: &str, sequence: u64, reason: &str) -> Value {
    screen::stop_payload(stream_id, sequence, reason)
}

/// `begin` or `end`.
pub fn control_payload(stream_id: &str, sequence: u64, action: &str) -> Value {
    json!({"version": 1, "streamId": stream_id, "sequence": sequence, "action": action})
}

/// A touch at (`tx`, `ty`) on a view of `view` pixels showing a `video` picture letterboxed (fitted and centred): the
/// position as fractions of the picture, or None on the letterbox (nothing is sent). docs/protocol.md "Geometry".
pub fn letterbox(view: (f64, f64), video: (f64, f64), touch: (f64, f64)) -> Option<(f64, f64)> {
    let (vw, vh) = view;
    let (w, h) = video;
    if !(vw > 0.0 && vh > 0.0 && w > 0.0 && h > 0.0) {
        return None;
    }
    let k = (vw / w).min(vh / h);
    let (pw, ph) = (w * k, h * k);
    let (left, top) = ((vw - pw) / 2.0, (vh - ph) / 2.0);
    let (x, y) = ((touch.0 - left) / pw, (touch.1 - top) / ph);
    ((0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y)).then_some((x, y))
}

// MARK: - The engine

/// What the view shows about controlling the Mac.
#[derive(Clone, Debug, Default)]
struct ControlView {
    /// The two devices' capabilities leave something to control with.
    capable: bool,
    /// The Mac said control may be asked for.
    allowed: bool,
    /// off, starting or active.
    phase: &'static str,
    input: sc::InputCapabilities,
    /// Why control ended or was refused, until it starts again.
    note: Option<String>,
}

struct Stream {
    handle: u64,
    start: Start,
    mac_seq: u64,
    my_seq: u64,
    geometry: sc::Geometry,
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
            "streamId": self.start.stream_id,
            "width": self.geometry.width,
            "height": self.geometry.height,
            "fps": self.start.fps,
            "bitrate": self.start.bitrate,
            "screenshots": false,
            "displayName": self.start.display_name,
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
struct Mac {
    pending: Option<Request>,
    last_request: Option<Instant>,
    stream: Option<Stream>,
    ended: VecDeque<String>,
}

impl Mac {
    fn known(&self, stream_id: &str) -> bool {
        self.ended.iter().any(|s| s == stream_id) || self.stream.as_ref().is_some_and(|s| s.start.stream_id == stream_id)
    }
    fn remember(&mut self, stream_id: &str) {
        self.ended.retain(|s| s != stream_id);
        self.ended.push_back(stream_id.to_string());
        while self.ended.len() > REMEMBERED {
            self.ended.pop_front();
        }
    }
}

/// Every Mac's screen, by device ID, and the frame queues the host pulls from, by stream.
#[derive(Default)]
pub struct State {
    macs: HashMap<String, Mac>,
    queues: HashMap<u64, Arc<FrameQueue>>,
    ticking: bool,
    flushing: bool,
    sim: HashMap<String, SimStream>,
}

/// What a change sends and tells the host, done after the state's lock is released.
#[derive(Default)]
struct Effects {
    sends: Vec<(&'static str, String)>,
    events: Vec<(&'static str, u64, Value)>,
    opened: Vec<(u64, Arc<FrameQueue>)>,
    closed: Vec<u64>,
}

impl Effects {
    fn send(&mut self, kind: &'static str, v: Value) {
        self.sends.push((kind, v.to_string()));
    }
    fn event(&mut self, what: &'static str, id: u64, v: Value) {
        self.events.push((what, id, v));
    }
    fn apply(self, inner: &Inner, device_id: &str) {
        if !self.opened.is_empty() || !self.closed.is_empty() {
            let mut st = inner.phone.display.lock().unwrap();
            for (handle, queue) in self.opened {
                st.queues.insert(handle, queue);
            }
            for handle in self.closed {
                st.queues.remove(&handle);
            }
        }
        for (kind, plain) in self.sends {
            // A stop goes whatever this device's switch now says: See Mac screens may have just been turned off.
            let _ = if kind == "display.stop" { inner.encrypted_to_peer(device_id, FEATURE, kind, plain.into_bytes(), true) } else { inner.encrypted_to(device_id, FEATURE, kind, plain) };
        }
        for (what, id, v) in self.events {
            phone::emit(inner, Area::Display, device_id, what, id, v);
        }
    }
}

fn with<R>(inner: &Inner, device_id: &str, f: impl FnOnce(&mut Mac, &mut Effects) -> R) -> R {
    let mut fx = Effects::default();
    let r = {
        let mut st = inner.phone.display.lock().unwrap();
        let mac = st.macs.entry(device_id.to_string()).or_default();
        f(mac, &mut fx)
    };
    fx.apply(inner, device_id);
    r
}

/// See Mac screens is on here for the device, and the device shows the key (it has a screen grant for this device).
fn available(inner: &Inner, device_id: &str) -> bool {
    inner.policy_for(device_id).get(FEATURE) && inner.remote_features(device_id).is_some_and(|r| r.get(FEATURE))
}

/// Ends the stream here: the host's frames stop, it is remembered, the host is told.
fn end(mac: &mut Mac, fx: &mut Effects, reason: &str, by: &str) {
    let Some(stream) = mac.stream.take() else { return };
    stream.queue.close();
    fx.closed.push(stream.handle);
    mac.remember(&stream.start.stream_id);
    fx.event("stopped", stream.handle, json!({"stream": stream.handle, "reason": reason, "by": by}));
}

/// Sends `display.stop` (control's stop packet first when control is on) and ends the stream.
fn stop(mac: &mut Mac, fx: &mut Effects, reason: &str) {
    if let Some(s) = mac.stream.as_mut() {
        if s.control.phase == "active" {
            if let Some(p) = s.sender.as_mut().and_then(Sender::stop) {
                fx.send("display.input", serde_json::to_value(&p).unwrap_or(Value::Null));
            }
        }
        let seq = s.next();
        fx.send("display.stop", stop_payload(&s.start.stream_id, seq, reason));
    }
    end(mac, fx, reason, "here");
}

/// Acknowledges a frame; a key frame is asked for at most once a second.
fn ack(s: &mut Stream, fx: &mut Effects, frame: u32, decode_ms: u32, want_key: bool) {
    let keyframe = want_key && s.last_key_request.is_none_or(|t| t.elapsed() >= KEY_SPACING);
    if keyframe {
        s.last_key_request = Some(Instant::now());
    }
    let seq = s.next();
    fx.send("display.ack", ack_payload(&s.start.stream_id, seq, frame, decode_ms, keyframe));
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
    s.control.input = sc::InputCapabilities::default();
    s.control.note = note;
    fx.event("control", s.handle, s.control_json());
}

pub(crate) fn receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) {
    if inner.simulating.load(Ordering::Relaxed) {
        sim_receive(inner, device_id, kind, plain);
        return;
    }
    match kind {
        "display.status" => {
            let Some((request, status)) = decode_status(plain) else { return };
            with(inner, device_id, |m, fx| {
                if m.pending.as_ref().map(|r| r.id.as_str()) != Some(request.as_str()) {
                    return;
                }
                if status != "waiting" {
                    m.pending = None;
                }
                fx.event("status", 0, json!({"requestId": request, "status": status}));
            });
        }
        "display.start" => start(inner, device_id, plain),
        "display.frame" => {
            let Some(part) = screen::decode_part(plain) else { return };
            frame_part(inner, device_id, part);
        }
        "display.stats" => {
            let Some(stats) = screen::decode_stats(plain) else { return };
            with(inner, device_id, |m, fx| {
                let Some(s) = m.stream.as_mut().filter(|s| s.start.stream_id == stats.stream_id && stats.sequence > s.mac_seq) else { return };
                s.mac_seq = stats.sequence;
                s.last_activity = Instant::now();
                fx.event(
                    "stats",
                    s.handle,
                    json!({"stream": s.handle, "latencyMs": stats.latency_ms, "rttMs": stats.rtt_ms, "bitrate": stats.bitrate, "sentBitrate": stats.sent_bitrate, "fps": stats.fps, "dropped": stats.dropped}),
                );
            });
        }
        "display.stop" => {
            let Some((stream_id, seq, reason)) = decode_stop(plain) else { return };
            with(inner, device_id, |m, fx| {
                if m.stream.as_ref().is_some_and(|s| s.start.stream_id == stream_id && seq > s.mac_seq) {
                    end(m, fx, &reason, "mac");
                }
            });
        }
        "display.geometry" => {
            let Some((stream_id, seq, geometry)) = screen::decode_geometry(plain) else { return };
            let now = crate::session::clock_ms();
            with(inner, device_id, |m, fx| {
                let Some(s) = m.stream.as_mut().filter(|s| s.start.stream_id == stream_id && seq > s.mac_seq) else { return };
                s.mac_seq = seq;
                s.last_activity = Instant::now();
                // A higher generation of the same display; anything else is ignored.
                if geometry.generation <= s.geometry.generation || geometry.source != s.geometry.source {
                    return;
                }
                s.geometry = geometry;
                // Input not sent yet is dropped (the Mac has released what was held) and the new generation acknowledged
                // before anything else; frames of the new size start with a key frame.
                if let Some(sender) = s.sender.as_mut() {
                    for packet in sender.geometry_changed(geometry.generation, now) {
                        fx.send("display.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
                    }
                }
                fx.event("geometry", s.handle, json!({"stream": s.handle, "generation": geometry.generation, "width": geometry.width, "height": geometry.height}));
            });
        }
        "display.control" => {
            let Some((stream_id, seq, state)) = decode_control(plain) else { return };
            let now = crate::session::clock_ms();
            let started = with(inner, device_id, |m, fx| {
                let Some(s) = m.stream.as_mut().filter(|s| s.start.stream_id == stream_id && seq > s.mac_seq) else { return false };
                s.mac_seq = seq;
                s.last_activity = Instant::now();
                match state {
                    ControlState::Active { session, input } => {
                        if s.control.phase != "starting" {
                            // Control this device did not ask for (or no longer wants) ends at once.
                            let seq = s.next();
                            fx.send("display.control", control_payload(&s.start.stream_id, seq, "end"));
                            return false;
                        }
                        let mut sender = Sender::new(now);
                        let binding = Binding { transport: s.start.transport, connection: s.connection, stream: s.start.stream };
                        let packets = sender.begin(session, input, binding, s.geometry.generation, now);
                        if packets.is_empty() {
                            end_control(s, fx, Some("failed".into()));
                            return false;
                        }
                        for packet in packets {
                            fx.send("display.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
                        }
                        s.sender = Some(sender);
                        s.control.phase = "active";
                        s.control.input = input;
                        s.control.note = None;
                        fx.event("control", s.handle, s.control_json());
                        true
                    }
                    ControlState::Ended(reason) | ControlState::Refused(reason) => {
                        if s.control.phase == "off" {
                            return false;
                        }
                        let note = (reason != "user").then_some(reason);
                        end_control(s, fx, note);
                        false
                    }
                }
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
        // A start that names its stream is answered `invalid`, once, with this device's sequence 1.
        if let Some(stream_id) = start_stream_id(plain) {
            with(inner, device_id, |m, fx| {
                if !m.known(&stream_id) {
                    fx.send("display.stop", stop_payload(&stream_id, 1, "invalid"));
                    m.remember(&stream_id);
                }
            });
        }
        return;
    };
    let connection = inner.screen_connection(device_id).unwrap_or([0; 16]);
    let handle = inner.next_id();
    let queue = Arc::new(FrameQueue::default());
    let fresh = with(inner, device_id, |m, fx| {
        if m.known(&start.stream_id) {
            return false;
        }
        // Only the answer to this device's open request is shown: otherwise nobody is looking, and the Mac must not
        // stream.
        if m.pending.as_ref().map(|r| r.id.as_str()) != Some(start.request_id.as_str()) {
            fx.send("display.stop", stop_payload(&start.stream_id, 1, "left_screen"));
            m.remember(&start.stream_id);
            return false;
        }
        m.pending = None;
        end(m, fx, "replaced", "mac");
        let capable = sc::Capabilities::negotiated_input(start.capabilities, viewer_capabilities()).is_ok() && connection != [0; 16];
        let mut s = Stream {
            handle,
            geometry: start.geometry,
            control: ControlView { capable, allowed: capable && start.control, phase: "off", ..Default::default() },
            mac_seq: start.sequence,
            start: start.clone(),
            my_seq: 0,
            connection,
            assembler: Assembler::default(),
            waiting_for_key: true,
            last_key_request: None,
            last_activity: Instant::now(),
            decode_ms: 0,
            queue: queue.clone(),
            sender: None,
        };
        let seq = s.next();
        fx.send("display.started", started_payload(&s.start.stream_id, seq));
        fx.opened.push((handle, queue.clone()));
        fx.event("started", handle, s.json());
        m.stream = Some(s);
        true
    });
    if fresh {
        ensure_ticking(inner);
    }
}

fn frame_part(inner: &Inner, device_id: &str, part: Part) {
    with(inner, device_id, |m, fx| {
        let Some(s) = m.stream.as_mut().filter(|s| s.start.stream_id == part.stream_id && part.sequence > s.mac_seq) else { return };
        s.mac_seq = part.sequence;
        s.last_activity = Instant::now();
        match s.assembler.add(part) {
            Assembled::Pending | Assembled::Ignored => {}
            Assembled::Lost(frame) => {
                s.waiting_for_key = true;
                ack(s, fx, frame, 0, true);
            }
            Assembled::Complete(frame) => {
                if s.waiting_for_key && !frame.key {
                    // Dropped while waiting for a key frame: acknowledged so the Mac's count drains.
                    ack(s, fx, frame.frame, 0, true);
                    return;
                }
                s.waiting_for_key = false;
                let dropped = s.queue.push(frame);
                if !dropped.is_empty() {
                    // The host fell behind: those frames went, and the next ones wait for a key frame.
                    s.waiting_for_key = true;
                    for f in &dropped {
                        ack(s, fx, *f, 0, true);
                    }
                }
            }
        }
    });
}

/// The stream is one of a Mac's (its frames are pulled through display.rs).
pub(crate) fn owns(inner: &Inner, stream: u64) -> bool {
    inner.phone.display.lock().unwrap().queues.contains_key(&stream)
}

/// The next whole frame of a stream for the host: Ok(None) after the timeout, Err(None) once the stream has ended,
/// Err(Some(size)) when `capacity` is too small (the frame stays first).
pub(crate) fn take(inner: &Inner, stream: u64, timeout: Duration, capacity: usize) -> Result<Option<Frame>, Option<usize>> {
    let Some(queue) = inner.phone.display.lock().unwrap().queues.get(&stream).cloned() else { return Err(None) };
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
        let st = inner.phone.display.lock().unwrap();
        st.macs.iter().find(|(_, m)| m.stream.as_ref().is_some_and(|s| s.handle == stream)).map(|(d, _)| d.clone())
    };
    if let Some(device) = device {
        let number = frame.frame;
        with(inner, &device, |m, fx| {
            if let Some(s) = m.stream.as_mut().filter(|s| s.handle == stream) {
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
        let mut st = inner.phone.display.lock().unwrap();
        if st.ticking {
            return;
        }
        st.ticking = true;
    }
    phone::after(inner, Duration::from_secs(1), tick);
}

fn tick(inner: &Inner) {
    let devices: Vec<String> = inner.phone.display.lock().unwrap().macs.keys().cloned().collect();
    let mut busy = false;
    for d in devices {
        busy |= with(inner, &d, |m, fx| {
            if m.pending.as_ref().is_some_and(|r| r.at.elapsed() >= REQUEST_LIFETIME) {
                let r = m.pending.take().unwrap();
                fx.event("status", 0, json!({"requestId": r.id, "status": "expired"}));
            }
            if m.stream.as_ref().is_some_and(|s| s.last_activity.elapsed() >= STREAM_TIMEOUT) {
                stop(m, fx, "timeout");
            }
            m.pending.is_some() || m.stream.is_some()
        });
    }
    let again = {
        let mut st = inner.phone.display.lock().unwrap();
        st.ticking = busy;
        busy
    };
    if again {
        phone::after(inner, Duration::from_secs(1), tick);
    }
}

/// Motion, scrolling and heartbeats go about 60 times a second while any Mac is controlled.
fn ensure_flushing(inner: &Inner) {
    {
        let mut st = inner.phone.display.lock().unwrap();
        if st.flushing {
            return;
        }
        st.flushing = true;
    }
    phone::after(inner, FLUSH_EVERY, flush_all);
}

fn flush_all(inner: &Inner) {
    let devices: Vec<String> = inner.phone.display.lock().unwrap().macs.keys().cloned().collect();
    let now = crate::session::clock_ms();
    let mut active = false;
    for d in devices {
        active |= with(inner, &d, |m, fx| {
            let Some(sender) = m.stream.as_mut().and_then(|s| s.sender.as_mut()).filter(|s| s.active()) else { return false };
            for packet in sender.flush(now) {
                fx.send("display.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
            }
            true
        });
    }
    let again = {
        let mut st = inner.phone.display.lock().unwrap();
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

fn button_of(name: &str) -> Option<sc::Button> {
    serde_json::from_value(json!(name)).ok()
}

pub(crate) fn command(inner: &Inner, device_id: &str, command: &Value) -> Value {
    match phone::op(command) {
        Some("status") => {
            let on = available(inner, device_id);
            let enabled = inner.policy_for(device_id).get(FEATURE);
            with(inner, device_id, |m, _| {
                phone::ok(json!({
                    "enabled": enabled,
                    "available": on,
                    // The Mac decides control per stream (its Remote control permission and macOS Accessibility).
                    "controlAvailable": on,
                    "pending": m.pending.as_ref().map(|r| r.id.clone()),
                    "stream": m.stream.as_ref().map(Stream::json),
                }))
            })
        }
        Some("request") => {
            if !available(inner, device_id) {
                return phone::error("feature_off");
            }
            let id = crate::crypto::uuid4();
            let answer = with(inner, device_id, |m, _| {
                if let Some(s) = &m.stream {
                    return Err(phone::ok(json!({"showing": true, "stream": s.handle})));
                }
                if let Some(r) = &m.pending {
                    return Err(phone::ok(json!({"requestId": r.id, "waiting": true})));
                }
                if m.last_request.is_some_and(|t| t.elapsed() < REQUEST_SPACING) {
                    return Err(phone::error("too_soon"));
                }
                m.last_request = Some(Instant::now());
                m.pending = Some(Request { id: id.clone(), at: Instant::now() });
                Ok(())
            });
            if let Err(answer) = answer {
                return answer;
            }
            if inner.encrypted_to(device_id, FEATURE, "display.request", request_payload(&id).to_string()).is_err() {
                with(inner, device_id, |m, _| m.pending = None);
                return phone::error("not_connected");
            }
            ensure_ticking(inner);
            phone::ok(json!({"requestId": id}))
        }
        Some("stop") => {
            // user (Stop), left_screen (the view closed or the app left the screen) or screen_off.
            let reason = match command.get("reason").and_then(Value::as_str) {
                None | Some("user") => "user",
                Some("left_screen") => "left_screen",
                Some("screen_off") => "screen_off",
                Some(_) => return phone::error("invalid"),
            };
            with(inner, device_id, |m, fx| {
                m.pending = None;
                stop(m, fx, reason);
            });
            phone::ok(json!({}))
        }
        Some("decoded") => {
            let ms = command.get("ms").and_then(Value::as_u64).unwrap_or(0).min(60_000) as u32;
            with(inner, device_id, |m, _| {
                if let Some(s) = m.stream.as_mut() {
                    s.decode_ms = ms;
                }
            });
            phone::ok(json!({}))
        }
        Some("keyframe") => {
            // The host's decoder failed: frames wait for the next key frame, which is asked for now.
            with(inner, device_id, |m, fx| {
                if let Some(s) = m.stream.as_mut() {
                    s.waiting_for_key = true;
                    let newest = s.assembler.newest();
                    if newest > 0 {
                        ack(s, fx, newest, 0, true);
                    }
                }
            });
            phone::ok(json!({}))
        }
        Some("control_begin") => with(inner, device_id, |m, fx| {
            let Some(s) = m.stream.as_mut().filter(|s| s.control.capable && s.control.allowed && s.control.phase == "off") else { return phone::error("unavailable") };
            s.control.phase = "starting";
            s.control.note = None;
            let seq = s.next();
            fx.send("display.control", control_payload(&s.start.stream_id, seq, "begin"));
            fx.event("control", s.handle, s.control_json());
            phone::ok(json!({}))
        }),
        Some("control_end") => with(inner, device_id, |m, fx| {
            let Some(s) = m.stream.as_mut() else { return phone::ok(json!({})) };
            match s.control.phase {
                "starting" => {
                    let seq = s.next();
                    fx.send("display.control", control_payload(&s.start.stream_id, seq, "end"));
                }
                "active" => {
                    // The contract's stop packet ends control; the stream goes on.
                    if let Some(packet) = s.sender.as_mut().and_then(Sender::stop) {
                        fx.send("display.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
                    }
                }
                _ => return phone::ok(json!({})),
            }
            end_control(s, fx, None);
            phone::ok(json!({}))
        }),
        Some("touch" | "navigate") => phone::error("unsupported"),
        Some(op @ ("pointer" | "button" | "scroll" | "text" | "key" | "press")) => {
            let position = || Some((f(command, "x")?, f(command, "y")?));
            let action = match op {
                "pointer" => {
                    let Some((x, y)) = position() else { return phone::error("invalid") };
                    Some(Action::Pointer { x, y })
                }
                "button" => {
                    let Some((x, y)) = position() else { return phone::error("invalid") };
                    let Some(button) = command.get("button").and_then(Value::as_str).map_or(Some(sc::Button::Primary), button_of) else { return phone::error("invalid") };
                    Some(Action::Button { button, down: command.get("down").and_then(Value::as_bool).unwrap_or(true), x, y })
                }
                "scroll" => {
                    let Some((x, y)) = position() else { return phone::error("invalid") };
                    let dx = command.get("dx").and_then(Value::as_f64).unwrap_or(0.0).round() as i64;
                    let dy = command.get("dy").and_then(Value::as_f64).unwrap_or(0.0).round() as i64;
                    Some(Action::Scroll { dx, dy, x, y })
                }
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
            with(inner, device_id, |m, fx| {
                let Some(sender) = m.stream.as_mut().filter(|s| s.control.phase == "active").and_then(|s| s.sender.as_mut()) else { return phone::ok(json!({"taken": false})) };
                let taken = match (&action, press) {
                    (_, Some(key)) => sender.press(key, command.get("shift").and_then(Value::as_bool).unwrap_or(false)),
                    (Some(a), None) => sender.submit(a.clone()),
                    _ => false,
                };
                // Transitions go at once when the budget allows; motion and scrolling wait for the next flush.
                let motion = matches!(action, Some(Action::Scroll { .. }) | Some(Action::Pointer { .. }));
                if taken && !motion {
                    for packet in sender.flush(now) {
                        fx.send("display.input", serde_json::to_value(&packet).unwrap_or(Value::Null));
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
    with(inner, device_id, |m, fx| {
        if !local {
            // See Mac screens turned off here.
            m.pending = None;
            stop(m, fx, "user");
        } else if remote == Some(false) {
            // The Mac no longer grants this device its screen.
            m.pending = None;
            end(m, fx, "disabled", "mac");
        }
    });
}

pub(crate) fn disconnected(inner: &Inner, device_id: &str) {
    with(inner, device_id, |m, fx| {
        m.pending = None;
        end(m, fx, "disconnected", "here");
    });
    sim_stop(inner, device_id);
}

pub(crate) fn forgotten(inner: &Inner, device_id: &str) {
    disconnected(inner, device_id);
    inner.phone.display.lock().unwrap().macs.remove(device_id);
}

// MARK: - A simulated Mac (sim.rs): the synthetic test clip as its display, control and the input it gets

struct SimStream {
    stream_id: String,
    running: Arc<std::sync::atomic::AtomicBool>,
    sequence: Arc<std::sync::atomic::AtomicU64>,
    generation: u64,
}

pub(crate) fn sim_incoming(kind: &str) -> Option<Incoming> {
    let (kind, max): (&'static str, usize) = match kind {
        "display.request" => ("display.request", REQUEST),
        "display.started" => ("display.started", MESSAGE),
        "display.ack" => ("display.ack", MESSAGE),
        "display.input" => ("display.input", sc::MAX_PACKET_BYTES),
        _ => return None,
    };
    Some(Incoming { area: Area::Display, kind, feature: FEATURE, max, with_message_id: false })
}

/// The simulated Mac's capabilities: a full-display H.264 source that takes a pointer, keys and text.
fn sim_capabilities() -> Value {
    json!({"v": 1, "screenSource": true, "fullDisplaySource": true, "h264Encode": true, "captureRestoreSupported": true,
           "inputHost": {"pointer": true, "keys": true, "text": true}})
}

fn sim_send(inner: &Inner, device_id: &str, kind: &'static str, v: &Value) {
    let _ = inner.encrypted_to(device_id, FEATURE, kind, v.to_string());
}

fn sim_stop(inner: &Inner, device_id: &str) {
    if let Some(s) = inner.phone.display.lock().unwrap().sim.remove(device_id) {
        s.running.store(false, Ordering::Relaxed);
    }
}

/// The simulated Mac's stream ID and its next sequence.
fn sim_next(inner: &Inner, device: &str) -> Option<(String, u64)> {
    let st = inner.phone.display.lock().unwrap();
    let s = st.sim.get(device)?;
    Some((s.stream_id.clone(), s.sequence.fetch_add(1, Ordering::Relaxed) + 1))
}

/// Tests only: the simulated Mac's display changes size (a new geometry generation, 160 by 96).
pub(crate) fn sim_change_geometry(inner: &Inner, device_id: &str) -> bool {
    let generation = {
        let mut st = inner.phone.display.lock().unwrap();
        let Some(s) = st.sim.get_mut(device_id) else { return false };
        s.generation += 1;
        s.generation
    };
    let Some((stream_id, seq)) = sim_next(inner, device_id) else { return false };
    let (width, height) = if generation % 2 == 0 { (160, 96) } else { (96, 160) };
    sim_send(inner, device_id, "display.geometry", &json!({"version": 1, "streamId": stream_id, "sequence": seq, "geometry": {"generation": generation, "source": 1, "kind": "display", "width": width, "height": height}}));
    true
}

pub(crate) fn sim_receive(inner: &Inner, device_id: &str, kind: &str, plain: &[u8]) -> bool {
    use std::sync::atomic::{AtomicBool, AtomicU64};
    match kind {
        "display.request" => {
            let Some(o) = phone::versioned(plain, REQUEST) else { return true };
            let Some(request) = request_id(o.get("requestId")) else { return true };
            // As a Mac with Allow without asking: a moment of waiting, then the stream.
            sim_send(inner, device_id, "display.status", &json!({"version": 1, "requestId": request, "status": "waiting"}));
            sim_stop(inner, device_id);
            let stream_id = crate::crypto::uuid4();
            let running = Arc::new(AtomicBool::new(true));
            let sequence = Arc::new(AtomicU64::new(1));
            inner.phone.display.lock().unwrap().sim.insert(device_id.to_string(), SimStream { stream_id: stream_id.clone(), running: running.clone(), sequence: sequence.clone(), generation: 1 });
            let device = device_id.to_string();
            phone::after(inner, Duration::from_millis(300), move |inner| {
                let start = json!({"version": 1, "streamId": stream_id, "sequence": 1, "requestId": request, "codec": "h264", "fps": 10, "bitrate": 300_000,
                                   "stream": 1, "transport": 1, "geometry": {"generation": 1, "source": 1, "kind": "display", "width": 96, "height": 160},
                                   "capabilities": sim_capabilities(), "control": true, "displayName": "Built-in Retina Display"});
                sim_send(inner, &device, "display.start", &start);
                sim_frames_loop(inner, device, stream_id, running, sequence, 0);
            });
        }
        "display.started" => {}
        "display.ack" => {
            if let Some(o) = phone::versioned(plain, MESSAGE) {
                phone::emit(inner, Area::Display, device_id, "sim_ack", 0, json!({"frame": o.get("frame"), "keyframe": o.get("keyframe")}));
            }
        }
        "display.stop" => {
            let reason = decode_stop(plain).map(|s| s.2);
            sim_stop(inner, device_id);
            phone::emit(inner, Area::Display, device_id, "sim_stop", 0, json!({"reason": reason}));
        }
        "display.control" => {
            let Some(o) = phone::versioned(plain, MESSAGE) else { return true };
            let Some((stream_id, seq)) = sim_next(inner, device_id) else { return true };
            match o.get("action").and_then(Value::as_str) {
                Some("begin") => sim_send(inner, device_id, "display.control", &json!({"version": 1, "streamId": stream_id, "sequence": seq, "state": "active", "session": 1, "input": {"pointer": true, "keys": true, "text": true}})),
                Some("end") => sim_send(inner, device_id, "display.control", &json!({"version": 1, "streamId": stream_id, "sequence": seq, "state": "ended", "reason": "user"})),
                _ => {}
            }
        }
        "display.input" => {
            let Ok(packet) = sc::Packet::decode(plain) else { return true };
            let ours = inner.screen_connection(device_id).is_some_and(|c| c == packet.connection);
            let input = serde_json::to_value(&packet.input).unwrap_or(Value::Null);
            let op = input.get("op").and_then(Value::as_str).unwrap_or_default().to_string();
            phone::emit(inner, Area::Display, device_id, "sim_input", 0, json!({"op": op, "seq": packet.seq, "geometry": packet.geometry, "session": packet.session, "stream": packet.stream, "transport": packet.transport, "connection": ours, "input": input}));
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
    let frames = screen::sim_frames();
    let (key, sets, data) = &frames[(n as usize) % frames.len()];
    let seq = sequence.fetch_add(1, Ordering::Relaxed) + 1;
    let part = Part { stream_id: stream_id.clone(), sequence: seq, frame: (n + 1) as u32, part: 0, key: *key, parameter_sets: *sets, last: true, capture_micros: (n * 100_000) as i64, payload: data.clone() };
    let _ = inner.encrypted_to_peer(&device, FEATURE, "display.frame", screen::encode_part(&part), false);
    if n % 10 == 9 {
        let seq = sequence.fetch_add(1, Ordering::Relaxed) + 1;
        sim_send(inner, &device, "display.stats", &json!({"version": 1, "streamId": stream_id, "sequence": seq, "latencyMs": 30, "rttMs": 5, "bitrate": 300_000, "sentBitrate": 280_000, "fps": 10, "dropped": 0}));
    }
    phone::after(inner, Duration::from_millis(100), move |inner| sim_frames_loop(inner, device, stream_id, running, sequence, n + 1));
}

#[cfg(test)]
mod tests;
