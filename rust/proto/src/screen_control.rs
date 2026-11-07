//! Unwired draft screen/control contract. No native feature is enabled by this module.
//!
//! Native adapters own grants, permissions, capture and injection. They pass a fresh local
//! authority snapshot plus the sender's authenticated binding; neither comes from packet JSON.
//! Every transition's `release` must be applied before dispatching another native input.

use serde::{Deserialize, Serialize};

pub const PROTOCOL: &str = "bridgey-screen-control-draft1";
pub const VERSION: u8 = 1;
// Preserve existing remote_input_draft1 limits while adding absolute selected-source input.
pub const MAX_SEQUENCE: u64 = 9_007_199_254_740_991;
pub const MAX_PACKET_BYTES: usize = 2_048;
pub const MAX_TEXT_BYTES: usize = 1_024;
pub const MAX_TEXT_SCALARS: usize = 256;
pub const IDLE_MILLIS: u64 = 6_000;
pub const MAX_DIMENSION: u32 = 32_768;
pub const MAX_PIXELS: u64 = 67_108_864;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct InputCapabilities {
    pub pointer: bool,
    pub touch: bool,
    pub keys: bool,
    pub text: bool,
    pub navigation: bool,
}

impl InputCapabilities {
    fn any(self) -> bool {
        self.pointer || self.touch || self.keys || self.text || self.navigation
    }
    fn intersect(self, other: Self) -> Self {
        Self {
            pointer: self.pointer && other.pointer,
            touch: self.touch && other.touch,
            keys: self.keys && other.keys,
            text: self.text && other.text,
            navigation: self.navigation && other.navigation,
        }
    }
}

/// Capabilities are advisory support, never permission. Missing flags remain false; unknown flags
/// may be ignored for additive negotiation. A new operation still requires an understood decoder.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Capabilities {
    pub v: u8,
    pub screen_source: bool,
    pub screen_viewer: bool,
    pub full_display_source: bool,
    pub h264_encode: bool,
    pub h264_decode: bool,
    pub input_host: InputCapabilities,
    pub input_controller: InputCapabilities,
    pub capture_requires_prompt: bool,
    pub capture_restore_supported: bool,
}

impl Capabilities {
    pub fn decode(bytes: &[u8]) -> Result<Self, Rejection> {
        if bytes.len() > MAX_PACKET_BYTES {
            return Err(Rejection::PacketSize);
        }
        let capabilities: Self = serde_json::from_slice(bytes).map_err(|_| Rejection::Malformed)?;
        if capabilities.v != VERSION {
            return Err(Rejection::Version);
        }
        Ok(capabilities)
    }

    pub fn negotiated_input(host: Self, controller: Self) -> Result<InputCapabilities, Rejection> {
        if host.v != VERSION || controller.v != VERSION {
            return Err(Rejection::Version);
        }
        if !host.screen_source || !host.full_display_source || !host.h264_encode || !controller.screen_viewer || !controller.h264_decode {
            return Err(Rejection::Unsupported);
        }
        let input = host.input_host.intersect(controller.input_controller);
        if !input.any() {
            return Err(Rejection::Unsupported);
        }
        Ok(input)
    }
}

/// Pinned identity, not a display name or self-reported platform. Host-local only: not serde.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PeerIdentity {
    pub device: [u8; 16],
    pub key_sha256: [u8; 32],
}

impl PeerIdentity {
    fn valid(self) -> bool {
        self.device != [0; 16] && self.key_sha256 != [0; 32]
    }
}

/// `transport` is a host-issued generation of an authenticated encrypted transport.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Binding {
    pub peer: PeerIdentity,
    pub transport: u64,
    /// Unique authenticated-transport transcript nonce, never reused after process restart.
    pub connection: [u8; 16],
}

/// Fresh LOCAL state, supplied on every input and on every permission/grant/lifecycle event.
/// A native adapter must advance `generation` whenever any authority/source/connection changes.
/// Persistent grants stay in the host's secure store; no state here enables or syncs them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Authority {
    pub generation: u64,
    pub binding: Binding,
    pub stream: u64,
    pub trusted_device: bool,
    pub view_grant: bool,
    pub control_grant: bool,
    pub capture_ready: bool,
    /// Permission AND the selected native target's eligibility for the attempted operation.
    /// For key/text this includes focused-editor/source scope, not just Accessibility enabled.
    pub input_ready: bool,
    pub unlocked: bool,
    pub stream_active: bool,
    pub host: Capabilities,
    pub controller: Capabilities,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    Display,
    Window,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Geometry {
    pub generation: u64,
    pub source: u64,
    pub kind: SourceKind,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PixelPoint {
    pub x: u32,
    pub y: u32,
}

impl Geometry {
    pub fn valid(self) -> bool {
        valid_counter(self.generation)
            && valid_counter(self.source)
            && self.width > 0
            && self.height > 0
            && self.width <= MAX_DIMENSION
            && self.height <= MAX_DIMENSION
            && u64::from(self.width) * u64::from(self.height) <= MAX_PIXELS
    }

    /// Coordinates are fractions of the captured FULL display, after the viewer excludes its
    /// letterbox. The host adapter maps these pixels to its chosen display (scale/origin/rotation).
    pub fn pixel(self, x: f64, y: f64) -> Option<PixelPoint> {
        if !self.valid() || !coordinate(x) || !coordinate(y) {
            return None;
        }
        Some(PixelPoint { x: (x * f64::from(self.width - 1)).round() as u32, y: (y * f64::from(self.height - 1)).round() as u32 })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
#[serde(rename_all = "snake_case")]
pub enum Button {
    Primary,
    Secondary,
    Middle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[repr(u8)]
#[serde(rename_all = "snake_case")]
pub enum Key {
    Enter,
    Tab,
    Backspace,
    Escape,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    Delete,
    Shift,
    Control,
    Alt,
    Meta,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Navigation {
    Back,
    Home,
    Recents,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TouchPhase {
    Down,
    Move,
    Up,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Input {
    // Empty structs preserve strict unknown-field rejection; serde unit variants ignore fields.
    GeometryAck {},
    Pointer { x: f64, y: f64 },
    Button { button: Button, down: bool, x: f64, y: f64 },
    Scroll { dx: i32, dy: i32, x: f64, y: f64 },
    Key { key: Key, down: bool },
    Text { text: String },
    Navigate { action: Navigation },
    Touch { contact: u8, phase: TouchPhase, x: f64, y: f64 },
    Heartbeat {},
    Stop {},
}

impl std::fmt::Debug for Input {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Accidentally debugging a packet must not expose typed text, keys or positions.
        formatter.write_str(match self {
            Self::GeometryAck {} => "GeometryAck",
            Self::Pointer { .. } => "Pointer(..)",
            Self::Button { .. } => "Button(..)",
            Self::Scroll { .. } => "Scroll(..)",
            Self::Key { .. } => "Key(..)",
            Self::Text { .. } => "Text([redacted])",
            Self::Navigate { .. } => "Navigate(..)",
            Self::Touch { .. } => "Touch(..)",
            Self::Heartbeat {} => "Heartbeat",
            Self::Stop {} => "Stop",
        })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Packet {
    pub v: u8,
    pub session: u64,
    pub transport: u64,
    pub connection: [u8; 16],
    pub stream: u64,
    pub geometry: u64,
    pub seq: u64,
    pub input: Input,
}

impl Packet {
    /// Bound bytes BEFORE JSON allocates strings. Invalid JSON and unknown operations fail closed.
    pub fn decode(bytes: &[u8]) -> Result<Self, Rejection> {
        if bytes.len() > MAX_PACKET_BYTES {
            return Err(Rejection::PacketSize);
        }
        let packet: Self = serde_json::from_slice(bytes).map_err(|_| Rejection::Malformed)?;
        if packet.v != VERSION {
            return Err(Rejection::Version);
        }
        if ![packet.session, packet.transport, packet.stream, packet.geometry, packet.seq].into_iter().all(valid_counter) {
            return Err(Rejection::Counter);
        }
        if packet.connection == [0; 16] {
            return Err(Rejection::Binding);
        }
        Ok(packet)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HeldInput {
    pub buttons: u8,
    pub keys: u32,
    pub contacts: u16,
}

impl HeldInput {
    pub fn is_empty(self) -> bool {
        self == Self::default()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rejection {
    Version,
    Unsupported,
    Identity,
    Counter,
    Grant,
    Permission,
    Locked,
    NoStream,
    Busy,
    AuthorityReplay,
    Binding,
    Session,
    Replay,
    Geometry,
    GeometryNotAcknowledged,
    Coordinates,
    InvalidInput,
    Rate,
    PacketSize,
    Malformed,
    Clock,
    Exhausted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopReason {
    User,
    AuthorityChanged,
    PermissionLost,
    Revoked,
    Locked,
    Disconnected,
    Timeout,
    SequenceGap,
    SourceChanged,
    GeometryInvalid,
    RateLimited,
    InvalidInput,
    Clock,
    Exhausted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Accepted,
    Rejected(Rejection),
    Stopped(StopReason),
}

/// Native code must release every indicated button/key/contact, even on rejection/stop.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Transition {
    pub status: Status,
    pub release: HeldInput,
}

impl Transition {
    fn accepted() -> Self {
        Self { status: Status::Accepted, release: HeldInput::default() }
    }
    fn rejected(reason: Rejection) -> Self {
        Self { status: Status::Rejected(reason), release: HeldInput::default() }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionInfo {
    pub session: u64,
    pub transport: u64,
    pub connection: [u8; 16],
    pub stream: u64,
    pub geometry: Geometry,
}

#[derive(Clone, Copy, Debug)]
struct Bucket {
    tokens: u64,
    updated_ms: u64,
    rate: u64,
}

impl Bucket {
    fn new(rate: u64, now_ms: u64) -> Self {
        Self { tokens: rate * 1_000, updated_ms: now_ms, rate }
    }
    fn take(&mut self, now_ms: u64) -> bool {
        // The caller rejects clock reversal first. Refill at most one capacity, avoiding overflow.
        let refill = now_ms.saturating_sub(self.updated_ms).min(1_000) * self.rate;
        self.tokens = (self.tokens + refill).min(self.rate * 1_000);
        self.updated_ms = now_ms;
        if self.tokens < 1_000 {
            false
        } else {
            self.tokens -= 1_000;
            true
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Active {
    info: SessionInfo,
    authority: Authority,
    input: InputCapabilities,
    acknowledged: bool,
    sequence: u64,
    last_valid_ms: u64,
    last_clock_ms: u64,
    held: HeldInput,
    motion: Bucket,
    discrete: Bucket,
    control: Bucket,
}

/// One selected controller per host reducer. Session IDs are host-issued, monotonic within the
/// reducer lifetime, and never secret capabilities. Authentication still comes from Binding.
#[derive(Debug, Default)]
pub struct HostSession {
    highest_authority: u64,
    observed_authority: Option<Authority>,
    blocked_authority: bool,
    last_session: u64,
    active: Option<Active>,
}

impl HostSession {
    pub fn info(&self) -> Option<SessionInfo> {
        self.active.map(|s| s.info)
    }
    pub fn held(&self) -> HeldInput {
        self.active.map(|s| s.held).unwrap_or_default()
    }

    pub fn begin(&mut self, authority: Authority, geometry: Geometry, now_ms: u64) -> Result<SessionInfo, Rejection> {
        if self.active.is_some() {
            return Err(Rejection::Busy);
        }
        let input = self.check_authority(authority)?;
        if !geometry.valid() || geometry.kind != SourceKind::Display {
            return Err(Rejection::Geometry);
        }
        let session = self.last_session.checked_add(1).filter(|v| valid_counter(*v)).ok_or(Rejection::Exhausted)?;
        self.last_session = session;
        let info = SessionInfo {
            session,
            transport: authority.binding.transport,
            connection: authority.binding.connection,
            stream: authority.stream,
            geometry,
        };
        self.active = Some(Active {
            info,
            authority,
            input,
            acknowledged: false,
            sequence: 0,
            last_valid_ms: now_ms,
            last_clock_ms: now_ms,
            held: HeldInput::default(),
            motion: Bucket::new(120, now_ms),
            discrete: Bucket::new(20, now_ms),
            control: Bucket::new(10, now_ms),
        });
        Ok(info)
    }

    /// Call immediately on grant/permission/connection/lock events, not just on incoming packets.
    pub fn synchronize(&mut self, authority: Authority) -> Transition {
        let obsolete = valid_counter(authority.generation) && authority.generation < self.highest_authority;
        let checked = self.check_authority(authority);
        let Some(active) = self.active else {
            return checked.map(|_| Transition::accepted()).unwrap_or_else(Transition::rejected);
        };
        if let Err(reason) = checked {
            // An old asynchronous native callback cannot tear down a newer valid session.
            if obsolete {
                return Transition::rejected(reason);
            }
            return self.stop(stop_for(reason));
        }
        if authority != active.authority {
            return self.stop(StopReason::AuthorityChanged);
        }
        Transition::accepted()
    }

    /// New captured dimensions fence all input until an ordered ACK of the new generation.
    /// Replacing the selected source stops; it cannot silently retarget an existing controller.
    pub fn geometry_changed(&mut self, expected: SessionInfo, geometry: Geometry) -> Transition {
        let Some(active) = self.active.as_mut() else {
            return Transition::rejected(Rejection::NoStream);
        };
        if expected.session != active.info.session
            || expected.transport != active.info.transport
            || expected.connection != active.info.connection
            || expected.stream != active.info.stream
        {
            return Transition::rejected(Rejection::Session);
        }
        if !geometry.valid() {
            return self.stop(StopReason::GeometryInvalid);
        }
        if geometry.generation == active.info.geometry.generation && geometry != active.info.geometry {
            return self.stop(StopReason::GeometryInvalid);
        }
        if geometry.generation <= active.info.geometry.generation {
            return Transition::rejected(Rejection::Geometry);
        }
        if geometry.source != active.info.geometry.source || geometry.kind != SourceKind::Display {
            return self.stop(StopReason::SourceChanged);
        }
        let release = std::mem::take(&mut active.held);
        active.info.geometry = geometry;
        active.acknowledged = false;
        Transition { status: Status::Accepted, release }
    }

    /// Stop is never rate-limited, and held state is returned exactly once.
    pub fn stop(&mut self, reason: StopReason) -> Transition {
        let active = self.active.take();
        // Also burn an observed authority whose asynchronous native begin is still pending.
        // Persistent grants remain; a genuinely new request gets a fresh local generation.
        self.blocked_authority = true;
        let release = active.map(|s| s.held).unwrap_or_default();
        Transition { status: Status::Stopped(reason), release }
    }

    pub fn tick(&mut self, now_ms: u64) -> Transition {
        let Some(active) = self.active.as_mut() else {
            return Transition::rejected(Rejection::NoStream);
        };
        if now_ms < active.last_clock_ms {
            return self.stop(StopReason::Clock);
        }
        active.last_clock_ms = now_ms;
        if now_ms - active.last_valid_ms >= IDLE_MILLIS {
            return self.stop(StopReason::Timeout);
        }
        Transition::accepted()
    }

    pub fn receive(&mut self, authority: Authority, sender: Binding, packet: &Packet, now_ms: u64) -> Transition {
        let authority_result = self.synchronize(authority);
        if authority_result.status != Status::Accepted {
            return authority_result;
        }
        let time_result = self.tick(now_ms);
        if time_result.status != Status::Accepted {
            return time_result;
        }
        let Some(active) = self.active.as_mut() else {
            return Transition::rejected(Rejection::NoStream);
        };
        if sender != active.authority.binding || packet.transport != sender.transport || packet.connection != sender.connection {
            return Transition::rejected(Rejection::Binding);
        }
        if packet.v != VERSION {
            return Transition::rejected(Rejection::Version);
        }
        if packet.session != active.info.session || packet.stream != active.info.stream {
            return Transition::rejected(Rejection::Session);
        }
        if !valid_counter(packet.seq) {
            return Transition::rejected(Rejection::Counter);
        }
        if packet.seq <= active.sequence {
            return Transition::rejected(Rejection::Replay);
        }
        let Some(next) = active.sequence.checked_add(1).filter(|v| valid_counter(*v)) else {
            return self.stop(StopReason::Exhausted);
        };
        if packet.seq != next {
            return self.stop(StopReason::SequenceGap);
        }
        // Consume an authenticated ordered header even if its payload is rejected. Invalid inputs
        // do not refresh idle liveness, and cannot be replayed later after permission/geometry changes.
        active.sequence = packet.seq;
        if matches!(packet.input, Input::Stop {}) {
            return self.stop(StopReason::User);
        }
        if packet.seq == MAX_SEQUENCE {
            return self.stop(StopReason::Exhausted);
        }
        if packet.geometry != active.info.geometry.generation {
            if !active.held.is_empty() {
                return self.stop(StopReason::GeometryInvalid);
            }
            return Transition::rejected(Rejection::Geometry);
        }
        if matches!(packet.input, Input::GeometryAck {}) {
            if !active.control.take(now_ms) {
                return Transition::rejected(Rejection::Rate);
            }
            active.acknowledged = true;
            active.last_valid_ms = now_ms;
            return Transition::accepted();
        }
        if matches!(packet.input, Input::Heartbeat {}) {
            if !active.control.take(now_ms) {
                return Transition::rejected(Rejection::Rate);
            }
            active.last_valid_ms = now_ms;
            return Transition::accepted();
        }
        if !active.acknowledged {
            return Transition::rejected(Rejection::GeometryNotAcknowledged);
        }
        let motion = matches!(packet.input, Input::Pointer { .. } | Input::Scroll { .. } | Input::Touch { phase: TouchPhase::Move, .. });
        if let Err(reason) = validate_input(&packet.input, active.input, active.info.geometry, active.held) {
            if !motion && !active.held.is_empty() {
                return self.stop(StopReason::InvalidInput);
            }
            return Transition::rejected(reason);
        }
        let allowed = if motion { active.motion.take(now_ms) } else { active.discrete.take(now_ms) };
        if !allowed {
            // Never silently drop a key/button/touch transition and leave a native hold stuck.
            if !motion {
                return self.stop(StopReason::RateLimited);
            }
            return Transition::rejected(Rejection::Rate);
        }
        match &packet.input {
            Input::Button { button, down, .. } => set_bit_u8(&mut active.held.buttons, 1 << (*button as u8), *down),
            Input::Key { key, down } => set_bit_u32(&mut active.held.keys, 1 << (*key as u8), *down),
            Input::Touch { contact, phase, .. } => match phase {
                TouchPhase::Down => active.held.contacts |= 1u16 << *contact,
                TouchPhase::Up => active.held.contacts &= !(1u16 << *contact),
                TouchPhase::Move => (),
            },
            _ => (),
        }
        active.last_valid_ms = now_ms;
        Transition::accepted()
    }

    fn check_authority(&mut self, authority: Authority) -> Result<InputCapabilities, Rejection> {
        if !valid_counter(authority.generation) || !valid_counter(authority.binding.transport) || !valid_counter(authority.stream) {
            return Err(Rejection::Counter);
        }
        if authority.generation < self.highest_authority {
            return Err(Rejection::AuthorityReplay);
        }
        if authority.generation > self.highest_authority {
            self.highest_authority = authority.generation;
            self.observed_authority = Some(authority);
            self.blocked_authority = false;
        } else if self.blocked_authority || self.observed_authority != Some(authority) {
            // Reusing one local authority generation for different permission/grant state is
            // invalid. Burn that generation so an older enabled snapshot cannot restart it.
            self.blocked_authority = true;
            return Err(Rejection::AuthorityReplay);
        }
        if !authority.binding.peer.valid() || !authority.trusted_device {
            return Err(Rejection::Identity);
        }
        if authority.binding.connection == [0; 16] {
            return Err(Rejection::Binding);
        }
        if !authority.view_grant || !authority.control_grant {
            return Err(Rejection::Grant);
        }
        if !authority.unlocked {
            return Err(Rejection::Locked);
        }
        if !authority.capture_ready || !authority.input_ready {
            return Err(Rejection::Permission);
        }
        if !authority.stream_active {
            return Err(Rejection::NoStream);
        }
        Capabilities::negotiated_input(authority.host, authority.controller)
    }
}

fn valid_counter(value: u64) -> bool {
    value > 0 && value <= MAX_SEQUENCE
}
fn coordinate(value: f64) -> bool {
    value.is_finite() && (0.0..=1.0).contains(&value)
}
fn set_bit_u8(value: &mut u8, bit: u8, down: bool) {
    if down {
        *value |= bit
    } else {
        *value &= !bit
    }
}
fn set_bit_u32(value: &mut u32, bit: u32, down: bool) {
    if down {
        *value |= bit
    } else {
        *value &= !bit
    }
}
fn stop_for(reason: Rejection) -> StopReason {
    match reason {
        Rejection::Grant | Rejection::Identity => StopReason::Revoked,
        Rejection::Permission => StopReason::PermissionLost,
        Rejection::Locked => StopReason::Locked,
        Rejection::NoStream => StopReason::Disconnected,
        _ => StopReason::AuthorityChanged,
    }
}

fn validate_input(input: &Input, capabilities: InputCapabilities, geometry: Geometry, held: HeldInput) -> Result<(), Rejection> {
    match input {
        Input::Pointer { x, y } => {
            if !capabilities.pointer {
                return Err(Rejection::Unsupported);
            }
            if geometry.pixel(*x, *y).is_none() {
                return Err(Rejection::Coordinates);
            }
        }
        Input::Button { button, down, x, y } => {
            if !capabilities.pointer {
                return Err(Rejection::Unsupported);
            }
            if geometry.pixel(*x, *y).is_none() {
                return Err(Rejection::Coordinates);
            }
            if (held.buttons & (1 << (*button as u8)) != 0) == *down {
                return Err(Rejection::InvalidInput);
            }
        }
        Input::Scroll { dx, dy, x, y } => {
            if !capabilities.pointer {
                return Err(Rejection::Unsupported);
            }
            if geometry.pixel(*x, *y).is_none() {
                return Err(Rejection::Coordinates);
            }
            if !(-1_000..=1_000).contains(dx) || !(-1_000..=1_000).contains(dy) || (*dx == 0 && *dy == 0) {
                return Err(Rejection::InvalidInput);
            }
        }
        Input::Key { key, down } => {
            if !capabilities.keys {
                return Err(Rejection::Unsupported);
            }
            if (held.keys & (1 << (*key as u8)) != 0) == *down {
                return Err(Rejection::InvalidInput);
            }
        }
        Input::Text { text } => {
            if !capabilities.text {
                return Err(Rejection::Unsupported);
            }
            if text.is_empty()
                || text.len() > MAX_TEXT_BYTES
                || text.chars().count() > MAX_TEXT_SCALARS
                || text.chars().any(char::is_control)
            {
                return Err(Rejection::InvalidInput);
            }
        }
        Input::Navigate { .. } => {
            if !capabilities.navigation {
                return Err(Rejection::Unsupported);
            }
        }
        Input::Touch { contact, phase, x, y } => {
            if !capabilities.touch {
                return Err(Rejection::Unsupported);
            }
            if *contact >= 10 || geometry.pixel(*x, *y).is_none() {
                return Err(Rejection::Coordinates);
            }
            let held = held.contacts & (1u16 << *contact) != 0;
            if matches!(phase, TouchPhase::Down) == held {
                return Err(Rejection::InvalidInput);
            }
        }
        Input::GeometryAck {} | Input::Heartbeat {} | Input::Stop {} => (),
    }
    Ok(())
}

#[cfg(test)]
mod tests;
