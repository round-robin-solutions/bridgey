# Compatibility

This page says which phones and Macs Bridgey by Round Robin has been tried on, and what to
watch for on the rest.

- **Tested live** means a maintainer ran the app on that exact phone or Mac and it worked.
- **Emulator** means the signed release APK passed the scripted smoke below on a Google APIs
  emulator of that Android version. It shows the app starts, sets up and lays out on that
  version. It says nothing about a phone maker's battery rules, Bluetooth or a real network.
- **Not tested** means nobody has reported a result yet. It does not mean unsupported.

Automated checks (Android lint and unit tests on Ubuntu, Swift tests and the app build on macOS 15
runners, see [releasing and CI](rr-edition.md#with-rr-ci)) run on every push. They catch code
errors, not device behaviour, so they never move a row to Tested.

Last updated: 2026-10-29.

## Matrix

| Android | API | Status | Where |
| --- | --- | --- | --- |
| 8.0 | 26 | Emulator | Pixel 6 profile, Google APIs arm64, 2026-10-27 |
| 8.1 to 9 | 27 to 28 | Not tested | |
| 10 | 29 | Emulator | Pixel 6 profile, 2026-10-27 |
| 11 | 30 | Not tested | |
| 12 | 31 | Emulator | Pixel 6 profile, 2026-10-27 |
| 12L | 32 | Not tested | |
| 13 | 33 | Emulator | Pixel 6 profile, 2026-10-27 |
| 14 | 34 | Emulator | Pixel 6 profile, 2026-10-27 |
| 15 | 35 | Emulator | Pixel 6 profile (`iieon-shared`), 2026-10-27 |
| 16 | 36 | Tested live and Emulator | OnePlus 11, OxygenOS, 0.6.0-rr.1-beta.13 and earlier betas; Pixel 6 profile, 2026-10-27 |

| Mac | macOS | Status | Where |
| --- | --- | --- | --- |
| Apple silicon (M4) | 27.0.1 | Tested live | With the OnePlus 11 row above; Swift tests and app build run here too |
| Apple silicon | 13, 14, 15, 26 | Not tested | The automated Mac checks run on macOS 15 runners; that is not a device test |
| Intel | any | Not tested | See [macOS versions](#macos-versions) |

Per-feature results are not recorded in this table. The older step-by-step checklists are
[testing-0.6.md](testing-0.6.md) and [testing-remote-input.md](testing-remote-input.md).

### The emulator smoke

Each emulator ran the signed release APK (build 0.10.0-rr.1-dev from `rr/v010-review`) through
the same script, in `scripts/rr/compat-smoke/`:

1. Install on a clean emulator and launch.
2. Setup: Get started quickly, Pair later, skip the permission steps, Start.
3. Home in portrait and landscape.
4. Every Settings page (Devices and permissions, Clipboard, Notifications, Calls, Files, Media
   and quick actions, Remote control, Privacy, Updates, General, About), each scrolled.
5. Settings > Privacy > Permissions in portrait and landscape; General in landscape.
6. Kill the process as the system would (`kill -9` as root) while it is on Settings > Privacy,
   then open it again.
7. Read the crash buffer and app errors from logcat, and check every screen for text that runs
   off the screen or overlaps other text.

Results on all seven versions: no crash, no ANR and no app error in logcat. After the kill the
connection service restarted on its own and the app reopened on Settings > Privacy. No text ran
off the screen. On Android 12 and 13 in landscape, the check flagged the Permissions title
over a Manage button; the screenshots show list rows scrolling under the page bar, which is how
the page is drawn, not a break.

To run it again, follow the header of `scripts/rr/compat-smoke/run-all.sh`. It uses the emulator
lock `/tmp/android-emulator.lock` on the personal Mac.

## Android versions

The app supports Android 8.0 (API 26, `minSdk`) and up. It is built for Android 16 (API 36,
`targetSdk` and `compileSdk`). Both values are in `android/app/build.gradle.kts`.

| Android | API | What differs on this version |
| --- | --- | --- |
| 8.0 to 8.1 | 26 to 27 | Lowest supported version. |
| 9 | 28 | Diagnostics add the app standby bucket from here (see [diagnostics](diagnostics.md)). |
| 10 to 12L | 29 to 32 | Android 10 and later let an app read the clipboard only while it is on screen (see below). Photo access for "Send a fresh screenshot" uses the older storage permission up to Android 12L. |
| 13 to 14 | 33 to 34 | Notification permission is a runtime prompt. Android 13 adds the sensitive-clip flag that Bridgey honours. "Keep Wi-Fi awake" applies to Android 13 and older only. Photo access has a "selected photos only" mode, which cannot see new screenshots. Sideloaded apps hit "restricted settings" (see below). |
| 15 | 35 | Android hides the text of notifications it thinks hold a code unless the phone is linked to the Mac (see below). |
| 16 | 36 | As Android 15. |

### Restricted settings (Android 13 and later)

An app installed from a file or a browser cannot turn on Notification access or Accessibility until the
person opens App info, taps More (the three dots) and chooses **Allow restricted settings**
([Android Help](https://support.google.com/android/answer/12623953)). The system dialog says "Restricted
setting. For your security, this setting is currently unavailable" (the Settings app's own strings, in
[AOSP](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/heads/main/res/values/strings.xml)).
Community guides report that on some phones the More menu shows only after Android has blocked the
switch once; Google's page does not say so.

Since 0.10, setup helps with this:

- The Notification access "why" text says so on Android 13 and later.
- Android does not tell an app it was blocked, so Bridgey guesses: on setup's Notification access step or
  Permissions page, when Allow opened Android's screen and Bridgey is back with nothing granted, a card says
  Android may be blocking it, lists the three steps and has an **Open App info** button.
- Accessibility has no row yet. When phone control ships
  ([screen-control-decision.md](screen-control-decision.md)) it joins the same card.
- Not tested on a phone where Android really blocks the switch. The card's trigger and copy are covered by
  unit tests, and its layout by the setup screenshots.

## Pairing with other Bridgey versions

Decided on 2026-10-27: 0.10 pairs only the safer way, with no fallback.

| Other device runs | First pairing | Devices already paired |
| --- | --- | --- |
| Bridgey by Round Robin 0.10 or newer | Works | Works |
| Bridgey by Round Robin 0.9 or older | Refused in both directions. The 0.10 device says "<name> runs an older Bridgey. Update it to 0.10 or newer, then pair again." | Keep working until the pair has once connected on 0.10 on both sides; after that the pair stays on the 0.10 protocol |
| Upstream Bridgey | Refused, as for 0.9 | Keep working, as for 0.9 |
| A 0.10 device rolled back to 0.9 | Refused | Refused once the pair has connected on 0.10: forget and pair again after updating |

Why: the older pairing code can be forced to match by someone on the same Wi-Fi (see
[security-review-0.10.md](security-review-0.10.md)), so 0.10 does not offer it, even as an option.

## Phone makers and skins

Only the OnePlus 11 has been tried. The rest is what public sources report, checked against the
in-app checklist (Settings > General, "Keep Bridgey running", from `setup/OemBattery.kt`). The
checklist appears on OnePlus, Oppo and Realme, Xiaomi, Redmi and Poco, Samsung, Vivo and iQOO, and (since
0.10) Google Pixel, which is found by the manufacturer name "Google".

| Maker | Status | What stops Bridgey | In-app checklist |
| --- | --- | --- | --- |
| OnePlus (OxygenOS) | Tested live on OnePlus 11, Android 16 | Swiping from Recents can kill the app. Deep optimisation and Sleep standby optimisation (Battery, Battery optimisation, Advanced optimisation) cut the network while the phone sleeps. Firmware updates can reset the battery choice. A OnePlus 13 was reported to drop a notification listener and not rebind it. ([dontkillmyapp](https://dontkillmyapp.com/oneplus), [faceclaw #55](https://github.com/jimrandomh/faceclaw/pull/55)) | Auto launch, background activity, battery optimisation, and since 0.10 Deep and Sleep standby optimisation. Lock in Recents is not listed. |
| Samsung (One UI) | Not tested | Apps unused for about 3 days become Sleeping apps and 16 days Deep sleeping apps, with background work and notifications limited. Never sleeping apps exempts Bridgey. Samsung may re-add apps to the lists after an update. ([Samsung developers](https://developer.samsung.com/mobile/app-management.html), [dontkillmyapp](https://dontkillmyapp.com/samsung)) | Unrestricted battery, Put unused apps to sleep off, Never sleeping apps, and since 0.10 removing Bridgey from Sleeping and Deep sleeping apps. Auto-disable unused apps and Adaptive battery are not listed. |
| Xiaomi, Redmi, Poco (MIUI, HyperOS) | Not tested | Background work usually fails on default settings. Autostart must be on and Battery saver set to No restrictions; locking the app in Recents keeps it through Clear all. MIUI is reported to not rebind notification listeners after a kill. ([dontkillmyapp](https://dontkillmyapp.com/xiaomi), [ListenBrainz #772](https://github.com/metabrainz/listenbrainz-android/issues/772)) | Autostart, No restrictions, battery optimisation and lock in Recents. "Pause app activity if unused" is not listed. |
| Google Pixel | Not tested | Close to stock Android: Doze, Adaptive Battery and a Background restriction the user can set by accident. A rarely opened app is paused ("Pause app activity if unused") after months. ([dontkillmyapp](https://dontkillmyapp.com/google), [Android hibernation](https://developer.android.com/topic/performance/app-hibernation)) | Since 0.10: App battery usage set to Unrestricted, Adaptive Battery, and Pause app activity if unused off, for Android 14 to 16. Sources and wording are in [Pixel steps](#pixel-steps). Android's own battery optimisation step in setup still comes first. |
| Oppo and Realme (ColorOS), Vivo and iQOO | Not tested | Aggressive background limits; check battery, auto launch and notification access. | Have their own checklists. |
| Motorola, Nothing, Honor, Huawei | Not tested | Honor (MagicOS) is reported to not rebind notification listeners after an update. ([ListenBrainz #772](https://github.com/metabrainz/listenbrainz-android/issues/772)) | No checklist. |

### Pixel steps

The in-app Pixel checklist (Settings > General, "Keep Bridgey running on Google Pixel") has three steps,
for the Android 14 to 16 Pixel Settings app. Each was checked on 2026-10-29 against Google's own
documentation and the Settings app's source strings. No step has been run on a Pixel yet.

| Step in the app | What the app tells the person | Checked against |
| --- | --- | --- |
| App battery usage | Settings, Apps, Bridgey, App battery usage: tap Allow background usage, then choose Unrestricted. | Pixel Phone Help gives the path (Settings, Apps, See all apps, the app, App battery usage, Allow background usage) and recommends Optimized, so Unrestricted is the same page one choice over ([Keep Adaptive Battery and battery optimization on](https://support.google.com/pixelphone/answer/7015477)). The labels "Allow background usage", Unrestricted, Optimized and Restricted are the Settings app's own strings ([AOSP `strings.xml`](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/heads/main/res/values/strings.xml)). Android 14 QPR1 showed three choices on one screen; from QPR2 the page has the "Allow background usage" row you tap to reach them ([9to5Google](https://9to5google.com/2024/03/15/android-14-qpr2-app-battery-usage/)). |
| Adaptive Battery | Settings, Battery, Battery Saver, Adaptive Battery. Unrestricted already keeps Bridgey out of it, so it can stay on. If notifications still arrive late, turn it off. | Pixel Help puts Use Adaptive Battery under Battery, Battery Saver, Adaptive Battery (same page as above) and recommends keeping it on, and says that an app with battery optimisation turned off "can run more while you're not using it, even when Adaptive Battery is on". Android's App Standby page says apps on the Doze exemption list are exempt from the standby-bucket limits ([App Standby](https://developer.android.com/topic/performance/appstandby)). Some third-party guides give Battery, Adaptive preferences for Android 11 to 13; the app uses the Pixel Help path. |
| Pause app activity if unused | Settings, Apps, Bridgey, Unused app settings: turn off Pause app activity if unused. Some versions call it Manage app if unused. | Pixel Help, "Manage unused apps on your Android device": App info, Unused apps, turn off Pause app activity if unused ([page](https://support.google.com/pixelphone/answer/13627979)). Android documents hibernation after a few months without use ([App hibernation](https://developer.android.com/topic/performance/app-hibernation)). The Settings app has both labels: "Pause app activity if unused" and the newer "Manage app if unused" ([AOSP `strings.xml`](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/heads/main/res/values/strings.xml)). |

The first step opens Bridgey's App info, where App battery usage is the next row. The second opens
Android's Battery Saver page. The third opens App info. If a screen cannot open, App info opens instead.
The Adaptive Battery wording is a judgement call: Google recommends leaving it on, so the step does not ask
to turn it off.

What Bridgey already does: the connection service is a `connectedDevice` foreground service
(Android 15's six-hour limit applies only to `dataSync` and `mediaProcessing`,
[Android docs](https://developer.android.com/develop/background-work/services/fgs/timeout)) and
restarts itself after the process is killed, as the emulator smoke shows. The notification
listener asks to rebind when Android disconnects it. Nothing rebinds it after an app update
until Bridgey is opened.

The three things to check on any phone:

1. **The connection service is stopped in the background.** Allow Bridgey to run in the
   background in Settings > General, then follow the phone maker's checklist there.
2. **Notification access is off or unbound.** Settings > Notifications shows "Needs notification
   access" when it is off. If notifications stop after an update, open Bridgey once, or turn its
   notification access off and on.
3. **The companion link does not complete.** Linking uses Android's own Bluetooth dialog.
   Bluetooth (and, on some phones, Location) must be on. If a phone cannot make the link, use the
   ADB command shown on the phone.

## macOS versions

The app needs macOS 13 or later (`macos/Package.swift`, `LSMinimumSystemVersion` 13.0).

| macOS | Status | Notes |
| --- | --- | --- |
| 13.0 to 13.2 | Untested | Supported by the app, but "On this Mac" for codes shows as not available (the model runtime needs 13.3). The cloud option is separate; this page has not checked it on that version. |
| 13.3 and later 13.x | Untested | |
| 14 | Untested | |
| 15 | Untested | The automated Mac checks run on macOS 15. That is not a device test. |
| 26 | Untested | |
| 27 | Tested live (27.0.1, M4) | With the OnePlus 11 row above. |

| Mac hardware | Status | Notes |
| --- | --- | --- |
| Apple silicon (M-series) | Tested live on macOS 27 (M4) | |
| Intel | Untested | The app is built on an Apple silicon Mac. Nothing in this repository checks that the published DMG contains an Intel (x86_64) slice, so it may not run. Check with `lipo -archs` on the app's executable. |

macOS permissions that matter, and when they are asked:

- **Local network:** needed for discovery and connections.
- **Notifications:** only when Android notification display is on.
- **Bluetooth:** only when linking a phone for codes.
- **Accessibility:** only when remote control is on and a phone is allowed. Whether macOS keeps the
  grant after an update of an ad-hoc signed build is not tested (see
  [testing-remote-input.md](testing-remote-input.md)).
- **Automation:** Music or Spotify, only if media control is chosen.

## How to report a result

A report moves a row to Tested live. It also helps if something fails.

Open an issue at
[github.com/round-robin-solutions/bridgey/issues](https://github.com/round-robin-solutions/bridgey/issues).
Include:

1. **Phone:** make and model, Android version, and the skin with its build number (Android
   Settings > About phone).
2. **Mac:** model or chip, and macOS version.
3. **App versions:** Bridgey on the phone (Settings > About > Version) and on the Mac
   (Settings > About). Also say which update channel you use (Settings > Updates).
4. **What you tried and what happened:** which features, and what you expected. For a success
   report, name the features you checked.
5. **A diagnostics export from each device.** See [diagnostics](diagnostics.md) for how, what is
   inside, and how to check it before sharing.

Do not paste clipboard text, notification text, codes, phone numbers or file names into an
issue.

When a report confirms a combination, a maintainer adds a row to the Tested table with the date and
the app version from the report. Reports of failure stay open as issues and are linked from the
row they affect.

See also: [user guide](user-guide.md), [diagnostics](diagnostics.md).
