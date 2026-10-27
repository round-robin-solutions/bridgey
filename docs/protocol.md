# Bridgey Protocol v1

Status: mixed implementation reference and future design draft. The native
clients currently use newline-delimited JSON over TCP, **not TLS/WebSockets**.
The proposed WebSocket envelope and `core.hello` negotiation below are future
design, not the wire format shipped in 0.5/0.6. JSON is UTF-8 encoded.

## Current native transport (0.5/0.6)

`PairingMessage` / Android `Message` use `kind`, `sessionId`, optional
`messageId`, and message-specific fields. Encrypted payloads use base64 `nonce`
and `ciphertext` (AES-GCM ciphertext followed by its authentication tag).
Native frames have a 65,536-byte limit. The session ID salts HKDF-SHA-256 for
ephemeral P-256 ECDH; the shared info is `bridgey-pairing-v1`. The displayed code
is derived from the first four key bytes modulo 1,000,000. Confirmation HMACs
bind identity keys; P-256 signatures bind session ID, ordered device IDs and
ephemeral keys. Trusted reconnects verify the stored peer signing identity.

Reconnects (Round Robin edition): both peers redial a dropped trusted peer at
its last known addresses, whichever side dialled before. A reconnect's
`pairing.offer` carries an optional `targetDeviceId`, the trusted peer it is
meant for; a receiver with another device ID closes the socket without a
pairing prompt, and a dialler whose `pairing.answer` names another device
closes too. Older clients ignore the field. When both sides dial at once, both
keep the socket dialled by the lower device ID (newer one if the same side
dialled both). Values and trade-offs: `docs/reconnect-reliability.md`.

Payload encryption is application-layer protection, not TLS. Routing headers
and some acknowledgements remain outside the encrypted payload; traffic
metadata is visible. Replay caches are bounded and session-local, not persistent.
The future transport design must not be advertised as an implemented guarantee.

## Discovery

Browse and publish DNS-SD service type `_bridgey._tcp.local.`. TXT values are
UTF-8 and advisory:

| Key | Meaning | Limit |
| --- | --- | --- |
| `id` | Stable random UUID, used only as a hint before authentication | 36 bytes |
| `name` | User-visible device name | 64 bytes |
| `version` | Highest supported envelope major version | 8 bytes |
| `platform` | `android`, `macos`, or a future identifier | 16 bytes |

The SRV port identifies the TLS WebSocket listener. TXT, hostnames, addresses,
and ports are attacker-controlled until the peer authenticates. Implementations
must deduplicate discoveries by service instance and refresh endpoints on every
network change.

## Framing and envelope

After the TLS WebSocket opens, each text frame contains exactly one JSON object:

```json
{
  "version": 1,
  "id": "018f5228-76c7-7b37-a42c-3cfe6f78219a",
  "type": "clipboard.update",
  "timestamp": 1786550000000,
  "replyTo": null,
  "expectsReply": false,
  "payload": {}
}
```

`id` is unique per sender (UUIDv7 recommended). `timestamp` is Unix epoch
milliseconds and is used for diagnostics/expiry, not message ordering. `replyTo`
correlates a response or acknowledgement. Receivers keep a bounded, persistent
window of recently accepted IDs per peer; a repeated ID is acknowledged if
needed but its side effect is not executed again.

Limits before negotiation for the planned capability envelope are 256 KiB per
JSON frame, depth 32, string length 128 KiB, and 1,024 keys. The current native
newline transport intentionally applies a stricter 65,536-byte frame limit
before UTF-8/JSON decoding. A malformed, oversized, or unterminated frame closes
the session before plugin dispatch. File chunks remain bounded independently.

## Session negotiation

The first authenticated application message is `core.hello`:

```json
{
  "deviceId": "550e8400-e29b-41d4-a716-446655440000",
  "deviceName": "Semyon's MacBook Pro",
  "platform": "macos",
  "protocolVersions": [1],
  "capabilities": ["battery.send.v1", "clipboard.v1", "files.v1", "notifications.receive.v1"]
}
```

The selected version is the highest intersection. Capability negotiation is the
set intersection; absence means disabled. Device ID must match the identity
bound to the pinned key. No common version closes the connection with
`unsupported_version`.

Core types are `core.hello`, `core.ack`, `core.error`, `core.ping`, and
`core.pong`. An acknowledgement payload contains `status` (`accepted`,
`completed`, or `rejected`). Errors contain a stable `code`, safe `message`, and
optional details. Error text must not disclose secrets.

The current native clients also exchange an authenticated, encrypted
`features.update` message after pairing and whenever local policy changes. Its
version 1 payload contains a complete boolean map for `clipboard`, `files`,
`notifications`, `battery`, `find_device`, `ping`, `calls`, `links`, and `media`. A UI action is
available only when both peers report the corresponding feature as enabled. Clients
predating this message are treated as enabling the original v1 features for
compatibility; the later `calls`, `ping`, `links`, and `media` features are disabled unless a peer
advertises them explicitly. Draft keys (`clipboard_files_draft1`, `remote_input_draft1`,
`sms_codes_draft1`) are optional booleans described in their own sections; a missing draft key
means `false`.

## Pairing flow

Pairing runs only after a user selects a discovered peer:

1. Both peers create ephemeral P-256 ECDH key pairs and exchange
   `pairing.offer`/`pairing.answer` containing nonces and public keys.
2. Each validates all fields and derives the same secret with platform crypto.
3. HKDF-SHA-256 derives independent verification and session keys, binding the
   ordered public keys, nonces, device IDs, and protocol version into `info`.
4. A six-digit code derived from the verification key is displayed on both
   devices. It is never sent over the network.
5. Each user explicitly confirms; peers exchange authenticated
   `pairing.confirm` records containing their long-term public keys.
6. Trust is stored only after both confirmations verify. Any timeout, mismatch,
   rejection, or disconnect erases ephemeral state.

Pairing offers expire after two minutes and cannot be silently retried. The
short code is a human MITM check, not a password. Detailed primitive and storage
requirements are in `SECURITY.md`.

## Plugin messages

### Quick actions (native 0.6)

`quick.request`, `quick.result` and `media.state` are AES-GCM-encrypted payloads
accepted only in the current connected session. Requests/results are limited
to 8 KiB plaintext; media state to 32 KiB. The normal 65,536-byte frame bound
still applies. Unknown versions, malformed values and stale sessions are ignored.

Requests contain `version: 1`, UUID `requestId`, `feature`, `action`, string
`value`, and positive integer `sequence` (at most 2^53−1). Receivers retain a
per-feature sequence high-water mark for the entire session, independent of
the outer message ID/replay cache; old encrypted requests cannot re-execute by
changing that ID. Sender sequences increase and requests are not auto-retried.
An authenticated result echoes the inner requestId and feature with boolean
`accepted`. Pending operations time out after eight seconds and are cleared
on disconnect or feature disable. Timeout means “not confirmed”, not an assertion
that an operation definitely never reached the other peer.

- `links` / `offer`: 4,096 UTF-8 bytes maximum, HTTP(S) only, nonempty host,
  no user credentials, whitespace/control characters or backslashes, valid
  optional port. One pending received link per device; a second is declined.
  Acceptance means queued for explicit local Open/Dismiss, **not** opened.
- `media`: Android → Mac, only `toggle`, `pause`, `next`, `previous`, `seek`
  (integer seconds 0…604800), `volume` (integer 0…100). The Mac must locally
  opt in and select running Music or Spotify. Commands map to fixed player
  AppleScript instructions, never received source code or a remote shell.
  Automation failures and a busy player are reported as rejected. Accepted
  means the player command completed, not that a particular track must exist.
- `media.state`: Mac → Android; `version`, `player`, `title`/`artist` (256
  characters each), boolean `playing`, integer `position`/`duration`
  (0…604800), `volume` (0…100), bounded `detail`. Optional base64 `artwork`
  contains at most 16 KiB JPEG, at most 128×128 pixels. The receiver validates
  both encoded size and decoded dimensions before allocating a bitmap.

Music artwork comes from player automation, not filesystem browsing; it is
optional and may be unavailable. Spotify artwork is not downloaded. Metadata
refreshes after commands/settings changes and on the ten-second heartbeat.

### Battery (`battery.send.v1`)

Either battery-powered peer sends `battery.update` after a secure session is
established and when its battery state changes. Android uses system battery
broadcasts; macOS checks its public IOKit power-source state on connection and
while the heartbeat is active:

```json
{
  "level": 79,
  "isCharging": true
}
```

`level` is an integer from 0 through 100. Receivers reject out-of-range or
malformed values. Battery updates contain no device identifier because the
authenticated session already binds them to the paired sender.

### Clipboard (`clipboard.v1`)

`clipboard.update` remains the compatible plain-text form: its decrypted payload
is UTF-8 text. `clipboard.rich` carries versioned UTF-8 JSON:

```json
{
  "version": 1,
  "text": "example",
  "html": "<p><strong>example</strong></p>"
}
```

The combined text and HTML content is limited to 32 KiB before encryption. The
text field is mandatory and is always written as a fallback; supported clients
also write the HTML representation. Receivers reject malformed, unsupported,
empty, or oversized payloads. Each encrypted update has a unique message ID and
the current transport replies with `clipboard.ack` after the write. If local
policy disabled clipboard handling while a peer still had stale capability
state, it replies with `clipboard.rejected` and immediately resends the
encrypted `features.update`; senders time out rather than displaying an
unbounded sending state.

### Clipboard offers (`clipboard_files_draft1`)

Status: **Draft, edition only until accepted upstream.** Bridgey by Round Robin uses it between
two edition peers; upstream clients never see these messages.

This lifts the 32 KiB limit and adds images and files, the way Apple's Universal Clipboard works:
the other device learns about a copy straight away, and the data moves when someone pastes.
Small items are pushed at once, so pasting them is instant; copying a 2 GB video and never pasting
it moves only the description.

**Negotiation.** `features.update` gains the boolean key `clipboard_files_draft1` in its `features`
map. A peer sets it when Clipboard is on for that device and its local "Copy images and files"
setting is on. The messages below are used only when both peers advertise `true` and Clipboard is
available on both. A missing key means `false`. Otherwise, and with upstream or older peers, the
clients keep the behaviour above exactly: text up to 32 KiB through `clipboard.update` and
`clipboard.rich`.

Between two peers that both advertise the key:

- text whose text and HTML together fit in 32 KiB still uses `clipboard.update`/`clipboard.rich`;
- longer text, images, and files use `clipboard.offer`.

#### `clipboard.offer`

An encrypted, replay-protected payload on the current session, like `features.update`. The outer
message has `kind`, `sessionId`, a unique `messageId`, `nonce` and `ciphertext`. The plaintext is
UTF-8 JSON of at most 40,960 bytes:

```json
{
  "version": 1,
  "offerId": "5b1f3a5e-7d0c-4f6e-9a51-0c2f6f7d1e0b",
  "createdAt": 1786550000000,
  "sensitive": false,
  "items": [
    { "index": 0, "kind": "image", "mime": "image/png", "size": 2202009,
      "sha256": "base64 of 32 bytes" },
    { "index": 1, "kind": "file", "mime": "video/mp4", "name": "video.mp4", "size": 356515840 }
  ]
}
```

| Field | Rule |
| --- | --- |
| `version` | `1` |
| `offerId` | UUID, chosen by the sender, unique per offer |
| `createdAt` | Unix milliseconds, non-negative integer |
| `sensitive` | optional boolean; receivers set Android's `EXTRA_IS_SENSITIVE` when true |
| `items` | 1 to 100 entries; `index` is the position, 0 to n-1 in order |
| `kind` | `text`, `html`, `image` or `file` |
| `mime` | 1 to 255 characters, `type/subtype`, no control characters |
| `name` | files only, 1 to 255 characters; receivers keep only the last path component |
| `size` | bytes, integer from 0 to 10 GiB |
| `sha256` | optional base64 SHA-256 of the item; required when `inline` is present |
| `inline` | optional base64 of the whole item; decoded length equals `size` and matches `sha256`. All inline items in one offer total at most 16 KiB decoded, so the frame stays well under 65,536 bytes |

An offer is either text (one `text` item, optionally followed by one `html` item that is the same
clip's HTML representation) or one or more `image`/`file` items. Mixed offers, an `html` item
without `text`, unknown kinds, duplicate offer IDs, out-of-range values and oversized payloads are
rejected. As with quick actions, a malformed or undecryptable offer is ignored without closing the
session. The receiver replies `clipboard.ack` with the offer's outer `messageId` once it has put
the offer on its clipboard, or `clipboard.rejected` (followed by `features.update`) when Clipboard
or "Copy images and files" is off locally.

A new offer, or any clipboard text, supersedes the previous offer in both directions. The receiver
cancels transfers still running for the old offer and deletes its cached items, except items it
already handed to an app (a pasted file in a draft message must stay readable; those age out with
the cache rules below). The sender stops serving the old offer.

#### `clipboard.fetch` and `clipboard.error`

When an app pastes an item that is not cached yet, the receiver asks for it:

```json
{ "version": 1, "offerId": "5b1f3a5e-...", "index": 1, "transferId": "c0ffee00-..." }
```

`clipboard.fetch` is encrypted; the receiver chooses `transferId` (a UUID) and also repeats it in
the outer message. The sender answers with one of:

- a clipboard-purpose transfer (below) using that `transferId`; or
- an encrypted `clipboard.error` with outer `transferId` and plaintext
  `{ "version": 1, "offerId", "index", "transferId", "code" }`.

| `code` | Meaning |
| --- | --- |
| `expired` | not the sender's current offer, or no such index |
| `changed` | the sender's clipboard, or the copied file, changed since the offer |
| `too_large` | the item is over a limit (for example it grew past 10 GiB) |
| `unavailable` | the sender can no longer read it (file deleted, permission gone, read error) |
| `disabled` | Clipboard or "Copy images and files" is off on the sender for this device |
| `busy` | the sender already runs 4 clipboard transfers; retry shortly |

A sender may also send `clipboard.error` during a transfer (for example the file changed while
streaming); the receiver then discards the partial data. A fetch that gets neither a transfer nor
an error within 15 seconds, or a transfer that stalls for 30 seconds, fails locally.

#### Clipboard-purpose transfers

Clipboard data reuses the chunked file transfer messages above, marked with a purpose:

1. `files.offer` (outer `transferId`) whose encrypted payload adds `"purpose": "clipboard"`,
   `offerId` and `index` to the usual `transferId`, `name`, `mimeType` and `size`. `sha256` is
   optional here: the sender may hash while it streams, so a 2 GB file is read once.
2. The receiver checks that the item belongs to its current received offer (and, for a fetch, that
   the transfer ID is the one it asked for), that the size matches, and replies `files.accept`.
   It never shows a prompt, never requires the Files feature (Clipboard governs these), and never
   writes to Downloads or the received-files folder: data goes to an app-private clipboard cache.
3. `files.chunk` messages of at most 24 KiB, sequence from 0. As for files, Android acknowledges
   with cumulative `files.chunk.ack` and the Mac keeps at most 64 chunks unacknowledged.
4. `files.complete` repeats `transferId` in the outer message and carries the SHA-256 of all
   bytes. The receiver checks the byte count, its own hash, and the offer's `sha256` when the
   offer had one, then replies `files.complete.ack`.

Either side can stop a transfer with the existing idempotent `files.cancel`. A receiver declines an
eager push it does not need (for example the item is already being fetched) the same way.

**Eager items.** Right after an offer, the sender pushes items through the same transfer path
without waiting for a fetch: in index order, while the total of pushed items stays within its
"Send right away up to" setting (5 MB, 25 MB (default) or 100 MB; "Always ask when pasting" pushes
nothing). Inline items need no push. An app that pastes during a push waits for that push instead
of starting a second transfer.

**Receivers.** The Mac writes one `NSPasteboardItem` per item with an `NSPasteboardItemDataProvider`
for the item's types (image types, `public.utf8-plain-text` and `public.html`, or `public.file-url`
for files, pointing into its cache with the original name); the provider waits for the data and
shows progress after about 300 ms, like Universal Clipboard. Android sets `ClipData` with
`content://${applicationId}.clipboard/...` URIs from a non-exported provider that grants read
access through the clipboard, and streams a lazy item into a pipe when an app opens it. Text up to
256 KiB is fetched at once and set as plain text (Android's Binder transaction limit rules out
larger `ClipData` text); longer text is offered as a `.txt` URI.

**Caches.** Each side keeps clipboard data in an app-private cache: superseded items are deleted
(unless handed to an app), nothing is kept longer than 24 hours, and the total is capped at 2 GB
(oldest first). Clear activity and Forget device delete the cache. Cached data, names and sizes
are never logged or put in diagnostics.

### Remote input (`remote_input_draft1`)

Status: **Draft.** Lets one device (the *controller*, today an Android phone) move the pointer,
click, scroll, drag, type bounded text, press a small set of named keys and drive presentations on
another (the *host*, today a Mac). The host decides everything: it is off by default, granted per
paired device, visible while it runs, and can be stopped locally at any moment.

**Negotiation.** `features.update` gains the boolean key `remote_input_draft1`. A host sets it when
the user turned remote control on and granted it to that particular device; a missing per-device
grant means `false`, even when the global switch is on. A controller sets it when its own remote
control setting is on for that device. A controller offers remote control only when both peers
advertise `true`. A missing key means `false`. Peers that cannot inject input (a phone, today)
answer an `input.session.start` with `input.session.stop`, reason `unsupported`.

**Encryption and replay.** Every message below is AES-GCM encrypted on the current authenticated
session, like `quick.request`: outer `kind`, `sessionId`, a unique `messageId`, `nonce` and
`ciphertext`. The plaintext is UTF-8 JSON of at most 2,048 bytes with `version: 1`, the
`inputSessionId` (a UUID the controller chooses in `input.session.start`) and a positive integer
`sequence` (at most 2^53-1). Receivers do **not** put input messages into the shared outer
`messageId` window: at 120 messages a second they would push every other feature's IDs out of the
256-entry cache within two seconds. Instead, each side keeps a sequence high-water mark per input
session: the controller numbers its messages 1, 2, 3, ... starting with `input.session.start`, the
host numbers its own replies the same way, and a receiver drops any message whose sequence is not
higher than the last one it accepted. TCP keeps order, so a lower or equal sequence is a replay.
An `inputSessionId` is used once: the host remembers the last 64 ended IDs and ignores a start that
reuses one. Because the key belongs to one transport session, nothing replays across sessions.
Malformed, oversized or out-of-sequence messages are dropped and counted, never answered, and never
close the transport session.

#### Session messages

| Message | Direction | Plaintext fields (besides `version`, `inputSessionId`, `sequence`) |
| --- | --- | --- |
| `input.session.start` | controller to host | `mode`: `touchpad` or `presentation` (informational; either mode may send any input) |
| `input.session.started` | host to controller | `heartbeatSeconds` (2), `idleSeconds` (6), `limits`: `{ "motion": 120, "discrete": 20, "text": 256 }` |
| `input.session.heartbeat` | controller to host | none |
| `input.session.stop` | either | `reason` (below) |

The controller sends `input.session.heartbeat` every 2 seconds while its remote control screen is
open, even without input, and gives up if `input.session.started` does not arrive within 5 seconds.
The host ends the session after 6 seconds without a valid input message or heartbeat. One session
runs at a time on a host; the host accepts at most one `input.session.start` per second from a
device. A start from the device that already controls the host replaces its session; a start from
another device is refused with `busy`.

| `reason` | Sent by | Meaning |
| --- | --- | --- |
| `user` | controller | the person tapped Stop |
| `left_screen` | controller | the remote control screen closed or the app went to the background |
| `screen_off` | controller | the controller's screen turned off |
| `local_stop` | host | stopped on the host (its Stop button or stop shortcut) |
| `timeout` | host | 6 seconds without input or a heartbeat |
| `disabled` | host | remote control is off on the host, or not granted to this device |
| `permission_required` | host | the operating system has not allowed the host to inject input (macOS Accessibility) |
| `busy` | host | another device is controlling the host |
| `invalid` | host | the start was malformed or asked for an unknown mode |
| `unsupported` | host | this peer cannot be controlled |

A host refuses a start by sending `input.session.stop` with the start's `inputSessionId`. When the
transport session closes, both sides end the input session locally (reason `disconnected`, never
sent). Ending a session releases every mouse button the host still holds and hides the laser.

#### Input messages (controller to host)

| Message | Fields | Bounds |
| --- | --- | --- |
| `input.pointer` | `dx`, `dy` | integers, -512 to 512 each, not both 0. Relative movement in host points, already scaled for the controller's pointer speed. The controller sums movement per frame (at most 60 a second) and splits a larger move into several messages |
| `input.button` | `button`: `left`, `right` or `middle`; `action`: `down` or `up` | an `up` without a matching `down` is ignored; a held button is released when the session ends |
| `input.scroll` | `dx`, `dy`, `unit`: `pixel` (precise) or `line` | integers, not both 0; pixel -1,000 to 1,000, line -10 to 10. How far the content moves, positive right and down, so with natural scrolling the content follows the fingers |
| `input.drag` | `phase`: `start`, `move` or `end`; `dx`, `dy` with `move` | `start` presses the left button where the pointer is, `move` follows the pointer bounds, `end` releases |
| `input.text` | `text` | 1 to 256 Unicode scalar values and at most 1,024 UTF-8 bytes, no control characters (Unicode category Cc; Return and Tab are keys). Typed as text, never as shortcuts. **Never logged or stored** |
| `input.key` | `key`; optional `modifiers` | see the allowlist below |
| `input.present` | `action`; `x`, `y` for the laser | see below |

**Key allowlist.** `key` is one of `left`, `right`, `up`, `down`, `return`, `escape`, `tab`,
`space`, `backspace`, `page_up`, `page_down`, `home`, `end`, `f5`, or the semantic `previous_app`
(switch to the most recent other app; macOS Command-Tab). `modifiers` may be absent, empty, or
`["shift"]`, and Shift may not combine with `previous_app`. There is no other modifier on the wire,
so a controller cannot send Command, Control or Option shortcuts. One message is one press and
release; holding a key on the controller sends repeated messages within the rate limit.

**Presentation actions.** `next` and `previous` press Page Down and Page Up, like presentation
clickers. `start` plays the slideshow from the current slide in the host's frontmost presentation
app (on macOS: Keynote Option-Command-P; PowerPoint and Google Slides in a browser Command-Return;
any other app enters full screen with Control-Command-F). `end` presses Escape. `black` presses B,
which blacks out the screen in Keynote, PowerPoint and Google Slides. `laser_on` and `laser_move`
carry `x` and `y` (integers 0 to 10,000, a fraction of the display that held the pointer when the
laser turned on, origin top left) and show a dot the host draws in its own click-through overlay;
the real pointer does not move. `laser_off` hides it. The host maps these actions itself, so the
controller never chooses key codes.

**Rate limits.** Hosts apply token buckets per session and drop and count what exceeds them:
*motion* (`input.pointer`, `input.scroll`, `input.drag` move, `laser_move`) 120 messages a second;
*discrete* (`input.button`, `input.key`, `input.text`, `input.drag` start and end, other
`input.present` actions) 20 messages a second; *control* (`input.session.heartbeat`,
`input.session.stop`) 10 messages a second. Each bucket holds one second's worth, so a short burst
passes. Controllers apply the same limits before sending.

#### Host obligations

- Ask the operating system for input injection rights only after the user turns remote control on,
  explaining why, and refuse sessions with `permission_required` while the right is missing.
- Show a visible indicator for the whole session, naming the controlling device, with a Stop control
  that does not need the controller, plus a local keyboard shortcut that the wire cannot send
  (macOS: Control-Option-Escape).
- Keep a private, local audit log of sessions and refused starts: device, start and end time, the
  end reason and the number of messages of each type. Never text, key names or positions.
- Clamp the pointer to the union of the displays, so it cannot leave every screen.

#### Security review

| Threat | Mitigations |
| --- | --- |
| A stolen or borrowed phone controls the Mac | Remote control is off by default and granted per paired device on the Mac; the phone must also be unlocked and paired (pinned identity). Every session shows the indicator with the device's name; the Mac user can stop it from the pill, the shortcut or Settings, and revoke the grant or Forget the device. The audit log shows who connected and when |
| Another device on the network injects or replays input | Only an authenticated session with the pinned identity key can send; payloads are AES-GCM encrypted with the session key. The per-session sequence rejects replays inside a session, the session key rejects them across sessions, and used `inputSessionId`s are not accepted again |
| Dangerous shortcuts (quit, force quit, lock, Spotlight, empty Trash, screenshots, clipboard) | No modifier except Shift exists on the wire; keys come from a fixed list and presentation actions are mapped by the host. Typed text goes through the text path, never as key codes, so it cannot trigger shortcuts |
| Keylogging-like misuse | The host injects input; it never captures or returns keystrokes, screen content or clipboard. The controller only receives session state. Typed text is never logged or stored on either side |
| A flood of input, or a stuck button | Token buckets drop excess input; buttons are released and the laser hidden on stop, timeout, disconnect and any policy change |
| Remote control left running unnoticed | A 6 second idle timeout without heartbeats; the controller stops when its screen closes, turns off or disconnects; the host's indicator stays on top of full-screen apps |

Remote control is as powerful as someone typing at the keyboard: with the pointer and text a
determined controller can reach any app. The allowlist keeps it from acting faster than the person
watching the indicator can react; the grant, the indicator, the local stop and the audit log are the
real protections. Hosts must not offer arbitrary shortcuts by default.

### Files (`files.v1`)

`files.offer` carries transfer ID, display filename, MIME type, unsigned byte
size, and SHA-256. `files.accept` selects a binary stream; `files.progress` is
advisory; `files.cancel` is idempotent; `files.complete` confirms the final hash.
Paths from a sender are never accepted. Implementations stream through bounded
buffers, enforce negotiated size limits, and delete or clearly mark partials.

The current JSON transport streams encrypted 24 KiB chunks rather than a raw
binary substream. An encrypted `files.offer` contains `transferId`, `name`,
`mimeType`, `size`, and the base64-encoded SHA-256. After `files.accept`, each
`files.chunk` carries the transfer ID, a monotonically increasing sequence
number, and an independently AES-GCM-encrypted chunk. An encrypted
`files.complete` repeats the transfer ID and hash; the receiver replies with
`files.complete.ack` only after byte count and hash verification and the atomic
rename of the partial file. The macOS v1 receiver saves collision-safe names in
a user-selected directory (default `~/Downloads/Bridgey`) and removes partial
files when a transfer is interrupted.

Sending several files does not add messages. The sender keeps a local queue and
offers one file at a time; the next `files.offer` follows only after the
previous transfer completes, fails, or is cancelled. Each queued file has its
own transfer ID, so cancelling or retrying one file does not affect the others.
Waiting files never reach the receiver, which therefore applies its limits and
feature policy to every file separately.

Receivers resolve name conflicts deterministically and never overwrite an
existing file. macOS uses Finder-style numbering (`photo.jpg`, `photo 2.jpg`,
`photo 3.jpg`) and also treats a name as taken while its `.bridgey-part` file
exists. Android lets `MediaStore` choose a unique name in `Download/Bridgey`,
which appends a number such as `photo (1).jpg`.

Version 1 does not resume a partial file stream. If a connection is interrupted,
the receiver deletes its pending partial file and both clients mark the transfer
as interrupted. A user-initiated retry creates a new transfer identifier,
recomputes the digest, and sends the file again from byte zero.

The Android v1 receiver writes through `MediaStore` to `Download/Bridgey` with
`IS_PENDING` set until verification, so partial files are hidden and deleted on
failure without requiring broad storage access.
Either peer can send `files.cancel` with the transfer ID. The sender stops
reading and sending chunks, while the receiver closes and deletes its partial
file. Cancellation is idempotent and leaves the authenticated session usable.
For Mac-to-Android transfers, Android sends cumulative `files.chunk.ack`
messages and macOS keeps at most 64 chunks (1.5 MiB) unacknowledged. This bounds
memory and cancellation latency without limiting throughput to one network
round trip per chunk.
An offer repeats its transfer ID in the outer session message so a receiver
whose local file policy is disabled can return `files.rejected` without
decrypting or accepting the offer. It then resends `features.update` to repair
stale UI state on the sender.

### Notifications (`notifications.send.v1`, `notifications.dismiss.v1`)

`notifications.post` carries package, application name, opaque notification ID,
title, text, timestamp, and an optional size-bounded base64 PNG icon. Content is
sensitive and must not be logged. `source=bridgey` messages are never forwarded.
`notifications.dismiss` carries the opaque notification ID back to Android when
the user dismisses its mirrored macOS notification. `notifications.remove`
carries the same ID to macOS when the original notification disappears on
Android. Both reference payloads are encrypted, replay-protected, limited to a
512-character opaque ID, and valid only for the authenticated device session.
Clients that do not recognize these messages ignore them. Future
`notification-actions.v1` messages reference the same opaque ID and a separately
scoped, 64-character action token. A `notifications.post` may contain up to four
actions with a 64-character title and `allowsReply` flag. macOS returns
`notifications.action` with the notification ID, action token, and an optional
reply of at most 4,096 characters. Android executes only tokens retained for the
still-active source notification; arbitrary `PendingIntent` data never crosses
the transport.

Per-application forwarding filters are enforced on Android before payload
construction and are intentionally local settings rather than protocol state.
The optional macOS notification history is also local-only, off by default,
bounded to 200 items and seven days, and never synchronized to a peer.

In the current JSON transport, the notification payload is AES-GCM encrypted
and contains `packageName`, `applicationName`, `notificationId`, `title`, `text`,
and the Android post time in Unix milliseconds. Android excludes Bridgey's own
foreground notification, ongoing items, group summaries, secret notifications,
and empty content before encryption. A `CATEGORY_CALL` notification may include
`callType` with one of `incoming`, `ongoing`, `screening`, or `unknown`; calls
are the only ongoing notifications forwarded. Call controls reuse the same
scoped notification action tokens and therefore exist only when the Android
phone application supplies the corresponding `PendingIntent`.

Call cards are persistent. Once Android forwards a call, the filters above never
retract it: an update of that call which is not forwardable leaves the Mac card
as it was, and an ongoing update without `CATEGORY_CALL` (dialers built on AOSP
re-post a ringing call that way) stays a call. A call notification the phone app
replaces with a new one within 1.5 s keeps the same `notificationId`, so the Mac
updates the same card. Android sends `notifications.remove` for a call only when
the call ends (the notification is gone and, for cellular calls, the phone state
is idle; an idle state must hold for 1.5 s) and then adds `"callEnded": true` to
the reference payload. macOS removes a call card at once when `callEnded` is
true; without it (an older Android release) the card stays for 2 s and survives
if the call is posted again in that time.

### Codes from messages (`sms_codes_draft1`)

Status: **Draft, edition only.** Bridgey by Round Robin shows one-time codes from text messages on
the Mac ("Code 482913 from HDFC Bank" with Copy code). The Mac finds the code; the phone marks SMS
notifications and makes Android show their text to Bridgey. Upstream peers never see any of this:
they ignore the extra fields and never receive the messages below.

**Negotiation.** `features.update` gains the boolean key `sms_codes_draft1`. Each side sets it when
notifications are on for that peer. A missing key means `false`; the `codes.*` messages go only to a
peer whose latest `features.update` showed `true`.

**Fields on `notifications.post`** (phone to Mac, inside the encrypted payload):

| Field | Type | Meaning |
| --- | --- | --- |
| `smsDefaultApp` | boolean, every notification | the notification came from the phone's default SMS app |
| `redacted` | boolean, only with `smsDefaultApp: true` | Android replaced the text with its "Sensitive notification content hidden" placeholder |

A Mac without these fields (an older phone) treats a short list of known SMS packages as SMS apps.
The Mac looks for a code only in an SMS-app notification that is not `redacted`, when its own
"Codes from messages" setting is on (off by default). It sends the text to the relay described in
`services/otp-proxy/README.md`, accepts the answer only if it appears verbatim in the message and
looks like a code (4 to 10 letters or digits, every part with a digit, an optional one or two letter
prefix such as `G-`), and otherwise, or after 2 seconds, posts the plain notification. The code
notification replaces the plain one under the same request identifier, so there is never a second
banner. Message text and codes are never logged on either side, whatever the logging settings say.

**Messages.** All are encrypted on the authenticated session like `quick.request` (outer `kind`,
`sessionId`, unique `messageId`, `nonce`, `ciphertext`; the `messageId` goes into the replay
window). The plaintext is UTF-8 JSON of at most 1,024 bytes with `version: 1`.

| Message | Direction | Fields | Meaning |
| --- | --- | --- | --- |
| `codes.status` | phone to Mac | `status`: `allowed`, `hidden` or `not_linked` | whether Android shows Bridgey the text of code messages; sent after each `features.update` with the key and whenever it changes |
| `codes.link_request` | Mac to phone | none | the Mac's "Link this phone to the Mac" button; the phone shows a notification that opens the link flow |
| `codes.advertise` | phone to Mac | `serviceUuid` (a random UUID per attempt) | start a Bluetooth LE advertisement of that 128-bit service UUID for 60 seconds |
| `codes.advertise_result` | Mac to phone | `serviceUuid`, `ok`; `reason` when not ok: `bluetooth_off`, `unauthorized`, `unsupported` or `failed` | the advertisement started, or why not |
| `codes.advertise_stop` | phone to Mac | `serviceUuid`, `linked` | stop advertising (the link was made, or the attempt ended) |

**Companion link.** Since Android 15, Android hides the text of notifications it thinks hold a code
from notification listeners it does not trust; an app with any Companion Device Manager association
is trusted. After `codes.advertise_result` with `ok: true`, the phone calls
`CompanionDeviceManager.associate` with a single-device `BluetoothLeDeviceFilter` for that service
UUID. Android shows its own dialog; when the person allows it, the phone reconnects its notification
listener (Android decides trust when a listener connects) and sends `codes.advertise_stop` with
`linked: true`. Nothing ever connects over Bluetooth. A Mac that receives `codes.advertise` while
notifications are off for that phone ignores it, and the phone gives up after 45 seconds. The
one-time fallback is `adb shell cmd appops set --user 0 <package> RECEIVE_SENSITIVE_NOTIFICATIONS allow`.

### Find device (`find-device.v1`)

Either connected peer can send an encrypted `find.start` payload containing an
opaque `alertId`. The receiver plays a repeating local alert until either user
stops it. An encrypted `find.stop` with the same logical alert scope stops the
local sound. The receiver answers with encrypted `find.started` or
`find.stopped`, and only that acknowledgement changes the sender's displayed
state. All messages use unique message IDs and are accepted only inside an
authenticated paired session.

Android presents a separate ongoing find-device notification with a Stop
action while its alert is active. Stopping from that action, from either app,
or disconnecting stops the local alert; find-device state is never persisted
across sessions.

### Ping (`ping.v1`)

`ping.request` is a lightweight, one-shot presence alert and is intentionally
separate from Find Device. It carries an encrypted `{ "version": 1 }` payload,
uses a unique replay-protected message ID, and causes the receiving device to
play one short system sound. Android also shows a short local toast. The
receiver returns `ping.ack` with the request message ID, so the sender reports
delivery or a bounded five-second timeout instead of leaving an indefinite
status. Ping never starts a repeating sound and has no state to restore after a
disconnect.

### Calls from Mac (`calls.v1`)

macOS sends `calls.request` only when both peers advertise the `calls` feature.
Its AES-GCM encrypted JSON payload contains a single `number` string. The
receiver accepts only 3–15 decimal digits with an optional leading `+`; spaces,
parentheses, dots, and hyphens may be present for display formatting and are
removed before use. Letters, extensions, USSD strings, and other dial commands
are rejected. Each request has a unique replay-protected message ID and Android
accepts at most one request every three seconds.

Android answers with the same message ID using `calls.started`,
`calls.confirmation_required`, or `calls.rejected`. Confirmation mode is the
default and posts a local notification whose explicit action opens the system
dialer with `ACTION_DIAL`. Direct mode is a separate local opt-in that requires
`CALL_PHONE`; the same local call-integration opt-in requests
`READ_PHONE_STATE` and `ANSWER_PHONE_CALLS` to identify call state and execute
Answer, Decline, and Hang Up commands sent through authenticated notification
action tokens. Bridgey uses the platform telecom service and never starts a
number the platform identifies as an emergency number. It does not request
contacts or call-log access. Local feature policy is checked again immediately
before any side effect. Number content is not logged.

## Draft: folders, places and settings sync

**Draft, edition only until accepted upstream.** Bridgey by Round Robin implements
this first; upstream clients never receive these messages. Implemented so far
(Files 2.0, first slice): folders Mac to phone and places on the phone. Phone to
Mac and settings sync are not built yet; clients do not advertise
`settings_sync_draft1`. The full design, user
experience and reasons are in [folders-and-settings-sync.md](folders-and-settings-sync.md).

### Negotiation

Three keys join the encrypted `features.update` map. A missing key is false, and
a client sends the messages below only while the peer's latest map shows the key
true (all three count as false until the first map of a session arrives):

- `folders`: folder transfers; mirrors `files` (no separate switch); Android 10+.
- `places`: the receiver serves `places.*`; mirrors `files`.
- `settings_sync`: settings sync; global and per-device switches, on by default.

Until upstream accepts this draft, the edition advertises `folders_draft1`,
`places_draft1` and `settings_sync_draft1` instead, so a different upstream design
under the final keys can never be confused with this one.

### Common rules

All messages are AES-GCM payloads in the current transport (`kind`, `sessionId`,
unique `messageId`, `nonce`, `ciphertext`), accepted only in the connected session
after the replay check. `folders.offer`, `folders.rejected`, `folders.cancel` and
`folders.cancel.ack` repeat the folder transfer ID in the outer `transferId`; a
receiver with Files off answers an outer-only `folders.rejected` without decrypting
and resends `features.update`. Folder and places payloads carry `version: 1`,
settings payloads `schema: 1`. Plaintext is at most 8 KiB, except
`folders.manifest`, `folders.complete`, `folders.result`, `places.listed` and
`places.children` (32 KiB) and `settings.snapshot`/`settings.update` (16 KiB).
A payload that fails decryption closes the session as today; one that decrypts
but fails validation is answered with an error and leaves the session up. IDs are
lowercase UUIDs and are never reused.

### Places

Places are folders on the receiver that its user granted (on Android, persisted
Storage Access Framework tree grants) plus its default received-files folder
(`placeId` `default`). `places.list` always answers with the receiver's folder
destination mode; places, browsing and folder creation are served only in
`sender_picks`. Senders send `places.list` before every folder.

- `places.list` `{version, requestId}` answers `places.listed` `{version, requestId,
  mode, places[], fixedLabel}`: `mode` is `sender_picks`, `receiver_asks` or
  `fixed`; `places` (empty unless `sender_picks`, at most 17) holds `placeId`
  (`default` or 22-character base64url random ID, never a URI or path), `label`
  (64 characters), `available` (bool), `freeBytes` (integer or null);
  `fixedLabel` is the display path of the default folder in `fixed` mode.
- `places.browse` `{version, requestId, placeId, path, cursor}` answers
  `places.children` `{version, requestId, placeId, path, folders[], fileCount,
  folderCount, nextCursor}`: folder names only, at most 500 per page, hidden
  folders excluded. Never file names, sizes, dates or contents.
- `places.create_folder` `{version, requestId, placeId, path, name}` answers
  `places.folder_created` `{version, requestId, placeId, path, name}`; a repeated
  `requestId` returns the first answer.
- Failures answer `places.error` `{version, requestId, code}`. At most 4 requests
  in flight and 20 per 10 seconds; senders time out after 8 seconds.

### Folder transfer

1. The sender sends `folders.offer` `{version, folderTransferId, rootName,
   fileCount, folderCount, totalSize, pageCount, manifestSha256, destination?,
   resume, skipped?}`, then `pageCount` `folders.manifest` pages `{version,
   folderTransferId, page, entries[]}` in order. `destination` `{placeId, path}`
   is present only when the sender picked it. Entries are `{type: "dir", path}`
   or `{type: "file", path, size, sha256, modified?}` in depth-first pre-order,
   siblings by UTF-8 byte order; each entry's index is its position across pages.
   `manifestSha256` is SHA-256 over `"folder-manifest-v1\n" + rootName + "\n"`
   followed, per entry, by `type \0 path \0 size \0 sha256 \n` (`0` and empty
   for folders). An empty folder has no entries: `pageCount` 0 and no pages
   (edition call; every other offer has 1 to 128 pages). `skipped` counts what the
   sender left out (`links`, `hidden`, `system`, `unreadable`, `tooLarge`,
   `notDownloaded`, `tooLong`, `other`); unknown counters are ignored.
2. Within 15 seconds of the last page the receiver answers `folders.accept`,
   `folders.waiting` `{version, folderTransferId, reason, timeoutSeconds}`
   (`destination` or `conflict`, while its user answers), `folders.conflict` or
   `folders.rejected` `{version, folderTransferId, code, entry?, neededBytes?,
   freeBytes?}`. The receiver's own mode decides; an offer without `destination`
   reaching a receiver in `sender_picks` is handled as `receiver_asks`.
3. When the target exists, the receiver applies its preset choice if it has one.
   If it asks and the sender picked the destination, the receiver
   sends `folders.conflict` `{version, folderTransferId, existing, clashingFiles,
   clashingFolders, newFolderName, choices[], timeoutSeconds}` and the sender
   answers `folders.resolve` `{version, folderTransferId, choice}` with `merge`
   (clashing files kept as `name (1).ext`), `replace` (clashing files replaced
   after verification), `new_folder` (`Name (1)`) or `cancel`. Otherwise the
   receiver asks its own user. A `replace` answered by the sender asks the
   receiver's user again unless that device allows other devices to replace
   files (a local switch, off by default); meanwhile the receiver sends
   `folders.waiting` with reason `conflict`. Questions time out after 180 seconds and cancel;
   nothing is written and nothing is overwritten. A folder is never replaced by a
   file or the reverse; such clashes keep both.
4. `folders.accept` `{version, folderTransferId, rootName, destinationLabel,
   choice, completedBitmap}` gives the final root name and display path.
5. Each file then uses the existing `files.offer`, `files.chunk` and
   `files.complete` messages. The offer adds `folderTransferId`, `entry` (strictly
   increasing since accept) and `path`, which must match the manifest entry
   (`name`, `size` and `sha256` too). Inside a folder transfer the sender does not
   wait for `files.accept` or for a file's last chunk acknowledgement; at most 64
   chunks are unacknowledged across the folder and at most 32 files await
   `files.complete.ack`. Chunks of different files never interleave. A file the
   receiver cannot save is answered `folders.entry_failed` `{version,
   folderTransferId, entry, transferId, code}`, its remaining chunks are dropped,
   and the transfer goes on; 50 failures cancel it. The receiver creates folders
   in manifest order as it reaches them and the remaining empty folders at the end.
   Outside a folder transfer, sender paths are still never accepted.
6. The sender ends with `folders.complete` `{version, folderTransferId, sentFiles,
   failedCount, failed[]}`; the receiver answers `folders.result` `{version,
   folderTransferId, status, savedFiles, savedBytes, createdFolders, renamedFiles,
   replacedFiles, failedCount, failed[]}` with `status` `complete` or `incomplete`
   (`failed` lists at most 500 `{entry, code}`).

Either side may send `folders.cancel` `{version, folderTransferId, reason, code?}`
(`user`, `timeout`, `policy` or `error`), answered by outer-only
`folders.cancel.ack`. Completed files stay; the file in progress is deleted.
One folder transfer is active per direction per session.

**Resume.** Both sides keep a journal per transfer until 24 hours after its last
progress, and the sender resumes by itself whenever the devices reconnect in that
window (Rahul, 2026-10-26). After a
reconnect the sender resends the offer with the same `folderTransferId`,
`resume: true` and the manifest; a receiver whose journal matches peer and
`manifestSha256` answers `folders.accept` with its stored choice and
`completedBitmap` (base64, bit `i` set when entry `i` is done, least significant
bit first), else `folders.rejected` `resume_unavailable`. Finished files are not
sent again; an interrupted file restarts from byte 0 under a new transfer ID.

**Names and limits.** Every new name (root, path components, created folders) is
a portable name: NFC; U+0000 to U+001F, U+007F and `" * / : < > ? \ |` replaced
by `_`; no leading spaces and no trailing spaces or dots; never empty; Windows
device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`) get `_`;
names ending `.bridgey-part` get `_`; at most 220 UTF-8 bytes. Senders convert,
receivers reject anything that is not already portable. Siblings may not clash
after NFC and lowercasing. Paths: at most 32 components and 1,024 bytes, no
empty, `.` or `..` components. Per transfer: 10,000 files, 2,000 folders, files up
to 10 GiB, 1 TiB in all, manifest at most 128 pages of 256 entries and 4 MiB.

**Error codes:** `unsupported`, `unsupported_schema`, `policy`, `busy`,
`invalid_message`, `invalid_manifest`, `limit_exceeded`, `insufficient_space`,
`place_unavailable`, `not_found`, `exists`, `invalid_name`, `timeout`,
`declined`, `io_error`, `verification_failed`, `source_changed`, `unreadable`,
`resume_unavailable`, `too_many_failures`, `cancelled`.

### Settings sync

When both peers report `settings_sync`, each sends `settings.snapshot` `{schema,
maxSchema, records}`; local edits follow as `settings.update` `{schema, records}`.
A record is `{value, changedAt, version, changedBy}` (bool or string value, Unix
ms, counter, device ID or empty). Schema 1 keys: `files.folder_destination`,
`files.folder_conflict` (`ask`, `merge`, `replace`, `new_folder`),
`clipboard.automatic`, `pair.clipboard.automatic` (scoped to the two devices),
`activity.previews`, `display.reduce_motion`. Device names, folders, places,
feature switches and update channels never sync.

A local edit sets `changedAt` to the larger of now and the current `changedAt`
plus one, and increments `version`. The higher `changedAt` wins, then the higher
`version`, then the larger `changedBy`. A winning remote record is stored
unchanged and never re-sent as a new edit, so updates cannot ping-pong. Receivers
answer `settings.ack` `{schema, ackOf, applied[], kept[]}` and send their newer
records for `kept` keys unless already sent to that peer; unknown keys and invalid records are skipped one by
one; an unsupported schema is answered `settings.error` `{schema, code, maxSchema}`.

## Draft: phone files, media and folders both ways

**Draft, edition only until accepted upstream** (Files 2.0, second slice). It builds
on the folders and places draft above and changes none of its messages; it adds
optional fields and new kinds that a peer sends only after the matching key below.
Design, user experience and performance budgets: [files-browse.md](files-browse.md).

### Negotiation

Two more keys in the encrypted `features.update` map, false when missing and
until the first map of a session arrives:

- `files_browse_draft1`: this device serves the browse requests below
  (`places.list` with `purpose: "browse"`, `places.files`, `media.*`,
  `places.download`) and accepts upload offers (`folders.offer` with `into`).
  On Android it is true when Files is on for the peer, the phone runs Android 10
  or newer, and its local switch "Let other devices browse this phone" is on (on by
  default). Macs advertise it false; they browse but serve nothing.
- `folders_receive_draft1`: this device accepts `folders.offer` from the peer
  (Files on for it). The first slice's Mac advertised `folders_draft1` while it
  only sent folders, so phones look for this key before sending a folder to a Mac.
  Phones advertise both keys; a Mac sending to a phone still checks `folders_draft1`.

Receivers refuse every message below when they did not advertise the key that
covers it (`places.error` `unsupported` for requests, `folders.rejected`
`unsupported` for offers).

### Common rules

The rules of the folders draft apply: AES-GCM payloads in the current transport,
connected session only, replay check, `version: 1`, unknown fields ignored, IDs are
lowercase UUIDs that are never reused, a payload that decrypts but fails
validation is answered and leaves the session up. Plaintext limits: requests
8 KiB; `places.files_page` and `media.page` 32 KiB; `media.thumbnails_batch`,
`media.preview_part` and `media.range_part` 44 KiB (45,056 bytes: after AES-GCM
and base64 the frame stays under 61 KB, inside the 65,536-byte limit). Every
request is answered within 8 seconds (the first part for streamed answers) or
fails on the asking side with `timeout`. Failures answer `places.error`
`{version, requestId, code}`.

Two lanes per session, each with its own budget; going over answers `busy`:

| Lane | Requests | Budget |
| --- | --- | --- |
| Browse | `places.list` (browse), `places.files`, `media.list`, `places.download` | 4 in flight, 40 per 10 s |
| Media (low priority) | `media.thumbnails`, `media.preview`, `media.range` | 4 active, 60 per 10 s |

Media lane answers are low priority: the serving device sends them only while no
file chunk, acknowledgement or control message waits in its send queue, so
thumbnails never slow a transfer. `replaces` (a `requestId` of the same session)
cancels an earlier media request when the new one is accepted; `media.cancel`
`{version, requestId}` cancels one without a new request and is not answered.
Parts already on the wire may still arrive and are dropped by the asker.

**Privacy.** Nothing here returns content URIs or file system paths. Names,
sizes, dates and thumbnails stay inside the encrypted session; neither side logs
them unless its own Privacy › Logging switch for file names allows it.

### References

A `ref` addresses one item on the serving device, in one of two forms:

- `{"placeId", "path", "name"}`: an item in a place. `path` follows the existing-path
  rules (5.3 of the folders design) and `name` is one existing component (1 to 255
  bytes, no `/`, NUL or control characters, never `.` or `..`), resolved by exact
  name. Hidden items (names starting with ".") and part files are never resolved.
- `{"mediaId": "1234"}`: a photo or video from the phone's media library (the
  decimal MediaStore `_ID`, at most 20 digits), only while the phone has photo
  access. Never a URI.

### Places for browsing

`places.list` `{version, requestId, purpose: "browse"}` answers `places.listed`
as before, plus: `places` lists every place whatever the folder destination mode
(`default`, then granted places by label, with `available`), `writable` (bool: the
phone's "Allow other devices to change files here" switch), `media` (`full`,
`partial` or `none`: photo and video access) and `documents` (bool: at least one
place is indexed for recent documents). Without `purpose` the request is unchanged.

### Listing a folder

`places.files` `{version, requestId, placeId, path, cursor, sort, descending}`:
`sort` is `name` (default), `modified`, `size` or `kind`; `cursor` is the opaque
string from the previous page. Answer `places.files_page`
`{version, requestId, placeId, path, entries[], folderCount, fileCount,
nextCursor, writable}`. An entry is `{name, dir, size, modified, mimeType, thumb}`:
`size` is null for folders, `modified` Unix ms or null, `mimeType` null for
folders, `thumb` true when `media.thumbnails` can make a thumbnail (images, videos,
and documents whose provider supports thumbnails). Folders first, then files, each
in sort order (names compare case-insensitively, then exactly). Hidden items and
part files are neither listed nor counted. At most 200 entries per page and
32 KiB. Served in every folder destination mode. Errors: `not_found`,
`place_unavailable`, `policy`.

### Media library and recent documents

`media.list` `{version, requestId, kind, cursor, limit}`: `kind` is `media`
(photos and videos, newest first by date taken, else date added), `files` (recent
documents: files in indexed places that are not images or videos, newest first by
modified) or `recent` (both, newest first). `limit` 1 to 200, default 100.

Answer `media.page` `{version, requestId, kind, items[], nextCursor, access,
indexing}`. An item is `{ref, name, size, modified, mimeType, width, height,
durationMs, thumb, location}`; `width`, `height` and `durationMs` are null when
unknown; `location` is a display path such as "Camera" or "Documents/Invoices" (at
most 128 characters). `access` is the photo access (`full`, `partial`, `none`;
with `none`, `kind: media` returns no items). `indexing` is true while the phone
refreshes its document index; the asker may list again later. The document index
covers granted places only (Android shared storage has no other way to see
documents without broad permission).

Askers cache by device ID, `ref`, `modified` and `size`: the same four always
mean the same bytes.

### Thumbnails

`media.thumbnails` `{version, requestId, items[], size, replaces}`: 1 to 64 items
`{key, ref}`, `key` 1 to 64 characters of `[A-Za-z0-9_-]` chosen by the asker;
`size` is the longest edge in pixels, 64 to 512 (default 256). The phone answers
in the order asked (the asker puts visible items first) with one or more
`media.thumbnails_batch` `{version, requestId, thumbs[], missing[], done}`. A thumb is
`{key, mimeType, width, height, tint, data}`: `data` is base64 image bytes, at most
24 KiB per thumbnail (WebP from Android 11, JPEG before; quality drops until it
fits), `tint` the average colour as `#rrggbb` for placeholders. `missing` lists
keys without a thumbnail (not found, unsupported type, decoding failed). As many
thumbnails as fit go into each batch; the last batch has `done: true`.

### Previews and ranges

`media.preview` `{version, requestId, ref, size, replaces}`: `size` 512 to 2048
(longest edge). For videos the poster frame. Answer: consecutive
`media.preview_part` `{version, requestId, index, count, mimeType, width, height,
tint, data}`, each with at most 32 KiB of image data; the whole preview is at most
1 MiB (quality drops until it fits). Errors: `not_found`, `unsupported`.

`media.range` `{version, requestId, ref, offset, length, replaces}`: bytes of a
file (not a folder), `length` 1 to 4 MiB. Answer: consecutive
`media.range_part` `{version, requestId, offset, fileSize, modified, data, last}`
from `offset`, each with at most 32 KiB; `last` is true on the final part (end of
the range or of the file). `fileSize` and `modified` describe the whole file so
the asker notices a change. Ranges are previews (a hover prefetch of a video's
first seconds, streamed playback): they carry no hash, so a saved copy always goes
through `places.download`.

### Downloads

`places.download` `{version, requestId, items[]}`: 1 to 100 refs (files and
folders; a folder brings its subtree, hidden and system files skipped and
counted). Answer within 8 seconds `places.download_started` `{version,
requestId, folderTransferId, rootName, fileCount, folderCount, totalSize}`, or
`places.error` (`not_found`, `place_unavailable`, `limit_exceeded`, `busy`,
`policy`). The phone then sends a `folders.offer` with that `folderTransferId`,
`into: true` and `downloadRequestId`, and the transfer runs as any folder
transfer (manifest, verified files, journal, resume). Downloads wait their turn
behind other folders in the same direction, in request order.

### Folder offers: `into`, downloads and uploads

`folders.offer` gains two optional fields:

- `into` (bool, default false): the entries land directly in the destination
  folder; no root folder is created. `rootName` is still a portable name, used for
  display and the digest only (the first top-level item's name). A top-level entry
  whose name clashes with an existing item (compared without case) is saved as a
  copy, "Name (1)" or "name (1).ext"; nothing is merged, replaced or asked.
  `folders.accept` answers `choice: none`.
- `downloadRequestId` (UUID): the offer answers a `places.download` of the
  receiver. The receiver lands it where that request said, without asking. From a
  phone to a Mac, `into` is valid only with a pending (or journaled) download
  request; anything else is rejected `policy`. A resumed download repeats it.

Uploads (Mac to phone, from a browser): `into: true` with `destination` required.
The phone rejects them with `read_only` while "Allow other devices to change files
here" is off, and `policy` while browsing is off. Ordinary folders sent from the
Mac's send sheet are unchanged (the phone's folder destination mode governs them).

Folders from the phone to the Mac (no `into`): phones send no `destination` (a Mac
serves no places). The Mac's own setting decides: "Always save to Received files"
(`fixed`, the default) or "Ask on this Mac each time" (`receiver_asks`, a Save
panel). "When a folder already exists" works as on the phone; the Mac asks its own
user and answers `folders.waiting` meanwhile. Same timeouts, journal and resume.

New error code: `read_only` (writing into the phone's places needs its "Allow
other devices to change files here" switch).

## Compatibility

Adding optional fields or message types is backward compatible. Changing field
meaning, authentication, or required behavior requires a new capability or
major version. JSON is a codec behind the envelope model; a future protobuf
codec must preserve IDs, types, correlation, and negotiated semantics.
