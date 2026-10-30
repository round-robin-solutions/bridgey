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
`sms_codes_draft1`, `mac_actions_draft1`, `links_open_draft1`, `focus_sync_draft1`, `camera_draft1`, `updates_draft1`,
`screen_draft1`, `connect_draft1`, `files_fast_draft1`)
are optional booleans described in their own sections; a missing draft key means `false`.

## Pairing flow

Pairing runs only after a user selects a discovered peer. What the native clients
do (protocol 2, v0.10):

1. The initiator creates an ephemeral P-256 key pair and sends `pairing.offer`
   with `protocolVersion: 2`. For a first pairing (the target is not already
   trusted) the offer carries `commitment`, the base64 SHA-256 of
   `"bridgey-commit-v2", sessionId, publicKey` (each field length-prefixed), and
   no `publicKey`. A reconnect to a trusted device sends `publicKey` instead,
   because that device's pinned identity signature authenticates it.
2. The responder answers with its own ephemeral key and `protocolVersion: 2`
   before it has seen the initiator's key.
3. After a commitment, the initiator sends `pairing.reveal` with its `publicKey`.
   The responder checks it against the commitment and fails the pairing on a
   mismatch.
4. Both derive the session key with ECDH and HKDF-SHA-256 (salt SHA-256 of the
   session ID, info `bridgey-pairing-v1`). The six-digit code of a protocol 2
   first pairing comes from its own label, `bridgey-sas-v2` over the initiator's
   and the responder's ephemeral keys, not from session key bytes. It is never
   sent over the network.
5. Each user explicitly confirms; peers exchange `pairing.confirm` with an HMAC
   proof and an identity signature over the session ID, device IDs and both
   ephemeral keys. Trust is stored only after both confirmations verify.

Because neither side can choose its ephemeral key after seeing the other's, an
active attacker in the middle cannot search for keys that make the two codes
match; each attempt is a one in a million guess that the user sees as a new
prompt. Pairing frames are only taken in order (the dialled end takes the offer
and the reveal, the dialler the answer), so an answer cannot stand in for the
reveal. Offers from other devices are limited to three a minute.

When both ends sent `protocolVersion: 2`, every frame after pairing carries
`tag`: base64 HMAC-SHA-256, under HMAC(session key, `bridgey-envelope-v2`), of the
sender's device ID and every envelope field (length-prefixed, an absent or empty
field written as length 0xFFFFFFFF). A frame with a missing or wrong tag is dropped, as
is any non-pairing frame on a session that has not authenticated; 16 dropped
frames close the connection. A device that once authenticated with protocol 2 is
pinned to it, so a later session without tags is refused. Shared vectors are in
`protocol/test-vectors/crypto-v1.properties` (from
`protocol/tools/crypto_v2_vectors.py`).

Compatibility: a protocol 1 client (0.9 and earlier, and upstream Bridgey)
still reconnects to a trusted protocol 2 client until the pair has once
connected on protocol 2. A first pairing needs protocol 2 on both ends, in both
directions: a protocol 2 client neither sends nor accepts an offer without a
commitment from a device it does not trust, because a man in the middle could
grind the protocol 1 leg to the code it saw on the other. Update both apps to
pair. Each answered offer from an untrusted device counts toward the three a
minute, whether or not it reveals.

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
round trip per chunk. Between peers with `files_fast_draft1`, chunks are binary
frames of up to 1 MiB in a byte window instead; see
[Fast transfers](#draft-fast-transfers-and-the-speed-test-files_fast_draft1).
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
The notification ID names the phone app's notification, not the call: dialers post
every call under the same notification, so consecutive calls arrive with the same
ID. macOS treats a post with another caller for a card that is waiting out those
2 s as a new call.

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

### Mac actions (`mac_actions_draft1`)

Status: **Draft, edition only.** A paired phone asks the Mac to lock its screen, sleep, start the
screen saver, change the volume, open an app or run a Shortcut. The phone never sends a command:
it picks one entry from a list the Mac published for it, and the Mac maps that entry to a fixed,
local operation. There is no shell, no argument and no free-form text on the wire.
Design and macOS research: [automation.md](automation.md).

**Negotiation.** `features.update` gains the boolean key `mac_actions_draft1`. The Mac sets it when
Mac actions is on for this Mac **and** granted to that phone (off by default; a missing grant is
`false`, like remote control). The phone sets it when its own Mac actions setting is on for that Mac.
`actions.*` messages go only to a peer whose latest map shows `true`; a peer receiving them while
its own key is `false` drops them (the Mac answers `actions.run` with `refused`/`not_allowed`).

**Messages.** All are AES-GCM encrypted on the current session like `quick.request` (outer `kind`,
`sessionId`, unique `messageId` in the replay window, `nonce`, `ciphertext`). The plaintext is UTF-8
JSON with `version: 1`: at most 8 KiB for `actions.catalog`, 1 KiB for the others.

| Message | Direction | Fields | Meaning |
| --- | --- | --- | --- |
| `actions.catalog` | Mac to phone | `actions` (array, at most 64), optional `volume` | what this phone may run now; sent after each `features.update` that shows the key on both sides and whenever the list, a switch, the grant or a permission changes. It replaces the previous list |
| `actions.run` | phone to Mac | `requestId` (UUID), `action` (an `id` from the catalog), `sequence`; `value` only with `volume_set` | run one entry. Not retried automatically |
| `actions.result` | Mac to phone | `requestId`, `action`, `status`: `done` or `refused`; `reason` when refused; optional `volume` | the outcome. One result per run |

A catalog entry is `{ "id": ..., "title": ... }`, with optional `blocked: "permission_required"`
when the Mac knows it cannot run the entry until the person allows something on the Mac
(Accessibility for Lock). Identifiers:

| `id` | Mac operation |
| --- | --- |
| `lock` | lock the screen (the system Lock Screen shortcut, Control-Command-Q, posted with Accessibility access) |
| `sleep` | put the Mac to sleep (IOKit `IOPMSleepSystem`) |
| `screensaver` | start the screen saver (open `ScreenSaverEngine.app`) |
| `volume_up`, `volume_down` | default output volume up or down one step (1/16, like the volume keys) |
| `volume_mute` | toggle mute on the default output |
| `volume_set` | `value`: integer 0 to 100 |
| `app:<bundle id>` | open that app with `NSWorkspace`; the bundle id must be on this Mac's list of apps for phones (`[A-Za-z0-9.-]`, at most 155 characters) |
| `shortcut:<uuid>` | run that macOS Shortcut with `/usr/bin/shortcuts run <name>` and no input; the UUID is a local handle the Mac made when the person added it, so the phone never sends a Shortcut name |

`title` is shown to the person: the app or Shortcut name (1 to 64 characters, no control
characters). Phones show their own translated titles for the fixed identifiers. `volume`, present
when volume is allowed and the default output has a settable volume, is `{ "level": 0..100,
"muted": bool }`; a result for a volume action carries the new value.

**Checks on the Mac, in order, before anything runs:** the session is the phone's current
authenticated session; the payload decodes, its `sequence` is above the session's high-water mark
for `actions` and `requestId` is a UUID; `mac_actions_draft1` is on and granted for that phone; the
identifier is in the catalog this Mac would send that phone now (unknown identifiers, apps and
Shortcuts that are no longer listed are `not_allowed`); `value` is present and valid only for
`volume_set`; the rate limit allows it. The Mac then checks the operating system permission and
runs the operation.

| `reason` | Meaning |
| --- | --- |
| `not_allowed` | Mac actions is off, not granted to this phone, this action is switched off, or the identifier is not in the list |
| `invalid` | a missing or out-of-range `value`, or a malformed request |
| `rate_limited` | over the limit below |
| `busy` | a Shortcut is still running (one at a time per Mac) |
| `permission_required` | macOS has not allowed it (Accessibility for Lock) |
| `unavailable` | the app is no longer installed, the Shortcut was deleted, or there is no output device with a volume |
| `failed` | the operation ran and reported an error, or a Shortcut ran longer than 60 seconds and was stopped |

**Rate limits** (per phone, token buckets, refused rather than queued): volume actions 10 at once,
then 5 a second; every other action 3 at once, then one every 2 seconds. A phone waits 10 seconds
for a result (70 seconds for a Shortcut), then reports "not confirmed".

**Audit.** The Mac keeps a private, local log of every run and refusal: phone, time, the
identifier and title, the outcome and reason. Never `value`. It is owner-only (`0600`), 30 days,
at most 500 entries, shown and cleared in Settings, like the remote control session log.

### Open links right away (`links_open_draft1`)

Status: **Draft, edition only.** "Open on Mac" from the phone's share sheet. The Mac sets
`links_open_draft1` in `features.update` when Web links is on for that phone; it means the Mac
understands the `open` action. The phone then sends `quick.request` with `feature: "links"`,
`action: "open"` and the link as `value` (same validation as `offer`); without the key it sends
`offer`. If the Mac's own "Open links from phones right away" setting is on (off by default), it
opens the link in the default browser and answers `quick.result` with `accepted: true` and
`opened: true`, at most one link per phone every 3 seconds. Otherwise the link is queued exactly
like `offer` (`opened: false`, declined while another link waits). Older phones ignore `opened`.

### Connection health (no wire change)

Both apps show, per paired device, how the connection is doing: the route class (same local
network, private network such as Tailscale's 100.64.0.0/10, or another network), who dialled, the
heartbeat round trip, when the link came up, the last disconnect reason, reconnect attempts since
local midnight and whether discovery sees the device now; the phone adds whether battery
optimisation is off. The round trip is measured from the existing `heartbeat.ping` and its
`heartbeat.pong`, which echoes the ping's `messageId`, so nothing new goes on the wire. The view and
its part of the diagnostics report hold no addresses, names or content: the first eight characters
of the device ID, tokens and numbers only.

### Focus and Do Not Disturb sync (`focus_sync_draft1`)

Status: **Draft, edition only.** Mirrors "quiet mode" between a phone and a Mac, each direction opt-in
on the device that changes (off by default). What each platform can read and set without private
interfaces is in [automation.md](automation.md).

**Negotiation.** `features.update` gains `focus_sync_draft1`: the peer understands `focus.state`. A
peer sends `focus.state` only when its own "share" switch is on for that peer and the peer's key is
`true`; the receiver applies it only when its own "follow" switch is on.

**Message.** `focus.state`, either direction, encrypted like `codes.*` (`messageId` in the replay
window), plaintext at most 256 bytes: `{ "version": 1, "active": bool }`. Sent once after each
`features.update` that shows the key on both sides, and whenever the state changes. A phone reports
Do Not Disturb as active for any interruption filter other than "all"; a Mac reports whether a Focus
is on. A receiver that follows sets its own quiet mode to match and does not send the resulting
change back for 10 seconds, so two devices following each other cannot loop.

### Phone camera to Mac (`camera_draft1`)

Status: **Draft, edition only.** "Take photo with OnePlus 11" on the Mac opens a full-screen camera on
the phone; the photo comes back as an ordinary file.

**Negotiation.** The phone sets `camera_draft1` when its "Take photos for the Mac" switch is on for
that Mac (on by default; Android asks for the camera permission the first time it is used). The
Mac sets it when it can ask (always, in builds that have the feature).

**Messages.** Encrypted like `codes.*`, plaintext at most 512 bytes, `version: 1`.

| Message | Direction | Fields | Meaning |
| --- | --- | --- | --- |
| `camera.request` | Mac to phone | `requestId` (UUID), `mode`: `photo` | ask for one photo. One open request per Mac; at most one request every 3 seconds; it expires after 2 minutes |
| `camera.status` | phone to Mac | `requestId`, `status` | `opened` (the camera is on screen), `locked` (the phone is locked: it shows "Unlock your phone to take the photo" and opens the camera after unlocking), `permission_required`, `cancelled`, `busy`, `disabled`, `sending`, `failed` |

The phone never opens the camera while it is locked or without the person tapping (Android does not
let an app start an activity from the background). The photo is sent with `files.v1` as a JPEG; its
encrypted `files.offer` payload adds `cameraRequestId`, which the Mac matches to its open request.
The Mac saves it in the received files folder like any file and, if its "Copy photos to the
clipboard" setting is on (off by default), also puts the image on the clipboard. Older Macs ignore
the field and simply receive a file.

### Update all (`updates_draft1`)

Status: **Draft, edition only.** Each device tells the devices connected to it which version it
runs, on which channel, and where its own update stands; **Update all** on one device then asks each
connected device to update itself, and updates the device you are using last. Macs are not paired
to each other, so "all" means every device connected to the one you are using: from a phone that is
every connected Mac, from a Mac every connected phone.

**Negotiation.** `features.update` gains `updates_draft1`: the device sends `updates.status` and
understands `updates.start`. Edition builds that have the feature always advertise it; whether this
device lets others start its update is a field of the status, not the key. Upstream peers and older
edition builds never advertise it, never receive these messages, and are listed as "Update this one
by hand".

**Messages.** Encrypted like `codes.*` (`messageId` in the replay window), `version: 1`. A malformed
message is dropped and the session stays.

| Message | Direction | Max plaintext | Fields |
| --- | --- | --- | --- |
| `updates.status` | either | 1,024 B | `platform` (`android` \| `macos`), `edition` (1 to 32 UTF-8 bytes, `rr` for this edition), `app` (installed version name, 1 to 64 UTF-8 bytes), `build` (installed build number, 1 to 2^53-1), `channel` (`stable` \| `beta` \| `nightly`), `state`, optional `target` (version on offer, 1 to 64 UTF-8 bytes) and `targetBuild` (1 to 2^53-1), optional `progress` (0 to 100, with `downloading`), optional `reason`, `remoteStart` (boolean), `checkedAt` (Unix ms of the last successful check, 0 for never), optional `auto` (boolean, default false), optional `busy` (string) |
| `updates.start` | either | 512 B | `requestId` (UUID), optional `retry` (boolean, default false), optional `auto` (boolean, default false) |
| `updates.result` | either | 512 B | `requestId` (echoes the start), `status` (`accepted` \| `refused`), `reason` with `refused` |

`state` is one of:

| State | Meaning | `target` | `reason` |
| --- | --- | --- | --- |
| `current` | Nothing newer was found on its channel at `checkedAt` | no | no |
| `checking` | Checking its channel feed now | no | no |
| `available` | A newer build is on offer | yes | no |
| `downloading` | Downloading it; `progress` when the size is known | yes | no |
| `ready` | Downloaded and verified, waiting to install (a countdown, or Later) | yes | no |
| `installing` | Handed to the installer; the app restarts next | yes | no |
| `needs_user` | The system needs the person at that device | yes | `confirm` (Android's install confirmation) \| `permission` (Install unknown apps is off) |
| `failed` | The last attempt stopped | when known | `check` \| `download` \| `safety` \| `installer` \| `cancelled` \| `not_applied` \| `other` |
| `manual` | This build cannot update itself (a development build, or the updater did not start) | no | no |

A receiver drops a status with an unknown `state`, `platform` or `channel`, and reads an unknown
`reason` as `other`. `not_applied` means the device handed version `target` to its installer and
started again on its old build.

`remoteStart` is the device's own "Let paired devices start updates on this device" switch (on by
default), and false when its updater cannot run.

`auto` (optional, written only when true) is the device's own "Update all devices automatically"
switch, true only while its updater can run. `busy` (optional, written only when set) says what the
person is doing on that device, so an automatic run waits: `call` (ringing or in a call), `screen_share`,
`remote_control`, `transfer` (a file or folder going either way), `phone_files` (a Mac downloading from
Phone files) or `setup` (setup or pairing on screen, Allow pairing on, or waiting for the other device to allow pairing). A receiver reads an unknown `busy` as `other`,
which still counts as busy, and drops a status whose `auto` is not a boolean or whose `busy` is not a
string. Builds without these fields ignore them.

**When a status is sent.** Once after each `features.update` that shows the key on both sides, then
whenever any field but `progress` changes, and while downloading at most once a second.

**`updates.start`** asks the receiver to update itself now from its own channel. It names no version,
URL, file or channel: the receiver checks its own feed, offers only a build newer than the installed
one, and installs only through its own checks (Android: SHA-256, package name, version code and
signing certificate; Mac: Sparkle's EdDSA signature). A downgrade is therefore impossible through
this message. The receiver answers exactly one `updates.result`:

- Dropped without an answer: wrong `version` or a `requestId` that is not a UUID, or a start from a
  peer whose latest map does not show the key.
- `refused` with `reason`: `disabled` (its switch is off), `rate_limited` (more than one start every
  30 seconds or five an hour from that device), `manual` (its updater cannot run), `not_applied`
  (the last version it tried did not apply and `retry` is not true), `busy` (its updater cannot
  start a check right now, or an `auto` start found its person busy). A sender reads an unknown
  reason as `other`.
- `accepted`: it updates. If an update is already running it carries on, and still answers
  `accepted`; a device running its own Update all keeps its own order and installs itself last.
  Progress follows as `updates.status`.

`retry: true` is set only when the person taps Retry for that device. Without it, a device whose
last attempt did not apply refuses, so a version that failed is never installed again on its own,
even when another device asks.

`auto: true` means nobody tapped Update all: the sender's "Update all devices automatically" or its
command line started the run. The receiver refuses it with `busy` while its person is busy (any of the
`busy` activities above), says which device started it ("Started automatically by Work Mac"), and
otherwise behaves as for any start. A start without `auto` is never refused for that reason. Retry is
always sent without `auto`.

**Order and results (the device running Update all).** It starts every connected peer that will
update at once, downloads its own update meanwhile, and installs its own last, after each peer has
finished, failed, or handed over to its installer (`installing`, or `needs_user`). Its own restart
waits through a 10-second countdown with **Later**; a peer that was asked installs and restarts
without asking. A peer that drops while `ready` or `installing` is restarting; when it reconnects,
its first `updates.status` decides: `build` at or above the `targetBuild` it was installing means
done, the same `build` as before means "Update didn't apply" (never retried on its own). A peer
whose current step has run for 3 minutes is marked as taking longer than usual. In an automatic run
the countdown is 60 seconds. In any run, the device's own restart waits while any connected device
reports `busy` (a call above all): a countdown in progress stops, and starts again from the beginning
once nobody is busy (looked at every 5 minutes in an automatic run).

**Automatic runs (Update all devices automatically).** These rules live in each app
(`AutoUpdate.kt`, `AutoUpdate.swift`); the wire only carries `auto` and `busy`. A device with the
setting on starts Update all by itself when its own check finds a newer build. Only one device starts
when several find it: the one with the lowest device ID among itself and the connected devices whose
status shows `auto`. The others wait for its `updates.start`; one that still has its own update after
15 minutes starts its own run. The lowest one also runs for a connected device with `auto` that reports
a newer build (`available`, `downloading` or `ready`) and allows remote starts. A device never starts a
run while one is going, or within 10 minutes of accepting another device's start while that update is
under way. An automatic run also asks each device that reported `current` from a check older than the
moment this device found the build to check again (a target with no known version).

### Phone screen to Mac (`screen_draft1`)

Status: **Draft, edition only, view only.** The Mac shows the phone's screen in a window. The phone
captures with Android's MediaProjection after the person confirms in the system dialog, encodes H.264
in hardware and streams it over the existing encrypted session. Control (touching the phone from the
Mac) is not part of this draft; see [screen-control-decision.md](screen-control-decision.md). Why the
stream shares the session instead of using a second connection, how it adapts to the link and what it
measured: [screen-sharing.md](screen-sharing.md).

**Negotiation.** `features.update` gains the boolean key `screen_draft1`. The phone sets it when
"Share screen with Macs" is on for that Mac (off by default; a global switch with per-Mac choices, like
the phone's other features). The Mac sets it when its "Show phone screens" switch is on (off by
default; one switch for every phone). The grant per device lives on the phone because the phone's
content is what is shared, as remote control's grant lives on the Mac it controls; the Mac's switch
only decides whether it will display streams at all. `screen.*` messages go only to a peer whose latest map shows `true`.
A receiver whose own switch is off answers `screen.request` with `screen.status` `disabled` and
`screen.start` with `screen.stop` `disabled`, and drops every other `screen.*` message.

**Asking and answering.** Both are encrypted like `camera.*` (outer `kind`, `sessionId`, a unique
`messageId` in the replay window, `nonce`, `ciphertext`), plaintext at most 512 bytes, `version: 1`.

| Message | Direction | Fields | Meaning |
| --- | --- | --- | --- |
| `screen.request` | Mac to phone | `requestId` (UUID) | "Phone screen" on the Mac. One open request per phone, at most one every 3 seconds; it expires after 2 minutes |
| `screen.status` | phone to Mac | `requestId`, `status` | `waiting` (the phone shows "MacBook Air wants to see your screen", with the Mac's name, and waits for the person to tap and confirm), `declined` (the person said no in Android's dialog), `busy` (the phone already shares with another Mac), `disabled`, `failed` |

Android does not let an app start capture, or open an activity, from the background, and asks for
consent before every capture (each time on Android 14 and later). So a request always ends with the
person tapping on the phone; the stream itself then starts with `screen.start` carrying the
`requestId`. The phone can also start sharing on its own (its device screen or the Quick Settings
tile), with no `requestId`; the Mac then opens the window if its switch is on.

**Stream messages.** Encrypted on the current session like remote input: the JSON ones have outer
`kind`, `sessionId`, a unique `messageId`, `nonce` and `ciphertext`; `screen.frame` has only `kind`,
`sessionId`, `nonce` and `ciphertext`. None of them enters the shared `messageId` window, because 30
frames a second would push every other feature's IDs out of it. Instead each side numbers its own
messages of a stream 1, 2, 3, ... (the phone from `screen.start`, the Mac from `screen.started` or the
refusing `screen.stop`), JSON and frames alike, and a receiver drops any message whose `sequence` is
not higher than the last one it accepted from that side for that stream. A `streamId` is chosen by the
phone and used once; the Mac remembers the last 16 ended stream IDs and ignores a start that reuses
one. Malformed, out-of-sequence or undecryptable messages are dropped and counted, never answered,
and never close the transport session. JSON plaintext is UTF-8, `version: 1`, at most 1,024 bytes for
`screen.start` and 512 for the others.

| Message | Direction | Fields (besides `version`, `streamId`, `sequence`) | Meaning |
| --- | --- | --- | --- |
| `screen.start` | phone to Mac | optional `requestId`; `codec`: `h264`; `width`, `height` (even integers, 16 to 4,096); `fps` (1 to 60); `bitrate` (bits a second, 100,000 to 50,000,000) | a new stream. Its first frame is a key frame |
| `screen.started` | Mac to phone | none | the window is open; frames may follow. The phone gives up after 5 seconds without it |
| `screen.frame` | phone to Mac | binary, below | one part of one encoded frame |
| `screen.ack` | Mac to phone | `frame` (1 to 2^32-1), `decodeMs` (0 to 60,000); optional `keyframe`: `true` | the newest frame the Mac has received completely and decoded (or dropped while waiting for a key frame, with `decodeMs` 0), and how long decoding took. `keyframe` asks for a key frame after a frame was lost or failed to decode (at most one a second) |
| `screen.stats` | phone to Mac | `latencyMs`, `rttMs` (0 to 60,000), `bitrate`, `sentBitrate` (0 to 50,000,000), `fps` (0 to 120), `dropped` (0 to 1,000) | once a second: the phone's latency estimate, its round trip, its target and measured bit rate, frames sent and dropped in the last second. Shown in the Mac window |
| `screen.stop` | either | `reason` | ends the stream (below) |

| `reason` | Sent by | Meaning |
| --- | --- | --- |
| `user` | phone | the person tapped Stop (notification, tile or app) |
| `closed` | Mac | the person closed the window or chose Stop |
| `ended` | phone | Android ended the capture (the status bar Stop, another app capturing, the shared app closed) |
| `screen_off` | phone | the phone's screen turned off or locked |
| `disabled` | either | the switch is off on this side |
| `invalid` | Mac | the start was malformed, or asked for a codec or size the Mac cannot decode |
| `timeout` | either | the phone got no `screen.started` within 5 seconds or no `screen.ack` for 6 seconds while frames were outstanding; the Mac got no frame or `screen.stats` for 6 seconds |
| `failed` | either | the encoder, the capture or the decoder failed |

An unknown `reason` reads as `failed`. When the transport session closes, both sides end the stream
locally (reason `disconnected`, never sent). One stream at a time per phone (a second Mac's request
gets `busy`); a Mac may show several phones, each in its own window.

**Frames.** The plaintext of `screen.frame` is a 40-byte header followed by 1 to 32,768 bytes of
H.264 Annex B data (at most 32,808 bytes; the encrypted frame stays well under the 65,536-byte frame
limit). Integers are big-endian.

| Bytes | Field | Rule |
| --- | --- | --- |
| 0 | version | `1` |
| 1 | flags | bit 0 key frame (IDR), bit 1 the frame starts with its SPS and PPS, bit 2 last part of the frame; other bits are sent as 0 and ignored |
| 2 to 3 | part | 0 to 63, the index of this part within the frame |
| 4 to 19 | stream ID | the 16 bytes of the `streamId` UUID |
| 20 to 27 | sequence | 1 to 2^53-1, the phone's stream sequence above |
| 28 to 31 | frame | 1 to 2^32-1; increases from one frame to the next |
| 32 to 39 | capture time | 0 to 2^63-1 microseconds on the phone's monotonic clock (a signed 64-bit value; a set top bit is rejected); only differences mean anything |

A frame is one H.264 access unit, split into parts sent in order 0, 1, 2, ...; part 0 starts with an
Annex B start code. Every key frame carries the current SPS and PPS at its start (flag bit 1), so it
can be decoded on its own and a size change (rotation) needs no separate message. B-frames are not
used, so frames are decoded and shown in the order they arrive. The Mac drops an unfinished frame when
a part of a later frame arrives, and drops frames until the next key frame after a lost or undecodable
one. Frames over 64 parts (2 MiB) are dropped.

**Pacing (phone).** The phone sends a frame only while at most 6 frames and at most
max(64 KiB, 250 ms at the current bit rate) are sent and not yet acknowledged. A frame that does not
fit is dropped, along with every following frame up to the next key frame, which the phone requests
from the encoder at once; then it lowers the bit rate. One exception keeps a stream from stalling:
when nothing is unacknowledged, a key frame is always sent, whatever its size. The Mac acknowledges
every frame it receives completely, including frames it drops while waiting for a key frame, so the
phone's count of unacknowledged frames always drains. This keeps at most a quarter of a second of
video queued in the socket, so clipboard, notifications and acknowledgements wait behind one part at
most. The bit rate goes down by a quarter when frames are dropped or the round trip grows 80 ms over
its minimum (at most every 500 ms), and up by 15 percent after 2 seconds without either, between
300 kb/s and 8 Mb/s.

**Security.**

| Threat | Mitigations |
| --- | --- |
| The Mac watches the phone without the person knowing | Both switches are off by default. Every stream needs the person's confirmation in Android's own dialog on the phone, every time. While it runs, the phone shows a persistent "Your screen is being shared with MacBook Air" notification (the Mac's name) with Stop, and Android 15 and later add the status bar indicator. The phone stops when its screen turns off |
| Sensitive content on screen | Android 15 and later hide one-time codes and other sensitive notification content during capture; secure windows (banking apps, passwords, FLAG_SECURE) appear black. The Mac never saves, records or forwards frames; nothing is written to disk |
| Another device on the network watches or injects frames | Frames are AES-GCM encrypted with the session key of the authenticated, pinned peer. The per-stream sequence and the stream ID in each header reject replays and splicing between streams; the session key rejects them across sessions |
| A flood of frames or huge frames | Parts are at most 32 KiB, frames at most 64 parts, and the Mac keeps one unfinished frame. Frames go only to a Mac whose switch is on; the Mac stops a stream with no traffic for 6 seconds |
| Sharing left running unnoticed | The notification stays until the stream ends; Stop on either side, a locked screen, a disconnect or switching the feature off ends it |
### Text messages (`sms_draft1`)

Status: **Draft, edition only.** Bridgey by Round Robin shows the phone's SMS conversations on the
Mac, Pushbullet style: a Messages window with the conversation list, each conversation, new messages
to a contact or number, MMS images (read only), delivery status and the SIM each conversation uses.
A text message notification gets a Reply field on the Mac that works whichever messaging app the
phone uses. Off by default on both sides; upstream peers never see any of it.

**Negotiation.** `features.update` gains `sms_draft1`. The phone sets it while its Text messages
switch is on for that Mac; the Mac sets it while its own Text messages setting is on. `sms.*`
messages and the two `notifications.post` fields below go only to a peer whose latest map shows the
key `true`. A phone that turns the feature off sends the key `false`, and the Mac then deletes what
it kept for that phone.

**Permissions and privacy.** The phone reads the SMS provider (`READ_SMS`), sends with `SmsManager`
(`SEND_SMS`), looks up names (`READ_CONTACTS`) and, on dual-SIM phones, lists SIMs
(`READ_PHONE_STATE`). It asks only when Text messages is turned on, and never becomes the default SMS
app: Android writes messages Bridgey sends into the provider itself. Message bodies, numbers and
names travel only inside the encrypted session and are never logged on either side. The phone keeps
nothing; the Mac keeps a cache (below) and MMS images only in memory.

**Fields on `notifications.post`** (phone to Mac, only to a Mac that shows the key, only for the
default SMS app's notifications):

| Field | Type | Meaning |
| --- | --- | --- |
| `smsReply` | boolean | the phone can answer this notification: the Mac shows one Reply field and sends `sms.send` with `notificationId` |
| `smsThreadId` | integer, optional | the conversation the newest message belongs to, so a click opens it |

The phone answers a notification reply through the messaging app's own reply (RemoteInput) when the
app offers one, so chat features such as RCS keep working, and through `SmsManager` when it does not,
or always when the phone's "Send replies as SMS" switch is on (for apps whose reply is unreliable).
SmsManager replies go to the conversation's single participant from the SIM it last used.

**Messages.** Encrypted like `codes.*` (`messageId` in the replay window), `version: 1`. Requests
carry a `requestId` (UUID) that the answer echoes.

| Message | Direction | Fields | Meaning |
| --- | --- | --- | --- |
| `sms.status` | phone to Mac | `read`, `send`, `contacts` (permissions), `sims` (`subId`, `slot`, `label`), `cursor` | sent after each `features.update` showing the key on both sides and whenever a permission or the SIM list changes |
| `sms.changed` | phone to Mac | `cursor` | the provider changed; at most one every 2 seconds |
| `sms.threads` / `sms.threads_page` | Mac asks, phone answers | `before` (date), `limit` up to 50 / `threads`, `more` | conversation list, newest first |
| `sms.messages` / `sms.messages_page` | Mac asks, phone answers | `threadId`, `before` (`date`, `id`), `limit` up to 100 / `messages`, `more` | one conversation, newest first |
| `sms.sync` / `sms.sync_page` | Mac asks, phone answers | `since` cursor, `limit` up to 200 / `messages`, `cursor`, `more`, `reset` | everything newer than the Mac's cursor |
| `sms.send` / `sms.send_status` | Mac asks, phone answers | `body` and one of `threadId`, `address`, `notificationId`, optional `subId` / `status`, `reason`, `via` | send one SMS; statuses `sending`, `sent`, `delivered`, `failed`, `refused` |
| `sms.attachment` / `sms.attachment_data` | Mac asks, phone answers | `partId` / `mimeType`, `width`, `height`, `data` | one MMS image as a JPEG of at most 28 KiB |
| `sms.contacts` / `sms.contacts_result` | Mac asks, phone answers | `query` / up to 20 `contacts` | names and numbers for a new message |
| `sms.mark_read` / `sms.mark_read_result` | Mac asks, phone answers | up to 50 `threadIds` / `results` (`threadId`, `result`) | conversations read on the Mac: the phone runs the messaging app's own Mark as read on the notifications it still shows for them |
| `sms.blocked_numbers` / `sms.blocked_numbers_result` | Mac asks, phone answers | optional `address` / `result` | opens Android's Blocked numbers screen on the phone |

Pages stay under 40 KiB of plaintext (the frame limit is 64 KiB); the phone stops adding entries
and sets `more`. A message is `{id, threadId, direction, status, date, address, body, truncated?,
subId?, read, parts?}`; ids are `s<_id>` for SMS and `m<_id>` for MMS, so the two provider tables
never collide. Bodies over 4,000 UTF-16 units are cut and marked `truncated`.

**Incremental sync.** The cursor is the newest `_id` of the SMS and MMS tables. A Mac with no cache
takes the cursor from `sms.status` as its starting point (it never copies the whole history) and
loads the newest conversations; older conversations and older messages load only when scrolled to.
After that it sends `sms.sync` on connect and after each `sms.changed`. The phone reads each table in
`_id` order from the cursor, so a page never skips a message, and answers `reset: true` when the
cursor is ahead of the phone (a restored phone) or more than 1,000 messages behind; the Mac then
drops its cache and starts again. Opening a conversation refreshes its newest page, which picks up
delivery reports and messages deleted on the phone.

**The Mac's cache.** At most 200 conversations and the newest 200 messages of each, per phone, in one
file under Application Support with permissions 0600. It is deleted when Text messages is turned off
on the Mac, when the phone turns it off, when the phone is forgotten, and from Reset. No cloud.

**Limits and safety.** `sms.send` goes to one recipient: a conversation with several people is
refused (`group`) and the Mac says to answer it on the phone. Emergency numbers are refused. At most
one send per second and 30 in 10 minutes per Mac (`rate_limited`); Android's own premium-number and
volume prompts still apply on the phone. At most 4 open `sms.attachment` requests per Mac.

**Managing conversations from the Mac.** Pin, mute, archive, read state, Mark as unread and Delete
(a conversation or one message) are this Mac's own: they live in a small per-phone file next to the
cache (0600, no message text), are never sent anywhere, and go when the cache goes (Forget, Text
messages off on either device, Reset). Android lets only the default SMS app write to the SMS
provider, so nothing the Mac does changes the phone's messages; Delete says "Removes it from this
Mac. It stays on your phone." and keeps a tombstone (thread ID, its newest message's date and ID) so
the next sync does not bring it back until a newer message arrives. An archived conversation comes
back when a newer message arrives unless it is muted. A muted conversation shows no banner on the
Mac (the phone sends `smsThreadId` with each SMS notification).

Two things do reach the phone:

- **Mark as read.** When a conversation is read on the Mac (opened, or marked read) and the phone
  still counts it unread, the Mac sends `sms.mark_read`. For each conversation the phone looks at the
  default SMS app's notifications it still shows (matched to conversations as for replies: by text,
  sender and time), and runs the app's own action tagged `SEMANTIC_ACTION_MARK_AS_READ`, which marks
  the messages read in the app and clears the notification. Each conversation's `result` is `marked`,
  `not_shown` (no notification for it, so it stays unread on the phone), `no_action` (the app's
  notification has no Mark as read) or `failed`. The Mac says which, in plain words. A phone that
  does not know the request (older than this draft revision) never answers; the Mac treats that as
  not reaching the phone.
- **Block on phone.** Only the default dialer, the default SMS app and the carrier may add to
  Android's blocked list, but any app may open the system Blocked numbers screen
  (`TelecomManager.createManageBlockedNumbersIntent`). `sms.blocked_numbers` opens it at once when
  Bridgey is in front on the phone (`opened`), otherwise Bridgey posts a notification that opens it
  when tapped (`notified`), because Android does not let an app open a screen from the background;
  `unavailable` when the phone has no such screen (for example a secondary user). The number is
  shown so the person can add it there.

**Codes from messages.** Unchanged: SMS notifications still carry `smsDefaultApp` and the Mac still
reads codes from them. The conversation view offers Copy code on a message that looks like it holds
one, using the same engine and guard as the notifications.

## Draft: folders, places and settings sync

**Draft, edition only until accepted upstream.** Bridgey by Round Robin implements
this first; upstream clients never receive these messages. Implemented: folders
Mac to phone and places on the phone (Files 2.0, first slice), phone to Mac (second
slice, below) and settings sync (v0.10). The full design, user
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
one; an unsupported schema is answered `settings.error` `{schema, code, maxSchema}`
(`unsupported_schema`), and a payload that fails validation `invalid_message`.

As built in v0.10 ([section 8.4](folders-and-settings-sync.md#84-as-built-v010-2026-10-27)):
26 keys sync, feature switches included (`feature.<key>`, `clipboard.automatic`,
`clipboard.files`, `focus.share`, `focus.follow`, `codes.enabled`) next to the four preferences and
the two folder switches `files.folder_include_hidden` and `files.folder_include_system`;
per-device grants and overrides, permissions, pairing, paths and the file access guards never
sync. Live updates apply when they win by the rule above and are relayed to the device's other
peers, so a phone with two Macs carries one Mac's change to the other. A snapshot never overwrites
a chosen value: a setting the receiver never chose (`version` 0) takes the sender's, and two
different chosen values stay as they are until Apply to all on either device. Snapshots and updates
may carry `waiting` (keys that are on but wait for a permission on the sender). More than 20
`settings.*` messages from one peer in 10 seconds are dropped and answered `settings.error`
`rate_limited`. Threat model: [section 8.5](folders-and-settings-sync.md#85-threat-model-settings-sync).

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
durationMs, thumb, location, taken}`; `width`, `height` and `durationMs` are null when
unknown; `location` is a display path such as "Camera" or "Documents/Invoices" (at
most 128 characters); `taken` (optional, media items only) is the Unix ms the list is
sorted by (date taken, else date added), so the asker's day headers follow the same
order as the items. Older phones leave it out; askers then use `modified`. `access` is the photo access (`full`, `partial`, `none`;
with `none`, `kind: media` returns no items). `indexing` is true while the phone
refreshes its document index; the asker may list again later. The document index
covers granted places only (Android shared storage has no other way to see
documents without broad permission).

Askers cache by device ID, `ref`, `modified` and `size`: the same four always
mean the same bytes.

### Thumbnails

`media.thumbnails` `{version, requestId, items[], size, replaces}`: 1 to 64 items
`{key, ref}`, `key` 1 to 64 characters of `[A-Za-z0-9_-]` chosen by the asker;
`size` is the longest edge in pixels, 64 to 512 (default 256). The phone makes
them in the order asked (the asker puts visible items first) and sends each as soon
as it is ready, so one slow item does not hold back the rest; askers match thumbnails
by `key`. The answer is one or more
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

An offer the receiver never accepted (the connection dropped before
`folders.accept`) may be offered again after the reconnect with the same
`folderTransferId` and `resume: false`; the receiver treats it as new, since
nothing was written. Accepted offers resume as in the folders draft.

New error code: `read_only` (writing into the phone's places needs its "Allow
other devices to change files here" switch).

### Free space

Every `places.listed` reply, with or without `purpose` and in every destination
mode, carries `defaultFreeBytes` (integer or null): free bytes where a file or
folder sent now would land by default. `folders.accept` carries `freeBytes`
(integer or null) for the chosen destination. Senders compare these with what a
send writes and block it when it would not fit with the receiver's 64 MiB margin,
or warn when less than 1 GiB would remain. Values are best effort; the receiver
still checks and answers `insufficient_space`.

## Draft: Connect anywhere (`connect_draft1`)

Status: **draft, edition-only, phase 1 built** (Bridgey by Round Robin). Design, numbers and the
phases: [connect-anywhere.md](connect-anywhere.md). Every wire string is unbranded so the protocol can
be offered upstream. Peers that do not both advertise the key keep today's transport unchanged.

### Negotiation

`features.update` gains the draft key `connect_draft1`. A device sets it for every peer while
"Connect away from home" is on and its Connect anywhere core loaded. It is read like every draft key:
`true` only for JSON `true`. (The spec's `capabilities` array is replaced by this key, following the
contract's rule for drafts.)

### The tunnel

New routes (a learned LAN or private-network address, ICE through the control service, a relay)
carry QUIC, never plain TCP:

- UDP, port 42458 when free. ALPN `bridgey/1`, TLS 1.3 only, a self-signed Ed25519 certificate on
  both sides (new at each start and every 24 hours). When signalling supplied the peer's `certSha256`
  (SHA-256 of the DER, base64url), the certificate must match it; a direct dial to a learned address
  has no pin and relies on the signatures below.
- STUN, TURN and QUIC share one socket, told apart by the first byte (RFC 9443), so QUIC does not
  grease the fixed bit.
- Stream 0, the first client-initiated bidirectional stream, carries the newline JSON session of this
  document unchanged, with its 65,536-byte frame limit. The core copies the stream's bytes without
  looking at them, so binary frames of fast transfers (`files_fast_draft1`, up to about 1 MiB each)
  travel inside it too; the limit is for JSON frames. The QUIC client sends `pairing.offer`.
- **Channel binding.** On a tunnel, `pairing.confirm` signs this transcript instead of
  `bridgey-auth-v1` (NUL-separated, initiator = the side that sent `pairing.offer`):

  ```text
  "bridgey-auth-v2" \0 sessionId \0 initiatorDeviceId \0 responderDeviceId
    \0 initiatorEphemeralKey \0 responderEphemeralKey \0 base64(exporter)
  exporter = TLS-Exporter("EXPORTER-bridgey-tunnel-v1", "", 32)
  ```

  A relay or a man in the middle that terminates QUIC on both sides sees two different exporters,
  so the signatures fail. `bridgey-auth-v1` stays the transcript on TCP.
- Tunnels carry trusted devices only, as a plain protocol 2 reconnect: an offer from a device that
  is not already paired, a committed offer (a new pairing), or an offer or answer without
  `protocolVersion` 2 closes the tunnel without a prompt. Both ends refuse to confirm a tunnel session
  without envelope tags, so every frame inside carries `tag` and goes through the replay window; a
  tunnel can never fall back to protocol 1. Pairing stays on the local network, where the code is
  compared (remote pairing by invite is a later phase).
- Duplicates follow the existing rule: both sides keep the session dialled by the lower device ID,
  the newer one if that side dialled both. The QUIC client of an ICE tunnel is always the lower
  device ID.

### In-session messages

Encrypted payloads in the current session format (`kind`, `sessionId`, `messageId`, `nonce`,
`ciphertext`), sent only when both peers advertise `connect_draft1`. A malformed payload is dropped
and the session stays.

| Message | Payload |
| --- | --- |
| `connect.setup` | `version` 1, `contribution` (base64 of 32 random bytes), optional `rotate` (boolean). A side that receives a contribution first answers with its own. Both then hold `pairSecret = HKDF-SHA256(cLow ‖ cHigh, salt "bridgey-pair-secret-v1", info idLow \0 idHigh, 32)`, where `cLow` is the lower device ID's contribution, and send `connect.setup.ack` `{version}`. |
| `connect.addresses` | `version` 1, `port` (the sender's UDP port), `addrs` (at most 16 `{a, kind, vpn?}`; `kind` is `lan`, `vpn` or `public6`, `vpn` is `tailscale` or `other`), optional `pairCheck` = base64url(HMAC-SHA256(pairSecret, "bridgey-pair-check-v1")[0..8]). Sent after every `features.update` that shows the key on both sides and when addresses change. Entries with an unknown kind or an unusable address are skipped. When the two pair checks differ (or one side has none), the lower device ID starts `connect.setup`. |

`connect.offer`, `connect.answer`, `connect.candidates`, `connect.restart`, `connect.bye` (in-band
ICE) and `connect.route` are specified in connect-anywhere.md and listed as `designed`: phase 1
signals ICE through the control service only.

### Rendezvous (Bridgey Rendezvous v1)

The edition's control service is `wss://connect.roundrobin.in/v1/ws` (`CONNECT_CONTROL_URL` in
`rr-edition.properties`); anyone can run one (`server/`). WebSocket text frames, one JSON object of at
most 16 KiB, the type in `t`:

| Message | Fields |
| --- | --- |
| `hello` | `v` 1, `node` (P-256 SEC1 public key, base64url), `app`, `keepalive` (60 to 270 s) |
| `challenge` | `nonce` (base64url, 32 bytes), `pow` (leading zero bits, 0 = off) |
| `auth` | `sig`: DER ECDSA-P256-SHA256 over `"bridgey-rdv-auth-v1\0" ‖ nonce ‖ node`, base64url; `pow` when asked: a solution with `SHA-256("bridgey-pow-v1" ‖ nonce ‖ node ‖ solution)` starting with that many zero bits |
| `welcome` | `nodeId` (base64url of SHA-256(node)[0..16]), `now`, `limits` |
| `register` / `registered` | `ids`: the rendezvous IDs (at most 64, replaces the set) / `online`: those whose other side is connected |
| `presence` | `rdv`, `online` |
| `signal` | `rdv`, `side` (0 for the lower device ID), `sid` (base64url, 16 bytes), `body` (sealed, at most 6 KiB) |
| `undeliverable` | `rdv`, `sid` |
| `relay.request` / `relay.claim` | `rdv`, `sid`, `side` (`rtts`, `need`, `estBytes`, `exclude` optional on the request). The claim gets the same relay, with its own credentials. |
| `relay.grant` | `sid`, `relay`: `id`, `kind`, `urls`, `username`, `credential`, `expiresAt`, `maxKbps` |
| `relay.denied`, `error` | `code`, `retryAfterMs` |

Derivations and sealing:

```text
rdvId(d) = base64url(HMAC-SHA256(pairSecret, "bridgey-rdv-v1" ‖ d)[0..16]), d = UTC "YYYY-MM-DD"
sigKey   = HKDF-SHA256(pairSecret, salt "", info "bridgey-signal-v1", 32)
body     = base64url(0x01 ‖ nonce(12) ‖ AES-256-GCM(sigKey, nonce, plaintext,
                     aad = "bridgey-signal-v1" \0 rdvId \0 side \0 sid))      side as "0" or "1"
```

Devices register today's and yesterday's IDs, and tomorrow's from 23:00 UTC. The sealed plaintext is
JSON with `t` `offer`, `answer`, `cand`, `restart` or `bye`; offers and answers carry `sid`, `v`,
`ufrag` (8 characters), `pwd` (24), `cands` (at most 24 of `{k, a, p, net?, pri, relay?}`), `cert`,
`ts` and `seq`. Receivers drop bodies more than 5 minutes off or with a `seq` not above the last
one for that session. Relay credentials are TURN REST style:
`username = "<expiry>:<sid prefix 8>.<side>"`, `credential = base64(HMAC-SHA1(secret, username))`,
valid 2 hours. Vectors for all of this: `protocol/test-vectors/connect-v1.json`.

## Draft: fast transfers and the speed test (`files_fast_draft1`)

**Draft, edition only.** Why and what it measured: [transfer-speed.md](transfer-speed.md). Peers without the key
keep everything in [Files](#files-filesv1) above: 24 KiB chunks as base64 inside JSON and at most 64 chunks
unacknowledged.

### Negotiation

`features.update` gains the boolean key `files_fast_draft1`. It is a capability, not a setting: both apps advertise
it whenever they support it, and use it only on a protocol 2 session (envelope tags on, see
[Pairing flow](#pairing-flow)); on a protocol 1 session every chunk stays JSON whatever the map says (the Mac can turn it off for a test with `defaults write in.roundrobin.bridgey
transfers.fastOff -bool true`). Fast transfers are used with a peer only while its latest map shows the key `true`. A
sender decides once, when a transfer starts, and keeps that form for the whole transfer; a peer that supports the key
reads binary frames for the rest of the session even if a later map shows `false`.

### Binary frames

Binary frames travel on the session's byte stream wherever it runs: the TCP socket on the local network, or stream 0
of a Connect anywhere tunnel (a tunnel session is always protocol 2). Once a session is authenticated on protocol 2, a client that supports the key also reads **binary frames** between
JSON frames. A
binary frame starts with the byte `0xB1`, which cannot start a JSON frame (`{` or whitespace) and is not a valid
first byte of UTF-8 text, so a peer without the key would close the session instead of misreading it. Before
authentication the byte is just an invalid JSON frame, as it always was. Integers are big-endian.

| Bytes | Field | Rule |
| --- | --- | --- |
| 0 | marker | `0xB1` |
| 1 | kind | `1` file chunk, `2` speed test bytes; another kind is skipped whole once its tag verifies, and the session stays |
| 2 to 5 | length | of what follows, 1 to 1,048,677; anything else closes the session |
| 6 | ID length | 1 to 64 |
| 7 to 6+L | ID | printable ASCII (0x21 to 0x7E): the transfer ID exactly as in `files.offer`, or the test ID |
| next 8 | sequence | 0 to 2^53-1 |
| next 12 | nonce | AES-GCM, random per frame |
| rest | ciphertext and tag | plaintext 1 to 1,048,576 bytes, then the 16-byte tag |

**Authentication under protocol 2.** JSON frames carry an envelope tag; a binary frame needs none, because its
AES-GCM tag already authenticates everything in it, under the frame key HMAC-SHA-256(session key,
`bridgey-fast-frame-key-v2`) (kept apart from the session key, as the envelope key is), and the associated data binds what the
envelope tag binds: it is length-prefixed exactly like the envelope tag input (each field a 4-byte big-endian length
and its UTF-8 bytes) and holds `bridgey-fast-frame-v2`, the **sending device's ID**, the kind (decimal), the ID and the
sequence (decimal). So a frame cannot be moved to another transfer, position or kind, nor reflected back to the device
that sent it (its own ID is not the sender the receiver checks), and nobody without the session key can make one.
The session key is fresh for every session, so a frame cannot be replayed into another one.

**Replay.** Binary frames do not enter the `messageId` window. Each side remembers, per kind and ID, the highest
sequence it took (for the 256 most recently used IDs, so a long transfer is never forgotten while short ones come and
go) and drops a frame that does not raise it; file transfers additionally require the next sequence exactly, as JSON
chunks always did, and only from the device the transfer is with.

**Bad frames.** A binary frame of any kind that fails its tag, is malformed inside its body or is a replay is dropped
and counted
with the frames dropped for a bad envelope tag; 16 close the connection, as for JSON. A header with a length outside
1 to 1,048,677 closes the session at once, because the stream can no longer be split into frames.

### Files over binary frames

Between two peers that show the key, **every** `files.chunk` (single files, folders, Phone files downloads and
uploads, clipboard files) is a binary frame of kind 1 instead of the JSON message. Everything else about files stays:
`files.offer`, `files.accept`, `files.complete` and the cancels are JSON as before.

- **Chunks** are up to 1 MiB; senders use 256 KiB.
- **Every chunk is acknowledged** with the existing outer `files.chunk.ack` (cumulative), in both directions and for
  single files too (the Mac did not acknowledge single files from the phone before).
- **The window is counted in bytes** and follows the link: it starts at 2 MiB, doubles while acknowledgements come back
  within 20 ms of the lowest round trip seen in the last 10 seconds, grows by about a chunk per round trip up to 40 ms
  over it, and shrinks to 70% (at most once per round trip) beyond that, between 512 KiB and 32 MiB. So a transfer
  fills the link while at most about 40 ms of file data waits in front of a clipboard update, a notification or a call
  (a delay-based controller in the spirit of LEDBAT, RFC 6817). A sender with nothing unacknowledged may always send
  one chunk.
- Receivers keep their limits: a chunk over 1 MiB, a gap in the sequence or more bytes than offered fail the file
  exactly as before.

### Speed test

Settings > Developer and experimental > Transfer speed (hidden until the version is tapped five times) on both apps. Either side starts; one test at a time per device. All JSON
plaintexts are UTF-8, `version: 1`, at most 1,024 bytes; test IDs are UUIDs and compare lowercased; an undecryptable or
malformed speed message is dropped and the session stays.

1. `speed.start` (encrypted) carries `testId`, `seconds` (2 to 15; the apps use 7) and `link`, the sender's own view of
   its network: `platform`, `network` (`wifi`, `ethernet`, `hotspot` when the phone is the Mac's access point, or
   `other`), and where readable `band` (`2.4`, `5`, `6`), `linkMbps` (transmit rate), `standard` (4 to 7 for Wi-Fi 4
   to 7) and `widthMhz`, plus on phones `lockHeld` and `screenOn`. No network names, addresses or device names.
2. The other side answers `speed.ready` (encrypted) with `status` `ready` (and its own `link`), `busy` or `disabled`
   within 5 seconds.
3. Ten outer-only `speed.ping` (`transferId` the test ID, `sequence` 1 to 10, 30 ms apart) are echoed at once as
   `speed.pong`; the idle round trip is their median.
4. The side that started sends binary frames of kind 2 (256 KiB of zeros, encrypted like file chunks) for `seconds`,
   paced by the window above; the other side answers each with an outer-only `speed.ack` and drops the bytes. Then
   `speed.turn` (encrypted, with what it measured), and the other side sends for `seconds` and finishes with
   `speed.done` (encrypted, with its measurement).
5. The side that started sends `speed.result` (encrypted): `forwardBytesPerSecond` (from it), `backBytesPerSecond`,
   `roundTripMs` and `loadedRoundTripMs` (the acknowledgements' smoothed round trip while sending), so both apps show
   the same result. Throughput counts acknowledged bytes after the first second.

Either side may send the outer-only `speed.cancel` (`transferId` the test ID) to stop: Stop, 5 seconds without an
acknowledgement or without test bytes, a disconnect or a failure. While a test runs the phone holds its Wi-Fi
power-save lock (below), as for transfers.

### Wi-Fi power saving on the phone

While any transfer or a speed test runs, the phone holds a low-latency Wi-Fi lock (Android 10 and later), a
high-performance one (Android 13 and older) and a partial wake lock, and lets them go two seconds after the last one
ends. Android applies the low-latency lock only while the screen is on and Bridgey is in front, so with the screen off
Wi-Fi power saving can still slow a transfer; the speed test reports `screenOn`.

## Compatibility

Adding optional fields or message types is backward compatible. Changing field
meaning, authentication, or required behavior requires a new capability or
major version. JSON is a codec behind the envelope model; a future protobuf
codec must preserve IDs, types, correlation, and negotiated semantics.
