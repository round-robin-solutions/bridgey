# Bridgey Protocol v1: proposed compatibility contract

Status: **proposal, 26 November 2026.** Nothing here is frozen until Rahul approves it. Until then the freeze check
runs in report-only mode, and nothing on the wire changes. This page proposes which parts of the protocol 1.0
freezes, why, and how the freeze is kept afterwards.

- Machine-readable copy: the `v1` field on every feature key and message kind in
  [`protocol/messages.json`](../protocol/messages.json), shown in the tables of [protocol-contract.md](protocol-contract.md).
- Freeze check: [`protocol/tools/v1_freeze.py`](../protocol/tools/v1_freeze.py) against
  [`protocol/v1-baseline.json`](../protocol/v1-baseline.json) ([below](#how-the-freeze-is-checked)).
- Design and behaviour of each feature: [protocol.md](protocol.md). Compatibility rules that already apply:
  [protocol-contract.md](protocol-contract.md#compatibility-rules).

## Summary

| | Core | Extension | Draft | Deprecated |
| --- | --- | --- | --- | --- |
| Feature keys (46) | 5 | 29 (4 upstream, 25 edition) | 12 | 0 |
| Message kinds (202) | 30 | 130 (9 upstream, 121 edition) | 42 | 0 |

The notable calls:

- **Core is small and old:** the transport, the envelope, protocol 2 pairing, `heartbeat.*`, `features.update` and the
  five keys every map must carry (`clipboard`, `files`, `notifications`, `battery`, `find_device`). All of it is in
  upstream Bridgey or in every edition build since 0.10 Beta 11, and every platform speaks it (the CLI advertises
  `notifications` false).
- **Update all is frozen** (`updates_draft1`), so any two v1 builds can always update each other.
- **Fast transfers are frozen** (`files_fast_draft1`, the binary frames), because every transfer between current builds
  uses them.
- **Connect anywhere is frozen for the parts both peers must agree on**; the control service's own protocol (node
  auth, relay credentials) is versioned with the service, and the designed in-band ICE kinds stay draft.
- **Agent devices are frozen** (the `bridgey` CLI on servers updates on its own schedule, so mixed versions are normal).
  The condition in [open question 4](#open-questions-for-rahul) is met: the CLI checks every agent vector it writes or
  reads, and a contract test ties its code to `protocol/messages.json`.
- **Recent or unfinished work stays draft:** screen sharing both ways and phone control, file resume, LAN first, the
  Calls window, call media quieting, smart notification routing and the share flow's two keys. Each shipped in the
  last 14 days, is labelled a prototype, or has acceptance outstanding.
- **Draft keys keep their names.** A frozen extension is still called `sms_draft1`; renaming would be a wire change.
- **Nothing is deprecated yet.** Two behaviours are: protocol 1 sessions and peers that never send `features.update`.

## The four statuses

| Status | Meaning |
| --- | --- |
| core | Required to interoperate. Every v1 build speaks the session messages, and every `features.update` map carries the five original keys. A build may advertise a core feature `false` (the CLI does for `notifications`) and then never sends its messages; when it is `true`, they are exactly as frozen. Changes only through a new feature key, or for the session itself a new protocol version. |
| extension | Optional, negotiated by its feature key, and may be absent. When both peers advertise the key, its messages and fields are exactly as frozen. Changes only through a new key; the key keeps its current name. |
| draft | Not part of v1. Sent only to a peer that advertises the draft key. It may still change, through a new `_draftN` key, and an older build then just loses that feature. |
| deprecated | Kept for older peers: still accepted and answered, never sent by new builds, retired only after the [deprecation window](#deprecation). |

A field inherits the status of the key that gates it. `v1DraftFields` on a frozen message lists the payload fields
gated by a draft key, which stay outside the frozen shape: `resumable` on `files.offer` (`files_resume_draft1`), and
`presentation` and `eventId` on `notifications.post` (`notification_routing_draft1`). `contract.py` fails when a frozen
message has a field naming a draft key that is not in the list.

## How each call was made

- **Core:** the session messages (no feature key), and the keys `requiredInMap` already makes mandatory. `contract.py`
  checks that the core keys and the keys every map must carry are the same set.
- **Extension:** every other key that meets all four:
  1. shipped in a release at least 14 days before this proposal (on or before 12 November 2026);
  2. implemented at both ends (phone and Mac, or phone and agent);
  3. no shape change in `protocol/messages.json` in those 14 days, apart from fields gated by a draft key;
  4. no outstanding acceptance, prototype label or planned wire change recorded in the docs or the roadmap.
- **Draft:** everything else, plus the six `connect.*` kinds that are designed but not built.
- **Deprecated:** none. Nothing the apps send today has a successor.

Vector coverage is not a condition: missing vectors are listed as [gaps](#gaps) to close before or after the switch
flips. Evidence: the first release whose tree contains each key (git tags), [CHANGELOG.md](../CHANGELOG.md), the
`implemented` lists (kept honest by the Kotlin, Swift and Rust contract tests), the history of `protocol/messages.json`
and `python3 protocol/tools/v1_freeze.py --coverage`.

Platforms: "Windows" means `rust/client`, the shared session client the Windows app runs (in the beta since 1.0
Beta 2). The iOS app runs the same client but its first slice enables only pairing, clipboard text, files and links.
"CLI" is the `bridgey` agent command (`rust/cli`). Upstream is `singeol/bridgey`; baseline 0.6.0-rc.2.

### Feature keys

| Key | Proposed | First shipped | Platforms | Cross-platform vectors | Why |
| --- | --- | --- | --- | --- | --- |
| `clipboard` | core | upstream 0.2 | Android, Mac, Windows, iOS, CLI | 4 of 4 kinds | Original key, required in every map |
| `files` | core | upstream 0.2 | Android, Mac, Windows, iOS, CLI | 9 of 9 | Original key |
| `notifications` | core | upstream 0.2 | Android, Mac, Windows (the CLI sends `false`) | 4 of 4 | Original key |
| `battery` | core | upstream 0.2 | Android, Mac, Windows, CLI | 1 of 1 | Original key |
| `find_device` | core | upstream 0.2 | Android, Mac, Windows, CLI | 4 of 4 | Original key |
| `ping` | extension | upstream 0.6 | Android, Mac, Windows, CLI | 2 of 2 | Upstream, optional in the map |
| `links` | extension | upstream 0.6 | Android, Mac, Windows, iOS | 2 of 2 | Upstream, optional |
| `media` | extension | upstream 0.6 | Android, Mac, Windows | 3 of 3 | Upstream, optional |
| `calls` | extension | upstream 0.5 | Android, Mac | 4 of 4 | Upstream, optional |
| `clipboard_files_draft1` | extension | 0.6 Beta 5, 25 Oct | Android, Mac | 3 of 3 | No change since the contract file began (27 Oct) |
| `remote_input_draft1` | extension | 0.6 Beta 9, 26 Oct | Android, Mac | 11 of 11 | No change since 27 Oct; keeps its quirk: a non-boolean value closes the session |
| `sms_codes_draft1` | extension | 0.6 Beta 13, 26 Oct | Android, Mac, Windows | 5 of 5 | Three implementations |
| `email_codes_draft1` | extension | 0.10 Beta 18, 31 Oct | Android, Mac, Windows | fields only, none | Gates fields of `notifications.post`; more mail apps need no wire change |
| `folders_draft1` | extension | 0.6 Beta 10, 26 Oct | Android, Mac | 12 of 12 | Files 2.0 |
| `places_draft1` | extension | 0.6 Beta 10, 26 Oct | Android, Mac | 7 of 7 | Files 2.0 |
| `files_browse_draft1` | extension | 0.8 Beta 1, 27 Oct | Android, Mac | 13 of 13 | Files 2.0 |
| `folders_receive_draft1` | extension | 0.8 Beta 1, 27 Oct | Android, Mac | shares `folders.*` | Files 2.0 |
| `mac_actions_draft1` | extension | 0.9 Beta 1, 27 Oct | Android, Mac | 3 of 3 | |
| `links_open_draft1` | extension | 0.9 Beta 1, 27 Oct | Mac, Windows (phones only send) | recorded session | Gates `open` and `opened` on `quick.*` |
| `focus_sync_draft1` | extension | 0.9 Beta 1, 27 Oct | Android, Mac | 1 of 1 | |
| `camera_draft1` | extension | 0.9 Beta 1, 27 Oct | Android, Mac | 2 of 2 | |
| `updates_draft1` | extension | 0.10 Beta 4, 27 Oct | Android, Mac | 3 of 3 | Update all must keep working between any two v1 builds |
| `files_fast_draft1` | extension | 0.10 Beta 15, 30 Oct | Android, Mac, Windows | 9 of 9 | Every transfer between current builds |
| `sms_draft1` | extension | 0.10 Beta 6, 27 Oct | Android, Mac | 18 of 18 | No change since 28 Oct (Beta 9 added the last kinds) |
| `settings_sync_draft1` | extension | 0.10 Beta 12, 29 Oct | Android, Mac | 4 of 4 | Last shape change 30 Oct; unknown settings keys are skipped, so new settings need no key |
| `connect_draft1` | extension | 0.10 Beta 13, 30 Oct | Android, Mac, Windows, CLI | 3 of 3 built kinds | Peer parts only ([open question 5](#open-questions-for-rahul)) |
| `agent_draft1` | extension | 0.10 Beta 21, 4 Nov | Android, CLI | 4 of 4 | CLI updates on its own schedule |
| `notify_draft1` | extension | 0.10 Beta 21, 4 Nov | Android, CLI | 2 of 2 | |
| `ask_draft1` | extension | 0.10 Beta 21, 4 Nov | Android, CLI | 8 of 8 | |
| `clipboard_request_draft1` | extension | 0.10 Beta 21, 4 Nov | Android, CLI | 2 of 2 | |
| `agent_codes_draft1` | extension | 0.10 Beta 21, 4 Nov | Android, CLI | 3 of 3 | |
| `agents_mirror_draft1` | extension | 0.10 Beta 21, 4 Nov | Android, Mac | 4 of 4 | |
| `codes_detect_draft1` | extension | 0.10 Beta 22, 4 Nov | Android, CLI | 2 of 2 | |
| `agent_notifications_draft1` | extension | 0.10 Beta 26, 7 Nov | Android, CLI | 2 of 2 | |
| `screen_draft1` | draft | 0.10 Beta 6, 27 Oct | Android, Mac | stream vectors exist | Labelled a view-only prototype; `screen.start` changed 25 Nov; the next roadmap item reworks screen sharing on the shared Rust rules |
| `screen_control_draft1` | draft | 1.0 Beta 5, 25 Nov | Android, Mac | `display-v1.json` | 1 day old |
| `phone_control_draft1` | draft | 1.0 Beta 6, 25 Nov | Android, Mac | `phone-control-v1.json` | 1 day old |
| `files_resume_draft1` | draft | 1.0 Beta 4, 25 Nov | Android, Mac, Windows | `files-resume-v1.json` | 1 day old; folder resume designed, not built |
| `lan_first_draft1` | draft | 1.0 Beta 2, 24 Nov | Android, Mac | behaviour only | 2 days old, already followed by `_draft2` |
| `lan_first_draft2` | draft | 1.0 Beta 5, 25 Nov | Android, Mac | behaviour only | 1 day old |
| `call_quiet_draft1` | draft | 0.11 Beta 1, 15 Nov | Android, Mac | `call-media-v1.json` | 11 days old |
| `notification_routing_draft1` | draft | 0.11 Beta 1, 15 Nov | Android, Mac, Windows | none of its own | 11 days old; [smart-device-routing.md](smart-device-routing.md) lists acceptance as outstanding |
| `dialer_draft1` | draft | 0.11 Beta 3, 15 Nov | Android, Mac | `dialer-v1.json` | 11 days old; Windows M3 will add a third implementation |
| `device_presence_draft1` | draft | 0.10 Beta 27, 11 Nov | Android, Mac, Windows | `device-presence-v1.json` | Its consumers, routing and the share flow, still have acceptance outstanding |
| `share_receive_draft1` | draft | 0.10 Beta 27, 11 Nov | Android, Mac | none | Share flow live checks are blocked ([phone-share-flow.md](phone-share-flow.md)) |
| `handoff_takeover_draft1` | draft | 0.10 Beta 19, 1 Nov | Mac (to other Macs) | no messages | Macs sent it before the contract listed it (found by the v1 gaps work); a new entry starts as draft |

### Message kinds

A kind takes the status of its feature key, with these exceptions, all checked by `contract.py`:

- `pairing.*`, `heartbeat.*` and `features.update` have no key and are core. `pairing.reveal` (an edition extension of
  pairing) is core because every 0.10 or newer build needs it for a first pairing.
- A kind gated by two keys (`quick.*`: `links | media`; `places.list`, `places.listed`, `places.error`:
  `places_draft1 | files_browse_draft1`; `folders.*`: `folders_draft1 | folders_receive_draft1`) takes the least frozen
  of them; in each case both keys have the same status.
- `connect.offer`, `connect.answer`, `connect.candidates`, `connect.restart`, `connect.bye` and `connect.route` are
  designed, not built: draft, even though `connect_draft1` is an extension. When they are built they need a key of
  their own, because a frozen key cannot start meaning more.

The full list is in the generated tables of [protocol-contract.md](protocol-contract.md#messages).

## Transport and envelope (core)

Frozen as [protocol-contract.md](protocol-contract.md#what-10-will-freeze) and `protocol/messages.json` describe them
today:

- **Framing.** One UTF-8 JSON object per line, ended by LF (a CR before it is ignored). At most 65,536 bytes per frame
  before decoding and 32 levels of nesting. Strict RFC 8259: no comments, single quotes, unquoted names, trailing commas
  or lone surrogate escapes. Senders never write duplicate names.
- **Where.** TCP port 42458 and the Bonjour service `_bridgey._tcp`, TXT `id`, `name`, `version` and `platform` (hints
  only, never trusted before authentication). A Connect anywhere tunnel carries the same session unchanged on QUIC
  stream 0 (`connect_draft1`, extension).
- **Envelope.** `kind` (1 to 64 bytes) and `sessionId` (at most 128 bytes, empty only in a `pairing.cancel` sent before
  the session ID is known), plus the optional fields in the contract, each with one type. `sequence` is an integral JSON
  number within ±(2^53-1). An empty optional string or `null` counts as absent.
- **Errors.** A malformed frame (over a limit, invalid UTF-8, not an object, a missing or wrong-typed envelope field)
  closes the session before dispatch. An unknown kind is ignored and the session stays. Unknown envelope and payload
  fields are ignored.
- **Replay.** Encrypted messages with a `messageId` go through one per-session window of the last 256 accepted IDs.
  Streams use a per-feature sequence high-water mark instead. Each feature's rule is frozen with that feature.
- **Binary frames** (`files_fast_draft1`, extension): marker 0xB1, kind, length; an AES-GCM body under
  HMAC-SHA-256(session key, `bridgey-fast-frame-key-v2`); only on protocol 2 sessions and only to a peer that shows the
  key. Unknown binary kinds are skipped once their tag verifies.
- **Feature negotiation.** Each peer sends an encrypted `features.update` (`version` 1, a complete map of booleans)
  after pairing and whenever its local policy changes. The five core keys must be present and boolean, or the session
  closes. The four upstream optional keys may be absent (false) but must be boolean when present. Edition keys read
  `true` only for JSON `true`, except `remote_input_draft1`, where a non-boolean closes the session (kept as shipped). A
  map with another `version` is ignored. A feature is on only when both latest maps show it `true`.
- **Map size.** A map carries at most 128 keys of 1 to 64 bytes, and senders send only keys `messages.json` lists (46).
  A receiver reads every key it knows from any map that fits in a frame, whatever else it holds, and never closes the
  session because a map is larger; keys it does not know may be dropped. Pinned by two `featuresUpdate` vectors on
  Android, the Mac and `rust/client`.

## Pairing and protocol 2 security (core)

Every v1 build pairs with protocol 2, as built in 0.10 Beta 11 and described in [protocol.md](protocol.md#pairing-flow)
and [SECURITY.md](../SECURITY.md). Frozen:

- Ephemeral P-256 ECDH; HKDF-SHA-256 with salt SHA-256(session ID) and info `bridgey-pairing-v1`; AES-256-GCM payloads
  in base64 `nonce` and `ciphertext`.
- `protocolVersion: 2` in `pairing.offer` and `pairing.answer`. A first pairing commits: the offer carries
  `commitment` = SHA-256 of `bridgey-commit-v2`, session ID and public key (length-prefixed) and no `publicKey`; the
  initiator reveals the key in `pairing.reveal` only after the answer. A reconnect to a trusted device sends
  `publicKey` and the target's `targetDeviceId`.
- The six-digit code comes from `bridgey-sas-v2` over both ephemeral keys, is never sent, and is compared by both
  people. `pairing.confirm` carries an HMAC proof and a P-256 identity signature over the `bridgey-auth-v1` transcript
  (`bridgey-auth-v2` with the TLS exporter on a tunnel). Trust is stored only after both confirmations verify.
- Every frame after pairing carries `tag`, HMAC-SHA-256 under HMAC(session key, `bridgey-envelope-v2`) over the
  sender's device ID and every envelope field. A missing or wrong tag drops the frame; 16 dropped frames close the
  connection. A device that once authenticated with protocol 2 is pinned to it.
- Pairing frames are taken only in order; offers from untrusted devices are limited to three a minute and answered only
  while pairing is allowed (otherwise `pairing.cancel` with `not_armed`); offers expire after two minutes. Android and
  the Mac read an unknown `pairing.cancel` `reason` as `cancelled`, so a new reason is a safe addition.
- Shared vectors: `crypto-v1.properties` (Kotlin, Swift, Rust) and five recorded protocol 2 sessions
  (`session-client-*.json`, written by Rust, opened frame by frame by Kotlin and Swift).

Protocol 1 (no commitment, no tags) is [deprecated](#deprecation): never offered, accepted only to reconnect a pair
that has never connected on protocol 2 (upstream Bridgey and edition builds before 0.10).

"Protocol 2" is the pairing and envelope security level inside contract version 1 (`contractVersion` in
`messages.json`). Both numbers stay.

## Versioning after v1

### What counts as a breaking change

For any core, extension or deprecated entry, anything that could make one v1 build misread another:

- removing or renaming a kind, envelope field, payload field or feature key, or reusing a retired one;
- changing a field's type, unit, encoding, meaning or whether it is required;
- loosening what a sender may send (a longer string, a larger number, a new enum value the entry does not say is
  ignored), or tightening what a receiver accepts below the frozen limits;
- changing a kind's direction, encryption, replay rule, reply kinds or feature key;
- changing what happens on bad input (close the session, drop, answer `*.rejected`);
- sending a gated kind or field to a peer whose latest map does not show its key `true`;
- changing framing, the envelope, pairing, key derivation or tags (that needs a new `protocolVersion`, negotiated in
  `pairing.offer` and `pairing.answer` as protocol 2 was);
- moving an entry from core or extension back to draft, or between core and extension.

### What does not

- A new feature key and new kinds behind it, as a draft (`<name>_draft1`).
- A new optional field on a frozen message, gated by a key and listed in `v1DraftFields` until that key is frozen.
- A new enum value where the entry already says unknown values are ignored or read as a fallback (for example "an
  unknown result reads as failed").
- New vectors, and wording that does not change behaviour (recorded as an amendment, below).

### How a draft becomes an extension

In a minor release (1.x.0), once the key meets the [four conditions](#how-each-call-was-made) and has cross-platform
vectors for its kinds: set `v1` to `extension`, run `python3 protocol/tools/contract.py --write` and
`python3 protocol/tools/v1_freeze.py --write-baseline`, and say so in the changelog. The key keeps its name. If upstream
later adopts it under a final name, the rule for promoting a draft upstream applies
([protocol-contract.md](protocol-contract.md#compatibility-rules), rule 7).

### Changing a frozen feature

Add a successor key (for example `sms_v2_draft1`) next to the old one, advertise both, prefer the successor between peers
that show it, and keep the old key working. Once no new build needs to send the old key's messages, mark it
`deprecated` (the check allows core or extension to deprecated), then retire it after the window.

### Deprecation

Proposed window ([open question 2](#open-questions-for-rahul)): a deprecated entry stays accepted and answered for at
least 12 months after the first Stable release that stops sending it, and never while the
[upgrade policy](upgrade-policy.md) still supports a build that needs it. Then it is retired as rule 6 of the contract
says: never sent or advertised, ignored when received, and its key and kinds are never reused.

Deprecated behaviours today, not entries:

| Behaviour | Kept for | Proposed end |
| --- | --- | --- |
| Protocol 1 reconnects (no commitment, no envelope tags) for pairs that never connected on protocol 2 | Upstream Bridgey and edition builds before 0.10 Beta 11, already paired | 12 months after Stable 1.0 ([open question 3](#open-questions-for-rahul)); never for a first pairing |
| A peer that has sent no `features.update` is treated as enabling the five original keys | Upstream builds before 0.2.1 | Same window as protocol 1 |

## Mixed-version guarantees

What any v1 build (1.0.0 and every later 1.x, any platform) promises any other v1 build:

1. They pair with protocol 2 and reconnect, on the local network or (when both have it on) over Connect anywhere.
2. Neither closes a session because of anything the other sends that it does not know: kinds, envelope fields, payload
   fields, feature keys or binary frame kinds.
3. Every core feature both have on works, in either direction, whichever build is newer.
4. Every extension both builds implement and advertise works with its frozen shape, whichever is newer.
5. A draft works only between builds that advertise the same draft key; otherwise the feature is hidden on both ends,
   never an error.
6. A build never sends a frozen message over its frozen limits, and accepts everything within them.
7. Update all works between any two v1 builds that both have `updates_draft1` (Android and Mac today).

What any v1 build promises an upstream Bridgey peer (`singeol/bridgey` 0.5, 0.6 and later releases that keep this
transport):

1. Upstream messages keep upstream's meaning, fields and limits; edition fields on them are optional and ignored by
   upstream.
2. Edition kinds are never sent to it: they are gated by keys upstream never advertises.
3. An existing pair keeps reconnecting on protocol 1 for the deprecation window.
4. A new pairing needs protocol 2 at both ends, so it works only once upstream adopts protocol 2 (the edition can offer
   it upstream as a pull request). This is the 0.10 decision in [compatibility.md](compatibility.md#pairing-with-other-bridgey-versions).

## How the freeze is checked

`protocol/v1-baseline.json` records everything v1 freezes, from `protocol/messages.json`:

- the transport (except `onUndecryptablePayload`, a summary of each feature's own rule) and the envelope;
- the shape of every core, extension and deprecated feature key and kind: every field except `implemented`, the older
  `status` label (superseded by `v1`) and the fields listed in `v1DraftFields`. Notes count: they carry meaning;
- a hash of each vector case that pins a frozen feature: the golden vector groups of those features, the crypto
  vectors, the recorded sessions, the fast transfer, folder, Phone files, agent and mirror vectors, and the peer parts of
  the Connect vectors. Cases are hashed one by one, so new cases are additions; a changed or removed case is breaking. The vectors
  are what the Kotlin, Swift and Rust suites already decode, so the baseline also pins what the code does.

`python3 protocol/tools/v1_freeze.py --check` compares the tree with it and lists:

- **breaking**: a frozen entry, the transport, the envelope or a pinned vector changed or disappeared, or an entry left
  the frozen set;
- **unrecorded**: a new frozen entry (a promoted draft), a deprecation or a newly pinned vector group not yet in the
  baseline;
- **info**: new vector cases not yet recorded. Never fails.

`scripts/rr/tests/test_protocol_v1_freeze.py` runs the same check in the Python suite (RR CI's `python` task) and prints
the report. It fails only when the freeze is enforced.

There is no separate copy in the Kotlin, Swift or Rust suites on purpose. The Android, Mac, `rust/client` and `rust/cli`
contract tests already fail when the code uses a kind that `messages.json` does not list for that platform, or the file
lists one the code never uses (Android, the Mac and the CLI also check the feature keys they advertise, and
`contract.py` fails on any `_draftN` key in app sources that the file does not list), and between them the suites decode
every pinned vector. A second diff in three languages could only disagree with this one.

### Flipping it on

When Rahul approves (in the same pull request):

1. Apply his answers to the [open questions](#open-questions-for-rahul) to the `v1` fields, then run
   `python3 protocol/tools/contract.py --write` and `python3 protocol/tools/v1_freeze.py --write-baseline`.
2. Set `"frozen": true` at the top of `protocol/v1-baseline.json`.
3. In `protocol/messages.json`, set `v1.state` to frozen with the date, update `contractStatus`, and reword the
   `edition-draft` status so it no longer says a frozen key may change. `status` is not part of the frozen shape, so
   relabelling it does not trip the check.
4. Update the status lines of this page and [protocol-contract.md](protocol-contract.md), and tick the README's v1.0 item.

To try enforcement without flipping: `BRIDGEY_PROTOCOL_V1_FROZEN=1 python3 protocol/tools/v1_freeze.py --check`, or the
same variable on the Python suite.

After the flip, a pull request that changes a frozen entry fails the `python` task. If the change is a wording fix or
an agreed exception, `python3 protocol/tools/v1_freeze.py --write-baseline --amend "why"` records it; the baseline keeps
each amendment with its date, reason and changes, so a reviewer sees it in the diff.

## Gaps

From `python3 protocol/tools/v1_freeze.py --coverage`. "Cross-platform" means a vector that at least two of the Kotlin,
Swift and Rust suites decode (`rust/cli` counts as Rust).

**Closed in this proposal** (vectors added to `protocol-v1.json`, decoded by Kotlin, Swift and Rust):

- Core kinds that had no vector: `heartbeat.pong` (and a valid `heartbeat.ping`; before, only a rejected one),
  `clipboard.rejected`, `files.rejected`, `files.cancel`, `files.cancel.ack`, `find.stop`.
- Upstream extension kinds that had none: `ping.request`, `calls.request`, `calls.started`,
  `calls.confirmation_required`, `calls.rejected`, plus `callsRequest`: `calls.request` payloads (the number each
  platform reads, or reject), checked by Kotlin and Swift.
- Unencrypted extension kinds, whose envelope is the whole message: `speed.ping`, `speed.pong`, `speed.ack`,
  `speed.cancel`, `folders.cancel.ack`.

**Closed by the v1 gaps work** (each vector written by the sender's real encoder and checked by every platform that
sends or receives the kind):

- Every core and extension kind now has a cross-platform vector: `--coverage` lists none without one and none read by
  one suite only.
- The 32 extension kinds that had none: `clipboard.fetch`, `clipboard.error`, `codes.advertise_stop`,
  `input.session.started`, `sms.changed`, `sms.threads_page`, `sms.attachment_data`, `sms.contacts_result`,
  `connect.setup.ack`, `settings.ack` and `settings.error` (new groups in `protocol-v1.json`); the Phone files pages and
  parts `places.files_page`, `places.download_started`, `media.list`, `media.thumbnails_batch`, `media.preview_part`,
  `media.range_part` and `media.cancel` (new file `browse-v1.json`); and the agent kinds `agent.hello`,
  `agent.grant_request`, `agent.request_result`, `notify.result`, the six `ask.*` kinds that carry only an `askId`,
  `clipboard.request`, `agent.notifications.query`, `agent.notifications.result` and `codes.cancel` (new groups in
  `agent-v1.json`).
- The eight read by one side only: the CLI now checks what it writes for `notify.post`, `ask.request` and `codes.query`,
  and what it reads for `ask.answer`, `clipboard.response` and `codes.result`; Android checks what it writes for
  `agents.state` (a new case in `agents-mirror-v1.json`) and `codes.read`.
- `rust/cli` has a contract test like the other platforms' (`src/contract_tests.rs`): every kind its code sends or
  handles is listed for `cli` with a direction an agent may use, nothing else is listed for `cli`, and every key in its
  `features.update` is in the contract. It also checks every `agent-v1.json` group it writes or reads
  (`src/payloads.rs`), which is the condition in [open question 4](#open-questions-for-rahul).
- How many `features.update` keys a receiver keeps, now written down ([above](#transport-and-envelope-core)).
- The `calls.request` number: a JSON string only. Receivers are strict, so a number or any other type is answered
  `calls.rejected` on a real phone as in the tests.

**Disagreements found and resolved** (no wire change; each is pinned by vectors now):

- `clipboard.error` without a known `code`: Android read it as `unavailable`, the Mac dropped the message and the paste
  failed at its timeout. The Mac now reads it as `unavailable` too, so a code added later is a safe addition.
- `calls.request` with a non-string `number`: a real phone's `org.json` dialled a JSON number, the JVM tests refused it.
  The phone now checks the type itself; Macs always send a string.
- `rust/client` kept the first 128 entries of a peer's map in name order, counting false and over-long ones, so a map
  crowded with unknown keys could hide a known key that Android and the Mac read. It now reads every listed key first.
- Macs advertised `handoff_takeover_draft1`, which `messages.json` did not list; it is listed now (draft), and
  `contract.py` fails on any unlisted `_draftN` key in app sources.
- `messages.json` said the CLI implements `files.cancel.ack`; it neither sends nor reads it (no peer waits for it).
  The entry now leaves `cli` out.
- The CLI sent a few things the phone refuses as `invalid`: a notification `tag` or `from` over 64 characters, a text hint
  over 40, a `from` over 64 on a question, a service over 64 on a codes query, a zero timeout on `ask` and
  `clip get`, and a request over 4,096 bytes once encoded. It now refuses them before sending. It also drops what the
  contract calls invalid from the phone (for example an answer with neither option nor text), where it used to cut it
  short or pass it through; no phone sends such messages.

**Still open** (none blocks the flip):

- Partial: `browseRef` pins only the ref object inside the browse requests (`places.files`, `places.download`,
  `media.thumbnails`, `media.preview`, `media.range`) and `media.page`; `smsMessage` pins one message object of
  `sms.messages_page` and `sms.sync_page` rather than whole pages;
  `email_codes_draft1`'s fields on `notifications.post` are in no wire vector (`email-codes-v1.json` pins the detection
  rules).
- Receivers more lenient than senders, left out of the vectors so they are not frozen: the Mac skips the `version` check
  on four Phone files answers, Android on `media.cancel`; Android clamps a `media.list` limit; the Mac checks fewer
  fields of `clipboard.error` and `settings.ack` than Android; the Mac reads `version` `1.0` or `true` as 1 on `codes.*`,
  where `rust/client` refuses both. None changes what a conforming sender gets.

## Open questions for Rahul

Each has a recommendation; answering "as recommended" approves the proposal as written.

1. **Approve the split?** Core 5 keys and 30 kinds, extension 29 and 130, draft 11 and 42, nothing deprecated.
   *Recommendation: approve.*
2. **Deprecation window.** How long a deprecated entry keeps working. *Recommendation: at least 12 months after the
   first Stable release that stops sending it, and never while the upgrade policy supports a build that needs it.*
3. **Protocol 1 reconnects** for upstream Bridgey and pre-0.10 pairs. *Recommendation: keep them, accept-only and never
   for a first pairing, until 12 months after Stable 1.0; offer protocol 2 to upstream meanwhile.*
4. **Agent devices now?** The agent keys are frozen in this proposal. The CLI now checks every agent vector it writes or
   reads. *Recommendation: freeze them; the CLI on servers updates separately, so it gains most from a freeze.*
5. **Connect anywhere scope.** *Recommendation: freeze the peer parts (`connect.setup`, `connect.setup.ack`,
   `connect.addresses`, the pair secret, sealed signals, the QUIC tunnel and `bridgey-auth-v2`); leave node auth and relay
   credentials to the control service's own versioning; keep in-band ICE draft under a new key when built.*
6. **Keep the `_draft1` names?** *Recommendation: yes. Renaming frozen keys to final names would mean advertising both
   for a whole deprecation window, for no gain on the wire.*
7. **When to flip.** *Recommendation: as soon as you approve, so the remaining 1.0 betas are already held to it; do not
   wait for Stable.*
8. **Gaps before the flip.** The CLI vectors and every missing extension vector are in. *Recommendation: flip now; close
   the partial items during 1.x, and add vectors for any extension before its first change.*
