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
- Links (on) and Open links right away (on), Media controls (off), Battery, Find device and Ping (on);
- for each paired device, its own Clipboard, Files, Battery, Find device, Ping, Notifications, Links and Media controls
  switches;
- start at sign-in, on by default;
- keep running in the notification area, on by default;
- appearance;
- reduce motion.

A second copy of `Bridgey.exe` doesn't start another app. It brings the running one forward. It also takes
`--tray-menu`, `--pair`, `--quit` and `--send <files>` (what Send to runs).

Test hooks: `BRIDGEY_DATA_DIR` runs a separate profile. That profile has its own pairing data, never touches the
sign-in items or the Send to menu, and runs as its own single instance. `BRIDGEY_PORT` and `BRIDGEY_DISCOVERY=0`
change the port and turn off discovery. `BRIDGEY_NO_BROWSER=1` logs links instead of opening them. `BRIDGEY_RECEIVE_DIR` and `BRIDGEY_SENDTO_DIR` move the default receive
folder and the Send to shortcut. `"fastTransfers": false` in settings.json sends JSON chunks instead of binary frames.

## Not yet

- Signing: Azure Trusted Signing or another certificate is a later decision.
- MSIX and winget.
- Self-update on the Stable, Beta and Nightly feeds (M2).
- Replying to text messages from the Messages window (M3); a notification's own Reply works now.
- Share from other apps: Windows offers Share targets only to packaged (MSIX) apps; Send to covers Explorer.
- Sending folders.
- Messages, calls, phone files, and screen view and control (M3).

The activity list is in memory only for now.
