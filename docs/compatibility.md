# Compatibility

This page says which phones and Macs Bridgey by Round Robin has been tried on, and what to
watch for on the rest.

- **Tested** means a maintainer ran the app on that exact combination and it worked.
- **Untested** means nobody has reported a result yet. It does not mean unsupported. Most
  Untested rows are likely to work, but nothing here says so.

Automated checks (Android lint and unit tests on Ubuntu, Swift tests and the app build on macOS 15
runners, see [releasing and CI](rr-edition.md#with-rr-ci)) run on every push. They catch code
errors, not device behaviour, so they never move a row to Tested.

Last updated: 2026-10-27.

## Tested

| Phone | Android | Phone skin | Mac | macOS | App version | Date |
| --- | --- | --- | --- | --- | --- | --- |
| OnePlus 11 | 16 (API 36) | OxygenOS | Apple silicon (M-series) | 27 | 0.6.0-rr.1-beta.13 and earlier betas | 2026-10-27 |

Per-feature results are not recorded in this table. The older step-by-step checklists are
[testing-0.6.md](testing-0.6.md) and [testing-remote-input.md](testing-remote-input.md), and some
items on them were still open when this page was written.

## Android versions

The app supports Android 8.0 (API 26, `minSdk`) and up. It is built for Android 16 (API 36,
`targetSdk` and `compileSdk`). Both values are in `android/app/build.gradle.kts`.

| Android | API | Status | What differs on this version |
| --- | --- | --- | --- |
| 8.0 to 8.1 | 26 to 27 | Untested | Lowest supported version. |
| 9 | 28 | Untested | Diagnostics add the app standby bucket from here (see [diagnostics](diagnostics.md)). |
| 10 to 12L | 29 to 32 | Untested | Android 10 and later let an app read the clipboard only while it is on screen (see below). Photo access for "Send a fresh screenshot" uses the older storage permission up to Android 12L. |
| 13 to 14 | 33 to 34 | Untested | Notification permission is a runtime prompt. Android 13 adds the sensitive-clip flag that Bridgey honours. "Keep Wi-Fi awake" applies to Android 13 and older only. Photo access has a "selected photos only" mode, which cannot see new screenshots. |
| 15 | 35 | Untested | Android hides the text of notifications it thinks hold a code unless the phone is linked to the Mac (see below). |
| 16 | 36 | Tested on OnePlus 11 only | As Android 15. Other phones on Android 16 are Untested. |

### Features that depend on the Android version

- **Phone to Mac clipboard (Android 10 and later).** Bridgey can read the clipboard only while
  it is on screen. Otherwise tap "Send copied item" in the notification or on the Quick Settings
  tile. Mac to phone is automatic on every version. The reason, and the optional ADB-based
  "Background clipboard (advanced)", are in [the edition notes](rr-edition.md#automatic-clipboard-and-why-it-is-not-fully-automatic-from-the-phone).
- **Codes from messages (Android 15 and later).** Android hides code text from notification readers
  it does not trust. Linking the phone to the Mac (a Companion Device Manager association) lets
  Bridgey see the text. The fallback is a one-time ADB command. See
  [the user guide](user-guide.md#codes-from-messages).
- **Sensitive clips (Android 13 and later).** A clip marked sensitive is stored as "Hidden" in
  the activity stream and is never sent automatically.
- **Photo access for fresh screenshots (Android 13 and later).** Needs access to all photos. "Selected
  photos only" is refused and the option turns itself off.

## Phone makers and skins

None of these has a reported result. The notes are risks to check, not findings.

| Skin | Status | Risks that matter for Bridgey |
| --- | --- | --- |
| OxygenOS (OnePlus) | Tested on OnePlus 11, Android 16 only | The app itself advises opening App info, Battery usage and allowing background activity. The optional background clipboard needs "Disable permission monitoring" in Developer options on OnePlus, Oppo, Realme and Xiaomi phones. |
| Samsung One UI | Untested | Battery features that put apps to sleep can stop the connection service. Secure Folder and work-profile copies of Bridgey do not connect (they show an explanation, see [architecture](architecture.md#platform-lifecycle)). |
| Xiaomi HyperOS and MIUI | Untested | Autostart and battery restrictions can stop the connection service. The background clipboard step about permission monitoring also applies. |
| Google Pixel | Untested | Close to stock Android, so version differences matter more than skin differences. Android 15 and later hide code text until the phone is linked. |
| Motorola | Untested | Close to stock Android. Check battery optimisation for Bridgey. |
| Vivo (Funtouch, OriginOS) and Oppo (ColorOS) | Untested | Aggressive background limits are common. Check battery, autostart and notification access. The OnePlus row does not carry over. |

The three risks to check on any phone:

1. **The connection service is killed in the background.** Open Settings > General in Bridgey and
   allow it to run in the background ("Stay connected while the phone sleeps"). Then look for
   the phone maker's own battery or app-launch settings. A third-party list of per-maker
   settings is at [dontkillmyapp.com](https://dontkillmyapp.com/). Bridgey does not add
   keep-alive tricks.
2. **Notification access is switched off.** Notification forwarding and codes need it. Some phones
   turn it off for an app they stopped. Settings > Notifications shows "Needs notification
   access" when it is missing. Removing the companion link in Android settings may also switch
   it off.
3. **The companion link does not complete.** Linking uses Android's own Bluetooth dialog. Bluetooth
   (and, on some phones, Location) must be on, and the Mac asks for Bluetooth permission the first
   time. If a phone cannot make the link, use the ADB command shown on the phone.

## macOS versions

The app needs macOS 13 or later (`macos/Package.swift`, `LSMinimumSystemVersion` 13.0).

| macOS | Status | Notes |
| --- | --- | --- |
| 13.0 to 13.2 | Untested | Supported by the app, but "On this Mac" for codes shows as not available (the model runtime needs 13.3). The cloud option is separate; this page has not checked it on that version. |
| 13.3 and later 13.x | Untested | |
| 14 | Untested | |
| 15 | Untested | The automated Mac checks run on macOS 15. That is not a device test. |
| 26 | Untested | |
| 27 | Tested with the OnePlus 11 row above | Apple silicon only. |

| Mac hardware | Status | Notes |
| --- | --- | --- |
| Apple silicon (M-series) | Tested on macOS 27 | |
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

A report moves a row from Untested to Tested. It also helps if something fails.

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
