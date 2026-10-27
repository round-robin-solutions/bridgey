# Phone screen on the Mac (v0.9 prototype)

Status: **prototype, view only, off by default on both sides.** The wire format is the draft
`screen_draft1` in [protocol.md](protocol.md) ("Phone screen to Mac"). Control from the Mac is a
separate decision: [screen-control-decision.md](screen-control-decision.md).

## How it works

1. Both switches are on: Settings > Media and quick actions > Share screen with Macs on the phone (per
   Mac), Settings > Remote control > Show phone screens on the Mac. Setup asks too ("Let your Mac see
   this screen?"), and the Remote control bundle includes it.
2. Either the Mac asks (Show Phone Screen in the panel's File menu or the device menu sends
   `screen.request`; the phone shows "MacBook Air wants to see your screen" with Share and Not now),
   or the person starts it on the phone (the Mac's device page, or the Share screen Quick Settings
   tile).
3. Android's own dialog asks for consent. Android 14 and later ask every time, and the result can be
   used once, so Bridgey asks for a fresh one for every share and never keeps it.
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

- View only. No audio (Android 10 and later could capture it with the same consent; not built).
- One phone stream at a time per phone; a Mac can show several phones.
- The share stops when the phone's screen turns off rather than showing the lock screen.
- On a still screen the emulator's encoder stops repeating frames after a few seconds, so the Mac
  shows the last frame and the stream stays alive on `screen.stats`; to check on a real phone.
- Secure windows (banking apps, password fields with FLAG_SECURE) are black, by Android's design.
