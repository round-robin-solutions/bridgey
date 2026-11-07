# Five-platform architecture and delivery plan

Android, macOS, Windows, Linux and iOS/iPadOS are core Bridgey targets. A platform
is supported when its native client, supported features and upgrade path have
been exercised there. A cross-compiled binary or the agent CLI alone does not
establish desktop or mobile app support.

Android and macOS apps exist today. The repository already has a portable Rust
networking core and agent CLI. Native Windows, Linux and iOS clients remain
required work. Keep their milestones visible while improving the existing apps.

## Share the core, keep the OS integration native

Extend the existing `rust/` workspace rather than add another transport stack.

| Layer | Ownership |
| --- | --- |
| Wire formats, decoding limits, version negotiation and golden fixtures | Shared Rust protocol modules |
| Encrypted sessions, identity pins, LAN/private-network/direct/relay routing | Existing Rust connection core |
| Screen/control session transitions, geometry versions, replay/rate limits and bounded queues | Shared Rust interaction module, to be implemented |
| Permissions, secure storage, capture, hardware codecs, input injection and background lifecycle | Native adapter on each OS |
| Settings, accessibility, device pickers, notification actions and app lifecycle | Native UI using the platform's conventions |

Rust is a reuse and performance tool, not a reason to rewrite a native GPU or
codec path. Keep frame data on hardware surfaces when possible. Do not pass raw
frames through JSON/base64 or copy them between languages on every frame.
Keep the existing C/JNI ownership conventions, explicit cancellation and bounded
event delivery. Introduce a binary media path only with mixed-version negotiation
and evidence that it improves the existing path.

An Android notification or a macOS permission panel stays native. Portable
classification and protocol rules should have shared fixtures so future clients
do not drift. Measure the benefit before moving working code across the FFI.

## Capabilities describe what a device can do

Negotiate individual screen-source, viewer, pointer, touch, keyboard and text
capabilities. Include whether the OS needs a fresh capture prompt, which source
geometries are supported, and which encoders/decoders are available. Do not infer
permission or support from an OS name, Tailscale membership or a paired-device
display name.

Older peers keep their existing view-only screen sharing and touchpad behavior.
Hide or explain unavailable controls. A headless Linux server does not advertise
a desktop. iOS remains a useful first-class viewer/controller even where its
public APIs do not permit input hosting.

| Platform | Capture and input adapter | Material boundary |
| --- | --- | --- |
| Android | MediaProjection/MediaCodec; explicitly enabled AccessibilityService for input | Fresh OS capture consent; secure content remains protected. API 26–32 retain gesture/navigation support; remote typing requires API 33+ without adding UI-tree access. |
| macOS | ScreenCaptureKit/VideoToolbox; existing Accessibility/CGEvent input adapter | Screen Recording and Accessibility are separate permissions. Select the source display and map its coordinates explicitly. |
| Windows | Windows.Graphics.Capture or measured DXGI capture; hardware encoder; SendInput | Elevated apps and the secure desktop are subject to Windows integrity restrictions. |
| Linux | Wayland portals/PipeWire/EIS; separate X11 capture/XTest adapter | Portal consent and persistence depend on the compositor. Do not bypass it or assume X11 behavior on Wayland. |
| iOS/iPadOS | Version-appropriate native capture/broadcast adapter and hardware media path; native viewer/controller | No unrestricted other-app touch injection through ordinary public APIs. Capture remains subject to system UI and background limits. |

Platform API references and availability research are in
[the screen-control design](screen-control-decision.md). Confirm SDK availability
again while implementing each adapter; it is not a substitute for native tests.

## Screen sharing and control

The requested experience supports both directions: see and control a phone from
a computer, and see and control a computer from a phone. Retain independent
view-only sharing.

Selected trusted devices may receive a persistent, host-local Bridgey grant for
unattended use. This is a separate opt-in from pairing and from ordinary
clipboard/file permissions. It does not bypass an OS permission dialog, unlock
a device, grant access to protected content or enable unavailable APIs. Do not
sync control grants to another host. A changed identity needs a new grant.

Every active share/control session names the controlling device, has a visible
local indicator, and can be stopped from either end. Revoke, disconnect, lock,
permission loss or source replacement invalidates pending input and releases
held buttons/keys. The persistent grant may remain, but an old session cannot
resume itself through a late callback.

Accept input only when all of these match: pinned peer, local grant, native
permission, active stream to that peer, current transport/session generation,
selected source and acknowledged geometry version. Reject out-of-bounds input,
replays and clicks on letterboxing. Android single-app video coordinates are not
whole-display touch coordinates: start control with explicit full-display
capture, and fence rotation/resize before accepting more input.

Keep button/key transitions ordered. Coalesce pointer motion separately. Stop
must not wait behind video frames; bound both queues and discard obsolete video.

## Work in order

1. **Finish the focused improvements already in progress.** Verify and ship the
   menu-bar opening fix, guided external Tailscale setup, and contextual phone
   clipboard actions. These do not require a new account service.
   Reconcile the open call/media/selection and smart-routing branches against the
   current release, then complete their native acceptance; green older branch
   checks are not evidence that those features are already shipped.
2. **Extract the shared screen/control contract.** Add capability/session/grant/
   geometry rules and cross-platform fixtures to Rust. Define the native adapter
   boundary before adding a second independent control implementation.
3. **Complete the existing phone/computer pair.** Add a Mac screen source and
   phone viewer alongside the existing phone-to-Mac input adapter. Add Android
   gesture input and a Mac controller alongside the existing phone screen stream.
   Exercise selected-device unattended grants and OS consent independently.
4. **Deliver Windows and Linux native clients against the same contract.** Both
   controller/viewer and supported capture/input host roles are required. Record
   Wayland/X11 and Windows integrity limits explicitly.
5. **Deliver the iOS/iPadOS client.** Viewer/controller, OS-consented screen source,
   device connection and supported sharing functions use the same core. Do not
   advertise unrestricted input hosting where no public API exists.
6. **Verify the supported cross-platform matrix.** Mixed versions, LAN/Tailscale/
   relay routes, sleep/wake, permission revocation, interrupted sessions, updates
   and long-running memory/battery behavior must have native evidence.

Stages 3–5 can proceed in parallel once the shared contract is stable. Completing
Android/macOS does not close the other three platform milestones.

## Performance and CI

Track cold and warm opening, input-to-present latency, capture/encode/network/
decode times, idle CPU, peak/steady memory and battery/thermal behavior. Record
the device, OS, build, content, route and load with every result. Establish
baselines before choosing numeric budgets; do not call an emulator result a
physical-device result.

All builds/tests use owned RR CI. Extend its native platform coverage through
reviewed, verified runner profiles; no parallel GitHub test pipeline. Hosted free
capacity remains build-only. Windows native tests need an owned Windows runner;
iOS and GPU-dependent Mac acceptance need the appropriate Mac/device capacity.
Do not label an unavailable platform tested because a different host compiled it.

Keep native fixtures synthetic and permissions injected in unit tests. Real
permission, capture, gesture and hardware-codec acceptance is separate. Never
capture private user screens or change production resources to make a test pass.
