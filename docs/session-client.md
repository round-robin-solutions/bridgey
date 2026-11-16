# Shared session client (`rust/client`)

The Windows app, and later iOS and Linux, run the Bridgey session from one Rust library, `bridgey_core`,
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
| Everything else (files, notifications, battery, media, calls, SMS, folders, screen, Connect anywhere tunnels, settings sync, updates) | yes | yes | Connect anywhere core, codes | not yet: each moves when a new platform needs it (Windows M2 and M3) |

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
- Ownership: client handles are `uint64_t`, so a stopped or freed handle is refused rather than dereferenced.
  Strings in are borrowed for the call; strings and events out are freed by the library. Panics never cross.
- Media will not use the event path. When files and screen sharing move here, data stays in buffers with binary
  frames (`files_fast_draft1`), never JSON or base64 per frame.

## How it is checked

- `cargo test -p bridgey-client`: the shared vectors (`crypto-v1.properties`, including the protocol 2 code, and
  the golden frames in `protocol-v1.json`), feature-map rules against `protocol/messages.json`, and two clients on
  one machine that pair, exchange clipboard text both ways, wait for Allow pairing, refuse a wrong code, reconnect
  after a restart, refuse a changed identity, pair when both people start at once, and forget. The C ABI is tested
  the way a host calls it, including host storage callbacks.
- `cargo test -p bridgey-cli`: the CLI's own session (which has paired with both apps since 0.10) pairs with the
  client in both directions.
- `protocol/test-vectors/session-client-v1.json` is a real session between two clients, recorded on the wire.
  `SessionClientVectorTest.kt` (Android) and `SessionClientVectorTests.swift` (Mac) check every frame with the
  apps' own decoder, commitment, code, proof, signature, envelope tag, AES-GCM and feature code.
- `protocol/messages.json` lists `client` for the 14 kinds it speaks; a test fails if the sources and the list
  differ.

`include/bridgey_core.h` is generated: `BRIDGEY_WRITE_HEADER=1 cargo test -p bridgey-client --test header`. The
recorded session is regenerated with `BRIDGEY_WRITE_VECTORS=1 cargo test -p bridgey-client --lib vectors`.

## Not covered yet

- A live pairing with the shipping apps on real devices or an emulator; the checks above are on the wire format
  and shared code.
- Connect anywhere (away from home) and tailnet discovery; the client is local network only for now.
- Link-local IPv6 addresses from DNS-SD are skipped (no scope ID is tracked).
