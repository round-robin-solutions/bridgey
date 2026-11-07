# Bridgey by Round Robin

This repository is **Bridgey by Round Robin**, Round Robin's edition of
[Bridgey](https://github.com/singeol/bridgey). Built on Bridgey by Semyon Mikhailov,
under the same [MIT licence](LICENSE).

- A separate app (`in.roundrobin.bridgey` on Android and macOS) that installs next to upstream
  Bridgey. New pairing requires protocol 2 on both peers; see
  [pairing compatibility](docs/compatibility.md#pairing-with-other-bridgey-versions).
- In-app updates with three channels, Stable, Beta and Nightly, chosen in Settings.
- Downloads: [releases of round-robin-solutions/bridgey](https://github.com/round-robin-solutions/bridgey/releases).
  Each release has the Android APK, a macOS DMG and ZIP, `SHA256SUMS`, an SBOM per platform and a
  provenance file.

What differs from upstream, how releases and channels work, where the signing keys live and
how to merge upstream changes: [docs/rr-edition.md](docs/rr-edition.md).

## Install

- **Mac, Homebrew:** `brew install --cask round-robin-solutions/tap/bridgey-rr`. The cask comes from
  [round-robin-solutions/homebrew-tap](https://github.com/round-robin-solutions/homebrew-tap) and
  installs the newest Stable release (until the first Stable release exists, the newest Beta). The app
  is ad-hoc signed because Round Robin has no Apple Developer membership yet, so the cask clears the
  quarantine flag on the installed app. The app then updates itself.
- **Mac, DMG:** download `Bridgey-RR-<version>-macOS.dmg` from the
  [releases page](https://github.com/round-robin-solutions/bridgey/releases), drag the app to
  Applications and, the first time, right-click it and choose **Open**.
- **Android, APK:** download `Bridgey-RR-<version>-Android.apk` from the same page and open it.
  Android asks once to allow installs from your browser or Files.
- **Android, Obtainium:** open one of the links below on the phone with
  [Obtainium](https://obtainium.imranr.dev) installed. Obtainium then installs and updates the APK from
  GitHub Releases. There is no Stable release yet, so use the Beta link for now.

<!-- obtainium:start markdown -->
[Stable](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522in.roundrobin.bridgey%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fround-robin-solutions%252Fbridgey%2522%252C%2522author%2522%253A%2522Round%2520Robin%2522%252C%2522name%2522%253A%2522Bridgey%2520by%2520Round%2520Robin%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522includePrereleases%255C%2522%253Afalse%257D%2522%257D) | [Beta](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522in.roundrobin.bridgey%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fround-robin-solutions%252Fbridgey%2522%252C%2522author%2522%253A%2522Round%2520Robin%2522%252C%2522name%2522%253A%2522Bridgey%2520by%2520Round%2520Robin%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522includePrereleases%255C%2522%253Atrue%252C%255C%2522filterReleaseTitlesByRegEx%255C%2522%253A%255C%2522-rr%255B.%255D%255B0-9%255D%252B%28-beta%255B.%255D%255B0-9%255D%252B%29%253F%2524%255C%2522%257D%2522%257D)
<!-- obtainium:end -->

The apps check for updates themselves on the channel you pick in Settings (Stable, Beta or Nightly).
More in the [user guide](docs/user-guide.md#install).

**Current milestone: v0.10, stabilisation.** The [roadmap below](#roadmap) tracks what this
edition has implemented and what still needs work. As of 2026-11-04, the latest published app
release is [0.10.0-rr.1 Beta 22](https://github.com/round-robin-solutions/bridgey/releases/tag/v0.10.0-rr.1-beta.22)
and the agent command is [0.2.0](https://github.com/round-robin-solutions/bridgey/releases/tag/cli-v0.2.0).
Settings search is merged and tagged for Beta 23; its app release is still pending.

Guides:

- [User guide](docs/user-guide.md): install, pair, send, notifications, calls, codes, remote
  control, updates, permissions, reset, uninstall, troubleshooting.
- [Compatibility](docs/compatibility.md): which phones and Macs have been tested, and how to
  report a result.
- [Diagnostics](docs/diagnostics.md): how to export, what is inside, what is never included.
- [Developer guide](#developer-guide): checks to run, protocol contract, tests, releases.

### Why can't copying on the phone sync automatically like O+ Connect or Phone Link?

Since Android 10, an app can read the clipboard only while it is on screen, or if it is the
keyboard ([Android 10 clipboard changes](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)).
OnePlus O+ Connect and Microsoft Phone Link are system or phone-maker partner apps: they hold
`READ_CLIPBOARD_IN_BACKGROUND`, which only apps signed by the phone maker can get. ADB cannot
grant it, and an app installed from a download cannot hold it. So Bridgey does the most that is
allowed: Mac to phone is always automatic; phone to Mac is automatic while Bridgey is open,
otherwise one tap on "Send copied item" in the notification or on the Quick Settings tile. The
optional "Background clipboard (advanced)" uses the same one-time ADB setup as
[KDE Connect](https://userbase.kde.org/KDEConnect) (it grants READ_LOGS, reading system logs) and
is off by default.

The project overview below is adapted from upstream. The roadmap records this edition's
progress; [upstream's roadmap](https://github.com/singeol/bridgey#roadmap) remains separate.

---

# Bridgey

[![Build](https://github.com/singeol/bridgey/actions/workflows/ci.yml/badge.svg)](https://github.com/singeol/bridgey/actions/workflows/ci.yml)
[![Security](https://github.com/singeol/bridgey/actions/workflows/security.yml/badge.svg)](https://github.com/singeol/bridgey/actions/workflows/security.yml)
[![Latest release](https://img.shields.io/github/v/release/singeol/bridgey)](https://github.com/singeol/bridgey/releases/latest)
[![License: MIT](https://img.shields.io/github/license/singeol/bridgey)](LICENSE)

[Website and documentation](https://bridgey.ai/) ·
[Download the latest release](https://github.com/singeol/bridgey/releases/latest)

Bridgey is an open-source, local-first bridge between Android and macOS. It aims
to provide a small, native and extensible subset of Apple Continuity and KDE
Connect without accounts, telemetry, or a mandatory cloud service. A Linux
client can later implement the same public protocol without Android changes.

> This edition builds on upstream's local Android–macOS companion with remote input,
> folders and phone-file browsing, multiple devices, automation, text messages,
> view-only phone screen sharing, optional off-LAN connections, codes and an agent CLI.
> It is still in Beta. Discovery data is intentionally treated as untrusted.

## MVP scope

- Explicit two-device pairing with a shared verification code
- Persistent TCP connections with application-layer AES-GCM encryption and pinned peer signing identities
- Plain-text and HTML clipboard synchronization with a safe payload limit
- Streaming file transfer with progress and cancellation
- Android notification forwarding to native macOS notifications
- Android battery status on macOS
- Find Device in both directions
- Start a phone call from selected text or the macOS clipboard

The edition has extended this original MVP. See the roadmap for implemented features,
experimental capabilities and the acceptance work still required before v1.0.

## Roadmap

Updated 2026-11-04 against `rr/main` through the Settings search merge (`b7d30c0`),
app releases through Beta 22 and CLI 0.2.0. Checked items are implemented in this edition;
they do not imply upstream acceptance or certification on every device. Beta 23 items are
identified separately until the release publishes.

Milestones describe direction, without fixed dates. **v0.10 is the current stabilisation
milestone; v1.0 has not shipped.** A stable, secure Android–macOS companion defines v1.0;
experimental plugins do not block it. Device coverage is recorded in the
[compatibility matrix](docs/compatibility.md), separately from automated checks.

### v0.2.1 — settings and quality

- [x] Synchronize feature availability between connected devices
- [x] Add a native macOS Settings window and clearer unavailable-feature states
- [x] Add lint, unit-test, CodeQL, dependency-review, and Dependabot workflows
- [x] Audit build tools, libraries, and refresh GitHub Actions
- [x] Migrate Android to AGP 9 and built-in Kotlin in a separately validated change
- [x] Complete device testing of settings changes and publish the patch release

### v0.3.0 — reliability

- [x] Add Android–macOS protocol integration tests with deterministic generated identities
- [x] Add malformed-message, interrupted-transfer, and reconnect test scenarios
- [x] Improve simultaneous transfer history, retry, and recovery behavior
- [x] Add structured diagnostics that can be exported without private content

### v0.4.0 — platform integration

- [x] Add an Android share target for sending files and text to a trusted device
- [x] Add drag-and-drop file sending on macOS
- [x] Add richer clipboard content after text synchronization is fully hardened
- [x] Improve accessibility, localization readiness, and first-run guidance

### v0.5.0 — notifications and communication

- [x] Synchronize notification dismissal/removal state between Android and macOS
- [x] Support notification action buttons and inline replies when Android exposes them
- [x] Add per-application notification filters and a private local history
- [x] Research SMS viewing/replies and document the permission-safe notification-action scope
- [x] Show live call state with explicit Answer, Decline, and Hang Up controls
- [x] Start a validated phone call from selected macOS text or the clipboard

### v0.6.0 — media and quick actions

- [x] Control Music/Spotify on macOS from Android: play/pause, previous/next, seek, and player volume
- [x] Show bounded now-playing metadata and local Music artwork when exposed by the player
- [x] Optionally pause the selected player while a phone call is ringing or active
- [x] Send and explicitly open web links in either direction
- [x] Add a lightweight Ping action separate from Find Device
- [x] Show Mac battery status on Android
- [x] Add an Android Quick Settings tile and configurable macOS shortcuts
- [ ] Complete multi-OEM stabilization of the v0.5 call and notification lifecycle

The feature code and call/notification fixes are included in the edition. Multi-OEM
acceptance remains open: only the OnePlus 11 has physical-phone results. See the
[0.6 acceptance checklist](docs/testing-0.6.md) and [compatibility matrix](docs/compatibility.md).
Media control is opt-in. Music and Spotify have dedicated controls; other installed players
can be selected for media-key control, with metadata and artwork depending on the player.

### v0.7.0 — remote input and presentations

- [x] Use Android as an opt-in macOS touchpad and keyboard
- [x] Support pointer movement, clicks, scrolling, dragging, and bounded text input
- [x] Add presentation actions for previous/next, start/full screen, escape, and laser pointer
- [x] Request macOS Accessibility access only when remote input is explicitly enabled
- [x] Require a visible active-session indicator and an immediate local stop control
- [x] Rate-limit remote input and keep a private audit log of remote-control sessions
- [x] Grant remote-control capabilities independently for every trusted device

Implemented with `remote_input_draft1`. Physical-device acceptance is tracked in the
[remote input checklist](docs/testing-remote-input.md).

### v0.8.0 — Files 2.0 and multiple devices

- [x] Send multiple files and folders with a visible queue and deterministic conflict handling
- [x] Resume folders at file boundaries, keeping verified completed files after disconnect or restart
- [ ] Resume an interrupted file from its last verified chunk rather than byte zero
- [x] Browse only Android folders explicitly granted through the system Storage Access Framework
- [x] Upload to and download from granted folders without broad storage permissions
- [x] Improve Finder, Quick Look, Downloads, and transfer-history integration
- [x] Support multiple simultaneous trusted-device sessions with per-device settings
- [ ] Stress-test cancellation, reconnection, and multi-gigabyte transfers in both directions

Includes the Mac Phone files browser, thumbnails, previews, folders both ways and the
[fast binary transfer path](docs/transfer-speed.md). File-level folder recovery is implemented;
the broader resumable transfer engine remains on hold. Existing emulator benchmarks do not
close real-Wi-Fi, large-library and long-running acceptance. See
[Files](docs/files-browse.md) and [folders and settings sync](docs/folders-and-settings-sync.md).

### v0.9.0 — automation and experimental communication

- [x] Add locally configured actions for lock, sleep, screensaver, volume, and launching an app
- [x] Permit custom automation only through a local allowlist; never expose a remote shell
- [x] Add Android Device Controls/widgets, link handoff and Mac Shortcuts/Siri actions
- [ ] Package browser extensions for link handoff
- [x] Add a privacy-preserving connection health and diagnostics view
- [x] Prototype explicitly confirmed, view-only phone-to-Mac screen sharing
- [ ] Add Mac-to-phone screen sharing and separately consented phone control
- [x] Add separately consented SMS conversations, new messages, contact names, SIM selection
      and delivery status in this APK edition; MMS images are read-only
- [x] Keep notification-based message replies as the permission-light fallback
- [x] Add phone battery alerts, Focus/Do Not Disturb sync and phone camera capture to the Mac

Screen sharing is an off-by-default, view-only prototype with per-session confirmation and
a persistent local indicator. SMS is opt-in and separately permissioned in the directly
distributed APK; this does not claim approval for a store distribution. Neither experimental
capability blocks v1.0. See [automation](docs/automation.md),
[screen sharing](docs/screen-sharing.md) and [SMS policy](docs/sms-call-policy.md).

### v0.10.0 — stabilisation and edition extensions (current Beta)

- [x] Draft the protocol contract and machine-readable message list; add strict decoding,
      fuzz cases, cross-platform golden vectors and upgrade/migration tests
- [x] Harden first pairing with protocol 2 commit/reveal and explicit confirmation on both devices
- [x] Explain optional permissions in setup and a Permissions page; add local-data reset controls
- [x] Publish compatibility, diagnostics, user and developer guides, plus release checksums,
      SBOMs and provenance
- [x] Ship Homebrew/Obtainium install paths, Stable/Beta/Nightly channels, What's new,
      Update all and automatic coordinated updates
- [x] Redesign both apps around devices and a private activity stream; add shared settings sync
- [x] Connect away from home through direct internet routes or an optional encrypted relay,
      with LAN preferred and no phone VPN required for relay connections
- [x] Add automatic clipboard, explicit image/file clipboard handoff, Handoff takeover controls
      and selection of other installed media players
- [x] Read SMS codes locally on a Mac or through the chosen cloud route; read email codes from
      Gmail, Outlook, Proton Mail and Spark notifications on the Mac only, with one shared
      pipeline, deduplication and Latest/Older labels
- [x] Ship the Rust agent CLI: invite pairing, files, clipboard, notifications, questions,
      device status and codes, with per-server grants, limits and an audit on the phone
- [x] Keep SMS code detection available when all Macs are offline: a permitted server running
      the shared Rust reader, or the phone's separately enabled cloud fallback
- [x] Add pairing over Tailscale addresses for Mac–Mac, server–Mac and server–server;
      new peers start restricted until explicitly trusted
- [x] Merge Settings search on Mac and Android: synonyms, typo tolerance, grouped results,
      and a jump/highlight to the setting (**Beta 23 tagged; release pending**)
- [ ] Complete live Settings search checks on Android and Mac keyboard/scroll interactions
- [ ] Complete the v1.0 acceptance work below before freezing the protocol or declaring Stable

Details: [edition](docs/rr-edition.md), [connect anywhere](docs/connect-anywhere.md),
[email codes](docs/codes-from-email.md), [agent CLI setup](docs/agent-cli-setup.md) and
[codes without a Mac and tailnet pairing](docs/mesh-and-codes.md#phase-2-2026-11-04).
For an existing Tailscale network, follow the
[Tailscale setup and pairing guide](docs/tailscale-setup.md).
The default CLI package does not include the optional local detection model/runner.

### v1.0.0 — stable local companion

- [ ] Freeze and document the Bridgey Protocol v1 compatibility contract
- [ ] Complete supported-upgrade acceptance for trust, settings and local history on real devices
- [ ] Complete long-running sleep, Wi-Fi-change, process-restart and interrupted-transfer acceptance
- [ ] Extend existing malformed-input, fuzz and cross-platform tests with long-lived device runs
- [x] Publish an Android/OEM and macOS compatibility matrix with tested and unverified rows
- [ ] Expand physical-device coverage beyond OnePlus 11 and the tested Apple silicon Macs
- [ ] Complete security, privacy, accessibility, and English/Russian localization reviews
- [x] Explain every optional permission in onboarding and provide local-data reset controls
- [x] Publish checksums, SBOM/provenance, diagnostics guidance, and user/developer documentation
- [x] Provide a clear update path and repeatable Android and macOS release packaging

Developer ID signing and notarization remain desirable when an Apple Developer
membership is available, but do not prevent a documented open-source v1.0.

### Remaining extensions

These are open items, not promises for the next Beta:

- [ ] Calls window with a dialer, contacts and WhatsApp voice/video actions
- [ ] Further email-code sources (phase 2); email detection on servers remains deferred
- [ ] Fully peer-to-peer mesh invites (`v: 2`) and one-hop Update all without a phone hub
- [ ] Local code detection on the phone; the shipped fallback uses the cloud by explicit choice
- [ ] Resumable content-addressed transfer engine (on hold), with verified recovery inside a file
- [ ] Temporary guest pairing without permanent trust and wider one-time remote permissions
- [ ] Home, Work and Public Network profiles with conservative defaults on unfamiliar networks
- [ ] A documented plugin SDK for future clients

Time-windowed agent grants, private action audits, image/file clipboard handoff, QR/link server
invites and the optional end-to-end encrypted relay are already implemented; wider guest
pairing and mesh invites remain separate work.

### After v1.0 / exploratory

- [ ] Linux client using the public Bridgey protocol
- [ ] Windows and iOS clients where platform restrictions permit useful background behavior
- [ ] Bluetooth transport fallback when local-network discovery is unavailable
- [ ] Optional accounts for recovery without making accounts mandatory
- [ ] Contacts and call-history synchronization only as separately consented plugins
- [ ] Developer ID signing and notarization when an Apple Developer membership is available
- [ ] Mac gallery manager (v2), alongside native Windows/Linux clients using the Rust core

## Repository

```text
android/              Kotlin + Jetpack Compose application and core tests
macos/                Swift + SwiftUI menu-bar application
protocol/             Machine-readable, platform-independent schemas
docs/architecture.md  Components, ownership, and delivery sequence
docs/protocol.md      Version 1 wire protocol
SECURITY.md            Threat model and cryptographic design
```

## Build and run

### Android

Requirements: Android Studio with JDK 17 and Android SDK 36. Open `android/`,
let Android Studio use its bundled JDK, then run the `app` configuration on an
Android 8.0+ device. From the command line, use the versioned Gradle Wrapper:

```bash
cd android
./gradlew :app:lintDebug :app:testDebugUnitTest :app:assembleDebug
```

Release APKs are signed by GitHub Actions using repository secrets. Never
commit an Android keystore.

### macOS

Requirements: macOS 13+, Swift 5.10+, and Xcode for producing a signed app.
The discovery/menu-bar target can also be compiled and tested as a Swift
package:

```bash
cd macos
./build-app.sh
open .build/debug/Bridgey.app
```

The `.app` bundle is required for Notification Center integration. The raw
SwiftPM executable remains useful for core diagnostics, but macOS does not
register it as a notification-capable application.

Create local release archives with:

```bash
cd macos
./package-release.sh
```

The current pipeline uses an ad-hoc macOS signature. Users may need to approve
the app in Privacy & Security until Developer ID signing and notarization are
configured.

## Automated releases

Pull requests and pushes to `main` build both clients. Tags matching `v*`
attach a signed Android APK, a macOS DMG/ZIP, and SHA-256 checksums to a GitHub
Release.

Configure these GitHub Actions secrets before creating the first tag:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Back up the original Android keystore and passwords permanently. Every future
update must be signed with the same key.

Local-network discovery works best on real devices on the same Wi-Fi network.
The macOS executable may require local-network permission when prompted.

## Permissions and privacy

Bridgey asks for access only when the related feature needs it:

- Android notifications let the foreground connection, transfer progress,
  received files, and Find Device controls remain visible.
- Android notification access is optional and is used only to forward a
  notification's application name, title, and text to the paired Mac.
- Android Phone access is optional and requested only when the user enables
  call status and controls. `CALL_PHONE` starts validated calls,
  `READ_PHONE_STATE` distinguishes ringing from active calls, and
  `ANSWER_PHONE_CALLS` enables Answer, Decline, and Hang Up. Bridgey does not
  request contacts or call-log access. Without this opt-in, a request from Mac
  opens the system dialer through an Android notification for confirmation.
- macOS local-network access is required for Bonjour discovery and direct
  encrypted connections to Android devices.
- macOS notifications are optional and are requested only when the user enables
  Android notification display on the Mac.
- File access is scoped to the files selected by the user and the Bridgey
  receive directory (`Downloads/Bridgey`).

Bridgey does not request location, contacts, SMS, call-log, camera, microphone,
screen recording, Accessibility, Input Monitoring, or Full Disk Access.
Permission denial disables only the corresponding optional integration.

## Settings

Open **Settings** on Android or the gear menu on macOS to:

- change the name advertised to nearby Bridgey devices;
- enable Clipboard, File transfer, Notification forwarding, Battery status,
  Find Device, and Calls from Mac globally;
- override those features for each trusted device or forget its trust record;
- choose the macOS folder used for received files;
- start the macOS app automatically at login.

To call from macOS, copy a phone number and press **Call** in Bridgey or
`Control-Option-P`. In applications that expose macOS Services, select a phone
number and choose **Services → Call with Bridgey**. Android uses confirmation
mode by default: tap the call-request notification to review the number in the
system dialer. An explicit Android Settings switch enables call status and
controls. It asks for `CALL_PHONE`, `READ_PHONE_STATE`, and
`ANSWER_PHONE_CALLS` so Bridgey can start a validated call, distinguish
ringing from an active call, and answer, decline, or hang up from the paired
Mac. It does not request contacts or call history, and emergency numbers are
never dialled directly by Bridgey.

Bridgey can also handle `tel:` links from browsers. In macOS Settings, press
**Use Bridgey for phone links** once; this explicit action makes Bridgey the
default phone-link handler. Browsers still show their external-application
confirmation before opening Bridgey and sending the validated number.

Incoming and active calls appear in a compact floating macOS call panel with
explicit controls. It stays available across Spaces without activating Bridgey
or taking focus from the current app; hiding it leaves the same controls in the
Bridgey menu-bar panel.

Connected devices exchange their effective feature state over the encrypted
session. A feature is available only when both devices enable it, so controls
and battery status update immediately on the other device. A file transfer
already accepted is allowed to finish, while disabling Find Device stops a
currently playing alert. Android received files remain in `Download/Bridgey`;
this uses scoped `MediaStore` access and avoids requesting broad storage
permission.

You can pick or drop several files at once on either device. They are sent one
after another as a visible queue in the transfer list: each waiting file shows
**Queued** and can be cancelled on its own, and cancelling all transfers also
empties the queue. Folders are not sent. A received file never replaces an existing
one: macOS adds a number (`photo 2.jpg`) and Android lets the system add one
(`photo (1).jpg`).

Recent file transfers remain visible until cleared. An outgoing transfer that
fails or is interrupted can be retried after the devices reconnect; retrying
creates a new transfer and starts from byte zero so that integrity verification
remains simple and deterministic. Each client keeps at most 20 completed or
interrupted entries in memory.

The Round Robin edition's Android app keeps a local activity stream (at most 200
items for seven days, owner-only, never backed up). Clipboard items keep a
one-line preview of at most 80 characters ("Hidden" for clips marked sensitive),
alert items the app name, and incoming calls the caller when the notification
shows one; Settings > Privacy > "Show previews in activity" turns that off. See
[the edition notes](docs/rr-edition.md#android-activity-stream-and-privacy). The macOS
app keeps the same stream under the same rules in its Application Support folder
([macOS notes](docs/rr-edition.md#macos-activity-stream-and-privacy)).

Settings can export a structured diagnostics JSON file. It contains bounded
event metadata, application/platform versions, feature states, connection
state, and transfer counts. It never includes clipboard text, notification
content, file names, network addresses, or full device/session/transfer
identifiers (a device appears only as the first eight characters of its ID).
See [docs/diagnostics.md](docs/diagnostics.md) for the export steps, the
fields, and how to share a report safely.

## Development principles

- Core routes envelopes and lifecycle events; it does not understand plugin
  payloads.
- Every plugin declares capabilities and owns its message types.
- Logs may include state transitions, message IDs, and peer IDs, but never
  secrets or clipboard/notification contents.
- No data learned through Bonjour/mDNS is trusted before authenticated pairing.
- Protocol changes are documented in `docs/protocol.md` before implementation.

Suggested debug log categories are `DISCOVERY`, `PAIRING`, `TRANSPORT`, and
`PLUGIN`. See [the architecture](docs/architecture.md), [wire protocol](docs/protocol.md),
the [security model](SECURITY.md), and [security testing](docs/security-testing.md).

## Developer guide

Run these before opening a pull request. They are close to what RR CI runs (see
[docs/rr-edition.md](docs/rr-edition.md#with-rr-ci)).

```bash
# Android: lint, unit tests and a debug build
cd android && ./gradlew :app:lintDebug :core:discovery:lintDebug \
  :app:testDebugUnitTest :core:discovery:testDebugUnitTest :app:assembleDebug

# macOS: tests (warnings are errors) and the app bundle
cd macos && swift test -Xswiftc -warnings-as-errors --skip MacTrustRegistryTests && ./build-app.sh

# Release scripts
python3 -m unittest discover -s scripts/rr/tests
```

Android needs JDK 17 and the Android SDK 36. The Mac needs Swift 5.10 or later. The Mac test run
skips `MacTrustRegistryTests`.

### Protocol changes

- Document a change in [docs/protocol.md](docs/protocol.md) before you implement it. The
  compatibility rules are in `docs/protocol-contract.md`.
- `protocol/messages.json` is the list of every message kind. A new kind must be added there. A
  test on each platform fails if a kind used in code is missing from the list.
- `protocol/test-vectors/` holds golden vectors that both platforms must match (for example the
  cryptographic vectors in `crypto-v1.properties`). Change a vector only with a protocol change,
  and update both platforms in the same pull request.

### Fuzz tests

Parser and decoder fuzz tests run in normal test runs with a bounded number of iterations, so they
stay fast. For a long run, set `BRIDGEY_FUZZ_ITERATIONS=100000` for both suites:

```bash
cd android && BRIDGEY_FUZZ_ITERATIONS=100000 ./gradlew :app:testDebugUnitTest -Pfuzz=100000
cd macos && BRIDGEY_FUZZ_ITERATIONS=100000 swift test -Xswiftc -warnings-as-errors --skip MacTrustRegistryTests
```

On Android the `-Pfuzz=100000` Gradle property does the same as the environment variable, and the
two can be used together.

### Stored data and upgrades

Every change to a file format on disk or a stored setting needs a migration, a fixture of the old
format, and a test that loads the fixture. The rules are in `docs/upgrade-policy.md`.

### Releases

Releases are built by `scripts/rr/` (see [docs/rr-edition.md](docs/rr-edition.md#releasing) and
[docs/releasing.md](docs/releasing.md)). Each release has the APK, the DMG and ZIP and
`SHA256SUMS`. The SBOM and provenance assets, and how to verify them, are described in
[docs/releasing.md](docs/releasing.md).

### Other developer docs

[Architecture](docs/architecture.md), [wire protocol](docs/protocol.md),
[security model](SECURITY.md), [security testing](docs/security-testing.md),
[reconnect reliability](docs/reconnect-reliability.md), [device test plans](docs/testing-0.6.md),
and [Mac signing](docs/rr-mac-signing.md).

## Contributing

Keep changes narrowly scoped and independently testable. New plugin proposals
should define capabilities, message schemas, permissions, privacy impact, and
failure behavior. By contributing, you agree that your contribution is
licensed under the MIT License.

## Credits

Bridgey is designed and developed by Semyon Mikhailov with the assistance of
[OpenAI Codex](https://openai.com/codex/). Product decisions, testing, and
release responsibility remain with the project maintainer.
