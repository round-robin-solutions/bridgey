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
| macOS pairing state | Keychain items `dev.bridgey.mac.trust`, `dev.bridgey.identity` | private file `~/Library/Application Support/in.roundrobin.bridgey/trust-v3.json` (0600, no Keychain prompts after updates; older Keychain items are moved once, see [rr-mac-signing.md](rr-mac-signing.md)) |
| macOS support folders | `~/Library/Application Support/Bridgey`, `~/Library/Caches/Bridgey` | `.../in.roundrobin.bridgey` |
| macOS legacy import | reads the old `BridgeyMac` defaults suite | never reads it (it belongs to upstream) |
| URL handler name, Services item | `dev.bridgey.mac.phone`, "Call with Bridgey" | `in.roundrobin.bridgey.phone`, "Call with Bridgey RR" |
| Android clipboard task affinity | `dev.bridgey.android.clipboard_action` | `${applicationId}.clipboard_action` |
| Updates | none (manual downloads) | Stable, Beta and Nightly channels, in-app updates |
| Releases | GitHub Actions on `v*` tags | `scripts/rr/release.sh` on our own machines; `release.yml` is manual-only |
| Android design | Material defaults | Direction B "Stream": device rings, activity stream, send bar (Round Robin theme) |
| Android activity stream | none | Local, private history of what moved between devices (see below) |
| macOS design | SwiftUI defaults | Direction B "Stream": 360 pt menu-bar panel with device chips, live cards, activity stream, quick actions and send bar; Settings window with a sidebar (Round Robin theme, bundled Space Grotesk and Inter) |
| macOS activity stream | none | The same private, local history on the Mac (see below) |
| Remote control | planned for 0.7 | Phone as touchpad, keyboard and presentation remote for the Mac, through the draft `remote_input_draft1` (see below) |
| Files 2.0 | planned for 0.8 | Folders both ways; Mac "Phone files" window (photos and videos, recent documents, granted folders) with instant thumbnails, Quick Look, drag out and in; Android attach sheet; Mac send sheet, Tray, menu-bar drops and send optimisation; Finder metadata and transfer history (drafts `folders_draft1`, `places_draft1`, `files_browse_draft1`, `folders_receive_draft1`; see [files-browse.md](files-browse.md)) |
| Codes from text messages | none | Opt-in: the Mac shows "Code 482913 from HDFC Bank" with Copy code, read on the Mac by a small downloaded model (default) or, if chosen, through Round Robin's relay to Cloudflare Workers AI; a companion link lets Android 15+ show Bridgey the codes (draft `sms_codes_draft1`, see below) |

Unchanged on purpose: the wire protocol, the Bonjour service type `_bridgey._tcp`, the default
port 42458, and the Kotlin and Swift package names. Because the port is the
same, the upstream app and this edition cannot both accept connections on one Mac at the same
time; quit one of them.

UserDefaults, Android SharedPreferences, Android Keystore keys, notification channels and the
FileProvider authority (`${applicationId}.fileprovider`) are already per app, so they needed no
change.

Edition settings live in one file, `rr-edition.properties`: app id, names, the next version,
the GitHub repository, the feed base URL and the expected Android certificate fingerprint.
Gradle, `macos/build-app.sh` and `scripts/rr/*` all read it. The Sparkle public key is in
`macos/Resources/Info.plist` (`SUPublicEDKey`).

### Android activity stream and privacy

The Android home screen shows what moved between your devices, newest first. It is kept only on
the phone: at most 200 items for seven days, in an owner-only file (`0600`) in no-backup storage,
and cleared from Settings > Privacy > Activity. It never goes into diagnostics or logs.

What an item stores: the kind of event, the device, the time, a count, and depending on the kind:

- clipboard sent or received: a one-line preview of the text (whitespace collapsed, at most 80
  characters). A clip marked sensitive on Android 13+ (`ClipDescription.EXTRA_IS_SENSITIVE`) is
  stored as "Hidden" with no text. Rich clips preview their plain text;
- files: the name of the file you sent or received;
- forwarded notifications: the app's name, grouped per device and app within 15 minutes
  ("4 WhatsApp alerts"). Never notification titles or text;
- incoming calls: the caller as shown in the call notification, when there is one.

Link addresses and phone numbers are never stored. Settings > Privacy > "Show previews in
activity" (on by default) turns previews, app names and callers off: new items then store none,
and existing previews are hidden.

### macOS activity stream and privacy

The Mac panel shows the same kind of stream with the same rules: at most 200 items for seven days,
one-line clipboard previews of at most 80 characters, alert app names grouped per device and app
within 15 minutes, callers from forwarded call notifications, file names, and nothing else. It is
kept in `~/Library/Application Support/in.roundrobin.bridgey/activity-stream.json`, owner-only
(`0600`), and cleared from Settings > Privacy. Clipboard content that a password
manager marks as concealed (`org.nspasteboard.ConcealedType`, 1Password's marker) is stored as
"Hidden". Settings > Privacy > "Show previews in activity" (on by default) works as on Android.
Nothing from the stream is logged or exported with diagnostics.

### macOS Automatic clipboard

Settings > Clipboard > "Automatic clipboard" (on by default, like Universal Clipboard; each device
can turn it off in Devices and permissions) sends what you copy on the Mac to the connected phone.
It uses the existing `clipboard.update` / `clipboard.rich` messages and acknowledgements, so the
wire protocol is unchanged and upstream peers receive it like a manual send.

- It runs only while connected with Clipboard on for both devices: the Mac polls
  `NSPasteboard.changeCount` every 0.5 s, and the timer stops otherwise.
- A change is sent once the pasteboard has been still for 300 ms (a burst sends only the last copy).
  What is already on the clipboard when the connection starts is not sent.
- Never sent: content marked `org.nspasteboard.ConcealedType`, `TransientType`,
  `AutoGeneratedType` or `com.agilebits.onepassword`; empty or non-text content; text over 32 KiB
  (one quiet status, no retry).
- No loops: a clip received from the phone records its `changeCount` and a hash of its text, and
  the same text is never sent twice in a row.
- The activity stream marks these sends "Automatic". Received clips look the same either way on
  the wire, so they are recorded like manual ones.

### Images, files and long text (draft protocol)

Settings > Clipboard > "Copy images and files" (on by default) lifts the 32 KiB limit between two
edition devices: images, videos, several files at once, and text of any size. It works like
Universal Clipboard: the other device learns about a copy at once, and the data moves when you
paste, with progress for big items. "Send right away up to" (5, 25 (default) or 100 MB, or Always
ask when pasting) pushes small copies straight away so pasting them is instant. The messages are
the draft `clipboard_files_draft1` in `docs/protocol.md`; with an upstream peer, or with the switch
off on either side, only text up to 32 KiB moves, as before.

- Mac: pasted items are lazy pasteboard items; files paste as files from
  `~/Library/Application Support/in.roundrobin.bridgey/ClipboardCache`. Items not yet on the Mac
  carry `org.nspasteboard.TransientType`, so clipboard managers do not pull a 2 GB video on copy.
- Android: pasted items are `content://in.roundrobin.bridgey.clipboard/...` URIs from a
  non-exported provider; lazy items stream through a pipe, with a progress notification and Cancel
  from 1 MB. Text up to 256 KiB is set as text, longer text as a `.txt` file.
- Both: the cache keeps superseded items only if an app already opened them, nothing past 24 hours,
  at most 2 GB, and is deleted by Clear activity and Forget device. Never logged or in diagnostics.
- The stream shows "Copied image from Personal Mac (2.1 MB)", "Pasted video.mp4 from OnePlus 11
  (340 MB)", "Copied 3 files"; with previews off, no file names.

The optional notification history (Settings > Notifications, off by default) is a different
thing and stays separate: it keeps forwarded notifications with their titles and text so you
can read them later, while the stream only says that "4 WhatsApp alerts" arrived.

The About section in Settings on both apps says "Built on Bridgey by Semyon Mikhailov" and
links to the original project. Keep it, and keep `LICENSE`.

### Automatic clipboard, and why it is not fully automatic from the phone

Automatic clipboard ("Copy on one device, paste on the other.") is on by default, reusing the
existing `clipboard.update`/`clipboard.rich` messages and acks, so it works with upstream peers too.

**Why can't copying on the phone sync automatically like OnePlus O+ Connect or Microsoft Phone
Link?** Since Android 10, an app can read the clipboard only while it is on screen, or if it is
the keyboard ([Android 10 clipboard changes](https://developer.android.com/about/versions/10/privacy/changes#clipboard-data)).
O+ Connect and Phone Link are system or phone-maker partner apps: they hold
`READ_CLIPBOARD_IN_BACKGROUND`, which only apps signed by the phone maker can get. ADB cannot
grant it, and an app installed from a download cannot hold it. So Bridgey does the most that is
allowed:

- Mac to phone is always automatic (writing the clipboard is allowed in the background).
- Phone to Mac is automatic while Bridgey is open, otherwise one tap on "Send copied item" in the
  notification or on the Quick Settings tile.
- "Send a fresh screenshot" (Settings > Clipboard, on by default): when a screenshot was taken in
  the last minute, after the last copy, "Send copied item" sends that screenshot as an image
  instead, once. It asks for photo access on first use (`READ_MEDIA_IMAGES`; selected photos only
  cannot see new screenshots) and turns itself off if access is refused.
- The optional "Background clipboard (advanced)" uses the same one-time ADB setup as
  [KDE Connect](https://userbase.kde.org/KDEConnect) (it grants READ_LOGS, reading system logs),
  and is off by default.

Skip rules apply in both directions: never send sensitive or empty content (or text over 32 KiB without Copy images and files), and never
re-send identical content (a per-device hash also stops a clip written because the Mac sent it from
bouncing back). Automatic and manual moves are both recorded in the activity stream, marked
"Automatic", and respect the previews switch.

### Remote control (draft protocol)

The phone can be a touchpad, keyboard and presentation remote for a Mac, through the draft
`remote_input_draft1` messages in `docs/protocol.md` (with its security review). It is off on both
sides until turned on, and only works between two edition devices.

- **Mac:** Settings > Remote control turns it on for this Mac; each phone then needs its own
  "Allow remote control" (in that pane, or Settings > Devices > [phone]). Bridgey asks macOS for
  Accessibility only when remote control first becomes usable (on, and a phone allowed), and
  explains why; sessions are refused while Accessibility is missing. During a session the menu-bar
  icon changes and a pill at the top of the screen says "OnePlus 11 is controlling this Mac" with
  Stop; Control-Option-Escape also stops it. The pill and the laser dot stay above full-screen
  slideshows. The session log (`remote-control-audit.json` in
  `~/Library/Application Support/in.roundrobin.bridgey`, `0600`, 30 days, at most 500 entries,
  Clear in the pane) records device, start, end, the reason and how many moves, clicks, keys and
  slide actions there were. Never typed text, key names or positions.
- **Android:** Settings > Remote control turns it on for this phone (pointer speed, and volume
  keys for slides, off by default). A Mac that allows it gets "Remote control" on its device page
  and a launcher quick action ("Control Personal Mac"). The screen has a touchpad (one finger moves,
  tap clicks, two-finger tap right-clicks, two fingers scroll, touch and hold then move drags), a
  keyboard with the allowed special keys and a text field, and a slides remote (Previous, Next,
  Start, Black screen, End, and a laser pad). The screen stays on while it is open; leaving it,
  turning the screen off or losing the connection ends the session, and coming back shows Start
  again.
- **Keys:** named keys only, with Shift; the one shortcut is "Previous app" (Command-Tab). Start
  maps to the frontmost app: Keynote Option-Command-P, PowerPoint and Google Slides Command-Return,
  anything else Control-Command-F. Next and previous are Page Down and Page Up, like clickers.
- **Accessibility after updates:** macOS records the app's code requirement with the grant. Whether
  it still honours the grant after an ad-hoc signed update is not tested yet (see the device test
  plan in `docs/testing-remote-input.md`). If it does not, sessions are refused with
  `permission_required`, the pane shows the grant as needed with Open System Settings, and
  Bridgey has to be switched off and on again in that list.

### Codes from text messages (draft protocol)

When a one-time code arrives by SMS, the Mac can show it as "Code 482913 from HDFC Bank" with
**Copy code**, instead of the plain mirrored notification. The messages are the draft
`sms_codes_draft1` in `docs/protocol.md`.

- **Mac, Settings > Notifications > Codes from messages:** "Show codes from text messages" is off
  by default. Only an SMS that looks like it has a code (from the phone's default SMS app, not
  hidden by Android) is read. **Read codes** picks the engine:
  - **On this Mac (private)**, the default: a fine-tuned Gemma 3 270M (GGUF Q4_K_M, 253 MB) runs
    in the app through llama.cpp with Metal, so the message never leaves the Mac. About 0.06 s
    per message (median, M4); the model loads on the first code message and unloads after 15 idle
    minutes. It is downloaded once, on first use (see "On-device code model" below).
  - **Cloud (Cloudflare)**, opt-in with its own warning: the text goes to the relay
    `services/otp-proxy` (a Cloudflare Worker on the Round Robin account, address in
    `rr-edition.properties` `OTP_PROXY_URL`), which asks Cloudflare Workers AI (Llama 3.2 3B). No
    API key ships in either app; the relay keeps no copy, logs nothing and rate-limits per install
    (a random id), per address and in total. A Mac that had turned codes on before the choice
    existed keeps the cloud until the user picks again.

  Both engines answer the same way and go through the same guard: the code must appear in the
  message as a whole token (or as digit groups of 3 or more, such as "482 913"), with 4 to 8
  letters or digits and a digit in every part; "5 min me" or a date such as 30-10-26 is refused.
  Otherwise, or after 2 seconds, the plain notification shows.
- **Copying:** the banner's Copy code button, a click on the banner, or the panel's code card (ten
  minutes). The copy is marked concealed and transient (clipboard managers and Automatic clipboard
  skip it), stays on this Mac (no Universal Clipboard), and is cleared after 60 seconds unless
  something else was copied since; Bridgey compares change counts and never reads the clipboard.
  "Copy automatically" (off by default) copies a new code only when the Mac is unlocked and was
  used in the last two minutes.
- **Privacy:** codes and message text are never logged on either side, whatever Settings > Privacy
  > Logging says (SMS-app notifications log without title and text). Notification history, when on,
  keeps "Sent a one-time code" for a code message, never the code. Diagnostics record only the
  outcome (found, none, timeout, rate limited, unavailable, model missing). llama.cpp's own log is
  switched off.
- **Code access (Android 15 and later):** Android hides the text of notifications it thinks hold a
  code from notification readers it does not trust. Settings > Notifications on the phone shows
  "Code access: allowed / hidden by Android / not linked" (the Mac shows the same for the selected
  phone). **Link this phone to the Mac** (on the phone, or from the Mac, which sends the phone a
  notification to tap) has the Mac advertise over Bluetooth for a minute, Android's own dialog finds
  it, and one Allow creates a Companion Device Manager association; Bridgey then reconnects its
  notification access. The fallback is the one-time command
  `adb shell cmd appops set --user 0 in.roundrobin.bridgey RECEIVE_SENSITIVE_NOTIFICATIONS allow`,
  shown with Copy on the phone. Removing the link in Android settings may also turn off Bridgey's
  notification access. The Mac asks for Bluetooth permission the first time it advertises.
- **Code reader test (Phase 0, beta and nightly only):** Settings > About, tap the version 7 times,
  Performance test, Code reader test. It reads the last 500, 2,000 or 5,000 SMS on the phone into
  memory, runs the pattern baseline and, only if "Send code-like test messages to the cloud
  provider" is ticked (off by default), the relay on up to 120 code-like messages (every one the
  pattern flagged first). Disagreements and a random audit of 20 agreed "code" and 20 agreed "no
  code" messages are shown one at a time to confirm (screenshots blocked). The report has totals
  only (right, wrong, missed, false alarms, latency, by script and sender kind, how many SMS
  notifications Android hid during the test) and exports as JSON without any message, code or
  sender. `READ_SMS` is declared only in non-stable builds (`src/lab/AndroidManifest.xml`, applied
  by `build.gradle.kts` when the version is not `x.y.z-rr.N`), asked for only at Start, and Bridgey
  asks Android to drop it at the next restart when the test ends (Restart Bridgey button), with the
  manual path shown.

### On-device code model

- **Where it comes from:** the fixed GitHub release `models` (prerelease, never "latest") on
  `round-robin-solutions/bridgey` holds `otp-model.json` (the manifest), the model files
  `bridgey-otp-v<N>.gguf`, `NOTICE`, the Gemma Terms of Use and Prohibited Use Policy, and
  Bridgey's model terms. The manifest gives version, URL, size, SHA-256, the licence links and a
  terms version. The app ships the manifest it was built with (`macos/Resources/otp-model.json`)
  and reads `rr-edition.properties` `OTP_MODEL_MANIFEST_URL` (at most every six hours, when the
  Codes card opens); a higher version is offered as **Update** without an app update. Model URLs
  must start with `UPDATE_ASSET_URL_PREFIX`.
- **Before the download:** a sheet says what it does, that it runs on this Mac and nothing leaves
  it, the exact size ("253 MB, one time") and that this is normal for an on-device model, the free
  space, and "Wi-Fi recommended". The Download button needs a tick accepting the Gemma Terms of
  Use, the Gemma Prohibited Use Policy and Bridgey's model terms (all linked) and enough space
  (size plus 100 MB). Each acceptance is kept in the app's preferences
  (`settings.codes.model.acceptance`: date, model version, terms version); an update under the same
  terms version does not ask again.
- **Download:** progress with MB of MB, speed and time left, Pause, Resume and Cancel, in Settings
  and as a card in the menu-bar panel. It resumes with an HTTP Range request after a pause, a lost
  connection (on its own when the network returns) or an app restart (`Models/download.json` keeps
  the state; a download the user paused stays paused). The SHA-256 is checked at the end; a damaged
  file is fetched once more before Bridgey says so. Errors are plain: no space, offline, damaged,
  server.
- **After:** "Code model ready" with **Test** (reads a synthetic message and shows the code and the
  time) and **Remove** (deletes the file and turns codes off while On this Mac is chosen). Right
  after a download Bridgey reads three synthetic messages once, so the one-time Metal shader
  compile (several seconds on a Mac's first run; macOS keeps the result) never delays a real code.
- **Storage:** `~/Library/Application Support/in.roundrobin.bridgey/Models/` (owner only, excluded
  from backups).
- **Licence:** the app code stays MIT. The model is a Model Derivative of Gemma, so it ships under
  the Gemma Terms of Use: `NOTICE` and `licences/` in the repository, the same texts in the app
  (Settings > About > Licences) and on the `models` release, and Bridgey's model terms
  (`licences/BRIDGEY-MODEL-TERMS.txt`) pass on Google's use restrictions as a condition of use.
  llama.cpp (b11899, MIT) is a SwiftPM binary target; `build-app.sh` embeds it, thins it to the
  app's architectures and signs it. It is built for macOS 13.3 and later; on older systems On this
  Mac shows as not available.
- **Published:** model version 1 is `bridgey-otp-v1.gguf` (253,115,744 bytes, SHA-256
  `69fe14b205ecaebbd1fa5d167f48a25c687b493341ff92476ca163a2ea12390f`) at
  https://github.com/round-robin-solutions/bridgey/releases/tag/models. Its GGUF metadata
  (`general.name`, `general.description`) states that Round Robin modified it; the weights are the
  research model v3 unchanged.
- **Publishing a new model:** stamp the modification notice into the GGUF metadata, upload `bridgey-otp-v<N>.gguf` to the `models` release, then replace
  `otp-model.json` with the new version, size and SHA-256, and update `macos/Resources/otp-model.json`
  for the next app build. Training data, evals and the decision rule are in Round Robin's research
  notes (`outputs/bridgey/research/otp-tiny-model/`).

## Versions

- **Version name** (shown to people): `0.6.0-rr.1` for Stable, `0.6.0-rr.2-beta.1` for Beta,
  `0.6.0-rr.2-nightly.20261025` for Nightly. The first part is the upstream version the
  edition is based on; `rr.N` counts our releases on it. Betas and nightlies carry the
  number of the stable release they lead to (`EDITION_NEXT_VERSION`).
- **Nightly tags**: one per build, `nightly-YYYYMMDD.HHMM` (the UTC minute of the build, the same
  minute as the build number), for example `nightly-20261026.0905`. Several nightlies a day share
  the version name `...-nightly.YYYYMMDD`, because the apps accept only that form; the build number
  tells them apart and orders them (Android snoozes and installs by `versionCode`, Sparkle compares
  `CFBundleVersion`). A per-build version name needs the apps' version pattern in
  `UpdateLogic.kt` and `UpdateLogic.swift` widened first.
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
  5 Stable, 5 Beta and 10 Nightly items.
- Settings → Updates: channel, automatic checks (on by default, daily), Check Now, version
  and last check. A custom Sparkle user driver (`InAppUpdateDriver` in `AppUpdater.swift`)
  shows every step in the app instead of Sparkle's windows: update found (notes, Install,
  Later, Skip), download progress, preparing, ready (Restart to update), installing, plain
  errors, and "You're up to date" after Check Now. The Stream panel shows the same step as a
  live card.
- `build-app.sh` embeds `Sparkle.framework` in `Contents/Frameworks`, adds the
  `@executable_path/../Frameworks` rpath, and signs Sparkle's XPC services, `Autoupdate`,
  `Updater.app` and the framework before the app (no `--deep`).

**Signing.** We have no Apple Developer ID yet. Builds are ad-hoc signed with the designated
requirement `identifier "in.roundrobin.bridgey"`, or, with `release.sh --mac-sign`, signed with
the self-signed "Bridgey by Round Robin Code Signing" identity (requirement pins that
certificate). Pairing state is a private file, not the Keychain, so updates never ask for the
login password. Details and test results: [rr-mac-signing.md](rr-mac-signing.md). Sparkle's validator
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
| macOS code signing identity (self-signed) | rr-dev-1 `~/.config/bridgey-rr/macos-codesign.p12` and `.p12.password` (chmod 600); vault note | Used only with `--mac-sign`. Piped to the Mac per build, imported into a throwaway keychain, then deleted |
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
- **Nightly** on every push to `rr/main`, once that revision's checks have passed, built and
  published on GitHub-hosted runners by `.github/workflows/rr-ci-nightly.yml`: Android on Ubuntu,
  the Mac app on macOS 15, then appcast signing and publishing. Notes are the commit subjects since
  the previous nightly or beta (`scripts/rr/release-notes.sh`). RR CI builds one nightly at a time
  and only the newest revision: a queued nightly for an older revision is dropped when a newer
  push passes, and a revision that already has a beta or stable tag gets no nightly.
  Its secrets are environment secrets of `rr-ci-release` (deployment rule: `rr/main` only), read
  by name only in the jobs that need them; publishing uses the run's `GITHUB_TOKEN`
  (`contents: write`). `scripts/rr/ci-release.sh nightly` on rr-dev-1 remains as a fallback.
- **Releases** from annotated tags on `rr/main`: push `v0.6.0-rr.1` for Stable or
  `v0.6.0-rr.1-beta.2` for Beta (betas lead to `EDITION_NEXT_VERSION`); the tag message is the
  release notes. RR CI checks the tag is on `rr/main` before starting.
  `scripts/rr/ci-release.sh tag` checks the tag (annotated, on `rr/main`, pointing at the build)
  and runs `release.sh` with that version; `publish.sh` uses the existing tag.

```sh
git tag -a v0.6.0-rr.1 -m "Release notes for people, in plain words"
git push origin v0.6.0-rr.1
```

Failures of the nightly or a release reach Rahul on Telegram. Beta and stable releases run only on
rr-dev-1, where the keys are, and need `~/.config/bridgey-rr/github-token` there (a token with
write access to the fork's releases).

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
2. takes the channels lock (`scripts/rr/channels-lock.sh`), the git ref `refs/rr-ci/channels-lock` (creating a ref is atomic on
   GitHub; a lock older than 30 minutes is taken over), because nightlies publish from GitHub
   Actions and betas and stable from rr-dev-1, and every channel shares `appcast.xml`,
3. downloads the feeds as published now and re-merges this release into them
   (`rrrelease.py rebase`); if the channel already has a newer build it stops without publishing,
4. creates the GitHub release: Stable `v<version>` as a normal release marked latest; Beta
   `v<version>` and Nightly `nightly-YYYYMMDD.HHMM` as prereleases,
5. uploads `<channel>.json` and `appcast.xml` to the `channels` release with `--clobber`, only
   after the release assets exist,
6. for Nightly, deletes all but the newest 10 nightly releases and their tags, and releases the lock.

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
