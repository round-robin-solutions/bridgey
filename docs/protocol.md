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

## Draft: Connect anywhere (edition-only)

Status: **draft, not implemented, edition-only** (Bridgey by Round Robin) until accepted
upstream. Peers that do not both advertise the capabilities below keep the current wire format
unchanged. Design, rationale and numbers: [connect-anywhere.md](connect-anywhere.md) and
[agent-cli.md](agent-cli.md). All identifiers are unbranded so the protocol can be offered upstream.

### Capabilities

`connect.v1` (QUIC tunnel, routes, signalling), `transfer.v1` (resumable transfer) and `agent.v1`
(notify, ask, clipboard request). They are advertised in the encrypted `features.update` payload
as an optional `capabilities` array next to `features`; clients that do not know the key ignore
it. Bonjour TXT may carry the advisory key `cv=1` (attacker-controlled, like all TXT data).

### QUIC tunnel

- **Transport.** UDP, default port 42458 (the TCP listener's number). ALPN `bridgey/1`. TLS 1.3
  with certificates in both directions: self-signed Ed25519, renewed every 24 hours.
- **Pin.** The certificate must match `certSha256` (SHA-256 of the DER) whenever signalling
  supplied one.
- **Shared socket.** STUN, TURN and QUIC share one socket, demultiplexed by first byte as in
  RFC 9443, so endpoints must not send `grease_quic_bit`.
- **Stream 0,** the first client-initiated bidirectional stream, carries the existing
  newline-delimited JSON session with the 65,536-byte frame limit. The QUIC client sends
  `pairing.offer`; all pairing fields and checks are unchanged except the signed transcript:

  ```text
  "bridgey-auth-v2" \0 sessionId \0 initiatorDeviceId \0 responderDeviceId
    \0 initiatorEphemeralKey \0 responderEphemeralKey \0 base64(exporter) [\0 base64(inviteHash)]
  exporter = TLS-Exporter("EXPORTER-bridgey-tunnel-v1", "", 32)
  ```

  `bridgey-auth-v1` remains the transcript on the TCP transport.
- **Unidirectional streams** carry `transfer.v1` data.

### In-session messages (`connect.v1`)

These are encrypted payloads in the current session format (`kind`, `sessionId`, `messageId`,
`nonce`, `ciphertext`):

| Message | Payload |
| --- | --- |
| `connect.setup` | `version` 1, `contribution` (base64, 32 random bytes), `rotate` (bool). The reply is `connect.setup.ack` `{version}`. `pairSecret = HKDF-SHA256(cLow ‖ cHigh, salt "bridgey-pair-secret-v1", info idLow \0 idHigh, 32)`. |
| `connect.addresses` | `version`, `port`, `addrs` (at most 16): `a`, `kind` (`lan`, `vpn`, `public6`), `vpn` (`tailscale`, `other`), `net` (8-byte tag) |
| `connect.offer`, `connect.answer` | `version`, `sid` (base64url 16 bytes), `ufrag` (8 characters), `pwd` (24 characters), `cands` (at most 24), `cert`, optional `rtts` and `net` |
| `connect.candidates` | `sid`, `cands`, `done` |
| `connect.restart` | `sid`, `ufrag`, `pwd`, `reason` (`network_change`, `path_failed`, `relay_switch`) |
| `connect.bye` | `sid`, `reason` |
| `connect.route` | `version`, `route` (`lan`, `vpn`, `direct`, `relay`), optional `relay`, `rttMs`. Informational only. |

A candidate is `{"k":"host|prflx|srflx|mapped|relay","a":"<ip>","p":<port>,"net":"lan|vpn|public6|cell|wifi","pri":<u32>}`.

### Rendezvous protocol (Bridgey Rendezvous v1)

Any operator can run the service. The edition's is `wss://connect.roundrobin.in/v1/ws`. It uses
WebSocket text frames, one JSON object of at most 16 KiB each, with the type in `t`.

| Message | Fields |
| --- | --- |
| `hello` | `v`, `node` (P-256 SEC1 public key, base64url), `app`, `keepalive` (60 to 270 s) |
| `challenge` | `nonce` (32 bytes), `pow` (required leading zero bits, 0 to 24) |
| `auth` | `sig`: DER ECDSA-P256-SHA256 over `"bridgey-rdv-auth-v1\0" ‖ nonce ‖ node`; optional `pow` solution with `SHA-256("bridgey-pow-v1" ‖ nonce ‖ node ‖ solution)` having `pow` leading zero bits |
| `welcome` | `nodeId` (SHA-256 of node, first 16 bytes), `now`, `limits` |
| `register`, `registered` | `ids` (at most 64; replaces the set), `online` |
| `presence` | `rdv`, `online` |
| `signal`, `undeliverable` | `to` or `rdv`, `side` (0 for the lower device ID), `sid`, `body` (sealed, at most 6 KiB) |
| `relay.request` | `rdv`, `sid`, `side`, `rtts`, `need` (`udp`, `tls443`), `estBytes`, `exclude` |
| `relay.claim` | `rdv`, `sid`, `side` |
| `relay.grant` | `sid`, `relay`: `id`, `kind` (`coturn`, `cloudflare`), `urls`, `username`, `credential`, `spki` (coturn only), `expiresAt`, `maxKbps` |
| `relay.denied`, `relay.release`, `error` | `code`, `retryAfterMs` |

Derivations and formats:

```text
rdvId(d) = base64url(HMAC-SHA256(pairSecret, "bridgey-rdv-v1" ‖ d)[0..16]), d = UTC "YYYY-MM-DD"
sigKey   = HKDF-SHA256(pairSecret, salt "", info "bridgey-signal-v1", 32)
body     = base64url(0x01 ‖ nonce(12) ‖ AES-256-GCM(sigKey, nonce, plaintext,
                     aad = "bridgey-signal-v1" \0 rdvId \0 side \0 sid))
```

- The sealed plaintext is JSON of type `offer`, `answer`, `cand`, `restart` or `bye`. Its fields
  match the in-session messages, plus `ts` (Unix ms) and `seq`. Receivers reject `ts` more than
  5 minutes off and non-increasing `seq` per `sid` and `side`.
- **Relay credentials.** coturn uses the TURN REST style:
  - `username = "<expiry>:<sid prefix 8>.<side>"`;
  - `credential = base64(HMAC-SHA1(secret, username))`.

  Cloudflare credentials come from its API. Both last 2 hours and are renewed at 75%.

### Remote pairing invites

- **Invite:** `bridgey://pair#<base64url JSON>`, with `v` 1, `rdv` (16 random bytes), `secret`
  (32 random bytes), `svc` (control URL), `name` and `exp` (at most 10 minutes). Single use.
- **Rendezvous:** both sides register `HMAC-SHA256(secret, "bridgey-invite-rdv-v1")[0..16]` and
  seal signalling with `HKDF-SHA256(secret, "", "bridgey-invite-signal-v1")`.
- **Pairing** then runs inside the tunnel, with `inviteHash = SHA-256(secret)` added to the
  transcript and the six-digit code confirmed on both devices.

### Resumable transfer (`transfer.v1`)

**Model:**

- 1 MiB chunks; `H_i = SHA-256(chunk_i)`.
- `root = SHA-256("bridgey-transfer-v1\0" ‖ u64be(size) ‖ u32be(chunkSize) ‖ H_0 ‖ ... ‖ H_{n-1})`.
- Files up to 1 TiB; at most 100,000 entries per transfer.

**Control messages** (encrypted session messages):

| Message | Fields |
| --- | --- |
| `xfer.offer` | `transferId`, `kind`, `rootName`, `itemCount`, `totalBytes`, `chunkSize`, `pages` |
| `xfer.manifest` | `page`; `items` (at most 1,000): `i`, `path`, `size`, `mtime`, `mime`, `dir` |
| `xfer.accept` | `streams` (1 to 8), `destination`, `conflict` (folders spec) |
| `xfer.reject` | `reason` |
| `xfer.have` | `files`: `[{i, ranges}]`, durable chunks only |
| `xfer.file.done` | `i`, `root` |
| `xfer.file.ok`, `xfer.file.bad` | `i`; `chunks` for `bad` |
| `xfer.resume`, `xfer.unknown` | `transferId` |
| `xfer.changed` | `i`, `size`, `mtime` |
| `xfer.pause`, `xfer.cancel`, `xfer.done`, `xfer.done.ack` | `transferId` |

Paths are relative, `/`-separated and NFC-normalised. No empty, `.` or `..` components, no
control characters or backslashes. At most 255 bytes per component, 4,096 per path and 32 levels.

**Data streams.** Each QUIC unidirectional stream starts with `"BXT1" | transferId (16) |
streamNo (u16) | flags (u16)`. Records follow: `type (u8, 1) | fileIndex (u32) | chunkIndex (u32)
| length (u32) | sha256 (32) | payload`, all big-endian. A hash mismatch stops the stream with
application error `0x10` and the chunk is re-requested in `xfer.file.bad`.

### Agent messages (`agent.v1`)

Encrypted session messages; the phone enforces per-device grants and rate limits.

| Message | Fields |
| --- | --- |
| `notify.post` | `version`, `notifyId`, `title` (at most 120), `body` (at most 1,000), `priority` (`normal`, `high`), `tag` (at most 64), `from` (at most 64). Replies: `notify.posted`, `notify.rejected`. |
| `ask.request` | `version`, `askId` (UUIDv7, idempotent), `title`, `body`, `options` (1 to 3 of `{id, label}`; id `[a-z0-9_-]{1,32}`, label at most 20; at most 2 when `allowText`), `allowText`, `textHint` (at most 40), `requireUnlock`, `expiresAt` (at most 24 h), `from`. Replies: `ask.posted`, `ask.rejected`. |
| `ask.answer` | `askId`, `option` or `text` (at most 1,000), `answeredAt` |
| `ask.dismissed`, `ask.expired`, `ask.cancelled` | `askId` |
| `ask.cancel` | `askId` |
| `ask.status` | `askIds` (at most 20). The reply is the latest state of each; answers are kept 24 h. |
| `clipboard.request` | `version`, `requestId`, `reason` (at most 120) |
| `clipboard.response` | `requestId`, `status` (`sent`, `declined`, `expired`), `text` and `html` (at most 32 KiB together) |

- **Rejection codes:** `not_granted`, `rate_limited` (with `retryAfterMs`), `disabled`, `invalid`,
  `busy`.
- **New optional `features.update` keys:** `notify`, `ask`, `clipboard_request`. Ring uses
  `find.start` and `find.stop`; battery uses `battery.update`; both exist today.

## Compatibility

Adding optional fields or message types is backward compatible. Changing field
meaning, authentication, or required behavior requires a new capability or
major version. JSON is a codec behind the envelope model; a future protobuf
codec must preserve IDs, types, correlation, and negotiated semantics.
