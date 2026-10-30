# Transfer speed: fast transfers (`files_fast_draft1`)

Status: built on `rr/fast-transfers` (October 2026), behind the draft key `files_fast_draft1`. Measured on the
personal Mac (M4), on `rr-dev-1` and with both apps on the bridgey-api36 emulator (Android 16, 4 cores, 2 GB) over
`adb forward`. **Not yet measured on real Wi-Fi or on the OnePlus 11** (section 7).

Rahul, 2026-10-29: Phone files downloads ran at about 1 to 3.5 MB/s; he expected 80 to 100 MB/s. This page explains
why the old path was slow, what changed, what was measured, and what is still an estimate.

Every number below is marked **measured** (with where and how) or **estimate** (with its source).

## 1. What changed

| | Before (any peer without the key) | Now (both peers show `files_fast_draft1`) |
| --- | --- | --- |
| Chunk on the wire | 24 KiB, AES-GCM, then base64 inside a JSON line | 256 KiB binary frame: AES-GCM with the frame's fields in the associated data, no base64, no JSON |
| In flight | at most 64 chunks (1.5 MiB) for the Mac's sends and for folders; the phone's single files only TCP's own limit | a byte window from 2 MiB up to 32 MiB that follows the link's queueing delay |
| Acknowledgements | one `files.chunk.ack` per chunk (folders); single files from the Mac paced on them | one `files.chunk.ack` per chunk for every kind of transfer, read as cumulative by the sender |
| Phone Wi-Fi power saving | not held off | low-latency and high-performance Wi-Fi locks plus a partial wake lock while a transfer or speed test runs |
| Speed test | none | Settings > Privacy > Transfer speed on both apps |

The wire format and rules are in [protocol.md](protocol.md#draft-fast-transfers-and-the-speed-test-files_fast_draft1).

### Acknowledgements: per chunk or cumulative?

Both. The receiver sends one `files.chunk.ack` (outer only: `transferId` and `sequence`) for **every** chunk it has
written. The sender's window (`TransferPacer` in `FastTransfer.kt` and `FastTransfer.swift`) treats each one as
**cumulative**: an ack for sequence N releases every chunk of that transfer up to N. Chunks of one transfer arrive in
order over one TCP connection and the receiver refuses a gap, so a lost or reordered ack cannot happen on today's
transport; reading them cumulatively only means a late ack never leaves bytes stuck in the window. With 256 KiB
chunks that is one small JSON line back for every 256 KiB forward (about 4,000 a second at 1 GB/s).

### Peers without the key

A peer that does not advertise `files_fast_draft1` (an older build, upstream Bridgey, or a Mac with
`defaults write in.roundrobin.bridgey transfers.fastOff -bool true`) gets exactly the old path: 24 KiB JSON chunks
and the 64-chunk window. Binary frames are also never used on a protocol 1 session. Tested:
`FastFrameSessionTest.aMacWithoutTheKeyGetsJsonChunks` (the real Android coordinator sends a 1 MiB file to a fake
Mac that shows the key as false: every chunk is a JSON `files.chunk` of at most 24 KiB, and the bytes arrive intact)
and `aMacWithTheKeyGetsBinaryFrames` (the same file as four 256 KiB frames and one of 100 bytes).

## 2. Measured: the ceiling of each layer

Each row is one layer on its own, so the slowest one shows where the time goes. Both apps' benches use the same frame
code the apps run (`FastTransferCeilingBench` on each platform): a sender reads a 1,000 MB file from disk, waits for
room in the window, seals and writes; a receiver splits frames, decrypts, checks replay, writes the file and its
SHA-256 and acknowledges each chunk; the acks drive the sender's window. On the Mac the receive side mirrors the
app's threads (frames decrypted on a receive queue, file writes and acks on the main thread).

| Layer | Where | Old path (24 KiB JSON) | Fast path (256 KiB binary) |
| --- | --- | --- | --- |
| Mac code, loopback, acks, disk, SHA-256 | personal Mac (M4), release build | **19 MB/s** | **574 MB/s** |
| Android code on the JVM, loopback, acks, disk, SHA-256 | rr-dev-1 (x86, busy with other builds) | **13 MB/s** | **133 MB/s** (211 MB/s without disk) |
| Android code on ART (Android's runtime), loopback inside the emulator, acks, no disk | bridgey-api36 (API 36, arm64) on the personal Mac | | **245 MB/s** |
| Android code on ART in the emulator, acks, file written to app storage (`/data`) | bridgey-api36 | **18 MB/s** | **145 MB/s** |
| Android code on ART in the emulator, acks, file written through Android's shared storage (`/sdcard/Download`, as received files are) | bridgey-api36 | **14 MB/s** | **116 MB/s** |
| TCP alone, loopback | Mac (NWConnection) / rr-dev-1 JVM | 2,929 MB/s / 883 MB/s | |
| TCP alone, Mac to emulator through `adb forward` | personal Mac, bridgey-api36 | 1,073 MB/s | |
| TCP alone, emulator to Mac through `adb forward` | personal Mac, bridgey-api36 | 71 MB/s | |
| TCP alone, emulator dials the Mac at 10.0.2.2 (the emulator's own network) | personal Mac, bridgey-api36 | 4.3 MB/s out, 6.7 MB/s in | |
| TCP alone, loopback inside the emulator | bridgey-api36 | 1,439 MB/s | |

Crypto alone, one core (measured): on the Mac AES-GCM seal 3,087 MB/s, open 3,158 MB/s, SHA-256 1,610 MB/s; on ART in the
emulator seal 560 MB/s, open 514 MB/s, SHA-256 1,378 MB/s; the old JSON chunk on ART 50 MB/s to build and 51 MB/s to
read, before any network.

All rows are single runs (the emulator disk rows used a 300 MB file, the rest 1,000 MB); rr-dev-1 had a load average
of 9 to 17 from other agents' builds, so its numbers are lower bounds. The ART rows run the app's own classes from the
debug APK with `app_process`, outside the app, so they include no UI, no Bridgey session and no MediaStore bookkeeping.

### Both apps on the emulator (measured, 2026-10-30)

The signed release APK (versionCode above every published beta, so it is never replaced from GitHub) on
bridgey-api36, and a throwaway Mac build (own bundle ID, support folder and port) on the personal Mac, connected by
`adb forward`, never through the emulator's own NAT. Files: 1,000 MB of random bytes; 200 files of 5 MB; for Phone
files downloads a 1,000 MB video and 200 photos of 5 MB in the phone's gallery. Time runs from the request on the Mac
to the last file verified (both apps hash every file), so it includes the sender's hashing pass. Every received file
was checked: the 1 GB files matched SHA-256 on both sides. Phone app in the background unless noted.

| Transfer | Fresh install, first runs | Later runs (another emulator boot) |
| --- | --- | --- |
| 1 GB Mac to phone | **283 MB/s** (3.5 s) | 109 to 176 MB/s (4 runs) |
| 1 GB Phone files download (phone to Mac) | **133 MB/s** (7.5 s) | 77 MB/s (2 runs) |
| 200 × 5 MB Mac to phone, as separate files | 38 MB/s | 39 to 47 MB/s |
| 200 × 5 MB Mac to phone, as one folder | 46 MB/s | 59 to 91 MB/s |
| 200 × 5 MB Phone files download | see below | see below |
| In-app speed test, started on the phone | | phone to Mac 134.6 MB/s, Mac to phone 332.9 MB/s, round trip 2 ms idle, 34 ms loaded |
| In-app speed test, started on the Mac | | Mac to phone 320.9 MB/s, phone to Mac 132.0 MB/s, round trip 2 ms idle, 27 ms loaded |

The two columns differ by up to 2x with the same builds: the first emulator boot (by another session) ran faster than
the later ones. Compare rows within one column only.

**A/B on one emulator boot, Phone files download of 200 photos of 5 MB** (each figure one run of 2 × 100 files):

| Build | Runs | Of which: preparing 100 files (hashing) |
| --- | --- | --- |
| Before this session's fixes (`fc56cb7`) | 47.3, 47.7, 48.4 MB/s | 2.0 to 2.4 s |
| After (hashing four files at a time) | 59.7, 59.9, 67.0 MB/s | 0.5 to 0.9 s |

**The app on screen costs half the speed on the emulator.** 200 × 5 MB Mac to phone ran at 25 to 26 MB/s with the
phone app in front (three runs, steady) against 46 MB/s with it in the background; the phone's `RenderThread` took 41
to 50% of the samples, all of it in the emulator's software graphics pipe. A phone with a real GPU will pay much less;
not measured.

The earlier session's 11 to 13 MB/s for 1 GB was not reproduced: the same kind of run measured 109 to 283 MB/s here.
Its numbers are left out of the tables.

## 3. Root causes, by impact

1. **The old chunk format itself.** 24 KiB per chunk, base64 (a third more bytes, and an encode and decode pass) inside
   a JSON line that is built, parsed and checked per chunk, with a fresh nonce, a UUID message ID and an envelope tag
   each. The same old path tops out at **19 MB/s on an M4, 13 MB/s on an x86 server and 14 to 18 MB/s on ART in the
   emulator, with no network at all** (measured, section 2). A OnePlus 11 core is slower than the M4 cores the
   emulator runs on, so on the phone it is lower still (inference). Fast frames remove it: the same code paths move
   116 to 574 MB/s.
2. **Only 1.5 MiB in flight** for the Mac's sends and for folders (a Phone files download is a folder transfer):
   64 chunks of 24 KiB. On Wi-Fi with a 10 to 30 ms round trip that caps a transfer at 50 to 150 MB/s before anything
   else, and any stall on the receiver (a disk flush, a busy main thread, the phone
   saving Wi-Fi power) empties the pipe. Now: 2 to 32 MiB, sized by the queueing delay (estimate of the cap from the
   window and round trip; not measured on Wi-Fi).
3. **Not the emulator's network, as long as the Mac dials the phone through `adb forward`** (measured): that path
   carries 71 MB/s from the emulator and about 1 GB/s to it. The emulator's own NAT (the phone dialling the Mac at
   10.0.2.2) carries only 4 to 7 MB/s, so a live test where the phone dialled the Mac would be capped there.
4. **Something in the apps that the benches do not include** (open): both apps' frame code reaches 116 to 574 MB/s and
   the emulator link 71 MB/s or more, yet the earlier session reported 11 to 13 MB/s for the apps on the emulator. The
   benches leave out the apps' UI, session routing, MediaStore bookkeeping, the sender's SHA-256 pass before it sends,
   and per-file round trips; one of those, or the earlier measurement itself, is the gap. Finding it needs the live run
   in section 6, with `sample` on the Mac and simpleperf on the phone during the transfer. The old path shows the same
   kind of gap (14 to 18 MB/s in the bench against 5.5 and 9.1 MB/s reported live), and a Mac `sample` from the earlier
   session's old-path download shows the Mac idle, waiting on the network, so the phone side is the first suspect.
5. **Phone Wi-Fi power saving** (estimate, not measured here): with the screen off Android may still save Wi-Fi power;
   Android applies the low-latency lock only while the screen is on and Bridgey is in front. The speed test reports
   `screenOn` so this shows up in results.

Not a cause (measured): AES-GCM and SHA-256 (gigabytes a second on the Mac) and TCP loopback. The Mac bench does every
file write and ack on the main thread, as the app does, and still moves 574 MB/s; the app's main thread also draws the
windows, which the bench does not.

## 4. Security of the binary path

A fresh reviewer checked the binary frame path on 2026-10-30, including what is parsed before authentication.

- **Before authentication** binary frames are not read at all: the marker byte is an invalid JSON frame, as it always
  was, and the pairing ends (`FastFrameSessionTest.aBinaryFrameBeforeAuthenticationEndsThePairing`). They are allowed
  only on a protocol 2 session, after both sides confirmed.
- **Authenticated and bound like envelope tags**: the AES-GCM tag covers the frame and associated data holding the
  label, the sending device's ID, the kind, the ID and the sequence; the frame key is derived from the session key,
  which is fresh for every session.
- **Forged, reflected and replayed frames** are dropped and counted with frames that fail an envelope tag; 16 close
  the session (`FastFrameSessionTest.forgedReflectedAndReplayedBinaryFramesAreDroppedAndSixteenCloseTheSession`, on the
  real Android coordinator, plus the shared vectors in `protocol/test-vectors/files-fast-v1.json` on both platforms).

Fixed after the review: the Mac cancelled another phone's transfer when a binary chunk named it (medium); binary and
JSON clipboard chunks were taken from any paired device (Android) or without the device check (Mac binary) (low);
the Mac read up to 1 MiB per batch and queued unbounded work for the main thread before authentication (low); the
replay guard forgot long transfers first instead of the least recently used ones (low); unknown binary kinds were
skipped before their tag was checked (low); Android allowed binary frames a moment after the session became active
(info); binary frames used the session key itself, which also encrypts JSON payloads (info; nothing could cross,
but frames now use their own key, HMAC-SHA-256 of the session key and `bridgey-fast-frame-key-v2`).

## 5. The speed test

Settings > Privacy > Transfer speed on both apps sends about 7 seconds of test data each way over the session and
shows both directions, the round trip idle and under load, each side's link, and a verdict:

- **Route**: both on one router, Mac on Ethernet, Mac on the phone's hotspot, or not Wi-Fi or Ethernet on both sides
  (a cable, a VPN, an emulator).
- **Estimate**, always labelled as one, with its source:
  - from the two Wi-Fi link rates when both are readable: half to three quarters of the rate (on one router, of the
    two hops sharing the air);
  - otherwise typical Wi-Fi 6 values: 30 to 45 MB/s through one router, 50 to 75 MB/s with the Mac on Ethernet, 50 to
    90 MB/s on the phone's hotspot.
  - Source: phones on Wi-Fi 6 (2x2, 80 MHz, a 1,201 Mbit/s link) measured 900 Mbit/s down and 540 to 600 Mbit/s up
    (Aggarwal et al., INFOCOM 2021), collected in `docs/transfer-engine/research.md` on `rr/transfer-engine-research`;
    through one access point every byte crosses the air twice, so the two hops share the airtime (an inference).
- **No estimate** when the route is not Wi-Fi or Ethernet on both sides: the emulator's loopback, a cable or a VPN
  says so and gives no "slower than expected" verdict and no advice about routers.

Checked on the emulator path: not live (section 6). The verdict for that route is pinned by the shared vectors
`loopback (the emulator)` and `loopback (the emulator), slow` in `protocol/test-vectors/files-fast-v1.json`, which both
apps pass: on the emulator the session runs over loopback, so each side reports its network as `other`, and the
verdict says there is no estimate instead of the old "On a typical Wi-Fi 6 router, expect 30 to 45 MB/s. Your
connection is slower than that. The signal may be weak or the network busy. Move closer to the router."

## 6. Not measured yet

- **Both apps end to end on the emulator** (1 GB each way, 200 files of 5 MB, Phone files downloads) and the in-app
  speed test there. These need the phone app installed, set up and paired through its screens; in this session the
  emulator on the personal Mac was not available as a watched device, and driving its screens over ssh is not allowed
  without Rahul's explicit OK.
- **Real Wi-Fi with the OnePlus 11** and either Mac. The estimates above are not measurements.
- **Window behaviour on Wi-Fi with power-save jitter.** The window shrinks when the round trip climbs more than 40 ms
  over the lowest seen; whether Wi-Fi power saving triggers that needs a real device.

## 7. Running the benches again

```sh
# Mac (on the personal Mac, holding /tmp/app-build-mac.lock)
cd macos && BRIDGEY_PERF=1 swift test -c release --filter FastTransferCeilingBench
# Android code on the JVM (rr-dev-1 through iieon-slot)
cd android && ./gradlew :app:testDebugUnitTest -Pbench=1 --tests '*FastTransferCeilingBench'
# Android code on ART: dex the compiled bench class (with JUnit) and run it beside the debug APK
adb push app-debug.apk bench.dex /data/local/tmp/
adb shell 'CLASSPATH=/data/local/tmp/app-debug.apk:/data/local/tmp/bench.dex app_process \
  -Djava.io.tmpdir=/data/local/tmp -Dbridgey.bench=1 /system/bin dev.bridgey.android.FastTransferCeilingBench'
```

`BRIDGEY_BENCH_MB` (Mac) and `-Pbench.mb` or `-Dbridgey.benchMb` (Android) change the file size;
`-Dbridgey.benchDir=/sdcard/Download` writes the received file through shared storage.
