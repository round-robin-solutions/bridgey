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
| `designed` | Specified in [protocol.md](protocol.md) but not built by either client yet (settings sync). Never sent. |

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
   decryption closes the session for `upstream-v1` messages and for folders and places, as in
   upstream; clipboard offers, codes and remote input drop it and keep the session.
9. **Replay.** Encrypted messages with a `messageId` go through one per-session window of the last
   256 accepted IDs (oldest evicted first); a repeated ID is not executed again. Quick actions and
   remote input use a sequence high-water mark instead, so their volume cannot push other IDs out of
   the window. Nothing is replayable across sessions because every session has its own key.
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
  `quick.request`, `codes.status`, remote input).
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
| `settings_sync_draft1` | designed | no | false |

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

### Messages

80 kinds. Envelope fields ending in `?` are optional. "Replay" is `messageId` (the shared 256-entry window), `sequence` (a per-feature or per-session high-water mark) or none.

#### `pairing.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `pairing.offer` | upstream-v1 | either | none | no | none | frame | sessionId, deviceId, deviceName, publicKey, targetDeviceId? | android, macos |
| `pairing.answer` | upstream-v1 | either | none | no | none | frame | sessionId, deviceId, deviceName, publicKey | android, macos |
| `pairing.confirm` | upstream-v1 | either | none | no | none | frame | sessionId, deviceId, identityKey, proof, signature | android, macos |
| `pairing.cancel` | upstream-v1 | either | none | no | none | frame | sessionId | android, macos |

`pairing.offer`

Sent by the side that dials. targetDeviceId (edition extension) names the trusted peer a reconnect is for; any other receiver closes quietly.

`pairing.confirm`

proof is an HMAC under the pairing key; signature is P-256 over the session transcript.

`pairing.cancel`

Ends only the session it arrives on.

#### `heartbeat.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `heartbeat.ping` | upstream-v1 | either | none | no | none | frame | sessionId, messageId | android, macos |
| `heartbeat.pong` | upstream-v1 | either | none | no | none | frame | sessionId, messageId | android, macos |

`heartbeat.ping`

Answered by `heartbeat.pong`.

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

Content is sensitive and never logged.

`notifications.remove`

- `notificationId`: string, at most 512
- `callEnded`: boolean, optional, edition extension

`notifications.dismiss`

- `notificationId`: string, at most 512

`notifications.action`

- `notificationId`: string, at most 512
- `actionToken`: string, at most 64
- `reply`: string, optional, at most 4,096

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
- `action`: string (links: offer; media: toggle | pause | next | previous | seek | volume)
- `value`: string (links: http(s) URL, at most 4,096 bytes; seek 0 to 604800; volume 0 to 100)
- `sequence`: integer, 1 to 2^53-1, per feature high-water mark

Answered by `quick.result`.

`quick.result`

- `version`: integer, 1
- `requestId`: string, echoes the request
- `feature`: string, echoes the request
- `accepted`: boolean

#### `media.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `media.state` | upstream-v1 | mac-to-phone | media | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |

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

#### `places.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `places.list` | edition-draft | mac-to-phone | places_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.listed` | edition-draft | phone-to-mac | places_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.browse` | edition-draft | mac-to-phone | places_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.children` | edition-draft | phone-to-mac | places_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.create_folder` | edition-draft | mac-to-phone | places_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.folder_created` | edition-draft | phone-to-mac | places_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `places.error` | edition-draft | phone-to-mac | places_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |

`places.list`

- `version`: integer, 1
- `requestId`: string, UUID

Answered by `places.listed`, `places.error`.

`places.listed`

- `version`: integer, 1
- `requestId`: string
- `mode`: sender_picks | receiver_asks | fixed
- `places`: array of at most 17 {placeId, label (64), available, freeBytes}
- `fixedLabel`: string

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
- `code`: error code, see docs/protocol.md

#### `folders.*`

| Kind | Status | Direction | Feature | Encrypted | Replay | Max plaintext | Envelope | Implemented |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `folders.offer` | edition-draft | sender-to-receiver | folders_draft1 | yes | messageId | 8,192 B | sessionId, messageId, transferId, nonce, ciphertext | android, macos |
| `folders.manifest` | edition-draft | sender-to-receiver | folders_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.waiting` | edition-draft | receiver-to-sender | folders_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.conflict` | edition-draft | receiver-to-sender | folders_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.resolve` | edition-draft | sender-to-receiver | folders_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.accept` | edition-draft | receiver-to-sender | folders_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.rejected` | edition-draft | receiver-to-sender | folders_draft1 | yes | messageId | 8,192 B | sessionId, messageId, transferId, nonce?, ciphertext? | android, macos |
| `folders.entry_failed` | edition-draft | receiver-to-sender | folders_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.complete` | edition-draft | sender-to-receiver | folders_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.result` | edition-draft | receiver-to-sender | folders_draft1 | yes | messageId | 32,768 B | sessionId, messageId, nonce, ciphertext | android, macos |
| `folders.cancel` | edition-draft | either | folders_draft1 | yes | messageId | 8,192 B | sessionId, messageId, transferId, nonce, ciphertext | android, macos |
| `folders.cancel.ack` | edition-draft | either | folders_draft1 | no | none | frame | sessionId, transferId | android, macos |

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
| `settings.snapshot` | designed | either | settings_sync_draft1 | yes | messageId | 16,384 B | sessionId, messageId, nonce, ciphertext | not yet |
| `settings.update` | designed | either | settings_sync_draft1 | yes | messageId | 16,384 B | sessionId, messageId, nonce, ciphertext | not yet |
| `settings.ack` | designed | either | settings_sync_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | not yet |
| `settings.error` | designed | either | settings_sync_draft1 | yes | messageId | 8,192 B | sessionId, messageId, nonce, ciphertext | not yet |

`settings.snapshot`

- `schema`: integer, 1
- `maxSchema`: integer
- `records`: object of key to {value, changedAt, version, changedBy}

`settings.update`

- `schema`: integer, 1
- `records`: object of key to record

`settings.ack`

- `schema`: integer
- `ackOf`: string, messageId
- `applied`: array of keys
- `kept`: array of keys

`settings.error`

- `schema`: integer
- `code`: unsupported_schema
- `maxSchema`: integer

<!-- END GENERATED -->
