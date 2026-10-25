# Bridgey by Round Robin

Bridgey by Round Robin is Round Robin's edition of [Bridgey](https://github.com/singeol/bridgey),
the open-source Android and macOS bridge by Semyon Mikhailov (MIT licence). It is a separate
app with its own identity, signing keys and self-updates, published from
`round-robin-solutions/bridgey`. It still speaks the upstream wire protocol, so it pairs with
upstream clients.

## What differs from upstream

| Area | Upstream | This edition |
| --- | --- | --- |
| Android application id | `dev.bridgey.android` | `in.roundrobin.bridgey` |
| macOS bundle id | `dev.bridgey.mac` | `in.roundrobin.bridgey` |
| Name | Bridgey | Bridgey by Round Robin (launcher label "Bridgey RR"; macOS `CFBundleName` "Bridgey RR") |
| macOS app file | `Bridgey.app` | `Bridgey by Round Robin.app`, so both can sit in /Applications |
| macOS Keychain items | `dev.bridgey.mac.trust`, `dev.bridgey.identity` | `in.roundrobin.bridgey.trust`, `in.roundrobin.bridgey.identity` |
| macOS support folders | `~/Library/Application Support/Bridgey`, `~/Library/Caches/Bridgey` | `.../in.roundrobin.bridgey` |
| macOS legacy import | reads the old `BridgeyMac` defaults suite | never reads it (it belongs to upstream) |
| URL handler name, Services item | `dev.bridgey.mac.phone`, "Call with Bridgey" | `in.roundrobin.bridgey.phone`, "Call with Bridgey RR" |
| Android clipboard task affinity | `dev.bridgey.android.clipboard_action` | `${applicationId}.clipboard_action` |
| Updates | none (manual downloads) | Stable, Beta and Nightly channels, in-app updates |
| Releases | GitHub Actions on `v*` tags | `scripts/rr/release.sh` on our own machines; `release.yml` is manual-only |

Unchanged on purpose: the wire protocol, the Bonjour service type `_bridgey._tcp`, the default
port 42458, Kotlin and Swift package names, and the visual design. Because the port is the
same, the upstream app and this edition cannot both accept connections on one Mac at the same
time; quit one of them.

UserDefaults, Android SharedPreferences, Android Keystore keys, notification channels and the
FileProvider authority (`${applicationId}.fileprovider`) are already per app, so they needed no
change.

Edition settings live in one file, `rr-edition.properties`: app id, names, the next version,
the GitHub repository, the feed base URL and the expected Android certificate fingerprint.
Gradle, `macos/build-app.sh` and `scripts/rr/*` all read it. The Sparkle public key is in
`macos/Resources/Info.plist` (`SUPublicEDKey`).

The About section in Settings on both apps says "Built on Bridgey by Semyon Mikhailov" and
links to the original project. Keep it, and keep `LICENSE`.

## Versions

- **Version name** (shown to people): `0.6.0-rr.1` for Stable, `0.6.0-rr.2-beta.1` for Beta,
  `0.6.0-rr.2-nightly.20261025` for Nightly. The first part is the upstream version the
  edition is based on; `rr.N` counts our releases on it. Betas and nightlies carry the
  number of the stable release they lead to (`EDITION_NEXT_VERSION`).
- **Build number** (Android `versionCode`, macOS `CFBundleVersion`): the UTC build time as
  `YYDDDHHMM` (two-digit year, day of year, hour, minute). 25 October 2026 13:15 UTC is
  `262981315`. It grows with time on every channel, so one number orders all builds, and it
  stays below Android's limit of 2,100,000,000 until 2099.
- Local builds (Android Studio, `swift run`, `./build-app.sh`) are `<next>-dev` with build 1,
  so any published build counts as newer.

The release script computes both, and refuses to publish a build that is not newer than the
one already on that channel.

## Channels and feeds

Each channel has a JSON feed, and macOS also has one Sparkle appcast. They are assets of a
fixed GitHub release with the tag `channels`, overwritten on each publish:

```
https://github.com/round-robin-solutions/bridgey/releases/download/channels/stable.json
https://github.com/round-robin-solutions/bridgey/releases/download/channels/beta.json
https://github.com/round-robin-solutions/bridgey/releases/download/channels/nightly.json
https://github.com/round-robin-solutions/bridgey/releases/download/channels/appcast.xml
```

Release downloads do not count against the GitHub API rate limit and need neither Pages nor
Actions. The `channels` release is a prerelease so it never becomes "latest".

A feed holds the newest release of its channel: `version`, `build`, `notesUrl`, `notes`, an
`android` entry (version name and code, APK URL, SHA-256, size, minimum SDK) and a `macos`
entry (version, build, minimum macOS, DMG and ZIP with URL, SHA-256 and size, and the
EdDSA signature of the ZIP). If a release skips a platform, the feed keeps that platform's
previous entry. A sample is in `scripts/rr/testdata/feed-sample/beta.json`.

How channels combine:

- Stable reads `stable.json`. Beta reads Stable and Beta. Nightly reads all three. The app
  offers the newest build that is newer than the installed one. So a Beta user also gets a
  Stable release when it is newer than the last beta.
- Switching to a more stable channel never downgrades. The app waits until that channel has
  a build newer than the installed one.
- The default channel is Stable.

### Android

- Checks when the app opens (at most every 15 minutes) and, while the connection service
  runs, at most once per 24 hours (a coroutine in the service; no WorkManager).
- A background check that finds an update posts one "Update available" notification per
  version. Opening the app shows a dialog with the notes, **Install** and **Later**. Later
  hides the dialog for that version for 24 hours; Settings still offers it.
- Install downloads the APK over HTTPS into the app cache, checks size and SHA-256, checks the
  package name and version code, and checks that the APK is signed by exactly the same
  certificate as the installed app. Then it hands the file to `PackageInstaller` with
  "user action required", so Android always shows its confirmation screen. Nothing installs
  silently.
- Android asks once for "Install unknown apps" for Bridgey; the app explains this and opens the
  right settings page.
- Settings → Updates: channel, Check now, last checked, current version and channel.

### macOS

- Sparkle 2 (Swift Package Manager), one appcast with Sparkle channels: Stable items have no
  `<sparkle:channel>`, Beta items `beta`, Nightly items `nightly`. Beta allows `beta`;
  Nightly allows `beta` and `nightly`. Sparkle always considers the default (Stable) items
  too and never offers a build older than the installed `CFBundleVersion`.
- Updates are the ZIP, signed with EdDSA (`sparkle:edSignature`). The appcast keeps the newest
  5 Stable, 5 Beta and 7 Nightly items.
- Settings → Updates: channel, automatic checks (on by default, daily), Check Now, version
  and last check. Sparkle shows its own update window.
- `build-app.sh` embeds `Sparkle.framework` in `Contents/Frameworks`, adds the
  `@executable_path/../Frameworks` rpath, and signs Sparkle's XPC services, `Autoupdate`,
  `Updater.app` and the framework before the app (no `--deep`).

**Ad-hoc signing.** We have no Apple Developer ID yet, so builds are ad-hoc signed with the
designated requirement `identifier "in.roundrobin.bridgey"`. Sparkle's validator
(`SUUpdateValidator.m`, Sparkle 2.10) accepts an update when the EdDSA signature matches the
installed app's `SUPublicEDKey`, or when the Apple code signature matches. Ad-hoc apps count
as code signed, so every update must stay at least ad-hoc signed, and the EdDSA key is the
real trust anchor. Losing the private key means users must reinstall by hand. Sparkle removes
the quarantine flag from the update it installs, so Gatekeeper does not stop the updated app.
The first install from the DMG still needs right-click → Open (or System Settings → Privacy &
Security → Open Anyway).

## Keys and secrets

| What | Where | Notes |
| --- | --- | --- |
| Android release keystore | rr-dev-1 `~/.config/bridgey-rr/rr-bridgey.jks`; vault note `Keychain/Bridgey by Round Robin` | Every APK must be signed with it, or updates fail the certificate check |
| Android passwords and alias | rr-dev-1 `~/.config/bridgey-rr/android-signing.env` (`ANDROID_STORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`); vault note | Gradle reads them from the environment of the build only |
| Sparkle EdDSA private key | rr-dev-1 `~/.config/bridgey-rr/sparkle_ed25519_private.key` (chmod 600); vault note | Base64 32-byte seed. Not in any Mac Keychain |
| Sparkle EdDSA public key | `macos/Resources/Info.plist` `SUPublicEDKey` | Public |
| Android certificate SHA-256 | `rr-edition.properties` `ANDROID_CERT_SHA256` | Public; the build script checks it |

Never commit any of these, and never print them. `.gitignore` already blocks `*.jks`.

## Releasing

Releases build on our machines, not GitHub Actions: Android on rr-dev-1 (inside the shared
`iieon-slot` build queue), macOS on a Mac over SSH (under `/tmp/app-build-mac.lock`). The
Sparkle key stays on rr-dev-1, so signing happens there. RR CI runs them (see below); the
commands also work by hand.

### With RR CI

The RR CI project `bridgey` (policy in `rbansal42/rr-ci` `examples/app_policies.py`) does this:

- **Checks** on pushes to `rr/main`, `main` and `fix/*` and on pull requests into them, forks
  included: `android` (lint, unit tests, debug APK on GitHub's Ubuntu runners), `macos`
  (`swift test -Xswiftc -warnings-as-errors` and `./build-app.sh` on macOS 15 runners) and
  `python` (`scripts/rr/tests`, where present). They run on GitHub-hosted runners without any
  secret and post `rr-ci/<task>` statuses.
- **Nightly** at 21:30 UTC when `rr/main` has a revision without a passing nightly:
  `scripts/rr/ci-release.sh nightly` on rr-dev-1, with notes from the commits since the previous
  nightly.
- **Releases** from annotated tags on `rr/main`: push `v0.6.0-rr.1` for Stable or
  `v0.6.0-rr.1-beta.2` for Beta (betas lead to `EDITION_NEXT_VERSION`); the tag message is the
  release notes. RR CI checks the tag is on `rr/main` before starting.
  `scripts/rr/ci-release.sh tag` checks the tag (annotated, on `rr/main`, pointing at the build)
  and runs `release.sh` with that version; `publish.sh` uses the existing tag.

```sh
git tag -a v0.6.0-rr.1 -m "Release notes for people, in plain words"
git push origin v0.6.0-rr.1
```

Failures of the nightly or a release reach Rahul on Telegram. Release jobs run only on rr-dev-1,
where the keys are, and need `~/.config/bridgey-rr/github-token` there (a token with write access
to the fork's releases). They never run on GitHub.

```sh
# Dry run into dist/<tag>/ (builds both apps, checksums, feeds, signed appcast; publishes nothing)
scripts/rr/release.sh nightly --mac-host personal
scripts/rr/release.sh beta --version 0.6.0-rr.1-beta.1 --mac-host personal --notes-file notes.md
scripts/rr/release.sh stable --mac-host personal --notes-file notes.md

# Publish what the dry run produced (needs gh with write access; HEAD must be pushed)
scripts/rr/publish.sh dist/v0.6.0-rr.1

# Or build and publish in one go
scripts/rr/release.sh stable --mac-host personal --notes-file notes.md --publish
```

Other options: `--skip-macos` / `--skip-android` (that platform's feed entry stays as it was),
`--macos-artifacts DIR` (use a DMG and ZIP built separately with
`scripts/rr/build-macos.sh`), `--apk FILE` (use an APK built separately with
`scripts/rr/build-android.sh`).

A release directory `dist/<tag>/` holds:

- `release/`: `Bridgey-RR-<version>-Android.apk`, `Bridgey-RR-<version>-macOS.dmg`,
  `Bridgey-RR-<version>-macOS.zip`, `SHA256SUMS`
- `channels/`: `<channel>.json` and `appcast.xml`, merged with what is already published
- `release.env`, `notes.md`

`publish.sh` then:

1. verifies the directory again (`rrrelease.py verify`),
2. creates the GitHub release: Stable `v<version>` as a normal release marked latest; Beta
   `v<version>` and Nightly `nightly-YYYYMMDD` as prereleases (a second nightly on the same day
   replaces the first),
3. uploads `<channel>.json` and `appcast.xml` to the `channels` release with `--clobber`, only
   after the release assets exist,
4. for Nightly, deletes all but the newest 7 nightly releases and their tags.

After a Stable release, bump `EDITION_NEXT_VERSION` (for example to `0.6.0-rr.2`) and commit.

Checks:

```sh
python3 -m unittest discover -s scripts/rr/tests            # generator, merge, signing, validation
python3 scripts/rr/rrrelease.py verify --dist dist/<tag>    # any release directory
# Feed parsers of both apps against a generated release directory:
BRIDGEY_RR_FEED_DIR=$PWD/dist/<tag>/channels ./gradlew :app:testDebugUnitTest --tests '*UpdateLogicTest*'   # in android/
BRIDGEY_RR_FEED_DIR=/path/to/dist/<tag>/channels swift test --filter UpdateLogicTests                       # in macos/
```

If the feed format changes, refresh the shared fixture with
`RR_UPDATE_FIXTURE=1 python3 -m unittest discover -s scripts/rr/tests` and update both parsers.

## Merging upstream

The edition keeps upstream's package names, file layout and design so merges stay cheap.

```sh
git fetch upstream
git merge upstream/main        # or a release tag such as v0.7.0
```

Expect conflicts only in the files the edition touches:

- `android/app/build.gradle.kts`: keep the edition block (properties, version from the
  environment, `buildConfig`, the `ANDROID_*` fallbacks); take upstream's dependency changes.
- `macos/Resources/Info.plist`: keep the edition id, names, URL name, Services label and the
  Sparkle keys; take upstream's new keys. Ignore upstream's version numbers (ours come from the
  release script).
- `macos/build-app.sh`, `macos/package-release.sh`, `macos/Package.swift`: keep the Sparkle
  embedding, signing order and edition names.
- `AndroidManifest.xml`, `MainActivity.kt`, `BridgeyApp.swift`: small hooks for the updater
  and the About section.
- `MacTrustRegistry.swift`, `Pairing.swift`, `NotificationHistory.swift`, `Discovery.swift`,
  `MediaController.swift`: identifiers now come from `Edition.swift`.

Edition-only files (no upstream conflicts): `rr-edition.properties`, `docs/rr-edition.md`,
`scripts/rr/`, `AppUpdater.kt`, `UpdateLogic.kt`, `UpdatesUi.kt`, `UpdateInstallReceiver.kt`,
`Edition.swift`, `AppUpdater.swift`, `UpdateLogic.swift`, `UpdateSettingsView.swift` and their
tests.

After a merge: search for new hardcoded `dev.bridgey` identifiers that store state (Keychain
services, support folders, task affinities, suites) and move them to the edition namespace;
then set `EDITION_NEXT_VERSION` to the new upstream base (for example `0.7.0-rr.1`).
