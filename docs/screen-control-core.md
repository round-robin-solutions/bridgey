# Shared screen/control contract

Status: **foundation only, not wired into an app or advertised to peers**. This
adds a portable draft contract and host reducer in
`rust/proto/src/screen_control.rs`. It does not add a native capture/input adapter,
enable a permission, store a control grant, or make a platform's app complete.
Existing `screen_draft1` and `remote_input_draft1` behavior is unchanged.

Android, macOS, Windows, Linux and iOS/iPadOS clients use this same contract when
their native adapters are implemented. The requested experience includes both
screen/control directions and persistent host-local grants for selected trusted
devices. A Bridgey grant never bypasses operating-system consent. Remote typing
on Android requires API 33+; older Android retains basic app and gesture support.

## Wire schema

`bridgey-screen-control-draft1`, version `1`, is additive to the current protocol.
Do not advertise it until the native adapter can enforce every host invariant.

`Capabilities` declares source/viewer roles, full-display source support, H.264
encoding/decoding, and separate host/controller pointer, touch, key, text and
navigation operations. Capture-prompt/restore flags describe OS behavior, not
permission. Missing flags are false; unknown flags may be ignored. An unknown
schema version is rejected. There is no platform-name switch that invents a
capability for Android, iOS, Windows or any other OS.

Input packets have these fields:

```json
{
  "v": 1,
  "session": 1,
  "transport": 1,
  "connection": [7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7],
  "stream": 4,
  "geometry": 1,
  "seq": 2,
  "input": {"op": "pointer", "x": 0.25, "y": 0.75}
}
```

The fixture nonce is synthetic. The real `connection` must be a unique 128-bit
nonce derived from the authenticated transport transcript (including fresh local
cryptographic material, such as the QUIC exporter), never reused after an app
restart. A remote-selected device/session name alone is not a valid nonce. It is not a permission token. The native adapter supplies the actual
authenticated sender separately; packet fields cannot assert their own identity.

Packets are limited to 2,048 bytes **before** JSON decoding. Unknown operations,
unknown packet fields and malformed field types are rejected. Counters are
nonzero and at most `2^53 - 1`, so future clients cannot lose integer precision.
Exhaustion stops or refuses the session rather than wrapping. Golden wire
fixtures live in `rust/proto/test-vectors/screen-control-v1.json`.

## Host API and authority

The native adapter owns the pinned device identity, local trusted-device status,
separate view/control grants, current permissions, lock state, active capture
stream and authenticated transport. Supply these as a fresh `Authority` on every
`receive`, and call `synchronize` immediately when any authority changes, even if
no input is arriving. `Authority` is intentionally not a serde wire type.

`input_ready` includes permission and the native target's eligibility for the
attempted operation. For key/text input it must check that the focused editor is
within the selected source; Accessibility permission alone is insufficient. A
changed native target cannot redirect typing outside what the controller sees.

Advance its host-local generation whenever authority, selected source or
transport changes. Reusing a generation for different state burns it until a
newer generation arrives. An older callback cannot re-enable a revoked grant or
tear down a newer valid session. Native callbacks need the same generation fence.
Stopping also burns the stopped generation. A genuinely new request may reuse
its persistent local grant, but gets a fresh host-issued authority generation;
an old start callback cannot reopen the stopped session.

1. Start an OS-consented full-display capture to the selected authenticated peer.
   Construct the local authority snapshot from the host's own state.
2. Call `begin`. The reducer issues a monotonic control-session ID. Only one
   selected controller is active per reducer; a second begin returns Busy.
3. Send its geometry to that peer. Input is blocked until the current geometry is
   acknowledged over the ordered control lane.
4. Decode bounded packet bytes, then call `receive` with current local authority
   and the actual authenticated sender binding. Inject only when the returned
   status is Accepted; ACK/heartbeat/Stop are not native input operations.
   A malformed packet from the selected authenticated peer must stop/release
   through the same reducer; it must not strand a held input in an adapter queue.
5. Apply every returned `release` **before** injecting anything else. Stop,
   disconnect, revocation, permission loss, lock, timeout and invalid source
   transitions return the held buttons, named keys and contacts exactly once.
6. Call `tick` with a monotonic local millisecond clock even when the network is
   silent. Six seconds without valid input/heartbeat stops the session. Invalid
   input does not extend its liveness.

Persistent grants remain in each host's secure storage, separate from ordinary
pairing and settings sync. A different pinned key requires a new grant. This
module neither persists nor transfers that authority, and no local OS state is
accepted from the remote packet.

## Geometry and input ordering

Geometry identifies one host-selected display, its captured width/height and a
monotonic version. Window-only capture is not control-capable in this first
contract. In particular, Android single-app video coordinates are not whole-
display gesture coordinates.

Resize/rotation uses `geometry_changed`: release held inputs, invalidate the ACK
and reject old-geometry commands until the new version is acknowledged. A new
source stops the session. Reusing a geometry version for different dimensions
also stops it; late older geometry callbacks are ignored. The callback carries
the original `SessionInfo` (session, stream and authenticated-connection binding),
so a callback from a previous capture cannot resize or stop the current session.
Register local authority before queuing an asynchronous native begin; Stop burns
that observed generation even if begin has not completed. Native callbacks must
still retain their request-generation fence before creating newer authority.

Pointer, button, scroll and touch fractions must be finite and within `[0,1]`.
Every button/scroll packet carries its own `x`/`y`; native adapters position and
dispatch that operation atomically, without relying on a preceding pointer
packet or the local cursor's current location. The viewer excludes
letterboxing before sending; the host maps validated captured pixels into its
selected native display using the real origin, scaling and orientation. Rust's
`Geometry.pixel` never chooses a global display or injects a coordinate itself.
The protocol bounds dimensions at 32,768 per axis and 67,108,864 pixels; these are
operating bounds, not throughput claims.

Packets use one ordered sequence. Coalesce pointer motion **before assigning
sequence numbers**, never discard an assigned discrete key/button transition.
A gap ends the session and releases holds. Replayed packets do not inject again.
Wrong-geometry packets also stop/release when input is held, so a stale release
cannot be ignored while later heartbeats keep a button or key down indefinitely.
Stop bypasses rate budgets. The inherited budgets are 120 motion, 20 discrete
and 10 control events per second. A rejected discrete transition stops/releases
rather than leaving a held key or contact stuck. Typed text is at most 256
Unicode scalars/1,024 UTF-8 bytes and excludes control characters; Return/Tab are
named keys. Packet-input debug formatting redacts text, positions and keys.

The reducer stores fixed-size authority, counters, buckets and hold bitmasks; it
does not allocate on pointer admission. JSON decode and text payload ownership
are separate. Native adapters must bound queues, prioritize Stop, sequence
Android continued gestures correctly, and use hardware capture/codecs/GPU
surfaces. This module is not a video codec or a new transport stack.

## Verification and remaining work

`scripts/rr/tests/test_screen_control_core.py` makes the scoped Rust tests a
mandatory part of the existing owned Python task. It uses the installed tool
homes through `rust-env.sh`, an attempt-temporary target directory, the worker's
CPU allocation and no toolchain installation. Missing tools or zero selected
tests fail. RR CI owns process termination and its overall deadline. Resource
fit in that task must be established by an actual owned run.

Tests cover golden encoding/decoding, capability intersection, grants, changed
identity/transport, nonce protection across process restart, authority replay,
source/geometry epochs, nonfinite coordinates, held-state release, rate limits,
clock/idle behavior, counter exhaustion, text limits and malformed operations.
These are pure synthetic tests, not evidence of native gesture/capture behavior.

Still required: C/JNI adapter integration, native grant storage/indicators/Stop,
OS capture/input permissions, hardware encode/decode, Android gesture sequencing,
Mac absolute display mapping, Windows/Linux/iOS clients, mixed-version and
cross-platform native acceptance, and measured latency/memory/battery budgets.
No native support or speed claim follows from compiling the Rust contract.
