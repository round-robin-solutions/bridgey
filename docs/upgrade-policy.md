# Upgrades and on-disk formats

Status: draft for v0.10 (stabilisation, before 1.0). These rules are to be fixed at 1.0; until
then they may still change. Round Robin edition only.

## Which upgrades are supported

- **Any edition release from `0.6.0-rr.1-beta.1` onward to the current build**, on Android and
  macOS, in one step. Skipping releases is fine: each build reads every older format in the table
  below.
- **Channel switches (Stable, Beta, Nightly).** All channels are the same app (`in.roundrobin.bridgey`)
  with the same storage; a switch only changes which feeds the updater reads. Moving to a more
  stable channel never installs an older build: the app waits until that channel has a build newer
  than the installed one (see [rr-edition.md](rr-edition.md)). So a channel switch is always an
  ordinary upgrade.
- **Not covered:** upstream Bridgey (`dev.bridgey.android`, `dev.bridgey.mac`) is a different app;
  the edition never reads its data, and moving between them means pairing again. The test build
  `v0.6.0-rc.2-rr.1` still used the upstream ids, so it is upstream for this purpose. Local builds
  (`<next>-dev`, build 1) are for development and carry no promise.

## Downgrades

Downgrades are not supported. Here is what happens if you try:

- **Android:** Android refuses to install a build with a lower version code over a newer one. The
  only way back is to uninstall, which deletes everything the app keeps, including its Keystore
  identity key. Every Mac then has to forget the phone and pair again.
- **macOS:** nothing stops you from opening an older DMG. An older build then reads the newer files
  like this:
  - **Back to Beta 7 or earlier (from Beta 8 or later): pairing is lost in that build.** Those builds
    read the Keychain, which after the move holds only the marker `moved-to-trust-v3.json` (or
    nothing). They see no trusted phones and create a new identity key, so phones must pair again.
    `trust-v3.json` stays where it is; upgrading again uses it, so the pairing from before the
    downgrade comes back, and pairings made while downgraded are lost.
  - Activity stream: an older build drops item kinds it does not know (folders before Beta 10,
    clipboard offers before Beta 5) and fields it does not know; its next write removes them. Before
    Beta 4 the file is not read at all.
  - Settings: an older build ignores keys it does not know. They stay in the app's defaults and are
    used again after the next upgrade.
  - Folder journals (before Beta 10), the remote control audit (before Beta 9) and the code model
    files (before Beta 13) are ignored and left on disk.
  - Codes from messages: from this change on, an engine value a build does not know reads as "On
    this Mac", never as the cloud.

If you must go back, the reliable path is: Forget the device on both sides, install the older
build, pair again.

## What an upgrade preserves

| What | Kept on upgrade | Limits that still apply |
| --- | --- | --- |
| Pairing: this device's identity key and the devices it trusts | Always | None |
| This device's id (`deviceID`, `device_id`) | Always | None |
| Settings on both apps | Always; a setting added later starts at its default | None |
| Activity stream | Every item | 200 items, 7 days |
| Notification history (Mac, optional) | Every item | 200 items, 7 days |
| Remote control audit (Mac) | Every entry | 500 entries, 30 days |
| Reconnect address book | Every record | 4 addresses per device |
| Folder transfer journals | Resumable transfers | 24 hours after the last progress |
| Clipboard cache | Items still in date | 24 hours, 2 GB |
| On-device code model, its paused download and the terms acceptance (Mac) | Always | None |

Not covered: the diagnostics logs (`diagnostics.json` on both, a bounded ring that may be reset),
the update download cache, and Sparkle's own state.

## How formats are versioned

- **Explicit versions** where a format may need a hard break: `trust-v3.json` (`"version": 3`),
  the old Keychain accounts (`trusted-devices-v1`, `p256-signing-v1`, `state-v2`), the Android
  Keystore alias `bridgey.identity.p256.v1`, folder journals (`"version": 1` on the Mac, header
  `v1` on Android), clipboard offers (`"version": 1`), the address book keys (`address_book_v1`,
  `reconnect.addressBook.v1`) and the code model manifest (`"schema": 1`).
- **Additive JSON** for history files (activity stream, notification history, remote control
  audit): no version field. Fields and kinds are only ever added; readers ignore what they do not
  know and give a missing field its default.
- **Preferences** (Android SharedPreferences, macOS UserDefaults): one key per setting. A new
  setting gets a new key and a default. A key is never renamed, never reused and never changes its
  type (on Android a type change makes the read throw). A retired setting's key is simply no longer
  read.
- **When a reader meets a version it does not know:** the pairing file is refused, left untouched
  and pairing waits (the panel says so); it is never overwritten and never replaced by a new
  identity. Folder journals and clipboard offers of an unknown version are dropped, because they
  only hold work in progress.

## Rule: every format change has a fixture and a test

Any change to what the apps write to disk (a new file, field, key or stored enum value, a renamed
file or folder, a changed type or encoding) needs, in the same change:

1. A **fixture** of the format as released builds wrote it, in
   `protocol/test-vectors/migrations/android/` or `protocol/test-vectors/migrations/macos/`.
   Synthetic only: throwaway keys, made-up names and ids, no real data. Fixtures of released
   formats are never edited; add a new one next to them.
2. A **test** in the migration suite proving the current build loads every older fixture without
   losing trust, settings or history, and drops malformed or unknown entries without crashing:
   `android/app/src/test/java/dev/bridgey/android/migrations/` (JUnit 4 and Robolectric) and
   `macos/Tests/BridgeyMacTests/Migration*Tests.swift`.
3. A new row in the table below.

Readers should drop a bad entry on its own rather than the whole file, and trust must never fall
back to a new identity because a read failed.

Run the suites:

```sh
# Android (on rr-dev-1 every Gradle run goes through iieon-slot)
cd android && iieon-slot ./gradlew :app:testDebugUnitTest --tests 'dev.bridgey.android.migrations.*'

# macOS
cd macos && swift test -Xswiftc -warnings-as-errors --filter Migration
```

The tests use temporary folders and an injected Keychain reader (`LegacyKeychainSource`); they never
touch the real Keychain or the user's Application Support. `BridgeySettings` on the Mac reads
`UserDefaults.standard`, which under `swift test` is the test runner's own domain; the test saves
and restores every `settings.*` key there.

## Formats

Commits are on `rr/main`; "Beta N" is the first edition tag `v0.6.0-rr.1-beta.N` that contains them.

### macOS

| Store | Where | Shape | Introduced | Fixture |
| --- | --- | --- | --- | --- |
| Pairing state, Keychain (v1) | Keychain `in.roundrobin.bridgey.trust` / `trusted-devices-v1` and `in.roundrobin.bridgey.identity` / `p256-signing-v1` | Trust: JSON map, device id to `{id, name, identityKey}`. Identity: the raw 32-byte P-256 key | Beta 1 (696a99d), last written by Beta 7; moved to the file once, then retired with the marker | `trust/keychain-beta.1/` |
| Pairing state, Keychain (v2) | Keychain `in.roundrobin.bridgey.trust` / `state-v2` | JSON `{identityKey (base64), devices: {id: {id, name, identityKey}}}` | Branch builds only (dbb157e), never in a tag | `trust/keychain-branch/` |
| Pairing state, file (v3) | `~/Library/Application Support/in.roundrobin.bridgey/trust-v3.json` (0600, folder 0700, no backup) | `{version: 3, identityKey: base64 raw key, devices: [{id, name, identityKey}]}`, sorted keys, devices by id | Beta 8 (c23ae57) | `trust/trust-v3.*.json` |
| Pre-Keychain trust | defaults `trustedDeviceIDs`, `trusted.<id>.name`, `trusted.<id>.identityKey` | Strings | Upstream before 0.2 only; the edition never wrote it but still imports it | (MacTrustRegistryTests) |
| Device id | defaults `deviceID` | Lower-case UUID | Upstream; Beta 1 | `settings/defaults.beta.*.plist` |
| Settings | defaults `settings.*` | Beta 1: `deviceName`, `onboarding.completed`, `notificationHistory.enabled`, `receiveFolderPath`, `receiveFolderBookmark`, `global.<feature>`, `device.<id>.<feature>` | Beta 1 (upstream keys) | `settings/defaults.beta.1.plist` |
| | | `activity.previews`, `reduceMotion`, `autoClipboard.enabled`, `autoClipboard.device.<id>` | Beta 4 (5fe35fc, d1be408) | `defaults.beta.4.plist` |
| | | `clipboardFiles.enabled`, `clipboardFiles.eagerLimit` (number) | Beta 5 (e19c4bf) | `defaults.beta.5.plist` |
| | | Feature `remote_input_draft1` in `global.*` and `device.*` (off by default) | Beta 9 (01396c0) | `defaults.beta.9.plist` |
| | | `folders.includeHidden`, `folders.includeSystem`; also `folders.lastDestination.<id>` (`{placeId, path}`) | Beta 10 (4e97e06) | `defaults.beta.10.plist` |
| | | `calls.ring`, `logging.*` (9 switches) | Beta 11 (ed3b49c, 1c83719) | `defaults.beta.11.plist` |
| | | `codes.enabled`, `codes.autoCopy`, `codes.installId`, `codes.engine`, `codes.model.acceptance` (JSON data, ISO 8601 dates) | Beta 13 (9e23012, d2c9129) | `defaults.beta.13.plist`, `defaults.codes-before-engine.plist` |
| Other defaults | `updates.channel`; `media.player`, `media.pauseForCalls`, `shortcuts.*` | Strings and Bools | Beta 1 (696a99d); media and shortcuts upstream | `settings/defaults.beta.*.plist` |
| Reconnect address book | defaults data `reconnect.addressBook.v1` | JSON `{id: {addresses: [{host, port, source, lastSeen}], lastConnectedAt?}}`, dates in seconds since 2001 | Beta 8 (c4d5b6e) | `reconnect/` |
| Activity stream | `.../in.roundrobin.bridgey/activity-stream.json` (0600) | Array of `{id, kind, deviceID?, deviceName, fileName?, preview?, appName?, sensitive, automatic, count, at}`, dates in ms | Beta 4 (5fe35fc) | `activity/activity-stream.beta.4.json` |
| | | Adds `bytes?`, `content?` and the `clip_offer_*`, `clip_paste*` kinds | Beta 5 (e19c4bf) | `activity-stream.beta.5.json` |
| | | Adds `fileCount?`, `destination?`, the `folder_*` kinds and folder facts in `content` | Beta 10 (4e97e06) | `activity-stream.beta.10.json` |
| Notification history | `.../in.roundrobin.bridgey/notification-history.json` (0600) | Array of `{id, packageName, applicationName, title, text, receivedAt}`, dates in seconds since 2001 | Upstream (84d1b54); edition folder since Beta 1 (696a99d) | `notification-history/` |
| Remote control audit | `.../in.roundrobin.bridgey/remote-control-audit.json` (0600) | Array of `{id, deviceID, deviceName, mode?, accepted, startedAt, endedAt, endReason, counts, dropped, rejected}`, sorted keys, dates in ms | Beta 9 (01396c0) | `remote-control/` |
| Folder journals (sender) | `.../in.roundrobin.bridgey/FolderTransfers/<id>.json` (0600, folder 0700) | `{version: 1, folderTransferId, deviceID, deviceName, rootPath, bookmark?, displayName, rootName, options, destination?, destinationLabel?, manifestSha256, fileCount, totalSize, createdAt, lastProgressAt, completed}`, dates in ms | Beta 10 (c4c49fb) | `folder-transfers/` |
| Clipboard cache | `.../in.roundrobin.bridgey/ClipboardCache/<offerId>/<index>/<name>`, `.handed-out`, `outgoing/` | Folders and files only, no index file | Beta 5 (e19c4bf) | built in the test |
| Code model | `.../in.roundrobin.bridgey/Models/installed.json`, `download.json`, `bridgey-otp-v<N>.gguf(.part)` | `installed.json`: `{version, name, size, sha256, fileName, installedAt}`; `download.json`: `{manifest, userPaused}`; ISO 8601 dates | Beta 13 (d2c9129) | `models/` |

### Android

| Store | Where | Shape | Introduced | Fixture |
| --- | --- | --- | --- | --- |
| Identity key | Android Keystore alias `bridgey.identity.p256.v1` | EC P-256 signing key, never leaves the Keystore | Upstream 0.1 (fd97fd1), unchanged | name pinned in `StorageNamesTest` |
| Trusted Macs | SharedPreferences `bridgey.trust` | `peer.<id>.name`, `peer.<id>.identityKey` (base64 public key); a key without a name shows as "Unknown device" | Upstream 0.1 (fd97fd1), unchanged | `shared_prefs/beta.*/bridgey.trust.xml` |
| Device id and service switch | SharedPreferences `bridgey` | `device_id` (UUID), `bridgey_enabled` | Upstream | `bridgey.xml` |
| Onboarding | SharedPreferences `bridgey_onboarding` | `completed` | Upstream | `bridgey_onboarding.xml` |
| Settings | SharedPreferences `bridgey.settings` | `device_name`, `global.<feature>`, `device.<id>.<feature>`, `notification.application.<package>`, `notification.disabled_packages` (string set), `calls.direct_enabled` | Beta 1 (upstream keys) | `shared_prefs/beta.1/` |
| | | `clipboard.auto.global`, `clipboard.auto.device.<id>`, `clipboard.background.enabled` | Beta 4 (c3edc84) | `beta.4/` |
| | | `clipboard.files.enabled`, `clipboard.files.eager_limit` (long) | Beta 5 (0982ca4) | `beta.5/` |
| | | `connection.keep_wifi_awake` | Beta 8 (129147d) | `beta.8/` |
| | | Feature `remote_input_draft1` (off by default) | Beta 9 (24a55f7) | `beta.9/` |
| | | `files.folder_destination`, `files.folder_conflict`, `files.folder_default_place`, `files.folder_allow_replace`, `files.folder_recent` (JSON) | Beta 10 (af501f7) | `beta.10/` |
| | | `clipboard.screenshot.enabled`, `logging.*` (9 switches) | Beta 11 (3ba3f65, 1c83719) | `beta.11/`, `beta.13/` |
| Appearance and privacy | SharedPreferences `bridgey.ui` | `show_activity_previews`, `reduce_motion` (Beta 2, 6030623 and a992670); `qs_tile_added` (Beta 4, deac2c5); `battery_prompt_shown` (Beta 8, 129147d) | Beta 2 | `bridgey.ui.xml` |
| Updates | SharedPreferences `bridgey.updates` | `channel`, `last_checked_at`, `snoozed_version_code`, `snoozed_until`, `notified_version_code` (Beta 1, 696a99d); `skipped_version_code` (Beta 11, 182a07b) | Beta 1 | `bridgey.updates.xml` |
| Reconnect address book | SharedPreferences `bridgey.reconnect`, key `address_book_v1` | JSON `{id: {lastConnectedAt?, addresses: [{host, port, source, lastSeen}]}}`, dates in ms | Beta 8 (06e8914) | `beta.8/` on, `bridgey.reconnect.xml` |
| Activity stream | `noBackupFilesDir/activity-stream.json` (owner only) | Array of `{id, kind, deviceId, deviceName, fileName, preview, appName, sensitive, count, at}`, dates in ms | Beta 2 (6030623, a992670) | `activity/activity-stream.beta.2.json` |
| | | Adds `automatic` and the `clipboard_receive_failed` kind | Beta 4 (c3edc84) | `activity-stream.beta.4.json` |
| | | Adds `bytes`, `content` and the `clip_*` kinds | Beta 5 (0982ca4) | `activity-stream.beta.5.json` |
| | | Adds `fileCount`, `destination`, `detail` and the `folder_*` kinds | Beta 10 (af501f7) | `activity-stream.beta.10.json` |
| Folder journals (receiver) | `noBackupFilesDir/folder-transfers/<id>.journal` (owner only) | Text: header `v1 <peer> <sha> <createdAt> <place> <choice> <rootName> <rootUri> <label> <oneOffTree>`, then `d`, `p`, `r`, `f`, `x` lines; URL-encoded fields; last progress is the file's modification time | Beta 10 (b381592, af501f7) | `folder-transfers/` |
| Clipboard cache | `noBackupFilesDir/clipboard-cache/<offerId>/offer.json`, `<index>/data`, `complete`, `handed-out` | `offer.json`: `{offer: {version: 1, offerId, createdAt, sensitive?, items: [...]}, deviceId, peerName, receivedAt}` | Beta 5 (f5229f8, 0982ca4) | `clipboard-cache/` |
| Other preferences | `bridgey.places` (Beta 10, 552f197), `bridgey.remote` (Beta 9, 24a55f7), `bridgey.screenshot` (Beta 11, 3ba3f65), `bridgey_codes` (Beta 13, 9e23012) | Owned by the Files, remote control, screenshot and codes features | As listed | None yet (deferred) |

## Known gaps (to close before 1.0)

- On the Mac, notification history, the remote control audit and the reconnect address book are
  read with strict decoding: one entry that does not decode (for example an address `source` a
  newer build added) drops the whole file. History and the audit start empty and the next write
  replaces the file; the address book is rebuilt from Bonjour and connections.
- On Android, an address book entry that is not a JSON object drops the whole book (a bad address
  inside an entry is dropped on its own).
- The Android preferences of Files places, remote control, fresh screenshots and code access have
  no migration fixtures yet.
- A macOS downgrade below Beta 8 loses pairing in the older build (see Downgrades).
