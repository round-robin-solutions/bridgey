# Bridgey by Round Robin for Windows

The Windows app: pairing with the Android and Mac apps (protocol 2), a home screen with each device's status and
battery, clipboard text and files in both directions, and find device both ways. It runs from the notification area.
Phone notifications show as Windows notifications with the phone's own buttons, a reply box and Dismiss, and on the
Notifications page. Notifications from other milestones follow ([plan](../docs/session-client.md)).

Links go both ways: a link the phone sends opens at once (or waits on Home with Open), and a link typed or pasted
into the send box goes to the phone with **Send link**. With Media controls on (off by default), the phone's media
buttons control whatever plays on this PC through Windows' media controls and show what it is. Connect away from home
(on by default) lets the phone and Mac reach this PC from other networks.

When the phone routes alerts to the device in use, this PC tells it whether it's in use (whether there was input
in the last two minutes, or the PC is locked; never keys or apps) and keeps notifications the phone marks quiet without
showing a banner. Codes from messages (off by default) shows one-time codes with Copy code. Windows finds them with
rules on this PC, where the Mac asks its model; nothing is sent anywhere.

**Messages** shows the phone's texts (Text messages, off until you turn it on here and for this PC on the phone):
conversations with unread ones first, each conversation with its pictures, sending and replying from either SIM, a new
message to a number or a contact the phone finds, and Mark as read, which the phone passes to its messaging app. A text's
notification opens its conversation, and its Reply goes through the phone even when the messaging app has none.
Conversations are kept encrypted for the Windows user (Settings > Text messages > Keep conversations on this PC).

**Calls** calls through the phone (the Calls window, off until you turn it on and allow each phone, here and in
Bridgey on the phone): a keypad and a field for a name or number, the phone's recent calls, its contacts with their
WhatsApp voice and video calls, and the SIM to call from. The phone places each call, so call audio stays on the phone
or its earbuds. When the phone rings, a card over every page shows the caller with the phone's own Answer and Decline,
then Hang up, until the call ends.

**Phone files** browses the phone (when Let other devices browse this phone is on there): its photos and videos, recent
files, and its folders, with thumbnails. **Download** brings the selection, files and whole folders, to the received
files folder (**Download to…** asks where); a name already there gets a number, so nothing is overwritten. **Add files**,
or a drop on the page, puts files from this PC in the folder being browsed, when the phone allows changes there. A
folder the phone sends lands in the received files folder.

Files go from the device card's **Send files**, by dragging them onto the window or a device card, from the
notification area menu, or from Explorer: right-click, **Send to**, **Bridgey**. Received files go to
Downloads\Bridgey (Settings > Files changes it) and are never overwritten: a second `photo.jpg` becomes
`photo (1).jpg`. Folders can't be sent yet.

## How it is built

- **UI:** WinUI 3 (Windows App SDK 2.6), in the edition's "Stream" style. It follows the app's light or dark
  setting, uses Mica where Windows has it, and keeps its motion to opacity and position. Windows' "Animation
  effects" and Settings > General > Reduce motion both turn motion off.
- **App code:** C# on .NET 10, compiled ahead of time (NativeAOT). It ships as one self-contained folder for x64
  and Arm64, and needs no .NET install.
- **Session:** `bridgey_core.dll`, built from [`rust/client`](../rust/client) and called through
  source-generated P/Invoke (`src/Bridgey.Core/Native`). Pairing data is encrypted for the Windows user with DPAPI
  in `%LOCALAPPDATA%\Bridgey by Round Robin`.

| Folder | What it is |
| --- | --- |
| `src/Bridgey.Core` | The interop, settings, version labels and view models. It builds and is tested on Linux too. |
| `src/Bridgey.App` | The WinUI app: windows and pages, the notification area icon, the clipboard and Windows services. |
| `tests/Bridgey.Core.Tests` | Unit tests. They include two clients pairing through the real `bridgey_core` library. |
| `tests/Bridgey.UiTests` | FlaUI tests. They take screenshots in light and dark and pair with a scripted peer. |

## Build and test

You need Windows 10 or 11, the .NET 10 SDK, Rust (`rustup`) and Visual Studio's C++ build tools with the ARM64
tools. Building for Arm64 also needs LLVM.

```powershell
pwsh -NoProfile -File scripts/rr/build-windows.ps1                    # both architectures, every test
pwsh -NoProfile -File scripts/rr/build-windows.ps1 -Architectures x64 -SkipUiTests
```

The output goes to `windows/out`:
- `Bridgey-RR-<version>-windows-x64.zip` and `...-arm64.zip`;
- `SHA256SUMS`;
- `screenshots/`;
- `test-results/`;
- `logs/`.

RR CI runs the same script on GitHub's hosted `windows-latest` runners, as the `windows` lane for pull requests
that touch `windows/` or `rust/` (task definition: [`ci/rr-ci-windows-task.json`](../ci/rr-ci-windows-task.json)).

The C# unit tests also run on Linux against `libbridgey_core.so`:

```sh
cargo build -p bridgey-client --manifest-path rust/Cargo.toml
cd windows && dotnet test --project tests/Bridgey.Core.Tests
```

## Installing a test build

1. Unzip the folder anywhere, for example into `%LOCALAPPDATA%\Programs`.
2. Run `Bridgey.exe`.

Bridgey updates itself from the edition's Stable, Beta and Nightly feeds: it offers a new version on Home or in
Settings > Updates, checks the download's size, checksum and the release key's signature, and installs it when you
say so. Keep the folder somewhere you can write to (not Program Files).

Builds aren't signed yet, so Windows SmartScreen says "Windows protected your PC" on the first run. Choose
**More info**, then **Run anyway**. The first time Bridgey listens for your devices, Windows Firewall asks whether
it may use private networks. Allow it, or your phone and Mac can't connect.

The settings that change the app's behaviour are in Settings:
- the name other devices see;
- Clipboard, on for paired devices;
- Automatic clipboard, off by default;
- Files, on, the folder received files go to, a notification when one arrives (on) and Bridgey in Send to (on);
- Notifications, on: Windows notifications (on), which apps show banners, history (off; 7 days, at most 200,
  encrypted), Codes from messages (off), Also read codes in email (off), Copy codes automatically (off), and Share
  when I'm using this PC (on);
- Away from home: Connect away from home, on, and its status;
- Text messages, off, and Keep conversations on this PC (on);
- the Calls window, off, the phones it may call through (each off until allowed), Call from (Ask each time), Show
  WhatsApp calls (on) and Recent calls (last 20);
- Links (on) and Open links right away (on), Browser extensions (off: the extension's native messaging host for
  Chrome, Edge, Brave and Firefox, [docs](../docs/browser-extensions.md)), Media controls (off), Battery, Find device
  and Ping (on);
- for each paired device, its own Clipboard, Files, Battery, Find device, Ping, Notifications, Links, Media controls,
  Text messages and Calls window switches;
- Updates: the channel (the build's own: Beta for a beta), Check for updates when Bridgey opens (on, at most every
  six hours), Check now and Install;
- start at sign-in, on by default;
- keep running in the notification area, on by default;
- appearance;
- reduce motion.

A second copy of `Bridgey.exe` doesn't start another app. It brings the running one forward. It also takes
`--tray-menu`, `--pair`, `--quit` and `--send <files>` (what Send to runs).

Test hooks: `BRIDGEY_DATA_DIR` runs a separate profile. That profile has its own pairing data, never touches the
sign-in items or the Send to menu, and runs as its own single instance. `BRIDGEY_PORT` and `BRIDGEY_DISCOVERY=0`
change the port and turn off discovery. `BRIDGEY_NO_BROWSER=1` logs links instead of opening them. `BRIDGEY_RECEIVE_DIR` and `BRIDGEY_SENDTO_DIR` move the default receive
folder and the Send to shortcut. `BRIDGEY_UPDATE_FEED_BASE`, `BRIDGEY_UPDATE_TRUSTED_PREFIX`, `BRIDGEY_UPDATE_PUBLIC_KEY`
and `BRIDGEY_UPDATE_CURRENT_BUILD` point a separate profile's updater at a test feed (a normal install ignores them). `"fastTransfers": false` in settings.json sends JSON chunks instead of binary frames.

## Not yet

- Signing: Azure Trusted Signing or another certificate is a later decision.
- MSIX and winget.
- Share from other apps: Windows offers Share targets only to packaged (MSIX) apps; Send to covers Explorer.
- Sending folders.
- Screen view and control (M3).
- Calls from tel: links in the browser extension and from other apps (the Mac asks first); call audio on this PC.
- Phone files: previews, opening a file without downloading it, adding folders, and continuing a download or upload
  that broke off (it stops, and the files that arrived stay).
- Pinning, muting, archiving and deleting conversations, and searching them (the Mac has these).

The activity list is in memory only for now.
