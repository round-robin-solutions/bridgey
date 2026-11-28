# Bridgey by Round Robin for iPhone and iPad

The iOS and iPadOS app. It pairs with the Mac, Android and Windows apps (protocol 2), shows your devices in the
Stream style, and sends clipboard text, links and files both ways. A Share extension sends from any app. Since I2 it
also shows and controls an Android phone's or a Mac's screen, and shows the phone's messages, files, notifications
and calls while it is open. What iOS allows and doesn't is in [docs/ios.md](../docs/ios.md).

## How it is built

- **UI:** SwiftUI for iOS 17 and later, one universal app. iPhone shows devices as chips above the stream; iPad
  and other wide windows put them in a sidebar. Light and dark, Dynamic Type, VoiceOver labels, and motion on
  opacity and transform only, which iOS's Reduce Motion or Settings > Reduce motion turns into a short fade.
- **Session:** `bridgey_core` from [`rust/client`](../rust/client), linked as `Frameworks/BridgeyCore.xcframework`
  (arm64 for devices and the simulator) and called through the C header as the `BridgeyCoreFFI` module
  (`Modules/`). The library's own DNS-SD is left out: iOS needs Bonjour through the system, so
  `Shared/Core/Discovery.swift` finds devices with Network.framework and advertises this one with DNS-SD.
- **Pairing data:** the identity and trusted devices are in the Keychain (this device only, after first unlock),
  through the library's storage callbacks. The app and the Share extension share them through a Keychain access
  group and an App Group. What the library keeps for features (the phone's conversations, interrupted files) goes
  to files only the app reads, protected until first unlock and left out of backups (`Shared/Core/HybridStore.swift`).
- **Features:** `AppModel` runs the session and hands it to one model per feature (`ScreenModel`, `MessagesModel`,
  `PhoneFilesModel`, `AlertsModel`), which drive `bridgey_phone` and the event kinds 23 to 36. Screen frames come
  through `bridgey_screen_frame` on their own thread, never through the event queue.
- **Screen keys by platform:** the same feature key means different things to different apps, so each paired device
  gets only the viewer key its platform reads that way (`ScreenRoles` in `Model/Items.swift`): `screen_draft1` and
  `phone_control_draft1` to an Android phone, `screen_control_draft1` to a Mac, none to anything else. No app ever
  offers to view or control an iPhone or iPad.
- **Languages:** British English and Russian. `scripts/rr/ios-l10n.py` exports the strings, lists the ones without
  Russian, fills them in and checks; the build fails on a string without Russian.

| Folder | What it is |
| --- | --- |
| `Bridgey/` | The app: model, settings, screens, assets, and the String Catalogs (English and Russian). |
| `Shared/` | Used by the app and the Share extension: the core wrapper, Keychain, Bonjour, the brand. |
| `ShareExtension/` | Share > Bridgey. |
| `BridgeyTests/` | Unit tests, including two real clients pairing through the Swift wrapper. |
| `BridgeyUITests/` | Pairing with a scripted peer, and light and dark screenshots. |
| `Config/` | Info.plists, entitlements and `Bridgey.xcconfig` (identifiers, versions, signing). |

The project uses Xcode's synchronised folders: a new Swift file in one of these folders is in the build without
editing the project.

## Build and test

You need a Mac with Xcode 27 and Rust (`rustup`).

```sh
scripts/rr/build-ios.sh              # the core, the app, unit and UI tests, iPad screenshots, a device build
scripts/rr/build-ios.sh --core-only  # just Frameworks/BridgeyCore.xcframework, then open Bridgey.xcodeproj
```

The script makes throwaway iPhone and iPad simulators (from the runtime's device types on a Mac that has none) and
deletes them afterwards. The UI tests pair with two copies of `rust/client/examples/peer.rs` on the same Mac: one as
an Android phone (`--phone`: conversations, files, a screen clip, notifications) and one as a Mac (`--mac`: a screen
clip and control). A test sends a peer commands by appending lines to its commands file (`BridgeyUITests/
ScriptedPeer.swift`). Output goes to `ios/out`: `screenshots/`, `test-results/` (zipped result bundles) and `logs/`.

RR CI runs the same script as the `ios` lane for pull requests that touch `ios/` or `rust/`
([`ci/rr-ci-ios-task.json`](../ci/rr-ci-ios-task.json)).

Debug builds read these when a test starts them: `BRIDGEY_DATA=memory` (pairing data in memory, settings in a
throwaway domain), `BRIDGEY_PORT`, `BRIDGEY_DISCOVERY=0`, `BRIDGEY_SKIP_SETUP=1`, `BRIDGEY_APPEARANCE=light|dark`
and `BRIDGEY_DEMO=home|empty|pair|setup` and the features' own values (sample devices for screenshots), and
`BRIDGEY_FOUND=id|name|platform|host|port` (a device on the network without Bonjour). Release builds ignore them.

## Versions

As the other apps ([docs/rr-edition.md](../docs/rr-edition.md), "Versions"): the build script passes
`BRIDGEY_VERSION_NAME` (`1.0.0-beta.2`, or `1.0.0-dev` locally) and the UTC build time as the build number.
`CFBundleShortVersionString` is the plain `1.0.0` the App Store needs; About shows "1.0 Beta 2" and the full
version with the build.

## Settings

Each has a sensible default and a switch:

- the name other devices see (the device's name);
- Clipboard, on;
- Copy received text, on;
- Files, on;
- Links, on;
- Open links right away, off;
- Text previews, on;
- Phone notifications, on;
- Codes from messages, off; Also read codes in email, off;
- Text messages, off until chosen (as on the Mac and Windows); Keep conversations, on;
- Screens, on (the phone or Mac decides who may see and control it);
- Battery, on; Find device, on;
- Connect away from home, on;
- Appearance, automatic;
- Reduce motion, off (iOS's own setting always applies).

Each paired device has its own Clipboard, Files, Links, Battery and Find device switches, Phone notifications and Text
messages for a phone, Screen for a phone or a Mac, a ping, Ring and Forget.

## TestFlight

Not set up yet. The Apple Developer membership was bought on 8 November; enrolment had an ID region query on
11 November, so nothing has been registered with Apple. Once enrolment is confirmed:

1. Put the team ID in `Config/Signing.local.xcconfig` (see the `.example`), or pass `DEVELOPMENT_TEAM`.
2. Register the App IDs `in.roundrobin.bridgey` and `in.roundrobin.bridgey.share`, the App Group
   `group.in.roundrobin.bridgey`, and Keychain sharing (automatic signing does this on the first signed build).
3. Create the app in App Store Connect and an API key for uploads.
4. Answer export compliance: Bridgey encrypts its own connections (AES-GCM, ECDH, ECDSA).
5. Run `scripts/rr/ios-archive.sh` (archive, export and, with `--upload`, TestFlight).

The Mac's direct and App Store editions use their own bundle IDs; using `in.roundrobin.bridgey` for iOS keeps
the door open for universal purchase with a Mac App Store app under the same ID later.
