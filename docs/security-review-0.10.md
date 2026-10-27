# Security review, 0.10

What we checked in Bridgey by Round Robin before 0.10, what we found, and what changed. The
review covered `rr/main` at `b5a4cf1` (2026-10-27): the Android app, the Mac app, the shared
protocol, the updaters and the codes relay in `services/otp-proxy`. It was a code review by four
independent reviewers, one per area, plus targeted checks on a Mac. It is not an outside audit.

The threat model is the one in [SECURITY.md](../SECURITY.md): the Wi-Fi is hostile, anyone on it
can advertise, connect, watch and change traffic, and a phone or Mac that was paired once may
later be compromised. A paired device should only get what the user turned on for it.

Severity:

- **High:** someone who is not paired, a web page or a local app gets code to run, data, or
  trust; or a paired device writes outside the folder it was given.
- **Medium:** a paired device gets more than it was granted, a resource attack that needs a
  restart, or a meaningful leak.
- **Low:** defence in depth.

Paths are relative to `android/app/src/main/java/dev/bridgey/android/` (Android) and
`macos/Sources/BridgeyMac/` (Mac) unless they start at the repository root. Line numbers are
from `b5a4cf1`.

## Summary

| | Found | Fixed in this branch | Follow-up |
| --- | --- | --- | --- |
| High | 3 | 3 | 0 |
| Medium | 15 | 15 | 0 |
| Low | 23 | 13 | 10 |

The protocol changes (H1, M1, M2) need both apps at 0.10. An 0.10 app and an 0.9 app that are
already paired keep working until they have once connected on protocol 2; a new pairing between
0.10 and 0.9 is refused. See [protocol.md](protocol.md#pairing-flow).

## High

### H1. The pairing code could be forced to match by a man in the middle (both apps)

- **Where:** `PairingCoordinator.kt:3786-3800` (`Crypto.pairingMaterial`), `:2503-2548`
  (`pairing.offer`, `pairing.answer`); `ProtocolCrypto.swift:8-27`, `Pairing.swift:2079-2126`.
- **What:** the six-digit code was the first four bytes of the session key, mod one million. The
  side that answered saw the other side's ephemeral key first, so it could choose its own.
- **Exploit:** an attacker advertises the Mac's name (TXT records are not authenticated), sits
  between the phone and the Mac, and tries keys on one leg until that leg's code equals the other
  leg's. About a million tries is seconds of work, inside the 20 s handshake. Both screens show
  the same code, both users confirm, and each device pins the attacker. From then on it reads
  notifications, codes, clipboard and files.
- **Fix:** protocol 2. A first pairing sends a SHA-256 commitment to the initiator's key instead
  of the key, the answer comes back, and only then `pairing.reveal` opens the commitment. The code
  comes from its own HKDF label over both keys, so it no longer leaks session key bits.
  `SessionSecurity.kt`, `SessionSecurity.swift`; shared vectors in
  `protocol/test-vectors/crypto-v1.properties` (written by `protocol/tools/crypto_v2_vectors.py`,
  which is independent of both apps). Tests: `ProtocolCryptoIntegrationTest`,
  `SessionSecurityTest`, and the Swift tests of the same names.

### H2. A received file named `..` landed outside the receive folder (Mac)

- **Where:** `Pairing.swift:4484-4489` (`IncomingFileTransfer.sanitize`), `:4393-4406`
  (`uniqueReceivedFileURL`).
- **What:** `sanitize` kept `.` and `..`. For a path ending in `..`, Foundation's
  `deletingLastPathComponent()` appends `../`, so the file was written to `<receive folder>/../.. 2`.
  Confirmed on macOS 27.
- **Exploit:** a compromised phone with Files on sends a file named `..`; it is written into the
  parent of the receive folder (a hidden file in `~/Downloads` by default). The name is fixed, so
  nothing could be overwritten.
- **Fix:** names are cut to their last component, lose NUL, control and bidirectional override
  characters, `.`, `..` and empty names become `file`, the length is capped in UTF-8 bytes with
  the extension kept, and the final path must sit directly in the receive folder or the transfer
  is refused. Test: `ReceivedFileSafetyTests`.

### H3. Encrypted messages were not bound to their headers (both apps)

The Android reviewer ranked this High because call requests are documented as replay-protected;
the Mac reviewers ranked it Medium or Low. It is listed here because of the call case.

- **Where:** `PairingCoordinator.kt:3823-3842` (`Crypto.encrypt`/`decrypt`, no associated data),
  `ProtocolDecoding.kt:186-197` (replay window keyed on the plaintext `messageId`);
  `ProtocolCrypto.swift:51-69`, `ProtocolDecoding.swift:231-256`.
- **What:** one session key served both directions, and nothing tied a ciphertext to its `kind`,
  `messageId`, `transferId` or `sequence`.
- **Exploit:** an attacker on the path copies an encrypted `calls.request` or
  `notifications.action` and sends it again with a new `messageId`: the phone dials again, or
  sends the same reply again. `find.stop` can be relabelled `find.start`, and a device's own
  `find.start` can be reflected back to it.
- **Fix:** protocol 2 envelope tags. When both ends sent `protocolVersion: 2`, every frame after
  pairing carries an HMAC over the sender's device ID and every envelope field, under a key
  derived from the session key. A frame with a missing or wrong tag is dropped. A device that once
  used protocol 2 is pinned to it, so stripping the version cannot downgrade a later session.
  Tests: the vector tests above plus a 500-case fuzz of mutated and forged frames on each platform.

## Medium

| # | Finding | Where | Fix | Test |
| --- | --- | --- | --- | --- |
| M1 | Transfer and clipboard control frames (`files.cancel`, `files.accept`, `files.complete.ack`, `files.rejected`, `clipboard.ack` and others) were acted on from connections that had not authenticated. Anyone who saw a transfer ID could cancel transfers or make one show as delivered. | `PairingCoordinator.kt:2585-2706`; `Pairing.swift:2280-2643` | Only `pairing.*` frames reach the handlers before authentication; others must carry the session ID (and the tag on protocol 2). 16 dropped frames close the connection. | `SessionSecurityTest`, `SessionSecurityTests` |
| M2 | No cap on connections before authentication, and the Android handshake deadline was only checked when a read timed out, so a peer that kept sending stayed forever. | `PairingCoordinator.kt:435`, `:2414-2449`; `Pairing.swift:1997-2006` | At most 8 pending connections, 3 per address; the deadline is checked after every frame. | `SessionSecurityTest`, `SessionSecurityTests` |
| M3 | Received files had no quarantine attribute, so Gatekeeper never checked an app or disk image from the phone, and one click on the notification opened it. | `Pairing.swift:4457`, `FolderReceiveSession.swift:352`, `ClipboardInbox.swift:291` | `com.apple.quarantine` on every received file, folder and clipboard file before it is moved into place. | `ReceivedFileSafetyTests` |
| M4 | A Mac with Calls off could answer or end a call through `notifications.action`. | `BridgeyNotificationListenerService.kt:344-349`, `PairingCoordinator.kt:2765-2786` | Call actions need Calls on for that Mac; such a Mac gets call notifications without action tokens; system call control also needs the global switch. | `ForwardedNotificationRegistryTest` |
| M5 | Unlimited concurrent single-file receives on Android; free-space check ignored files already arriving. | `PairingCoordinator.kt:2949-3010` | 4 per Mac, 8 in all; reserved bytes count against free space. | `IncomingFileAdmissionTest` |
| M6 | The same on the Mac, with no free-space check at all. | `Pairing.swift:2421-2436`, `:4425-4436` | 4 per phone, 8 in all, free space for the file, the running ones and 64 MB. | `ReceivedFileSafetyTests` |
| M7 | Unrequested clipboard pushes on Android ignored the phone's own limit and the cache cap; the current offer was never evicted. | `ClipboardInbox.kt:187-216`, `ClipboardCache.kt:141-159` | Pushes stay within the Send right away limit, free space plus 64 MiB and the cache cap, current offer included. | `ClipboardInboxTest`, `ClipboardCacheTest` |
| M8 | The same on the Mac. | `ClipboardInbox.swift:375-386`, `ClipboardCache.swift:137-143` | The same limits; otherwise `files.cancel`. | `ClipboardTransferTests` |
| M9 | Web-link offers were checked against the selected Mac's setting, not the sender's (Android). | `QuickActions.kt:112-124` | Checked and answered for the sending Mac. | `QuickActionsTest` |
| M10 | The same on the Mac for links from phones. | `QuickActions.swift:86`, `Pairing.swift:438` | Checked for the sending phone. | `QuickActionsTests` |
| M11 | On the Mac, transfer frames were not tied to the phone that owned the transfer: phone B could accept, and so receive, a file meant for phone A. | `Pairing.swift:2455-2541` | Every transfer records its phone; frames from another phone are ignored, and an offer cannot take over another transfer's ID. | `ReceivedFileSafetyTests` |
| M12 | Focus follow on the Mac had no rate limit or per-phone gate; each flip started `/usr/bin/shortcuts`. | `FocusSync.swift:49-108`, `Pairing.swift:3335-3343` | One run at a time, at least 2 s apart, latest state wins; only phones that advertise focus sync; state forgotten on disconnect. | `MacActionsTests` |
| M13 | Any local app could make the phone place a call through the Mac's `tel:` handler or the "Call with Bridgey" Service, with no prompt. | `PhoneURLHandler.swift:41-43`, `CallRequest.swift:28-38` | Calls from a URL or a Service show "Call <number> from <phone>?" first; Bridgey's own buttons go straight through. English and Russian. | `CallRequestTests` |
| M14 | Inbound pairing prompts could be repeated without limit and could take over a pairing the user had started. | `PairingCoordinator.kt:3156-3173`; `Pairing.swift:2858-2873` | A pairing this device started keeps the prompt; other devices may start 3 a minute. | `SessionSecurityTest`, `SessionSecurityTests` |
| M15 | Device names from the network were not cleaned or bounded and were shown in prompts and notifications. | `PairingCoordinator.kt:2513`, `:2541`; `Pairing.swift:2090` | Control and bidi characters removed, 64 characters at most. | `SessionSecurityTest`, `SessionSecurityTests` |

M14 and M15 were ranked Low by some reviewers; they are fixed with M1 because they touch the
same code.

## Low

### Fixed

| # | Finding | Fix |
| --- | --- | --- |
| L1 | Android: `allowBackup="false"` does not stop device-to-device transfer on Android 12 and later, which copied the device ID and trust list (`AndroidManifest.xml:68`). | Data extraction and backup rules exclude every domain. `ManifestPermissionsTest`. |
| L2 | Android: the share target accepted `file://` URIs and Bridgey's own provider URIs, so a local app could get Bridgey's private files sent after one tap (`MainActivity.kt:445-470`). | Only other apps' `content://` URIs are taken. `ShareTargetFilterTest`. |
| L3 | Android: a received file opened with the MIME type the Mac chose, so a file labelled as an APK opened the installer (`ReceivedFileNotifier.kt:69-73`). | Type from the file name; packages and unknown types are never opened directly. `ReceivedFileNotifierTest`. |
| L4 | Android: Focus follow accepted any paired Mac (`PairingCoordinator.kt:1568-1577`). | Only Macs that advertised focus sync. `FocusSyncTest`. |
| L5 | Android: no rate limit on ping sounds or codes link requests (`:1493`, `:3411`). | One per Mac every 2 s. `DeviceRateLimitTest`. |
| L6 | Mac: `codes.advertise` checked Notifications, not Codes from messages, and had no rate limit (`Pairing.swift:3454-3456`). | Needs Codes on; at most every 10 s. |
| L7 | Mac: refused Mac actions skipped the rate limiter and rewrote the audit file each time (`MacActions.swift:438`). | Logged at most 10 at once, then one every 2 s per phone. `MacActionsTests`. |
| L8 | Mac: images from a phone were decoded without a size check (`PhoneCamera.swift:55-60`, `ClipboardInbox.swift:282-284`, `PhoneThumbnailCache.swift:245-253`). | Images over 100 megapixels are not decoded. |
| L9 | Mac: remote control kept working while the screen was locked (`RemoteInputHost.swift:258-268`). | Ends on lock or session switch. `RemoteInputHostTests`. |
| L10 | Mac: trust was imported from UserDefaults on every launch and could replace a pinned key (`MacTrustRegistry.swift:13-61`). | Imported once, never over an existing key. `MacTrustRegistryTests`. |
| L11 | Mac: Forget ignored a failed write, so a forgotten phone could reconnect (`MacTrustRegistry.swift:35-37`). | Forgotten phones stay untrusted for the run; the failure is logged. |
| L12 | Mac: Sparkle unpacked updates before checking the signature (`Info.plist`). | `SUVerifyUpdateBeforeExtraction`; every release archive is EdDSA-signed by `scripts/rr/rrrelease.py`. |
| L13 | Docs: SECURITY.md said there is no cloud relay, but the opt-in codes relay sends message text to a Cloudflare Worker. | SECURITY.md describes it. |

### Follow-ups

| # | Finding | Where | Suggested fix |
| --- | --- | --- | --- |
| F1 | One client can use up the codes relay for everyone: the per-IP limit equals the global one (30 a minute), install IDs are self-made, chunked bodies are read in full before the size check, and the worker does not check that the code appears in the message (the apps do). | `services/otp-proxy/wrangler.toml`, `services/otp-proxy/src/index.js:94-150` | Per-IP limit well below global; byte-capped body read; check the code on the server too. |
| F2 | Forget device on Android leaves the codes companion link and `linked_mac_id`, so the phone keeps the Android 15 exemption. | `PairingCoordinator.kt:720-734`, `codes/CodeLinkTargets.kt:27-38` | Remove the association when the forgotten Mac is the linked one (needs the same UI path as Reset). |
| F3 | Sender-picks folder mode lets a Mac list folder names in granted places and create folders even with browsing off. | `folders/PlacesServer.kt:70-80` | Gate `places.browse` on the browse switch, or document it. Product decision. |
| F4 | Downloading a folder from the phone includes hidden files that browse hides. | `folders/FolderScan.kt:86` | Decide whether downloads should match browse. Product decision. |
| F5 | A pushed folder may Merge into an existing folder under the Mac's receive folder; if the receive folder were the home folder, `Library/LaunchAgents` could be written. | `FolderReceiveSession.swift:580-581`, `:714-718` | Refuse the home folder as the receive folder, or never merge pushed folders. |
| F6 | The code model manifest is not signed; its SHA-256 pin is only as strong as write access to the GitHub `models` release, and a restored model is checked by size only. | `CodeModelStore.swift:372-378`, `:660-668` | Sign the manifest with the update key and re-check the hash before loading. |
| F7 | Sparkle's feed is not signed (`SURequireSignedFeed`). | `macos/Resources/Info.plist` | Sign the appcast, then turn it on. |
| F8 | Dragging a phone gallery item to Finder uses the phone's name without the folder-name checks. | `BrowseMessages.swift:224`, `PhoneFilesInteraction.swift:117-128` | Validate media names like folder listings; check the destination. |
| F9 | Discovery maps on Android have no size bound, and a trusted ID's advert may name any address, which the phone dials. | `core/discovery/.../NsdDiscoveryService.kt:36`, `:183-188`; `Reconnect.kt:521-531` | Cap the maps; dial only private and link-local addresses from adverts. |
| F10 | After an app update, nothing rebinds the notification listener until Bridgey is opened, and setup does not explain Android 13 "restricted settings" for sideloaded installs. | `BridgeyNotificationListenerService.kt:78-86`, `SetupHost.kt:510` | A `MY_PACKAGE_REPLACED` receiver that requests a rebind; a line in the notification access step. Product decision (copy). |

Info notes kept for later: call events log the caller's name by default on the Mac
(`Logging.swift:12`); the local code model tokenises SMS text with special tokens enabled
(`LlamaRunner.swift:111`), which the literal-code check already contains; received file paths
are broadcast to local processes for Finder's "Where from" (`FinderMetadata.swift:60`), as
browsers do; the Bluetooth companion link can be started by any app through `MainActivity`'s
intent, but the system dialog still needs the user.

## Checked and found sound

- **Identity and trust:** Android Keystore P-256 signing key, not exportable; trust in private
  preferences holding public keys only. Mac `trust-v3.json` is 0600 in a 0700 folder, opened with
  `O_NOFOLLOW`, owner-checked, size-capped, written through a temporary file, `F_FULLFSYNC` and
  rename, and excluded from backup.
- **Pinned keys and confirmation:** a changed identity key is refused; the HMAC proof is compared
  in constant time; the identity signature covers the session ID, both device IDs and both
  ephemeral keys; reconnect target checks hold.
- **Authentication gating:** every handler that decrypts checks the session is authenticated and
  current before acting, on both platforms.
- **Framing:** 64 KiB frames, strict UTF-8 and JSON, depth 32, typed envelope; unknown fields
  ignored.
- **Folder receive (both):** portable-name rules, byte limits, depth 32, 10,000 files, sorted and
  unique manifests, children resolved by walking (no path strings), part files with `O_EXCL` and
  `O_NOFOLLOW` on the Mac, hash checked before publish, symlinks treated as clashes.
- **Browse server (Android):** per-device switch, references resolve only through listings of
  granted places, dot paths refused, lanes rate-limited, thumbnails downsampled, ranges capped.
- **Calls, camera, notifications, remote input, Mac actions, media:** per-device switches,
  inner sequence numbers for actions, quick and input, fixed media verbs with no AppleScript
  from the phone, a person presses the shutter, emergency numbers blocked, replies only into a
  RemoteInput.
- **Decompression:** no gzip, zip or zstd of peer data anywhere; the only peer image decodes are
  bounded (and now size-checked on the Mac).
- **Android updater:** HTTPS feed and asset prefix, no redirects away from HTTPS, size bound,
  SHA-256 before rename, package name, version code and signer set must match the installed app,
  newer only, APK in the private cache, `USER_ACTION_REQUIRED`.
- **Mac updater:** HTTPS feed, `SUPublicEDKey`, EdDSA-signed archives, hardened runtime with no
  library-validation, JIT or DYLD exceptions; the share extension is sandboxed.
- **Android components:** both providers unexported (the FileProvider covers only diagnostics and
  camera caches); tile, controls and listener services behind their `BIND_` permissions; every
  PendingIntent explicit and immutable except the unexported installer callback; no boot
  receiver; READ_SMS only in lab builds; cleartext off.
- **Logs and diagnostics:** content is off by default, IDs cut to 8 characters, exports carry
  tokens only, and no codes, keys or file names are logged.
- **Codes relay transport:** HTTPS only, ephemeral session, no cookies or cache, 2 s budget; the
  worker logs nothing.

## Tests added

- Shared protocol 2 vectors (commitment, code, envelope key, tag) checked by both apps.
- Golden frames for `pairing.reveal`, `commitment`, `protocolVersion` and `tag`, including wrong
  types, in `protocol/test-vectors/protocol-v1.json`.
- Fuzz on both platforms: 500 random frames each, with forged tags, wrong keys and single-field
  mutations that must all fail.
- Negative tests for pre-authentication kinds, pending connection caps, the pairing prompt
  limiter, peer name cleaning and protocol pins.
- Handler tests listed in the tables above.

Still missing, for the next round: a test that drives the whole Android `PairingCoordinator` or
Mac `PairingCoordinator.receive` over a socket pair (neither has one), a two-device man in the
middle simulation, and a decoder fuzz for the Mac payloads the reviewers listed
(`RemoteNotificationPayload`, `FileOfferPayload`, `ClipboardFetchPayload`, `codes.*`).

## Checks run

- Android: `:app:lintDebug :core:discovery:lintDebug :app:testDebugUnitTest
  :core:discovery:testDebugUnitTest :app:assembleDebug assembleRelease` on rr-dev-1.
- Mac: `swift test -Xswiftc -warnings-as-errors --skip MacTrustRegistryTests` (770 tests, 0
  failures) and `./build-app.sh` on the personal Mac (macOS 27.0.1, M4).
- Python: `python3 -m unittest discover -s scripts/rr/tests`; `protocol/tools/contract.py --check`;
  `node --test` in `services/otp-proxy`.
- Two-device pairing between an 0.10 phone and an 0.10 Mac was not run on hardware in this
  review; it needs a check on the OnePlus 11 before release.
