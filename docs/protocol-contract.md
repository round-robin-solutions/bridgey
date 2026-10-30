# Bridgey Protocol v1 compatibility contract

Status: **draft for v0.10, to be frozen at 1.0.** It covers the native newline JSON transport that
Bridgey 0.5/0.6 and Bridgey by Round Robin speak today. Nothing here is frozen yet: v0.10 is the
stabilisation milestone, and this contract is what 1.0 is meant to freeze. Until then, treat the
`upstream-v1` parts as fixed in practice (upstream peers depend on them) and the drafts as open. This page is the contract; [protocol.md](protocol.md) explains
the design and behaviour of each feature in prose.

The machine-readable copy is [`protocol/messages.json`](../protocol/messages.json). It is the source:
the tables at the end of this page are generated from it with
`python3 protocol/tools/contract.py --write`, and `--check` fails when they are stale.

## What 1.0 will freeze

- **Framing.** One UTF-8 JSON object per line, ended by LF (a CR before the LF is ignored), at most
  65,536 bytes per frame before decoding and at most 32 levels of JSON nesting. Frames are strict
  RFC 8259 JSON: no comments, single quotes, unquoted names or trailing commas, and no lone surrogate
  escapes. Both clients run the same strict check before parsing, so they accept exactly the same
  frames. Duplicate names are undefined; senders must not produce them. TCP port 42458,
  Bonjour service `_bridgey._tcp`.
- **Envelope.** The outer object has `kind` (1 to 64 bytes) and `sessionId` (at most 128 bytes;
  empty only in a `pairing.cancel` sent before the session ID is known) plus optional string fields
  and an integer `sequence`. Each field has one type. A wrong type, a missing `kind` or `sessionId`,
  invalid UTF-8, a frame that is not a JSON object, or a frame over either limit closes the session
  before any message is dispatched.
- **Every message kind** in the tables below with status `upstream-v1`: its direction, its envelope
  fields, its payload fields, their types and limits, and its meaning.
- **Pairing and encryption**: ephemeral P-256 ECDH, HKDF-SHA-256 with the session ID as salt and
  `bridgey-pairing-v1` as info, AES-GCM payloads (base64 `nonce` and `ciphertext`), the six-digit
  code and the signed transcript. See [protocol.md](protocol.md) and [SECURITY.md](../SECURITY.md).

## Statuses

| Status | Meaning |
| --- | --- |
| `upstream-v1` | Shipped by upstream Bridgey 0.5/0.6 (baseline 0.6.0-rc.2). Changed only through a new feature key, because upstream peers depend on it; frozen at 1.0. |
| `edition-extension` | An optional field this edition adds to an `upstream-v1` message (for example `targetDeviceId` on `pairing.offer`, `smsDefaultApp` on `notifications.post`). Upstream peers ignore it; it never changes the meaning of the fields they know. |
| `edition-draft` | Edition only, gated by a `*_draft1` feature key and sent only to a peer whose latest `features.update` shows that key `true`. It may still change; when upstream accepts it, it moves to a final key (below). |
| `retired` | No longer sent or advertised. Receivers keep ignoring it, and the key and kinds are never reused. None yet. |
| `designed` | Specified in [protocol.md](protocol.md) but not built by either client yet. Never sent. None now (settings sync was the last, built in v0.10). |

## Compatibility rules

1. **Unknown kinds are ignored.** A receiver that does not know a `kind` drops the message and keeps
   the session. Never close a session because of an unknown kind; that is what lets new features
   ship without breaking older peers.
2. **Unknown fields are ignored**, in the envelope and in payloads. New fields are always optional.
   A field never changes type or meaning; a different meaning needs a new field name or a new kind.
3. **Feature negotiation gates everything new.** Each peer sends an encrypted `features.update`
   with a complete map of booleans after pairing and whenever local policy changes. A feature is
   available only when both peers report `true`. The original keys (`clipboard`, `files`,
   `notifications`, `battery`, `find_device`) must be present; every later key is optional and a
   missing key means `false`. A sender must not send a gated message to a peer whose latest map does
   not show its key `true`; a receiver that gets one anyway answers its `*.rejected` form when there
   is one, resends `features.update`, and otherwise ignores it.
4. **Limits only get stricter through a key.** A receiver never accepts less than the limits in this
   contract from a peer that advertises the feature. Raising a limit needs a new key, so an older
   peer is never sent something it would reject.
5. **Drafts carry a version suffix.** Edition drafts use keys like `clipboard_files_draft1`. If the
   draft changes incompatibly it becomes `_draft2` and both keys may be advertised during a
   transition.
6. **Retiring a key.** To retire a feature key: (a) stop sending its messages and advertise the key
   as `false` for at least one release on the Stable channel; (b) then stop advertising it; (c) keep ignoring its
   messages forever (rule 1) and never reuse the key or its message kinds with a different meaning.
   Mark it `retired` in `protocol/messages.json` instead of deleting it.
7. **Promoting a draft upstream.** When upstream accepts a draft, the final key (for example
   `folders`) is added next to the draft key. Clients advertise both during at least one release on
   the Stable channel and prefer the final key; then the draft key is retired by rule 6.
8. **Malformed is not unknown.** Inside a known kind, a payload that is over its limit or fails
   validation is dropped (or answered with that feature's error message). A payload that fails
   decryption closes the session for `upstream-v1` messages and for folders, places, browsing and settings sync, as in
   upstream; clipboard offers, codes, remote input, the automation drafts (Mac actions, Focus sync,
   phone camera), Update all, screen sharing and text messages drop it and keep the session.
9. **Replay.** Encrypted messages with a `messageId` go through one per-session window of the last
   256 accepted IDs (oldest evicted first); a repeated ID is not executed again. Quick actions,
   remote input and screen sharing streams use a sequence high-water mark instead, so their volume cannot push other IDs out of
   the window; `actions.run` passes the window and then its own per-session sequence. Nothing is replayable across sessions because every session has its own key.
10. **Major versions.** Anything that changes framing, authentication or required behaviour for all
    peers is a new protocol version, negotiated before use (the future `core.hello` design in
    [protocol.md](protocol.md)). Until then the protocol is v1.

## How the contract is enforced

- `protocol/messages.json` lists every message kind. On Android, `ProtocolContractTest` and on macOS
  `ProtocolContractTests` scan the app sources for every kind the code sends or handles and fail when
  one is missing from the file, or when the file says a platform implements a kind its code never
  mentions. They also check that every feature key the app advertises is listed. Adding a message
  without documenting it fails the build's tests.
- `python3 -m unittest discover -s scripts/rr/tests` runs `test_protocol_contract.py`, which validates
  the file and fails when the tables on this page are stale.
- Golden vectors in [`protocol/test-vectors/protocol-v1.json`](../protocol/test-vectors/protocol-v1.json)
  are decoded by both test suites with the same expected results: valid and invalid frames, and
  key payloads (`features.update`, `clipboard.rich`, `clipboard.offer`, `battery.update`,
  `quick.request`, `codes.status`, remote input, Files 2.0 browse refs, and the automation drafts:
  `focus.state` on both, `actions.catalog`, `actions.result` and `camera.request` on the phone,
  `actions.run` and `camera.status` on the Mac, with each sending platform's own encoding checked
  against the same plaintext; Update all: `updates.status`, `updates.start` and `updates.result` on
  both, which also write the same plaintext for the vectors marked `write`; screen sharing:
  `screen.request` and the Mac's stream messages on the phone, `screen.status`, the phone's stream
  messages and the binary `screen.frame` header on the Mac; and Text messages: the `sms.*` requests
  and `sms.send` on the phone, `sms.status`, a page's message object, `sms.send_status`,
  `sms.mark_read_result` and `sms.blocked_numbers_result` on the Mac). `mac_actions_draft1` and `camera_draft1` are switches in the apps but
  draft keys on the wire: the vectors pin them once, under the draft keys, and like every draft key
  they read `true` only for JSON `true`. (`remote_input_draft1` predates the shared draft list: a
  non-boolean value still closes the session.) Settings sync (v0.10): both decode `settings.snapshot` and `settings.update` payloads alike
  (`settingsPayload`: records kept, entries skipped one by one, the first-connect flags, invalid messages, unsupported
  schemas), pick the same winner between two records (`settingsMerge`), treat a snapshot record alike (`settingsSnapshot`),
  pick the same device to ask on a first connect (`settingsAsker`) and stamp a local edit alike (`settingsStamp`).
- Fuzz tests on both platforms feed random bytes, truncated and oversized frames, wrong types,
  unknown kinds, replayed IDs and huge counts to the frame decoder and the payload decoders, and
  check that nothing crashes, memory stays bounded and a valid message still works afterwards. The
  normal runs use a bounded iteration count; set `BRIDGEY_FUZZ_ITERATIONS` (and on Android also
  `-Pfuzz=N`) for long runs.

## Changing the protocol

1. Write the change in [protocol.md](protocol.md) first, then add or update the entry in
   `protocol/messages.json` and run `python3 protocol/tools/contract.py --write`.
2. Add golden vectors for the new payload to `protocol/test-vectors/` and decode them on both
   platforms.
3. A new kind needs a feature key (rule 3) unless it only answers a message that already has one.

## Reference

<!-- BEGIN GENERATED: protocol/tools/contract.py --write -->

### Feature keys

| Key | Status | Required in the map | Missing means |
| --- | --- | --- | --- |
| `clipboard` | upstream-v1 | yes | close (invalid feature state) |
| `files` | upstream-v1 | yes | close (invalid feature state) |
| `notifications` | upstream-v1 | yes | close (invalid feature state) |
| `battery` | upstream-v1 | yes | close (invalid feature state) |
| `find_device` | upstream-v1 | yes | close (invalid feature state) |
| `ping` | upstream-v1 | no | false |
| `links` | upstream-v1 | no | false |
| `media` | upstream-v1 | no | false |
| `calls` | upstream-v1 | no | false |
| `clipboard_files_draft1` | edition-draft | no | false |
| `remote_input_draft1` | edition-draft | no | false |
| `sms_codes_draft1` | edition-draft | no | false |
| `folders_draft1` | edition-draft | no | false |
| `places_draft1` | edition-draft | no | false |
| `files_browse_draft1` | edition-draft | no | false |
| `folders_receive_draft1` | edition-draft | no | false |
| `mac_actions_draft1` | edition-draft | no | false |
| `links_open_draft1` | edition-draft | no | false |
| `focus_sync_draft1` | edition-draft | no | false |
| `camera_draft1` | edition-draft | no | false |
| `updates_draft1` | edition-draft | no | false |
| `screen_draft1` | edition-draft | no | false |
| `sms_draft1` | edition-draft | no | false |
| `settings_sync_draft1` | edition-draft | no | false |
| `connect_draft1` | edition-draft | no | false |

### Envelope fields

| Field | Type | Required | Limits and notes |
| --- | --- | --- | --- |
| `kind` | string | yes | minBytes 1; maxBytes 64 |
| `sessionId` | string | yes | maxBytes 128; empty only in pairing.cancel sent before the session ID is known |
| `messageId` | string | no | UUID; required by every encrypted message that uses the replay window. An empty optional string counts as absent |
| `deviceId` | string | no |  |
| `deviceName` | string | no |  |
| `publicKey` | string | no | base64 X9.63 P-256 ephemeral key |
| `identityKey` | string | no | base64 P-256 long-term signing key |
| `proof` | string | no |  |
| `signature` | string | no |  |
| `nonce` | string | no | base64 12-byte AES-GCM nonce |
| `ciphertext` | string | no | base64 AES-GCM ciphertext plus 16-byte tag |
| `transferId` | string | no |  |
| `sequence` | integer | no | min -9007199254740991; max 9007199254740991; an integral JSON number; each kind checks its own range |
| `targetDeviceId` | string | no | edition-extension |
| `commitment` | string | no | protocol 2: base64 SHA-256 commitment to the first-pairing offer's ephemeral key, opened by pairing.reveal; edition-extension |
| `protocolVersion` | integer | no | in pairing.offer and pairing.answer: the highest protocol the sender speaks; absent means 1; edition-extension |
| `reason` | string | no | maxBytes 32; in pairing.cancel: mismatch, cancelled, timeout, busy, rate_limited, not_armed, needs_protocol_2 or not_trusted; older peers send none; edition-extension |
| `tag` | string | no | protocol 2: base64 HMAC-SHA-256 over the sender's device ID and every other envelope field, on every frame after pairing when both ends sent protocolVersion 2; edition-extension |

### Messages

138 kinds. Envelope fields ending in `?` are optional. "Replay" is `messageId` (the shared 256-entry window), `sequence` (a per-feature or per-session high-water mark) or none.

#### `pairing.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `pairing.offer` | upstream-v1 | either | none | no | none | frame | sessionId, deviceId, deviceName, publicKey?, targetDeviceId?, commitment?, protocolVersion? | android, macos |
| `pairing.answer` | upstream-v1 | either | none | no | none | frame | sessionId, deviceId, deviceName, publicKey, protocolVersion? | android, macos |
| `pairing.reveal` | edition-extension | either | none | no | none | frame | sessionId, publicKey | android, macos |
| `pairing.confirm` | upstream-v1 | either | none | no | none | frame | sessionId, deviceId, identityKey, proof, signature | android, macos |
| `pairing.cancel` | upstream-v1 | either | none | no | none | frame | sessionId, reason?, tag? | android, macos |

`pairing.offer`

Sent by the side that dials. targetDeviceId (edition extension) names the trusted peer a reconnect is for; any other receiver closes quietly. Protocol 2: a first pairing sends commitment instead of publicKey, and reveals the key in pairing.reveal after the answer.

`pairing.reveal`

Protocol 2 first pairing: the initiator's ephemeral key after the answer. The responder checks it against the offer's commitment and fails the pairing on a mismatch.

`pairing.confirm`

proof is an HMAC under the pairing key; signature is P-256 over the session transcript.

`pairing.cancel`

Ends only the session it arrives on. reason (edition extension) says why, for the other screen. Tagged when the sender has an envelope key; after authentication only a tagged cancel is taken.

#### `heartbeat.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `heartbeat.ping` | upstream-v1 | either | none | no | none | frame | sessionId, messageId | android, macos |
| `heartbeat.pong` | upstream-v1 | either | none | no | none | frame | sessionId, messageId | android, macos |

`heartbeat.ping`

Answered by `heartbeat.pong`.

`heartbeat.pong`

messageId echoes the ping's. Connection health (both apps) times the round trip from it; health puts nothing new on the wire and has no feature key.

#### `features.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `features.update` | upstream-v1 | either | none | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |

`features.update`

- `version`: integer, 1
- `features`: object of feature key to boolean; see features

Sent after pairing and whenever local policy changes. A feature is available only when both peers report true.

#### `clipboard.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `clipboard.update` | upstream-v1 | either | clipboard | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `clipboard.rich` | upstream-v1 | either | clipboard | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `clipboard.ack` | upstream-v1 | either | clipboard | no | none | frame | sessionId, messageId | android, macos |
| `clipboard.rejected` | upstream-v1 | either | clipboard | no | none | frame | sessionId, messageId | android, macos |
| `clipboard.offer` | edition-draft | either | clipboard_files_draft1 | yes | messageId | 40,960 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `clipboard.fetch` | edition-draft | either | clipboard_files_draft1 | yes | messageId | frame | sessionId, messageId, transferId, nonce, ciphertext | android, macos |
| `clipboard.error` | edition-draft | either | clipboard_files_draft1 | yes | messageId | frame | sessionId, messageId, transferId, nonce, ciphertext | android, macos |

`clipboard.update`

- `(raw)`: UTF-8 text, not JSON, 1 to 32,768 bytes

Answered by `clipboard.ack`, `clipboard.rejected`.

`clipboard.rich`

- `version`: integer, 1
- `text`: string, required, not empty
- `html`: string, optional

Answered by `clipboard.ack`, `clipboard.rejected`.

text plus html at most 32 KiB.

`clipboard.ack`

messageId is the acknowledged message's ID.

`clipboard.rejected`

Clipboard is off locally; followed by features.update.

`clipboard.offer`

- `version`: integer, 1
- `offerId`: string, UUID
- `createdAt`: integer, Unix ms, >= 0
- `sensitive`: boolean, optional
- `items`: array of 1 to 100 {index, kind: text|html|image|file, mime (1 to 255 chars), name? (files, 1 to 255 chars), size (0 to 10 GiB), sha256? (base64 of 32 bytes), inline? (base64, all inline items at most 16 KiB decoded)}

Answered by `clipboard.ack`, `clipboard.rejected`.

`clipboard.fetch`

- `version`: integer, 1
- `offerId`: string, UUID
- `index`: integer, item index
- `transferId`: string, UUID chosen by the receiver

Answered by `files.offer`, `clipboard.error`.

`clipboard.error`

- `version`: integer, 1
- `offerId`: string
- `index`: integer
- `transferId`: string
- `code`: expired | changed | too_large | unavailable | disabled | busy

#### `files.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `files.offer` | upstream-v1 | either | files | yes | messageId | frame | sessionId, messageId, transferId, nonce, ciphertext | android, macos |
| `files.accept` | upstream-v1 | either | files | no | none | frame | sessionId, transferId | android, macos |
| `files.rejected` | upstream-v1 | either | files | no | none | frame | sessionId, transferId | android, macos |
| `files.chunk` | upstream-v1 | either | files | yes | none | frame | sessionId, transferId, sequence, nonce, ciphertext | android, macos |
| `files.chunk.ack` | upstream-v1 | either | files | no | none | frame | sessionId, transferId, sequence | android, macos |
| `files.complete` | upstream-v1 | either | files | yes | messageId | frame | sessionId, messageId, transferId, nonce, ciphertext | android, macos |
| `files.complete.ack` | upstream-v1 | either | files | no | none | frame | sessionId, transferId | android, macos |
| `files.cancel` | upstream-v1 | either | files | no | none | frame | sessionId, transferId | android, macos |
| `files.cancel.ack` | upstream-v1 | either | files | no | none | frame | sessionId, transferId | android, macos |

`files.offer`

- `transferId`: string, UUID
- `name`: string, display name, last path component only
- `mimeType`: string
- `size`: integer, bytes >= 0
- `sha256`: string, base64 (optional for clipboard purpose)
- `purpose`: edition extension: "clipboard" with offerId and index
- `folderTransferId`: edition extension (folders_draft1)
- `entry`: edition extension: manifest index
- `path`: edition extension: manifest path
- `cameraRequestId`: edition extension (camera_draft1): string, UUID of the Mac's open camera.request that this photo answers; older Macs ignore it and simply receive a file

Answered by `files.accept`, `files.rejected`.

`files.rejected`

Files is off locally; sent without decrypting the offer, followed by features.update.

`files.chunk`

- `(raw)`: file bytes, at most 24 KiB per chunk, sequence from 0 without gaps

`files.chunk.ack`

Cumulative. The Mac keeps at most 64 chunks unacknowledged.

`files.complete`

- `transferId`: string
- `sha256`: string, base64 SHA-256 of all bytes

Answered by `files.complete.ack`.

`files.cancel`

Answered by `files.cancel.ack`.

Idempotent.

#### `notifications.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `notifications.post` | upstream-v1 | phone-to-mac | notifications | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |
| `notifications.remove` | upstream-v1 | phone-to-mac | notifications | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |
| `notifications.dismiss` | upstream-v1 | mac-to-phone | notifications | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |
| `notifications.action` | upstream-v1 | mac-to-phone | notifications | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |

`notifications.post`

- `packageName`: string, at most 256
- `applicationName`: string, at most 128
- `notificationId`: string, opaque, at most 512
- `title`: string, at most 1,024
- `text`: string, at most 8,192
- `timestamp`: integer, Unix ms
- `applicationIcon`: string, optional base64 PNG, at most 28 KiB encoded
- `callType`: optional: incoming | ongoing | screening | unknown
- `actions`: array of at most 4 {actionToken (at most 64), title (at most 64), allowsReply}
- `smsDefaultApp`: boolean, edition extension (sms_codes_draft1)
- `redacted`: boolean, edition extension, only with smsDefaultApp true
- `smsReply`: boolean, edition extension (sms_draft1), only to a Mac that shows the key: the phone answers this notification by sms.send with notificationId
- `smsThreadId`: integer, optional, edition extension (sms_draft1): the conversation the message belongs to, when the phone found it

Content is sensitive and never logged.

`notifications.remove`

- `notificationId`: string, at most 512
- `callEnded`: boolean, optional, edition extension

`notifications.dismiss`

- `notificationId`: string, at most 512

`notifications.action`

- `notificationId`: string, at most 512
- `actionToken`: string, at most 64
- `replyText`: string, optional, at most 4,096

Android runs only tokens it retained for the still active notification.

#### `codes.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `codes.status` | edition-draft | phone-to-mac | sms_codes_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `codes.link_request` | edition-draft | mac-to-phone | sms_codes_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `codes.advertise` | edition-draft | phone-to-mac | sms_codes_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `codes.advertise_result` | edition-draft | mac-to-phone | sms_codes_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `codes.advertise_stop` | edition-draft | phone-to-mac | sms_codes_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |

`codes.status`

- `version`: integer, 1
- `status`: allowed | hidden | not_linked

`codes.link_request`

- `version`: integer, 1

`codes.advertise`

- `version`: integer, 1
- `serviceUuid`: string, random UUID per attempt

Answered by `codes.advertise_result`.

`codes.advertise_result`

- `version`: integer, 1
- `serviceUuid`: string
- `ok`: boolean
- `reason`: when not ok: bluetooth_off | unauthorized | unsupported | failed

`codes.advertise_stop`

- `version`: integer, 1
- `serviceUuid`: string
- `linked`: boolean

#### `quick.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `quick.request` | upstream-v1 | either | links \| media | yes | sequence | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `quick.result` | upstream-v1 | either | links \| media | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |

`quick.request`

- `version`: integer, 1
- `requestId`: string, UUID
- `feature`: links | media
- `action`: string (links: offer, or open to a Mac that advertises links_open_draft1; media: toggle | pause | next | previous | seek | volume)
- `value`: string (links: http(s) URL, at most 4,096 bytes; seek 0 to 604800; volume 0 to 100)
- `sequence`: integer, 1 to 2^53-1, per feature high-water mark

Answered by `quick.result`.

Edition extension (links_open_draft1): Open on Mac sends links action open. The Mac opens the link at once only when its own Open links from phones right away setting is on (off by default), at most one link per phone every 3 seconds; otherwise it queues the link like offer.

`quick.result`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `feature`: string, echoes the request
- `accepted`: boolean
- `opened`: edition extension (links_open_draft1): boolean, true when the Mac opened the link right away; older phones ignore it

#### `media.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `media.state` | upstream-v1 | mac-to-phone | media | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.list` | edition-draft | mac-to-phone | files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.page` | edition-draft | phone-to-mac | files_browse_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.thumbnails` | edition-draft | mac-to-phone | files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.thumbnails_batch` | edition-draft | phone-to-mac | files_browse_draft1 | yes | messageId | 45,056 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.preview` | edition-draft | mac-to-phone | files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.preview_part` | edition-draft | phone-to-mac | files_browse_draft1 | yes | messageId | 45,056 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.range` | edition-draft | mac-to-phone | files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.range_part` | edition-draft | phone-to-mac | files_browse_draft1 | yes | messageId | 45,056 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `media.cancel` | edition-draft | mac-to-phone | files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |

`media.state`

- `version`: integer, 1
- `player`: string
- `title`: string, at most 256 chars
- `artist`: string, at most 256 chars
- `playing`: boolean
- `position`: integer, 0 to 604800
- `duration`: integer, 0 to 604800
- `volume`: integer, 0 to 100
- `detail`: string, bounded
- `artwork`: string, optional base64 JPEG, at most 16 KiB, at most 128x128

`media.list`

- `version`: integer, 1
- `requestId`: string, UUID
- `kind`: media (photos and videos, newest first) | files (recent documents in indexed places) | recent (both)
- `cursor`: string or null, opaque
- `limit`: integer, 1 to 200, default 100

Answered by `media.page`, `places.error`.

Browse lane.

`media.page`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `kind`: string, echoes the request
- `items`: array of {ref, name, size, modified (Unix ms), mimeType, width, height, durationMs (null when unknown), thumb (boolean), location (display path, at most 128 characters), taken (Unix ms the gallery sorts by: date taken, else added; optional, for day headers)}
- `nextCursor`: string or null
- `access`: full | partial | none (photo and video access; none returns no media items)
- `indexing`: boolean, the document index is refreshing

Askers cache by device ID, ref, modified and size: the same four always mean the same bytes.

`media.thumbnails`

- `version`: integer, 1
- `requestId`: string, UUID
- `items`: array of 1 to 64 {key (1 to 64 of [A-Za-z0-9_-], chosen by the asker), ref}
- `size`: integer, longest edge 64 to 512, default 256
- `replaces`: string, optional, requestId of an earlier media request it cancels

Answered by `media.thumbnails_batch`, `places.error`.

Media lane: 4 active and 60 per 10 s, else busy. Answers are low priority: sent only while no file chunk, acknowledgement or control message waits.

`media.thumbnails_batch`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `thumbs`: array of {key, mimeType (image/webp from Android 11, else image/jpeg), width, height, tint (#rrggbb average colour), data (base64, at most 24 KiB decoded)}
- `missing`: array of keys without a thumbnail
- `done`: boolean, true on the last batch

In the order they are ready (made in the order asked, visible items first); askers match thumbnails by key. As many as fit in each batch. 45,056 bytes of plaintext keep the frame under the 65,536-byte limit after AES-GCM and base64.

`media.preview`

- `version`: integer, 1
- `requestId`: string, UUID
- `ref`: ref
- `size`: integer, longest edge 512 to 2048
- `replaces`: string, optional

Answered by `media.preview_part`, `places.error`.

Media lane. Videos answer with the poster frame. Errors not_found, unsupported.

`media.preview_part`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `index`: integer, from 0
- `count`: integer, parts in all
- `mimeType`: string
- `width`: integer
- `height`: integer
- `tint`: string, #rrggbb
- `data`: string, base64, at most 32 KiB decoded per part

Consecutive parts; the whole preview is at most 1 MiB.

`media.range`

- `version`: integer, 1
- `requestId`: string, UUID
- `ref`: ref to a file, not a folder
- `offset`: integer, >= 0
- `length`: integer, 1 to 4 MiB
- `replaces`: string, optional

Answered by `media.range_part`, `places.error`.

Media lane. Ranges are previews (hover prefetch, streamed playback) and carry no hash; a saved copy always goes through places.download.

`media.range_part`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `offset`: integer, of this part
- `fileSize`: integer, the whole file
- `modified`: integer, Unix ms, the whole file
- `data`: string, base64, at most 32 KiB decoded
- `last`: boolean, end of the range or of the file

`media.cancel`

- `version`: integer, 1
- `requestId`: string, the media request to cancel

Not answered. Parts already on the wire may still arrive and are dropped by the asker.

#### `battery.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `battery.update` | upstream-v1 | either | battery | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |

`battery.update`

- `level`: integer, 0 to 100
- `isCharging`: boolean

#### `find.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `find.start` | upstream-v1 | either | find_device | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |
| `find.stop` | upstream-v1 | either | find_device | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |
| `find.started` | upstream-v1 | either | find_device | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |
| `find.stopped` | upstream-v1 | either | find_device | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |

`find.start`

- `alertId`: string, opaque

Answered by `find.started`, `find.stopped`.

`find.stop`

- `alertId`: string, opaque

Answered by `find.stopped`.

`find.started`

- `alertId`: string, opaque

`find.stopped`

- `alertId`: string, opaque

#### `ping.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `ping.request` | upstream-v1 | either | ping | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |
| `ping.ack` | upstream-v1 | either | ping | no | none | frame | sessionId, messageId | android, macos |

`ping.request`

- `version`: integer, 1

Answered by `ping.ack`.

`ping.ack`

messageId is the request's ID. Senders time out after five seconds.

#### `calls.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `calls.request` | upstream-v1 | mac-to-phone | calls | yes | messageId | frame | sessionId, messageId, nonce, ciphertext | android, macos |
| `calls.started` | upstream-v1 | phone-to-mac | calls | no | none | frame | sessionId, messageId | android, macos |
| `calls.confirmation_required` | upstream-v1 | phone-to-mac | calls | no | none | frame | sessionId, messageId | android, macos |
| `calls.rejected` | upstream-v1 | phone-to-mac | calls | no | none | frame | sessionId, messageId | android, macos |

`calls.request`

- `number`: string, 3 to 15 digits with optional leading +; spaces, parentheses, dots and hyphens are removed

Answered by `calls.started`, `calls.confirmation_required`, `calls.rejected`.

At most one request every three seconds.

#### `input.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `input.session.start` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.session.started` | edition-draft | host-to-controller | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.session.heartbeat` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.session.stop` | edition-draft | either | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.pointer` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.button` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.scroll` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.drag` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.text` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.key` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `input.present` | edition-draft | controller-to-host | remote_input_draft1 | yes | sequence | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |

`input.session.start`

- `version`: integer, 1
- `inputSessionId`: string, UUID, used once
- `sequence`: integer, 1 to 2^53-1
- `mode`: touchpad | presentation

Answered by `input.session.started`, `input.session.stop`.

A phone that receives it answers input.session.stop, reason unsupported.

`input.session.started`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `heartbeatSeconds`: integer, 2
- `idleSeconds`: integer, 6
- `limits`: {motion: 120, discrete: 20, text: 256}

`input.session.heartbeat`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer

`input.session.stop`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `reason`: user | left_screen | screen_off | local_stop | timeout | disabled | permission_required | busy | invalid | unsupported

`input.pointer`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `dx`: integer, -512 to 512
- `dy`: integer, -512 to 512, not both 0

`input.button`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `button`: left | right | middle
- `action`: down | up

`input.scroll`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `dx`: integer
- `dy`: integer, not both 0
- `unit`: pixel (-1,000 to 1,000) | line (-10 to 10)

`input.drag`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `phase`: start | move | end
- `dx`: integer with move, pointer bounds
- `dy`: integer with move, pointer bounds

`input.text`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `text`: string, 1 to 256 scalars, at most 1,024 UTF-8 bytes, no Cc characters; never logged

`input.key`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `key`: left | right | up | down | return | escape | tab | space | backspace | page_up | page_down | home | end | f5 | previous_app
- `modifiers`: optional: [] or ["shift"] (not with previous_app)

`input.present`

- `version`: integer, 1
- `inputSessionId`: string
- `sequence`: integer
- `action`: next | previous | start | end | black | laser_on | laser_move | laser_off
- `x`: integer 0 to 10,000 with laser_on and laser_move
- `y`: integer 0 to 10,000 with laser_on and laser_move

#### `actions.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `actions.catalog` | edition-draft | mac-to-phone | mac_actions_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `actions.run` | edition-draft | phone-to-mac | mac_actions_draft1 | yes | sequence | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `actions.result` | edition-draft | mac-to-phone | mac_actions_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |

`actions.catalog`

- `version`: integer, 1
- `actions`: array of at most 64 {id, title, blocked?}. id: lock | sleep | screensaver | volume_up | volume_down | volume_mute | volume_set | app:<bundle id, [A-Za-z0-9.-], 1 to 155> | shortcut:<lowercase UUID>. title: 1 to 64 characters, no control characters, required for app: and shortcut: (phones show their own titles for the fixed ids). blocked: only permission_required (Lock without Accessibility)
- `volume`: optional {level: integer 0 to 100, muted: boolean}, while volume is allowed and the output has a settable volume

What this phone may run now; it replaces the previous list. Sent after each features.update that shows the key on both sides, and whenever the list, a switch, the grant or a permission changes. The phone drops single entries with an unknown id, a missing or bad title or a repeated id, and the whole catalog for a wrong version or more than 64 entries.

`actions.run`

- `version`: integer, 1
- `requestId`: string, UUID
- `action`: string, an id from the latest catalog
- `sequence`: integer, 1 to 2^53-1, per session high-water mark, checked after the messageId window
- `value`: integer 0 to 100, with volume_set only

Answered by `actions.result`.

Only an identifier from the Mac's own list goes on the wire: no command, argument, Shortcut name or text. A run that fails the version, requestId or sequence check is dropped; anything else gets exactly one actions.result. Rate limits per phone: volume 10 at once then 5 a second, other actions 3 at once then one every 2 seconds. The phone waits 10 seconds for the result (70 for a Shortcut), then reports it not confirmed.

`actions.result`

- `version`: integer, 1
- `requestId`: string, echoes the run
- `action`: string, echoes the run
- `status`: done | refused
- `reason`: with refused: not_allowed | invalid | rate_limited | busy | permission_required | unavailable | failed; phones read anything else as failed
- `volume`: optional {level, muted}: the volume after a volume action

The Mac keeps a private audit log of every run and refusal (owner-only, 30 days, at most 500 entries, never the value).

#### `focus.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `focus.state` | edition-draft | either | focus_sync_draft1 | yes | messageId | 256 B | sessionId, messageId, nonce, ciphertext | android, macos |

`focus.state`

- `version`: integer, 1
- `active`: boolean: the phone's Do Not Disturb (any interruption filter but all), or the Mac's Focus

Sent only while the sender's share switch is on and the peer's latest map shows the key: once after each features.update that shows it on both sides, then on every change. Applied only while the receiver's follow switch is on; a follower does not report the change it just made for 10 seconds, so two followers cannot loop.

#### `camera.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `camera.request` | edition-draft | mac-to-phone | camera_draft1 | yes | messageId | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `camera.status` | edition-draft | phone-to-mac | camera_draft1 | yes | messageId | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |

`camera.request`

- `version`: integer, 1
- `requestId`: string, UUID
- `mode`: photo

Answered by `camera.status`.

One open request per Mac, at most one every 3 seconds; it expires after 2 minutes. The phone opens the camera only when unlocked and after a tap. A malformed request is dropped without an answer.

`camera.status`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `status`: opened | locked | permission_required | cancelled | busy | disabled | sending | failed; the Mac drops an unknown status

The photo itself arrives as a files.offer carrying cameraRequestId.

#### `updates.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `updates.status` | edition-draft | either | updates_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `updates.start` | edition-draft | either | updates_draft1 | yes | messageId | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `updates.result` | edition-draft | either | updates_draft1 | yes | messageId | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |

`updates.status`

- `version`: integer, 1
- `platform`: android | macos
- `edition`: string, 1 to 32 UTF-8 bytes, rr for this edition
- `app`: string, installed version name, 1 to 64 UTF-8 bytes
- `build`: integer, installed build number, 1 to 2^53-1
- `channel`: stable | beta | nightly
- `state`: current | checking | available | downloading | ready | installing | needs_user | failed | manual
- `target`: string, optional, the version on offer, 1 to 64 UTF-8 bytes (available, downloading, ready, installing, needs_user; failed when known)
- `targetBuild`: integer, optional, with target, 1 to 2^53-1
- `progress`: integer, optional, 0 to 100, with downloading
- `reason`: optional: with needs_user confirm | permission; with failed check | download | safety | installer | cancelled | not_applied | other; unknown reads as other
- `remoteStart`: boolean: Let paired devices start updates on this device is on and the updater can run
- `checkedAt`: integer, Unix ms of the last successful check, 0 for never
- `auto`: boolean, optional, default false: Update all devices automatically is on there and its updater can run
- `busy`: string, optional: what the person is doing there, so automatic updates wait: call | screen_share | remote_control | transfer | phone_files | setup; unknown reads as other (still busy)

Sent once after each features.update that shows the key on both sides, then on every change of a field other than progress, and while downloading at most once a second. A receiver drops a status with an unknown state, platform or channel, an auto that is not a boolean or a busy that is not a string. auto is written only when true, busy only when set.

`updates.start`

- `version`: integer, 1
- `requestId`: string, UUID
- `retry`: boolean, optional, default false: the person tapped Retry for this device
- `auto`: boolean, optional, default false: started automatically (nobody tapped Update all); the receiver names the device that started it

Answered by `updates.result`.

Update yourself now from your own channel. It names no version, URL, file or channel: the receiver checks its own feed and installs only a newer build through its own checks (Android SHA-256 and signer, Mac Sparkle EdDSA), so it can never downgrade. Accepted only from a paired device whose map shows the key, while the receiver's Let paired devices start updates switch is on; at most one start every 30 seconds and five an hour per device. A start with a wrong version or a requestId that is not a UUID is dropped; anything else gets exactly one updates.result. Without retry, a device whose last attempt did not apply refuses not_applied. With auto, a device whose person is busy (a call, a screen share, remote control, a transfer, a Phone files download, setup or pairing) refuses busy.

`updates.result`

- `version`: integer, 1
- `requestId`: string, echoes the start
- `status`: accepted | refused
- `reason`: with refused: disabled | rate_limited | manual | not_applied | busy (its updater cannot start now, or an automatic start found its person busy); senders read anything else as other

accepted also when an update was already running. Progress follows as updates.status.

#### `screen.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `screen.request` | edition-draft | mac-to-phone | screen_draft1 | yes | messageId | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `screen.status` | edition-draft | phone-to-mac | screen_draft1 | yes | messageId | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `screen.start` | edition-draft | phone-to-mac | screen_draft1 | yes | sequence | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `screen.started` | edition-draft | mac-to-phone | screen_draft1 | yes | sequence | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `screen.frame` | edition-draft | phone-to-mac | screen_draft1 | yes | sequence | 32,808 B | sessionId, nonce, ciphertext | android, macos |
| `screen.ack` | edition-draft | mac-to-phone | screen_draft1 | yes | sequence | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `screen.stats` | edition-draft | phone-to-mac | screen_draft1 | yes | sequence | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `screen.stop` | edition-draft | either | screen_draft1 | yes | sequence | 512 B | sessionId, messageId, nonce, ciphertext | android, macos |

`screen.request`

- `version`: integer, 1
- `requestId`: string, UUID

Answered by `screen.status`, `screen.start`.

Phone screen on the Mac. One open request per phone, at most one every 3 seconds; it expires after 2 minutes. The phone always needs a tap and Android's consent; it answers screen.status and, once the person confirms, screen.start with the requestId. A malformed request is dropped without an answer.

`screen.status`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `status`: waiting | declined | busy | disabled | failed; the Mac drops an unknown status

`screen.start`

- `version`: integer, 1
- `streamId`: string, UUID chosen by the phone, used once
- `sequence`: integer, 1 to 2^53-1, the phone's stream sequence (1 here)
- `requestId`: optional string, UUID of the Mac's screen.request this answers
- `codec`: h264
- `width`: integer, even, 16 to 4096
- `height`: integer, even, 16 to 4096
- `fps`: integer, 1 to 60
- `bitrate`: integer, bits a second, 100000 to 50000000

Answered by `screen.started`, `screen.stop`.

The Mac refuses with screen.stop (disabled, invalid). It ignores a start whose streamId is one of the last 16 that ended.

`screen.started`

- `version`: integer, 1
- `streamId`: string
- `sequence`: integer, the Mac's stream sequence

The phone sends frames only after it and stops with timeout after 5 seconds without it.

`screen.frame`

- `(raw)`: 40-byte big-endian header (version 1, flags: bit 0 key frame, bit 1 starts with SPS and PPS, bit 2 last part; part 0 to 63; 16-byte stream ID; sequence 1 to 2^53-1; frame 1 to 2^32-1; capture time 0 to 2^63-1 microseconds) then 1 to 32768 bytes of H.264 Annex B

One part of one access unit; parts in order, part 0 starts with a start code, at most 64 parts. Not in the messageId window: the header sequence is the replay guard. An undecryptable or malformed frame is dropped and the session stays.

`screen.ack`

- `version`: integer, 1
- `streamId`: string
- `sequence`: integer
- `frame`: integer, 1 to 2^32-1, newest frame received completely and decoded
- `decodeMs`: integer, 0 to 60000
- `keyframe`: optional boolean, true asks for a key frame (at most one a second)

Paces the phone: at most 6 frames and max(64 KiB, 250 ms at the bit rate) unacknowledged.

`screen.stats`

- `version`: integer, 1
- `streamId`: string
- `sequence`: integer
- `latencyMs`: integer, 0 to 60000
- `rttMs`: integer, 0 to 60000
- `bitrate`: integer, 0 to 50000000
- `sentBitrate`: integer, 0 to 50000000
- `fps`: integer, 0 to 120
- `dropped`: integer, 0 to 1000

Once a second while streaming; shown in the Mac window.

`screen.stop`

- `version`: integer, 1
- `streamId`: string
- `sequence`: integer
- `reason`: user | closed | ended | screen_off | disabled | invalid | timeout | failed; an unknown reason reads as failed

Either side ends the stream. A Mac refusing a start sends it with the start's streamId and its own sequence 1.

#### `sms.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `sms.status` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.changed` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 256 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.threads` | edition-draft | mac-to-phone | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.threads_page` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 40,960 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.messages` | edition-draft | mac-to-phone | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.messages_page` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 40,960 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.sync` | edition-draft | mac-to-phone | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.sync_page` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 40,960 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.send` | edition-draft | mac-to-phone | sms_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.send_status` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.attachment` | edition-draft | mac-to-phone | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.attachment_data` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 40,960 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.contacts` | edition-draft | mac-to-phone | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.contacts_result` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 16,384 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.mark_read` | edition-draft | mac-to-phone | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.mark_read_result` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 4,096 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.blocked_numbers` | edition-draft | mac-to-phone | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `sms.blocked_numbers_result` | edition-draft | phone-to-mac | sms_draft1 | yes | messageId | 1,024 B | sessionId, messageId, nonce, ciphertext | android, macos |

`sms.status`

- `version`: integer, 1
- `read`: boolean, READ_SMS allowed
- `send`: boolean, SEND_SMS allowed
- `contacts`: boolean, READ_CONTACTS allowed
- `sims`: array of at most 4 {subId (integer), slot (0 to 3), label (at most 64)}; empty when the phone cannot list them; an invalid entry is dropped
- `cursor`: {sms, mms}: integers, the newest _id in each SMS provider table

Sent after each features.update that shows the key on both sides, and when a permission or the SIM list changes.

`sms.changed`

- `version`: integer, 1
- `cursor`: {sms, mms}: integers, the newest _id in each SMS provider table

The SMS provider changed (a ContentObserver, only while a Mac shows the key), at most one every 2 seconds. The Mac asks sms.sync when the cursor is ahead of its own and refreshes an open conversation.

`sms.threads`

- `version`: integer, 1
- `requestId`: string, UUID
- `before`: integer, optional, Unix ms, exclusive (absent: the newest)
- `limit`: integer, 1 to 50

Answered by `sms.threads_page`.

`sms.threads_page`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `threads`: array, newest first, of {threadId, participants (1 to 10 {address (at most 64), name (optional, at most 128)}), snippet (at most 160), date (Unix ms), unread (integer), subId (optional)}
- `more`: boolean
- `error`: optional: disabled | permission (threads is then empty)

The phone stops adding entries before the plaintext limit and sets more.

`sms.messages`

- `version`: integer, 1
- `requestId`: string, UUID
- `threadId`: integer, at least 1
- `before`: optional {date (Unix ms), id}, exclusive, ordered by date then id (absent: the newest)
- `limit`: integer, 1 to 100

Answered by `sms.messages_page`.

`sms.messages_page`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `threadId`: integer
- `messages`: array, newest first, of {id (s<n> or m<n>, at most 24), threadId, direction: in | out, status: received | pending | sent | delivered | failed (an unknown status reads as received or sent), date (Unix ms), address (at most 64; the other side, empty for an outgoing MMS), body (at most 4,000 UTF-16 units), truncated (optional boolean), subId (optional integer), read (optional boolean, default true), parts (optional, at most 8 images {partId (p<n>), mimeType image/*, size?})}; an invalid message is dropped
- `more`: boolean
- `error`: optional: disabled | permission | not_found

`sms.sync`

- `version`: integer, 1
- `requestId`: string, UUID
- `since`: {sms, mms}: integers, the newest _id in each SMS provider table, from the Mac's cache
- `limit`: integer, 1 to 200

Answered by `sms.sync_page`.

`sms.sync_page`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `messages`: array of messages newer than since (any order; the Mac sorts), as in sms.messages_page
- `cursor`: {sms, mms}: integers, the newest _id in each SMS provider table: where the next sms.sync starts
- `more`: boolean
- `reset`: boolean: since is ahead of the phone or over 1,000 messages behind; the Mac drops its cache and loads the threads again
- `error`: optional: disabled | permission

Each table is read in _id order, so the cursor never skips a message.

`sms.send`

- `version`: integer, 1
- `requestId`: string, UUID
- `body`: string, 1 to 2,000 UTF-16 units, not only spaces
- `threadId`: integer, one of threadId, address and notificationId
- `address`: string, a phone number: + and 2 to 20 digits once spaces, dashes, dots and brackets are removed
- `notificationId`: string, at most 512: answers an SMS notification that carried smsReply
- `subId`: integer, optional: the SIM to send from (default: the thread's last SIM, else the phone's default)

Answered by `sms.send_status`.

One recipient only: a conversation with several people is refused (group). Emergency numbers are refused (invalid). At most one per second and 30 in 10 minutes per Mac. Bridgey never becomes the default SMS app; Android writes the sent message to the SMS provider. A reply to a notification goes through the messaging app's own reply when it has one, unless the phone's Send replies as SMS is on.

`sms.send_status`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `status`: sending | sent | delivered | failed | refused; the Mac drops an unknown status
- `reason`: with failed or refused: disabled | permission | invalid | group | no_sim | rate_limited | not_found | radio_off | no_service | failed (an unknown or missing reason reads as failed)
- `via`: optional: sms (SmsManager) | app (the messaging app's reply)

Several per request: sending, then sent or failed, then delivered when the network reports it.

`sms.attachment`

- `version`: integer, 1
- `requestId`: string, UUID
- `partId`: string, p<n>

Answered by `sms.attachment_data`.

Read-only MMS images. At most 4 open requests per Mac.

`sms.attachment_data`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `partId`: string
- `mimeType`: image/jpeg
- `width`: integer
- `height`: integer
- `data`: string, base64 JPEG of at most 28,672 bytes, scaled down on the phone
- `error`: optional: not_found | unsupported | permission (no image fields)

The Mac keeps images in memory only.

`sms.contacts`

- `version`: integer, 1
- `requestId`: string, UUID
- `query`: string, 1 to 64 UTF-16 units

Answered by `sms.contacts_result`.

`sms.contacts_result`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `contacts`: array of at most 20 {name (at most 128), address (at most 64), label (optional, at most 32)}
- `error`: optional: permission (contacts is then empty)

`sms.mark_read`

- `version`: integer, 1
- `requestId`: string, UUID
- `threadIds`: array of 1 to 50 integers, each at least 1 (repeats count once)

Answered by `sms.mark_read_result`.

Read on the Mac: the phone runs the messaging app's own Mark as read (Notification.Action SEMANTIC_ACTION_MARK_AS_READ) on each notification it still shows for those conversations. Bridgey never writes to the SMS provider; a conversation without a notification stays unread on the phone.

`sms.mark_read_result`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `results`: array of at most 50 {threadId (integer), result: marked | not_shown | no_action | failed (an unknown result reads as failed)}; an invalid entry is dropped
- `error`: optional: disabled (results is then empty)

`sms.blocked_numbers`

- `version`: integer, 1
- `requestId`: string, UUID
- `address`: string, optional, the number to block as in sms.send (shown to the person, never written by Bridgey)

Answered by `sms.blocked_numbers_result`.

Opens Android's own Blocked numbers screen (TelecomManager.createManageBlockedNumbersIntent): at once when Bridgey is in front, otherwise through a Bridgey notification the person taps. Only the default dialer or SMS app may write the blocked list, so the person adds the number there.

`sms.blocked_numbers_result`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `result`: opened | notified | unavailable (an unknown result reads as unavailable)

#### `connect.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `connect.setup` | edition-draft | either | connect_draft1 | yes | messageId | 256 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `connect.setup.ack` | edition-draft | either | connect_draft1 | yes | messageId | 64 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `connect.addresses` | edition-draft | either | connect_draft1 | yes | messageId | 2,048 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `connect.offer` | designed | either | connect_draft1 | yes | messageId | 4,096 B | sessionId, messageId, nonce, ciphertext | not yet |
| `connect.answer` | designed | either | connect_draft1 | yes | messageId | 4,096 B | sessionId, messageId, nonce, ciphertext | not yet |
| `connect.candidates` | designed | either | connect_draft1 | yes | messageId | 4,096 B | sessionId, messageId, nonce, ciphertext | not yet |
| `connect.restart` | designed | either | connect_draft1 | yes | messageId | 512 B | sessionId, messageId, nonce, ciphertext | not yet |
| `connect.bye` | designed | either | connect_draft1 | yes | messageId | 256 B | sessionId, messageId, nonce, ciphertext | not yet |
| `connect.route` | designed | either | connect_draft1 | yes | messageId | 256 B | sessionId, messageId, nonce, ciphertext | not yet |

`connect.setup`

- `version`: integer, 1
- `contribution`: string, base64 of 32 random bytes
- `rotate`: optional boolean (Reset away-from-home identity); missing means false

Answered by `connect.setup`, `connect.setup.ack`.

Creates the pair secret: each side sends its contribution once per exchange (a side that receives one first answers with its own), then pairSecret = HKDF-SHA256(cLow || cHigh, salt bridgey-pair-secret-v1, info idLow 0x00 idHigh, 32). Started by the lower device ID when its pair check differs from the peer's connect.addresses. A malformed payload is dropped and the session stays.

`connect.setup.ack`

- `version`: integer, 1

Informational: the sender holds the new pair secret.

`connect.addresses`

- `version`: integer, 1
- `port`: integer 1 to 65535, the sender's UDP port
- `addrs`: array of at most 16 {a: IP address string, kind: lan | vpn | public6, vpn?: tailscale | other}; entries with an unknown kind or an unusable address are skipped
- `pairCheck`: optional string, base64url of HMAC-SHA256(pairSecret, bridgey-pair-check-v1)[0..8]; absent without a pair secret

Sent after every features.update that shows the key on both sides and whenever the sender's addresses change. The receiver keeps at most 16 per peer (30 days) and dials them over QUIC when the peer is away. The pair check never reveals the secret.

`connect.offer`

- `version`: integer, 1
- `sid`: string, base64url 16 bytes
- `ufrag`: 8 characters
- `pwd`: 24 characters
- `cands`: at most 24 candidates
- `cert`: certSha256

In-band ICE (spec 4.4). Phase 1 signals ICE through the control service only.

`connect.answer`

- `version`: integer, 1
- `sid`: as connect.offer
- `ufrag`: 8 characters
- `pwd`: 24 characters
- `cands`: at most 24 candidates
- `cert`: certSha256

`connect.candidates`

- `sid`: string
- `cands`: at most 24 candidates
- `done`: boolean

`connect.restart`

- `sid`: string
- `ufrag`: 8 characters
- `pwd`: 24 characters
- `reason`: network_change | path_failed | relay_switch

`connect.bye`

- `sid`: string
- `reason`: string

`connect.route`

- `version`: integer, 1
- `route`: lan | vpn | direct | relay
- `relay`: optional relay ID
- `rttMs`: integer

Informational. Phase 1 shows each side's own route from its core instead.

#### `places.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `places.list` | edition-draft | mac-to-phone | places_draft1 \| files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.listed` | edition-draft | phone-to-mac | places_draft1 \| files_browse_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.browse` | edition-draft | mac-to-phone | places_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.children` | edition-draft | phone-to-mac | places_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.create_folder` | edition-draft | mac-to-phone | places_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.folder_created` | edition-draft | phone-to-mac | places_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.error` | edition-draft | phone-to-mac | places_draft1 \| files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.files` | edition-draft | mac-to-phone | files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.files_page` | edition-draft | phone-to-mac | files_browse_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.download` | edition-draft | mac-to-phone | files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.download_started` | edition-draft | phone-to-mac | files_browse_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |

`places.list`

- `version`: integer, 1
- `requestId`: string, UUID
- `purpose`: optional "browse" (files_browse_draft1): every place whatever the destination mode, plus writable, media and documents in the answer

Answered by `places.listed`, `places.error`.

`places.listed`

- `version`: integer, 1
- `requestId`: string
- `mode`: sender_picks | receiver_asks | fixed
- `places`: array of at most 17 {placeId, label (64), available, freeBytes}
- `fixedLabel`: string
- `defaultFreeBytes`: integer or null, free bytes where a send would land by default (every answer)
- `writable`: boolean, purpose browse only: "Allow other devices to change files here"
- `media`: purpose browse only: full | partial | none (photo and video access)
- `documents`: boolean, purpose browse only: at least one place is indexed for recent documents

`places.browse`

- `version`: integer, 1
- `requestId`: string
- `placeId`: string
- `path`: string, portable path
- `cursor`: string or null

Answered by `places.children`, `places.error`.

`places.children`

- `version`: integer, 1
- `requestId`: string
- `placeId`: string
- `path`: string
- `folders`: array of folder names, at most 500 per page
- `fileCount`: integer
- `folderCount`: integer
- `nextCursor`: string or null

`places.create_folder`

- `version`: integer, 1
- `requestId`: string
- `placeId`: string
- `path`: string
- `name`: string, portable name

Answered by `places.folder_created`, `places.error`.

`places.folder_created`

- `version`: integer, 1
- `requestId`: string
- `placeId`: string
- `path`: string
- `name`: string

`places.error`

- `version`: integer, 1
- `requestId`: string
- `code`: error code, see docs/protocol.md (browse adds read_only)

Also the failure answer to every browse request (places.files, media.*, places.download). Browse requests from a Mac whose files_browse_draft1 the phone did not advertise answer unsupported; over a lane budget, busy.

`places.files`

- `version`: integer, 1
- `requestId`: string, UUID
- `placeId`: string, default or a granted place
- `path`: string, existing path
- `cursor`: string or null, opaque, from the previous page
- `sort`: name (default) | modified | size | kind
- `descending`: boolean

Answered by `places.files_page`, `places.error`.

Browse lane: 4 in flight and 40 per 10 s, else busy; answered within 8 s. Served in every folder destination mode. Errors not_found, place_unavailable, policy.

`places.files_page`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `placeId`: string
- `path`: string
- `entries`: array of at most 200 {name (one existing component, 1 to 255 bytes), dir (boolean), size (integer, null for folders), modified (Unix ms or null), mimeType (null for folders), thumb (boolean)}
- `folderCount`: integer
- `fileCount`: integer
- `nextCursor`: string or null
- `writable`: boolean

Folders first, then files, each in sort order (names case-insensitive, then exact). Hidden items and part files are neither listed nor counted.

`places.download`

- `version`: integer, 1
- `requestId`: string, UUID
- `items`: array of 1 to 100 refs ({placeId, path, name} or {mediaId}); a folder brings its subtree, hidden and system files skipped and counted

Answered by `places.download_started`, `places.error`.

Browse lane. The phone then sends folders.offer with into: true and downloadRequestId; the Mac accepts a download offer only when it asked for it. Errors not_found, place_unavailable, limit_exceeded, busy, policy.

`places.download_started`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `folderTransferId`: string, UUID of the folders.offer that follows
- `rootName`: string, portable name
- `fileCount`: integer
- `folderCount`: integer
- `totalSize`: integer, bytes

#### `folders.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `folders.offer` | edition-draft | sender-to-receiver | folders_draft1 \| folders_receive_draft1 | yes | messageId | 8,192 B | sessionId, messageId, transferId, nonce, ciphertext | android, macos |
| `folders.manifest` | edition-draft | sender-to-receiver | folders_draft1 \| folders_receive_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.waiting` | edition-draft | receiver-to-sender | folders_draft1 \| folders_receive_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.conflict` | edition-draft | receiver-to-sender | folders_draft1 \| folders_receive_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.resolve` | edition-draft | sender-to-receiver | folders_draft1 \| folders_receive_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.accept` | edition-draft | receiver-to-sender | folders_draft1 \| folders_receive_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.rejected` | edition-draft | receiver-to-sender | folders_draft1 \| folders_receive_draft1 | yes | messageId | 8,192 B | sessionId, messageId, transferId, nonce?, ciphertext? | android, macos |
| `folders.entry_failed` | edition-draft | receiver-to-sender | folders_draft1 \| folders_receive_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.complete` | edition-draft | sender-to-receiver | folders_draft1 \| folders_receive_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.result` | edition-draft | receiver-to-sender | folders_draft1 \| folders_receive_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.cancel` | edition-draft | either | folders_draft1 \| folders_receive_draft1 | yes | messageId | 8,192 B | sessionId, messageId, transferId, nonce, ciphertext | android, macos |
| `folders.cancel.ack` | edition-draft | either | folders_draft1 \| folders_receive_draft1 | no | none | frame | sessionId, transferId | android, macos |

`folders.offer`

- `version`: integer, 1
- `folderTransferId`: string, UUID
- `rootName`: string, portable name
- `fileCount`: integer, at most 10,000
- `folderCount`: integer, at most 2,000
- `totalSize`: integer, at most 1 TiB
- `pageCount`: integer, 0 to 128
- `manifestSha256`: string
- `destination`: optional {placeId, path}
- `resume`: boolean
- `skipped`: optional object of counters
- `into`: boolean, optional, default false (files_browse_draft1): entries land directly in the destination, top-level clashes saved as copies, nothing merged, replaced or asked
- `downloadRequestId`: string, UUID, optional (files_browse_draft1): the offer answers that places.download of the receiver

The Mac checks folders_draft1 before sending to a phone, the phone folders_receive_draft1 before sending to a Mac (no destination: a Mac serves no places). Uploads are into with destination; a phone rejects them read_only while it does not allow changes, policy while browsing is off.

`folders.manifest`

- `version`: integer, 1
- `folderTransferId`: string
- `page`: integer
- `entries`: array of at most 256 {type: dir | file, path, size?, sha256?, modified?}

`folders.waiting`

- `version`: integer, 1
- `folderTransferId`: string
- `reason`: destination | conflict
- `timeoutSeconds`: integer

`folders.conflict`

- `version`: integer, 1
- `folderTransferId`: string
- `existing`: string
- `clashingFiles`: integer
- `clashingFolders`: integer
- `newFolderName`: string
- `choices`: array of merge | replace | new_folder | cancel
- `timeoutSeconds`: integer

Answered by `folders.resolve`.

`folders.resolve`

- `version`: integer, 1
- `folderTransferId`: string
- `choice`: merge | replace | new_folder | cancel

`folders.accept`

- `version`: integer, 1
- `folderTransferId`: string
- `rootName`: string
- `destinationLabel`: string
- `choice`: none | merge | replace | new_folder
- `completedBitmap`: string, base64, bit i set when entry i is done
- `freeBytes`: integer or null, free bytes at the chosen destination (files_browse_draft1)

`folders.rejected`

- `version`: integer, 1
- `folderTransferId`: string
- `code`: error code
- `entry`: integer, optional
- `neededBytes`: integer, optional
- `freeBytes`: integer, optional

With Files off the receiver sends it outer only, without decrypting the offer.

`folders.entry_failed`

- `version`: integer, 1
- `folderTransferId`: string
- `entry`: integer
- `transferId`: string
- `code`: error code

`folders.complete`

- `version`: integer, 1
- `folderTransferId`: string
- `sentFiles`: integer
- `failedCount`: integer
- `failed`: array of at most 500 {entry, code}

Answered by `folders.result`.

`folders.result`

- `version`: integer, 1
- `folderTransferId`: string
- `status`: complete | incomplete
- `savedFiles`: integer
- `savedBytes`: integer
- `createdFolders`: integer
- `renamedFiles`: integer
- `replacedFiles`: integer
- `failedCount`: integer
- `failed`: array of at most 500 {entry, code}

`folders.cancel`

- `version`: integer, 1
- `folderTransferId`: string
- `reason`: user | timeout | policy | error
- `code`: optional error code

Answered by `folders.cancel.ack`.

#### `settings.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `settings.snapshot` | edition-draft | either | settings_sync_draft1 | yes | messageId | 16,384 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `settings.update` | edition-draft | either | settings_sync_draft1 | yes | messageId | 16,384 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `settings.ack` | edition-draft | either | settings_sync_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `settings.error` | edition-draft | either | settings_sync_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |

`settings.snapshot`

- `schema`: integer, 1
- `maxSchema`: integer
- `records`: object of key to {value, changedAt, version, changedBy}, at most 32; every schema 1 key the sender syncs
- `waiting`: optional array of at most 32 keys that are on but wait for a permission on the sender
- `first`: optional bool: the sender has no first-connect answer for the receiver
- `new`: optional bool: the sender has no answer for any device

Answered by `settings.ack`.

Sent by each side when settings_sync_draft1 becomes true on both for the session, including right after connecting. A snapshot never overwrites a chosen value: a setting the receiver never chose (version 0) takes the sender's chosen record; two different chosen values stay and show as Different on <device> with Apply to all. Schema 1 has 24 keys (docs/folders-and-settings-sync.md 8.4); unknown and per-device keys and invalid records are skipped one by one. A payload that fails decryption closes the session; one that fails validation is answered settings.error invalid_message.

`settings.update`

- `schema`: integer, 1
- `records`: object of key to record, at most 32
- `waiting`: optional array of at most 32 keys
- `answered`: optional bool: the asker's person answered the first-connect question

Answered by `settings.ack`.

Local edits and Apply to all (debounced 500 ms), relayed records from other peers, records that won (kept) and were not yet sent to this peer, and waiting list changes (records may be empty). A record that wins by the merge rule is applied.

`settings.ack`

- `schema`: integer
- `ackOf`: string, messageId
- `applied`: array of keys
- `kept`: array of keys

kept lists keys where the receiver's own record won; it sends those records in settings.update unless it already sent them to this peer.

`settings.error`

- `schema`: integer
- `code`: unsupported_schema | invalid_message | rate_limited
- `maxSchema`: integer

rate_limited: more than 20 settings.* messages from this peer in 10 seconds; the extra messages were dropped. Sent at most once per window.

<!-- END GENERATED -->
