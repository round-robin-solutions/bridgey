# Phone screen on the Mac (v0.9 prototype)

Status: **prototype, off by default on both sides.** The wire format is the draft `screen_draft1` in
[protocol.md](protocol.md) ("Phone screen to Mac"). It is view only unless the phone allows the Mac to control
it, a separate grant and key (`phone_control_draft1`, "The Mac controls the phone" below); the decisions are in
[screen-control-decision.md](screen-control-decision.md).

## How it works

1. Both switches are on: Settings > Media and quick actions > Share screen with Macs on the phone (per
   Mac), Settings > Remote control > Show phone screens on the Mac. Setup asks too ("Let your Mac see
   this screen?"), and the Remote control bundle includes it.
2. Either the Mac asks (Show Phone Screen in the panel's File menu or the device menu sends
   `screen.request`; the phone shows "MacBook Air wants to see your screen" with Share and Not now),
   or the person starts it on the phone (the Mac's device page, or the Share screen Quick Settings
   tile).
3. Android's own dialog asks for consent. Android 14 and later ask every time, and the result can be
   used once, so Bridgey asks for a fresh one for every share and never keeps it. A Mac allowed without
   asking gets screenshots instead when nobody approves (below, "Unattended access").
4. The phone starts a foreground service of type `mediaProjection` (after consent, before it takes
   the projection, as Android 14 requires), registers the projection callback, creates one virtual
   display into the hardware H.264 encoder and sends `screen.start`. The Mac opens a window, answers
   `screen.started`, and frames follow.
5. While it runs the phone shows "Your screen is being shared with MacBook Air" with Stop, and
   Android 15 and later add their own status bar indicator. Stop on either side, the window closing,
   the phone's screen turning off, a disconnect or a switch going off ends it.

Encoder settings: H.264, long side at most 1,600 pixels (stepping down to 1,280 and 960 when the
encoder cannot do it), 30 frames a second, no B-frames, the previous frame repeated after 100 ms of
no change so a still screen stays fresh, key frames on demand, SPS and PPS at the start of every key
frame. The Mac decodes with a VideoToolbox decompression session (hardware decoder requested) and
shows each frame as soon as it is decoded; there is no jitter buffer, because a screen is better
late by nothing than smooth by 100 ms.

## Transport: a paced lane inside the existing session

The question was how to carry a continuous stream next to the session without starving clipboard,
notifications and the rest. Three options:

| Option | For | Against |
| --- | --- | --- |
| **A. Frames on the existing session, paced by the Mac's acknowledgements** (chosen) | No new port, listener, pairing or authentication; the session key already encrypts it and the pinned identity already authenticates it. Works on every route the session works on today (same network, Tailscale) and later through the relay, with nothing extra to build there | JSON and base64 framing cost about a third more bytes; a frame in the socket delays a clipboard message queued behind it |
| B. A second TCP connection bound to the session (a token derived from the session key) | Binary framing; separate kernel buffers | A second listener path and handshake to secure and fuzz; every route (relay included) has to carry two connections; both still share the same Wi-Fi link, so without pacing the video still fills the link and the queue just moves into the router |
| C. UDP (RTP, QUIC datagrams or WebRTC) | Loss without head-of-line blocking; the best latency on bad links | A new encrypted transport, NAT and firewall work, and its own congestion control; far beyond a prototype |

What actually protects clipboard and notifications is **how much video is allowed to wait in
queues**, not how many sockets there are. With option A the phone sends a frame only while at most
6 frames and at most max(64 KiB, 250 ms at the current bit rate) are unacknowledged, and the Mac
acknowledges each frame as soon as it is decoded. So the socket never holds more than about a
quarter of a second of video, and usually much less, because the link is faster than the stream. A
clipboard message waits for the part that is being written (at most 32 KiB, a few milliseconds on a
LAN) and whatever is queued behind it, which the pacing keeps small. Frames are written by their
own thread and do not count as "urgent" senders, so the media lane (thumbnails) keeps working too.

When a frame does not fit, the phone drops it and every frame up to the next key frame, asks the
encoder for a key frame at once, and lowers the bit rate. Dropping a P-frame without that would
corrupt everything until the next key frame; dropping whole groups keeps the picture correct and
the latency low. The bit rate follows the link: down by a quarter on a drop or when the round trip
grows 80 ms over its minimum (at most every 500 ms), up by 15 percent after 2 calm seconds, between
300 kb/s and 8 Mb/s.

Option B stays open: if a future relay or the transfer engine adds a multiplexed binary transport
(the transfer engine design proposes QUIC), the frame format here moves onto it unchanged, because
the 40-byte header already carries everything the receiver needs.

## Measuring

The phone measures what the person sees, minus the Mac's display refresh:

- **round trip** = (ack received) minus (frame fully written to the socket) minus the Mac's decode
  time, which the ack carries;
- **latency** = (ack received) minus (capture time stamped by the display pipeline) minus half the
  round trip. That covers encoding, sending, the network, reassembly and decoding.

Once a second the phone sends these with its bit rates, frame rate and drops in `screen.stats`; the
Mac window shows latency, Mb/s and frames a second in its header, and both sides log the numbers.

## Measured

Live, 2026-10-27: the signed release APK on the Android 15 (API 35) emulator on the personal Mac
(M4), streaming to a Mac build of this branch on the same Mac. The link is the emulator's network
and an `adb forward`, so it is a loopback, not Wi-Fi. The emulator only has Android's software
encoder (`c2.android.avc.encoder`), so encoding on a real phone's hardware encoder is untested.
Capture 720x1600 from 1080x2400.

| Screen | Frames a second | Bit rate (Mac received) | Latency, capture to decoded | Round trip | Mac decode, average (max) | Dropped |
| --- | --- | --- | --- | --- | --- | --- |
| Continuous scrolling, 16 seconds | 25 to 31, mostly 30 | 7.0 to 9.8 Mb/s (target 8 Mb/s) | 12 to 14 ms | 6 to 12 ms | 1.9 to 2.4 ms (3.9 ms) | 0 |
| Still screen | about 10 while the encoder repeats, then 0 until something changes | 130 to 230 kb/s, then 0 | 24 to 56 ms | 2 to 5 ms | 2.5 ms | 0 |

- Bit rate grew from 4 Mb/s to the 8 Mb/s ceiling in about 2 seconds of motion; with no congestion
  on a loopback the downward path (drops, rising round trip) did not trigger live. It is covered by
  unit tests only.
- The VideoToolbox round trip test on the M4 decodes 720x1600 in 0.93 ms median (p90 1.32 ms).
- The first live run found the emulator encoder refusing `KEY_PREPEND_HEADER_TO_SYNC_FRAMES`, which
  made the fallback drop the 30 fps cap: 60 frames a second at 14 to 19 Mb/s and 25 frames dropped
  in the first second. Fixed (the prepend key is not used; Bridgey prepends SPS and PPS itself) and
  measured again above.
- Stopping works from the phone (Stop sharing: the Mac logs `user`) and by locking the phone (`screen_off`
  on both sides); the projection is released each time.
- Not measured: a clipboard or ping round trip while the stream runs at full rate, and real Wi-Fi.

## Limits of the prototype

- View only unless the phone allows the Mac to control it (below). No audio (Android 10 and later could capture it with the same consent; not built).
- One phone stream at a time per phone; a Mac can show several phones.
- The share stops when the phone's screen turns off rather than showing the lock screen.
- On a still screen the emulator's encoder stops repeating frames after a few seconds, so the Mac
  shows the last frame and the stream stays alive on `screen.stats`; to check on a real phone.
- Secure windows (banking apps, password fields with FLAG_SECURE) are black, by Android's design.

## Unattended access: screenshots when nobody approves video

Decided 26 November ([screen-control-decision.md](screen-control-decision.md)). A Mac allowed without
asking on the phone (its own choice, or Default while Unattended access is on) is not asked about in
Bridgey. Android still asks for consent before every MediaProjection capture, and nobody may be at the
phone, so the share falls back to Bridgey control's accessibility screenshots:

- **When.** The phone is unlocked with its screen on, it runs Android 11 or later, and Bridgey control is
  connected. Otherwise the request waits for someone at the phone exactly as before, and `screen.status`
  `waiting` tells the Mac why (`needs`: `unlock`, `android_11` or `accessibility`), which the Mac shows in
  its panel. The phone's Settings > Remote control says what is missing too.
- **Frames.** `ScreenshotFrameSource` asks for one screenshot at a time, at most one every 340 ms (Android
  refuses two within 333 ms), so about 3 a second, and draws each onto the encoder's input surface with
  Android's mirroring fit (aspect kept, centred). The encoder, pacing, acks, stats and phone control are the
  ones video uses; `screen.start` says `mode` `screenshots` and `fps` 3, the bit rate starts at 1.5 Mb/s
  and never goes above 3 Mb/s, and the encoder does not repeat frames. A refusal for asking too soon backs
  off 60 ms at a time; five other failures in a row, losing the capability or the display end the share as
  `failed`; a screenshot with no answer in 1 second counts as a failure, so one lost callback freezes the
  picture for about a second at most.
- **On the phone.** The sharing notification says it is sending screenshots and offers Use video (Android's
  consent, then a video stream that replaces this one; if video cannot start, the screenshots go on), and
  Bridgey control's small bar above the navigation bar says "MacBook Air is viewing this phone" with Stop,
  which needs no notification permission. Nothing is captured until the bar is on the screen, and the share
  ends if it cannot be shown. When the Mac takes control the control bar at the top says so instead.
  Locking the phone or turning its screen off ends the share; a request that waited for the unlock starts
  once the phone is unlocked (on Android's "user present", which comes before the keyguard stops reading
  locked, and otherwise by looking again every half second while the screen is on at the lock screen). Lowering access (the Mac to Ask each time or Off, the switch off for a Mac on
  Default, Share screen with Macs off, the device an agent) ends it at once. There is no foreground service
  of its own: Bridgey's connection service and the bound accessibility service keep the app alive.
- **On the Mac.** The window's header says "Slower mode" before its numbers.
- **Checked live (26 Nov, Android 16 emulator, a throwaway Mac test instance):** an update keeps Bridgey control
  on with the new capability, screenshots start with no dialog at about 2.9 a second (342 ms median gap), Stop,
  the screen turning off, `needs` `unlock` and `accessibility`, Use video, control during a share, and the
  switch off asking as before. Evidence in Round Robin's output folder (`bridgey/screen/unattended-pr68`).
- **Not checked yet:** a real phone (OEM screenshot behaviour, secure windows, rotation), Android 11 and
  12, and how a busy screen at 3 frames a second compresses. Covered by unit tests: which requests go
  unattended, the pacing and back-off, the mirroring fit and the `screen.start` and `screen.status` fields.

## Mac screen on the phone (`screen_control_draft1`)

The other direction uses the same lane and the same pacing, with the roles swapped: the Mac captures a
display it chose, encodes H.264 with VideoToolbox and paces frames on the phone's acks; the phone
decodes with MediaCodec straight to a surface. Control rides in the shared contract's input packets
(protocol in [protocol.md](protocol.md), "Mac screen to phone"; the contract in
[screen-control-core.md](screen-control-core.md)).

Capture sits behind a protocol. The app uses ScreenCaptureKit on the selected display; test instances
(`make-test-instance.sh <label> <port> --synthetic-screen`) use a synthetic display, a moving test
pattern that also draws a crosshair where control input landed, and a recording injector that never
posts an event, so no Screen Recording or Accessibility permission is involved.

### Measured

Live, 2026-11-25: a throwaway test instance of the debug Mac app with the synthetic display (1512 by
982 points at 2x, streamed at 1,920 by 1,246) on the personal Mac (M4), viewed by the release-minified
test build (`stress`, its own app ID) on the Android 16 emulator (bridgey-api36) on the same Mac,
through `adb forward`, so a loopback rather than Wi-Fi. The emulator decodes in software
(`c2.goldfish.h264.decoder`). The Mac used VideoToolbox's low-latency encoder
(`com.apple.videotoolbox.videoencoder.h264.rtvc`); macOS does not say whether that one runs in
hardware, while the plain hardware-preferred session on the same Mac reports `ave.avc` in hardware.

| Measure | Result |
| --- | --- |
| Frames a second, Mac sent and phone decoded (30 s) | 30 sent every second; 29 to 31 decoded |
| Latency, capture to decoded, minus half the round trip (30 s) | 13 to 23 ms, median 19 ms |
| Round trip | 1 to 8 ms, median 4 ms |
| Phone decode (software decoder) | 8.8 ms median of the per-second averages, 27 ms at most |
| Dropped or lost in the measured 30 s | 0 |
| A tap on the phone to the point the Mac would click | exact: (1133.6, 736.5) in display points, as computed from the geometry rules; also after a size change and in landscape |

The test pattern compresses well (about 180 kb/s), so these numbers say nothing yet about a busy
desktop, real Wi-Fi or a phone's hardware decoder.

Also checked live: Ask each time asks for every stream (Allow and Don't allow), Allow without asking
starts at once, a size change moves both ends to a new geometry generation with control still working,
rotation keeps the stream and control, a tap on the letterbox sends nothing, keys and text arrive in
order, Stop on either end, turning off the phone's remote control permission ends control and keeps
the picture, turning off the screen grant ends the stream and hides See screen, and after a disconnect
and reconnect nothing resumes on either end.

### Still to check on real devices

- The ScreenCaptureKit source on a Mac where Bridgey has Screen Recording: picture, cursor, display
  choice, a display unplugged or resized, Retina and a display left of or above the main one.
- Real CGEvent clicks, drags, scrolls and typing at absolute points on that Mac, with Accessibility,
  and the focused-window rule with two displays.
- A real phone's hardware decoder (latency, surface behaviour after rotation and backgrounding).
- Real Wi-Fi and a busy screen (video, scrolling), and long sessions (memory, heat).

## The Mac controls the phone (`phone_control_draft1`)

Inside a phone screen window the Mac can tap, drag, scroll, pinch and type on the phone and press Back, Home
and Recents (protocol in [protocol.md](protocol.md), "Mac controls the phone"; the contract in
[screen-control-core.md](screen-control-core.md) with the phone as the host). The phone shares its whole
display for a Mac with a control grant, because gestures land on the whole display; for any other Mac the
share keeps Android's choice of one app or the whole screen.

On the phone, control goes through Bridgey control, an accessibility service that is off until the person
turns it on in Android's accessibility settings. It never reads window content. Gestures go out one part at
a time: Android cancels a gesture in progress when another starts, so each continuation waits for the
previous part's callback, starts exactly where it ended and carries every finger still down, and motion that
arrives meanwhile is merged into the next part. A part lasts at most 50 ms and at most 64 inputs wait. A
scroll is a drag of its own finger that goes down alone, then crosses the touch slop in a 32 ms part of its
own, then moves the whole distance, and lifts after 150 ms without scrolling, still for its last 50 ms so
the list does not fling. (A list starts dragging on the move that crosses the slop and scrolls only on the
moves after it; the first build moved the slop and the distance in one 8 ms part, which Android delivered as
a single move, and the list never scrolled.) Typing uses the accessibility input method on Android 13 and
later.

### Measured

Live, 2026-11-26: a throwaway test instance of the debug Mac app (its own bundle ID, port and Bonjour type) on
the personal Mac (M4) controlling the release-minified test build (`stress`, its own app ID) on the Android 16
emulator (bridgey-api36) on the same Mac, through `adb forward`, so a loopback rather than Wi-Fi. Input came
from the instance's control files, which call the same coordinator methods as the window; the mapping from
mouse, trackpad and keys to those calls is covered by unit tests only.

| Measure | Result |
| --- | --- |
| Control asked to `active`, Allow without asking | 12 ms (`asked` to `active` in the Mac's log) |
| Mac sends an input to the phone accepting it | within the clock comparison's ±20 ms (median 0 ms over 40 taps); the stream's round trip on this loopback is 3 to 6 ms, median 4 ms |
| Phone accepts an input to its gesture part starting | median 0 ms, p90 35 ms, max 50 ms (the tail is input waiting behind a 50 ms still part of a scroll) |
| Phone accepts an input to its gesture part completing | median 4 ms, p90 52 ms, max 60 ms (88 parts, none cancelled) |
| Capture to decoded on the Mac while controlling | 23 to 48 ms, median 37 ms (a mostly still screen at about 10 frames a second) |

So a tap shows on the Mac roughly 2 ms (network) + 4 ms (injection) + the app's own drawing and up to one
frame + 23 to 48 ms (capture to decoded) after it is sent. That is an estimate from the stages, not a
measured input-to-picture time.

Also checked live: the share dialog offers only "Share entire screen" for a Mac with a control grant ("Share
one app: Not supported by the app") and keeps "Share one app" for a Mac without one; taps open apps and rows
at the right place in portrait and in landscape (after rotation the phone moved to a new geometry
generation, the Mac acknowledged it, and control went on); typing into a search field, Backspace; scrolling
both ways; Back, Home and Recents; Ask each time (the question on the screen and as a notification, Allow
starts control); raising the grant while controlled is refused; turning the grant off ends control on both
ends (`disabled`); turning the service off ends it (`permission`) and the Mac's Control button turns off
until the service is back; Stop on the phone's bar ends it (`local_stop`) and keeps the picture; Stop control
on the Mac sends the contract's `stop`; a silent disconnect ends control after the contract's 6 seconds and
the stream after its ack timeout, and nothing resumes after reconnecting.

Found and fixed during the live check: the scroll start above; the phone's bar squeezed its Stop button to
nothing on a long Mac name; Android 16 showed the Ask each time notification redacted ("Unlock to view")
while the screen was shared, so it is now public (nothing in it is private) and the question is also drawn on
the screen by the service; and a Mac kept showing control as active when the phone withdrew the key before
its `ended` arrived, so the Mac now ends control when the key goes.

### Still to check on real devices

- A real phone's accessibility gestures and input method (OEM builds differ), with Allow restricted settings
  on an APK installed from a file (Android 13 and later), and Android 8 to 12 without typing.
- Mouse, trackpad (scroll momentum, pinch) and keyboard in the real window on a Mac, rather than control files.
- The bar's position over apps' own top bars, real Wi-Fi, a busy screen and long sessions.
