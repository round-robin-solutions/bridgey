# Shared session client (`rust/client`)

The Windows and iOS apps, and later Linux, run the Bridgey session from one Rust library, `bridgey_core`,
behind a C ABI ([`rust/client/include/bridgey_core.h`](../rust/client/include/bridgey_core.h)). Android and the
Mac keep their own Kotlin and Swift code; nothing in either app changed.

## Where the session lives today

| Part | Android (Kotlin) | Mac (Swift) | Rust before this | `rust/client` |
| --- | --- | --- | --- | --- |
| Discovery (`_bridgey._tcp`, TXT `id`, `name`, `version`, `platform`) | `NsdDiscoveryService` | `BonjourDiscovery` | none (the CLI uses the tailnet only) | built-in DNS-SD (`mdns-sd`), or the host passes devices in |
| Frame codec (newline JSON, 65,536 bytes, depth 32, strict types) | `ProtocolDecoding.kt` | `ProtocolDecoding.swift` | `rust/cli/src/wire.rs` | the same code, moved here; the CLI re-exports it |
| Protocol 2 pairing (commit, answer, reveal, code, confirm, `bridgey-auth-v1` transcript) | `PairingCoordinator.kt`, `SessionSecurity.kt` | `Pairing.swift`, `SessionSecurity.swift` | CLI tailnet and invite pairing | yes, dial and answer, with Allow pairing, `not_armed` retries, three answered offers a minute, busy, and crossed pairing |
| Trust store and identity pins | identity in Android Keystore, trusted devices in private `bridgey.trust` preferences | `trust-v3.json` | CLI files | host storage callbacks (DPAPI on Windows, Keychain on iOS) or owner-only files |
| Encrypted session (AES-256-GCM payloads, envelope tags, 256-entry replay window, 16 bad frames close) | yes | yes | CLI | yes |
| Features (`features.update`, required keys, drafts read true only when JSON true) | yes | yes | CLI (agent map) | yes, with per-device switches stored with each trusted device |
| Heartbeat and reconnect (10 s ping, 30 s dead; 2, 5, 15, 30, 60 s for an hour, then 10 min; lower device ID keeps a crossed dial) | `Reconnect.kt` | `Reconnect.swift`, `SessionRegistry.swift` | tunnel heartbeat only | yes |
| Clipboard text (`clipboard.update`, `clipboard.rich` in, ack and rejected) | yes | yes | CLI | yes |
| Ping (`ping.v1`) | yes | yes | CLI | yes |
| Files (`files.v1`, JSON chunks of 24 KiB, both ways, one at a time per device, SHA-256 checked, never overwriting) | yes | yes | CLI (sending) | yes, from iOS I1; received files go to a folder the host names, with names Windows accepts (`photo (1).jpg` on Windows, `photo 2.jpg` elsewhere) |
| Fast transfers (`files_fast_draft1`): binary frames of 256 KiB, their replay guard and the delay-based window | `FastTransfer.kt` | `FastTransfer.swift` | none | yes (`fast.rs`), from Windows M2, checked against `files-fast-v1.json` |
| Resuming files (`files_resume_draft1`): an interrupted file continues after the receiver's verified 1 MiB blocks | `FileResume.kt` | `FileResume.swift` | none | yes (`resume.rs`), checked against `files-resume-v1.json`; see [file-resume.md](file-resume.md) |
| Battery (`battery.update`) and find device (`find.*`) | yes | yes | CLI | yes, from Windows M2 |
| Links (`quick.request` / `quick.result`, feature `links`, `open` to a Mac with `links_open_draft1`) | yes | yes | none | yes, from iOS I1; a received link is an event, never opened by the library |
| Phone notifications (`notifications.post`, `remove`, `dismiss`, `action` with reply), quiet presentation (`notification_routing_draft1`) and presence (`device_presence_draft1`) | yes (phone side) | yes | none | yes, the desktop side: checked and bounded posts, quiet honoured, presence every ten seconds and on change |
| Codes from messages and email (`codes.*`, the code in a notification) | phone side | model or relay | `rust/codes` (candidate, gate, guard, model) | yes, with a rules reader instead of the model (`codes.rs`); the shared candidate rules and guard decide |
| The phone's media controls (`quick.request` media, `media.state`) and links the phone asks to open at once (`links_open_draft1`) | yes | yes | none | yes, the desktop side, from Windows M2: Open links right away opens at most one link every 3 s per device; media commands go to the host and are answered once the player has acted; `media.state` on change and every ten seconds while playing |
| Connect away from home (`connect_draft1`: `connect.setup`, `connect.addresses`, tunnel sessions with `bridgey-auth-v2`) | yes | yes | CLI and the core | yes: the core's node runs in the client, pair secrets and learned addresses are kept with each trusted device, tunnels carry protocol 2 reconnects only |
| Self-update for direct downloads (the channel feed's `windows` entry; size, SHA-256 and the release key's Ed25519 signature) | Play/APK updater | Sparkle | none | yes (`update.rs`, `bridgey_update_check` and `bridgey_update_verify`, no client needed) |
| Text messages (`sms_draft1`: conversations, sync, sends, MMS pictures, contacts, Mark as read, Block on phone) | phone side | yes | none | yes, the desktop side, from Windows M3 (`sms.rs`): the Mac's sync rules and cache, kept in the host's storage |
| The Calls window (`dialer_draft1`: status, contact search, recent calls, calls through the phone or its WhatsApp) and calls (`calls.request`) | phone side | yes | none | yes, the desktop side, from Windows M3 (`calls.rs`): the Mac's search, list and SIM rules; memory only |
| Phone files (`files_browse_draft1`: places, folders, photos and recent documents, thumbnails) and folders from the phone (`folders_draft1` receiving, `into` downloads) and to it (`into` uploads) | phone side | yes | none | yes, the desktop side, from Windows M3 (`phone_files.rs`, `folders.rs`): files to the folder being browsed; no folder journal or resume yet |
| Everything else (sending folders with a root, screen, settings sync, Update all) | yes | yes | none | not yet: each moves when a new platform needs it (Windows M3, iOS I2) |

## How it works

- One `Client` per app. It listens on 42458, publishes and browses DNS-SD, and keeps one authenticated session per
  trusted device. All network work runs on the library's own two threads.
- The host drains one bounded event queue with `bridgey_next_event`, a blocking poll. When the queue is full,
  discovery and feature events make room first; anything else dropped is counted, and the host gets
  `EVENTS_DROPPED` and refreshes from `bridgey_snapshot`.
- Pairing: `bridgey_pair` dials (by discovered ID, address, or both). The other device shows a "wants to pair"
  prompt unless it allows pairing; this end tries again every 3 s for two minutes. Both ends show the same six
  digits, both people confirm, and only then is the device trusted, pinned to its identity key and protocol 2.
  `bridgey_allow_pairing` lets others pair with this device (call it while a pairing screen is open).
- Per-device switches: `bridgey_set_feature` with a device ID changes that device only; without one it changes
  the default. Connected devices get the new `features.update` at once.
- Files: `bridgey_send_file` hashes a file, offers it, and sends it once accepted; `FileProgress`, `FileDone` and
  `FileFailed` follow with the transfer ID (`bytes` and `total` are on the event). Received files need a folder
  (`receive_dir` in the config, or `bridgey_set_receive_dir`); without one, offers get `files.rejected`. A file is
  written to a hidden `.bridgey-<id>.part` beside it and only renamed once its hash matches.
- Links: `bridgey_send_link` and the `Link` and `LinkSent` events.
- Hosts with their own Bonjour (iOS) build without the `mdns` feature and pass devices in with
  `bridgey_add_discovered` and `bridgey_remove_discovered`. A share extension sets `manual_connect` and calls
  `bridgey_connect` for the one device it sends to.
- Writes go through a queue, so reading never waits on the socket; file chunks wait when 16 are queued. Reads run in
  their own task and hand whole frames to the session, so a frame split across reads is never lost when a command,
  a chunk or the heartbeat wins a turn of the session loop; at most 48 MiB is read ahead.
- With a peer that shows `files_fast_draft1` (and `bridgey_set_fast_transfers` on, the default) chunks are binary
  frames of 256 KiB. The receiver acknowledges each one, and the sender keeps its unacknowledged bytes within a
  window that grows while acknowledgements come back quickly and shrinks when their round trip climbs 40 ms.
- With a peer that shows `files_resume_draft1` (on by default; `Config::file_resume`, `Client::set_file_resume`, not
  in the C ABI yet) an interrupted file over 1 MiB keeps its verified partial for 24 hours, its record in the host's
  storage under `file-resume`, and the next send of the same file continues after it. `FileProgress` then starts at
  the resume offset.
- Battery and find device: `bridgey_set_battery`, `bridgey_find`, `bridgey_find_stopped`, and the `Battery`,
  `FindRequested` and `FindState` events.
- The phone's own features (`phone.rs`, one module per area) take JSON commands through
  `bridgey_phone(handle, area, device_id, command)`, which answers at once (`{"ok":true,...}` or
  `{"ok":false,"error":...}`), and report changes as one event kind per area (`name` says what changed, `text` holds
  JSON). The library keeps each area's state and talks to the phone; the host only shows it.
- Text messages (area 1, `sms.rs`) follows the Mac: without a cache, the phone's cursor is the starting point and the
  newest 30 conversations load; with one, `sms.sync` from the cursor on connect and after each `sms.changed`. At most
  200 conversations and the newest 200 messages of each are kept in the host's storage under `sms-<device>` (DPAPI on
  Windows), written at most once a second, and deleted when Text messages goes off at either end or the phone is
  forgotten (`keep` off stores nothing). Ops: `status`, `threads` (unread first; `filter: unread`), `refresh`,
  `older_threads`, `open`, `close`, `messages`, `older_messages`, `send` (to a conversation, a number or an SMS
  notification), `retry`, `discard`, `image`, `contacts`, `mark_read`, `mark_unread`, `block`, `forget`, `keep`.
  Events: `status`, `changed`, `send`, `image` (base64, kept in the host's memory only), `contacts`, `notice`,
  `reply_failed`. Notifications carry `smsReply` and `smsThreadId`, so a text's notification can be answered and
  opens its conversation.
- The Calls window (area 2, `calls.rs`) follows the Mac: the phone's `dialer.status` brings its recent calls; a search
  goes 120 ms after typing stops and an answer to an older one is dropped; one call at a time, at most one every 3 s;
  with two SIMs and nothing chosen, a call answers `choose_sim` so the host asks. A phone without the Calls window for
  this device but with `calls` on still takes a number as `calls.request` (answered outer-only with its own message
  ID). Never for agent devices; nothing is kept on disk. Ops: `state`, `recents`, `search`, `rows` (the list for what
  is typed: a typed number, contacts, then recent calls once per number), `call` (`address`, `subId`, `prefer` ask,
  sim1 or sim2), `whatsapp` (`dataId`, `video`). Events: `changed`, `call` (sent, started, confirm, refused with its
  reason, or no_answer).
- Phone files (area 3, `phone_files.rs`) asks in two lanes with the phone's budgets (browse: 4 in flight and 40 per
  10 s; media: 4 active and 60 per 10 s), and each answer must start within 8 s. Ops: `status`, `places`, `list`
  (`placeId`, `path`, `cursor`, `sort`, `descending`), `media` (`media`, `files` or `recent`), `thumbnails` (up to 64
  `{key, ref}`, `replaces`), `cancel`, `download` (up to 100 refs, `folder` or the receive folder), `cancel_download`,
  `upload` (`placeId`, `path`, files), `cancel_upload`. Events: `status`, `places`, `list`, `media`, `thumbnails` (one per
  batch, base64), `download` and `upload` (progress and outcome). A download is a folder transfer from the phone with
  `into`: the session's file engine writes each entry (binary frames or JSON chunks, verified against the manifest)
  under a name the folder receiver chose in that folder, and a clash becomes "name (1).ext"; nothing is merged or
  overwritten. A folder the phone sends on its own lands in the receive folder under its own (numbered) name. An
  upload offers the files with `into` to the folder being browsed, each name made portable. A folder that breaks off
  is not resumed (the phone hears `resume_unavailable`); the files saved stay. The host advertises
  `folders_receive_draft1` with Files (a switch, so iOS sends nothing new).
- ABI 1 grows only at the end: `BridgeyConfig` fields after `data_dir` are read only when `struct_size` covers
  them, and new event kinds are skipped by hosts that don't know them.
- Ownership: client handles are `uint64_t`, so a stopped or freed handle is refused rather than dereferenced.
  Strings in are borrowed for the call; strings and events out are freed by the library. Panics never cross.
- Media will not use the event path. File bytes never do: the library reads and writes the files itself.

## How it is checked

- `cargo test -p bridgey-client`: the shared vectors (`crypto-v1.properties`, including the protocol 2 code, and
  the golden frames in `protocol-v1.json`), feature-map rules against `protocol/messages.json`, and two clients on
  one machine that pair, exchange clipboard text both ways, wait for Allow pairing, refuse a wrong code, reconnect
  after a restart, refuse a changed identity, pair when both people start at once, and forget. The C ABI is tested
  the way a host calls it, including host storage callbacks.
- `tests/files.rs`: files both ways, in order, refused, cancelled, changed after hashing; links; manual connect;
  devices the host finds and loses. `tests/files_fast.rs`: binary frames both ways next to JSON chunks, Windows
  names, cancels from either end, a dropped connection, two devices sending 24 MB to each other at once, battery
  and find device. `tests/files_resume.rs`: resuming after the sender or the receiver drops or restarts, and starting
  from zero when the source changed, the partial expired or was tampered with, a peer lacks the key, or on a cancel.
- `protocol/test-vectors/session-client-files-v1.json` is a recorded session after pairing: battery both ways, find
  device, one file in binary frames and one in JSON chunks. `SessionClientFilesVectorTest.kt` and
  `SessionClientFilesVectorTests.swift` open every frame with the apps' own code (envelope tags, fast frame keys,
  AES-GCM, the file offer checks) and reassemble both files.
- `cargo test -p bridgey-cli`: the CLI's own session (which has paired with both apps since 0.10) pairs with the
  client in both directions.
- `protocol/test-vectors/session-client-v1.json` is a real session between two clients, recorded on the wire.
  `SessionClientVectorTest.kt` (Android) and `SessionClientVectorTests.swift` (Mac) check every frame with the
  apps' own decoder, commitment, code, proof, signature, envelope tag, AES-GCM and feature code.
- `protocol/test-vectors/session-client-notifications-v1.json` is a recorded session where one client sends what a
  phone sends (notifications, codes messages) and the Windows side answers (an action with a reply, dismiss, link
  request, advertising result, presence). `SessionClientNotificationsVectorTest.kt` reads every Windows message with
  the phone's own checks (64-character action tokens, presence decoding, codes payloads);
  `SessionClientNotificationsVectorTests.swift` decodes the posts' presentation as the Mac does.
- `session-client-quick-v1.json` records a phone's link and media requests and the Windows side's answers, its
  `media.state` and a link it sends. `SessionClientQuickVectorTest.kt` parses them with the phone's own code
  (`MacMediaState.parse`, `validatedWebLink`, `QuickRequestSequence`); `SessionClientQuickVectorTests.swift` checks the
  link with the Mac's. `cargo test -p bridgey-client --test connect` pairs two clients, lets them set up Connect away
  from home, cuts the local network and checks that the session comes back over a QUIC tunnel.
- The codes rules reader shows the right code for every sample in `otp-samples.json` that has one (30 of 30) and
  nothing for the 12 without.
- Text messages: every `sms*` group of `protocol-v1.json` (what the desktop reads from the phone, and the requests
  and sends it writes) is checked in `src/sms/tests.rs`, with the cache's merge, read and unread-first rules.
  `tests/sms.rs` runs a session against a client that answers as a phone (`simulate_phone_for_tests`, also the
  scripted peer's `--phone`): conversations, a send to delivered, a refused send, a picture, contacts, Mark as read,
  Block on phone, and the cache going when Text messages is turned off.
- The Calls window: every group of `dialer-v1.json` and the callsRequest group of `protocol-v1.json` are checked in
  `src/calls/tests.rs`, with the Mac's list and SIM rules. `tests/calls.rs` runs a session against a simulated phone:
  recent calls, a contact search, the SIM question, a call started, a WhatsApp call waiting for a tap, an emergency
  number refused, a call request when only `calls` is on, and an agent that never gets calls.
- Phone files: every group of `browse-v1.json` (pages, download answers, thumbnails, previews and ranges read; media
  lists and cancels written), the `browseRef` group of `protocol-v1.json`, and `folders-v1.json` (portable names, paths,
  conflict names, case clashes, the manifest digest, a manifest's pages and the receiver's checks) are checked in
  `src/phone_files/tests.rs` and `src/folders.rs`. Names that need NFC composition are left to the host (Windows
  composes the names it uploads), so the vectors with combining marks are skipped. `tests/phone_files.rs` runs a session
  against a client that answers as a phone: places, folders, photos, thumbnails, the lanes under load, a download of a
  file and a folder tree that lands verified next to a file of the same name, and an upload of two files.
- `protocol/messages.json` lists `client` for the 98 kinds it speaks; a test fails if the sources and the list
  differ.

`include/bridgey_core.h` is generated: `BRIDGEY_WRITE_HEADER=1 cargo test -p bridgey-client --test header`. The
recorded session is regenerated with `BRIDGEY_WRITE_VECTORS=1 cargo test -p bridgey-client --lib vectors`.

## Not covered yet

- A live pairing with the shipping apps on real devices or an emulator; the checks above are on the wire format
  and shared code.
- Tailnet discovery (Tailscale's own addresses are learned through `connect.addresses`).
- Remote pairing by invite (the agent CLI's); pairing stays on the local network.
- Clipboard files, sending folders with a root, resuming a folder, and resuming a file.
- Link-local IPv6 addresses from DNS-SD are skipped (no scope ID is tracked).
