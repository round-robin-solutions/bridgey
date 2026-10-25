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
advertises them explicitly.

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
this first; upstream clients never receive these messages. The full design, user
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
   for folders).
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
   receiver asks its own user. Questions time out after 180 seconds and cancel;
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

**Resume.** Both sides keep a journal per transfer for 24 hours. After a
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

## Compatibility

Adding optional fields or message types is backward compatible. Changing field
meaning, authentication, or required behavior requires a new capability or
major version. JSON is a codec behind the envelope model; a future protobuf
codec must preserve IDs, types, correlation, and negotiated semantics.
