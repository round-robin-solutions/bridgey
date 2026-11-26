# Screen sharing and control: implementation plan

Status: Mac screen to phone and phone control from the Mac shipped in 1.0 Beta 5 and 6;
unattended access (below) follows them. User decisions on 2026-11-07: both
directions and native Android/macOS/Windows/Linux/iOS clients as core targets. The 7 Nov
rule "persistent unattended grants for explicitly selected trusted devices" is replaced by
the 26 Nov decision below. The [five-platform architecture](platform-architecture.md)
defines the shared core.

## Unattended access (decision, 2026-11-26)

Rahul, 26 November 2026: a person's own devices may view and control each other's
screens without a confirmation prompt each time.

- **One switch, Unattended access, on by default,** on each device that can be viewed or
  controlled: Settings > Remote control on the Mac (This Mac's screen) and on Android
  (with Let Macs control this phone). Windows has no screen source yet; the switch comes
  with its screen work in Windows M3. iOS cannot be viewed or controlled unattended, so it
  offers nothing.
- **Per-device overrides.** Each paired device's grant can still be Off, Ask each time or
  Allow without asking. A device with no choice of its own shows Default and follows the
  switch: on is Allow without asking, off is Off (the default before this decision).
  Choices made before this change stay as they were. Builds before it did not store Off
  (Off removed the entry), so a device someone had set to Off reads as Default.
- **Never servers or agents.** The `bridgey agent` CLI, devices paired as agents or
  servers, and devices paired over the tailnet until trusted get Off whatever the switch
  or a stored choice says.
- **Who is connected stays visible on the device being viewed or controlled,** always,
  with Stop: the Mac's pill and stop shortcut; on Android the sharing notification, and for
  an unattended share Bridgey control's bar ("MacBook Air is viewing this phone").
- **Android has no unattended video.** MediaProjection needs the person's approval for
  every capture. For a Mac on Allow without asking, the phone skips Bridgey's own
  question and, with nobody to approve video, sends Bridgey control's accessibility
  screenshots (`takeScreenshot`, Android 11 and later) at about 3 frames a second, in the
  same H.264 stream, marked `mode: screenshots` in `screen.start`; the Mac's window says
  it is a slower mode. The sharing notification offers Use video, which asks Android for
  consent and replaces the share with video. Below Android 11, without Bridgey control, or
  with the phone locked, the request waits for someone at the phone as before, and the
  Mac hears why (`needs` in `screen.status`); the phone's Settings say what is missing.
- **Grants and the switch stay local.** They live in the host's private grant file
  (bound to each device's pinned key, never synced, never sent, outside backups); the
  switch is in the same file, never in settings sync. Bad data fails closed: an entry that
  does not decode is Off for that device, and a grant file that cannot be read turns the
  switch off and keeps every device ID it still names as Off.
- **Lowering access takes effect at once.** A screenshot share ends (`disabled`) when its
  Mac goes to Ask each time or Off, the switch goes off for a Mac on Default, Share screen
  with Macs goes off or the device turns out to be an agent; on the Mac a stream that
  started without a prompt ends when its device goes to Ask each time or Off. A video share
  the person approved on the phone stays.
- **A synced switch is not consent.** Share screen with Macs turned on through settings
  sync (a Mac's Show phone screens) never allows unattended viewing of the phone; it has to
  be turned on on the phone, and not while a Mac controls it.
- **Kept from the 1.0 security review:** no grant can be raised while the device is being
  controlled, and that includes turning the switch on and setting a device back to Default
  when that would raise it; lowering always works. On the Mac, the Ask each time prompt's
  Allow still ignores events Bridgey injected for another device.
- **Seeing still does not imply control.** On the Mac, control also needs Remote control
  allowed for that phone plus macOS Accessibility; on Android it needs Bridgey control on.
  The capability switches (Share screen with Macs on the phone, Show phone screens and
  See Mac screens on the viewers) are unchanged; unattended access removes prompts, it
  does not turn features on.
- **Known limit: on the same network a server says what it is.** A device paired by invite
  (the `bridgey` CLI) is an agent from the start, and one paired over the tailnet stays
  restricted until the person trusts it. One paired on the same network is marked an agent
  or server only when its own authenticated features map says so (`agent_draft1` with
  `notify_draft1` and `ask_draft1`). A server that leaves those keys out is treated as a
  person's device and gets Default, which is Allow without asking while the switch is on.
  Pairing still needs the code confirmed on both screens, so the person has to pair it
  themselves; set such a device to Off, or turn the switch off.

## Existing behavior

Android can share a view-only H.264 screen to the Mac using MediaProjection and
MediaCodec. The phone can also control a Mac's pointer/keyboard through the
separate, Accessibility-gated remote-input feature. The Mac cannot yet send its
screen to the phone, and the Mac viewer cannot inject input into Android.
Windows, Linux and iOS native apps are not implemented in this repository yet.

## First complete phone/computer slice

1. Add shared Rust capability, session/grant, replay/rate and geometry rules.
   Keep old peers' view-only and touchpad behavior compatible.
2. Add a selected-display Mac screen source using ScreenCaptureKit/VideoToolbox
   and an Android viewer. Bind input to that stream through the existing Mac
   input adapter, extended for selected-display absolute coordinates.
3. Add a separately enabled Android AccessibilityService for gestures and
   navigation, and pointer/keyboard interaction to the existing Mac viewer.
   Use the current encrypted connection stack on LAN, Tailscale, direct and relay
   routes; do not introduce Wireless ADB or a second control transport.
4. Add native Windows, Linux and iOS adapters against the same contract. Their
   capabilities reflect actual OS support, rather than copying Android/Mac
   permission assumptions.

## Grants and session ownership

A per-device host-local grant permits unattended Bridgey session requests from
that pinned identity; since 26 November a device with no choice of its own
follows the host's Unattended access switch (above). Keep screen viewing and
input control separately permissioned and revocable. Server/agent identities
never get device control.

An unattended Bridgey grant does not bypass OS consent. Android still requires
MediaProjection approval for a new capture session; Accessibility activation is
another explicit system setting. Linux Wayland approval/persistence depends on
the portal. Windows input follows integrity restrictions. iOS does not provide
ordinary apps unrestricted input injection into other apps.

While active, show which device is controlling, retain a local Stop action and
allow either end to stop. Disconnect, lock, permission loss, grant revocation or
source replacement drops pending input and releases held state. Do not silently
sync control grants or let reconnect resurrect a stopped session.

## Geometry is part of the protocol

Each stream identifies its source display, pixel dimensions, scale, orientation
and geometry version. Input binds to the current authenticated transport and
stream, plus an acknowledged geometry version. Ignore letterboxing and reject
coordinates outside the selected source. Use host-controlled display selection,
including Retina scaling and negative multi-monitor origins.

Android 14+ can share one app, while Accessibility gestures target the whole
display. For the first control-capable session, request full-display capture via
`MediaProjectionConfig.createConfigForDefaultDisplay()`; retain normal source
choice for view-only sharing. Rotation or resize invalidates input until the new
geometry is acknowledged. Never assume video-relative coordinates map directly
onto the full display.

## Android input capabilities

`dispatchGesture`, continued strokes and global Back/Home/Recents actions cover
the current API 26 minimum. Serialize gestures through callbacks: starting a new
gesture can cancel an existing one, so pointer packets cannot each become a new
independent gesture. Bound duration/queues and fence late completions after Stop.

API 33+ offers Accessibility InputMethod APIs for focused-editor text. The user
chose remote typing on Android 13+ only, while retaining basic compatibility and
gesture/navigation support on Android 8–12. No older-version keyboard workaround
is planned for the first release. Do not silently add `canRetrieveWindowContent`,
read accessibility UI trees, overwrite the clipboard, or enable ADB as a typing
fallback. The earlier proposed `ACTION_SET_TEXT` fallback did not fit the promise
of no window-content access and is withdrawn.

## Performance and acceptance

Keep hardware capture/encode/decode and native GPU surfaces. Share protocol,
policy, pacing and bounded queue logic in Rust. Separate coalesced pointer motion
from ordered buttons/keys; prioritize Stop over video and discard obsolete frames.
Measure input-to-present latency and capture/encode/network/decode stages on real
supported devices before setting targets. No one-frame or battery claim follows
from language choice or emulator-only measurements.

Owned RR CI covers pure rules, cross-platform wire fixtures and injected native
adapter tests. Native acceptance additionally covers OS permission denial/revoke,
selected-device grants, source changes, rotation/multi-monitor mapping, held keys
on disconnect, replay after reconnect, resize-before-input acknowledgement,
network failover, long-session memory and battery/thermal behavior. Use synthetic
screens and owned devices; do not change private user accounts or permissions to
make a test pass.

## Platform references

- [Android MediaProjection lifecycle and consent](https://developer.android.com/media/grow/media-projection)
- [Android full-display capture configuration](https://developer.android.com/reference/android/media/projection/MediaProjectionConfig)
- [AccessibilityService and input methods](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService)
- [Continued gestures](https://developer.android.com/reference/android/accessibilityservice/GestureDescription.StrokeDescription)
- [Accessibility input connection](https://developer.android.com/reference/android/accessibilityservice/InputMethod.AccessibilityInputConnection)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Screen-sharing picker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker)
- [ReplayKit](https://developer.apple.com/documentation/replaykit)
- [Windows capture](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture)
- [Windows SendInput/integrity restrictions](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)
- [Wayland RemoteDesktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html)
- [Wayland ScreenCast portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html)

Recheck SDK availability during each native implementation. Apple's current
capture APIs are evolving across OS versions; neither capture framework provides
general other-app touch injection on iOS.
