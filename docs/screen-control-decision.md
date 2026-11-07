# Screen sharing and control: implementation plan

Status: planned, not shipped. User decisions on 2026-11-07: both directions,
persistent unattended grants for explicitly selected trusted devices, and native
Android/macOS/Windows/Linux/iOS clients as core targets. The
[five-platform architecture](platform-architecture.md) defines the shared core.

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
that pinned identity. Pairing alone does not grant screen/control access. Keep
screen viewing and input control separately permissioned, revocable, and off
until chosen. Server/agent identities do not inherit device control.

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

API 33+ offers Accessibility InputMethod APIs for focused-editor text. API 26–32
needs a product choice: gesture/navigation-only initially, or a separately
user-enabled Bridgey keyboard. Do not silently add `canRetrieveWindowContent`,
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
