# Bridgey by Round Robin for Linux

The Linux app: pairing with the Android and Mac apps (protocol 2), a home screen with each device's status and battery,
the clipboard both ways, files both ways, the phone's notifications as desktop notifications with their buttons and a
reply, codes, links, find device both ways, the phone's media buttons for what plays here, and Connect away from home.
It keeps running in the background, with an icon in the tray where the desktop has one.

Files go from a device card's **Send files**, by dragging them onto the window or a card, from the tray menu, or from
the file manager: **Send to Bridgey** in Files (Nautilus) and Nemo (right-click, **Scripts**) and in Dolphin. Received
files go to Downloads/Bridgey (Settings > Sharing > Files changes it) and are never overwritten. A file that breaks off
continues from where it stopped the next time it is sent. Folders can't be sent yet.

Messages, the Calls window, Phone files and the phone's screen come in Linux M2: rust/client already has the desktop
side of each (`sms.rs`, `calls.rs`, `phone_files.rs`, `screen.rs`, from Windows M3), so M2 adds their pages here.

## What each desktop allows

| | GNOME on Wayland | KDE Plasma on Wayland | Sway, Hyprland, COSMIC, niri, labwc | Any desktop on X11 |
| --- | --- | --- | --- | --- |
| Clipboard, this computer to the phone | in the background, through XWayland | in the background (data-control) | in the background (data-control) | in the background |
| Clipboard, the phone to this computer | set at once, through XWayland | set at once | set at once | set at once |
| Tray icon | only with the AppIndicator extension (Ubuntu turns it on); otherwise none, and Bridgey opens from the app grid | yes | with a bar that shows StatusNotifierItems (waybar) | yes on Xfce, Cinnamon, MATE, Budgie |
| Notification buttons | up to three, Reply opens Bridgey | yes, and Reply in the banner | depends on the daemon (mako, dunst, swaync show them) | depends on the daemon |
| Start at sign-in | yes | yes | if the session runs XDG autostart | yes |
| Whether you're using this computer | yes (Mutter's idle monitor) | yes | not yet: reported as unknown | yes |

GNOME's compositor (Mutter) offers no clipboard protocol for apps in the background (checked here with Mutter 46;
upstream declined the request) and gives the Wayland clipboard only to the app in front. Bridgey therefore talks to the X11 clipboard of XWayland, which Mutter
keeps in step with the Wayland clipboard both ways (spice-vdagent works the same way). If a GNOME session runs without
X11 support at all, Bridgey falls back to the window in front: it reads copies made elsewhere when you bring Bridgey
forward, **Send copied item** in the tray or the menu brings it forward for a moment, and text from the phone waits on a
banner with **Copy**. Settings > Sharing > Clipboard says which of these applies.

Copied images and files go to the phone as files (Send copied item, or by themselves with Automatic clipboard on). The
phone's own images and files reach this computer the same way, as files; the clipboard offer protocol
(`clipboard_files_draft1`) is not in rust/client yet.

Text a password manager marks secret (`x-kde-passwordManagerHint`, which KeePassXC sets) is never sent by itself.

## How it is built

- **UI:** GTK 4 and libadwaita through gtk-rs, in the edition's "Stream" style: the Midnight Aurora palette of the Mac
  and Windows apps as libadwaita's colours, Space Grotesk headings and the aurora ring on connected devices. It follows
  the desktop's light or dark style unless Settings > App > Appearance says otherwise, and keeps motion to opacity;
  the desktop's reduce animation setting and Settings > App > Reduce motion both turn it off.
- **App code:** Rust, linked to [`rust/client`](../rust/client) as a crate (no C ABI). The model (`src/state.rs`) takes
  the client's events and returns what the desktop should do, so it is tested without GTK.
- **Desktop:** D-Bus through zbus (notifications, MPRIS media players, the screen lock and idle time, the file manager),
  StatusNotifierItem through ksni, the clipboard through Wayland's data-control protocols (wayland-client) or X11
  (x11rb), XDG autostart and desktop entries.
- **Pairing data** is in `~/.local/share/in.roundrobin.bridgey` (folder 0700, files 0600), as the agent CLI keeps
  it. The Secret Service is a later step.
- **Packaging:** one AppImage per architecture (x86_64, aarch64) that carries GTK 4.14 and libadwaita 1.5 from Ubuntu
  24.04, so it runs on any distribution with glibc 2.39 or later. AppImage first because Bridgey updates itself the
  way it does on Windows (one file, replaced in place after the checks), with nothing to install and no store; a
  Flatpak would need the portals for the clipboard and the tray, which do not cover what Bridgey does in the
  background yet.

gtk-rs directly rather than Relm4: the app is a handful of pages drawn from one state, which a small model and plain
widgets express well; Relm4 adds a macro layer and follows gtk-rs releases with a delay.

| Folder | What it is |
| --- | --- |
| `src/state.rs` | The state and the event handling, without GTK. |
| `src/ui` | The window, Home, Notifications, pairing and Settings. |
| `src/platform` | Notifications, the tray, the clipboard (data-control, X11), battery, sound, media, activity, autostart, the app menu entry and file manager actions. |
| `src/update.rs` | Self-update of the AppImage. |
| `tests/ui_smoke.py` | The UI smoke test: the real app under a headless display, paired with the scripted peer. |
| `packaging/appimage.sh` | The AppImage. |
| `build/Dockerfile` | Ubuntu 24.04 with the packages the build and the tests need. |

## Build and test

```sh
scripts/rr/build-linux.sh               # on Ubuntu 24.04 or later with linux/build/packages.txt installed
scripts/rr/build-linux.sh --container   # anywhere with Docker
```

It runs rust/client's tests, the app's clippy and unit tests, the UI smoke test under Xvfb (English and Russian, light
and dark, then self-update from a local feed) and under headless sway (Wayland, the data-control clipboard), builds the
AppImage and starts it. Output in `linux/out`: `Bridgey-RR-<version>-linux-<arch>.AppImage`, `SHA256SUMS`,
`screenshots/` and `logs/`.

RR CI runs it as the `linux` lane on GitHub's hosted `ubuntu-24.04` runners (task definitions:
[`ci/rr-ci-linux-task.json`](../ci/rr-ci-linux-task.json)). The UI smoke test also runs under a headless GNOME
compositor (`tests/headless-mutter.sh`, with `mutter` and `xwayland` installed).

## Installing a test build

1. Download the AppImage and make it executable: `chmod +x Bridgey-RR-*.AppImage`.
2. Open it. Bridgey adds itself to the app menu (Settings > App turns that off) and starts at sign-in.

It needs FUSE to mount itself (`libfuse2` or `fuse3` on most systems); without it, run it with
`APPIMAGE_EXTRACT_AND_RUN=1`. A firewall must let other devices reach TCP port 42458 on the local network.

Bridgey updates itself from the edition's Stable, Beta and Nightly feeds: it offers a new version on Home or in
Settings > App > Updates, checks the download's size, checksum and the release key's signature, and replaces the
AppImage when you say Install. Keep the AppImage in a folder you can write to (such as `~/Applications`).

A second copy doesn't start another app; it brings the running one forward. It also takes `--background`, `--pair`,
`--settings`, `--send-dialog`, `--send <files>` (what Send to Bridgey runs) and `--quit`.

Test hooks: `BRIDGEY_DATA_DIR` runs a separate profile, with its own pairing data, its own single instance, and never
the autostart entry, the app menu or the file manager actions. `BRIDGEY_PORT` and `BRIDGEY_DISCOVERY=0` change the port
and turn off discovery; `BRIDGEY_CONNECT=0` keeps Connect away from home off. `BRIDGEY_NO_BROWSER=1` logs links instead
of opening them. `BRIDGEY_RECEIVE_DIR` moves the default receive folder. `BRIDGEY_LANG` (en, ru) picks the language.
`BRIDGEY_BATTERY=<level>,<0|1>` stands in for a battery. `BRIDGEY_DATA_CONTROL=0` and `BRIDGEY_X11_CLIPBOARD=0` turn
off the background clipboard routes. `BRIDGEY_UPDATE_FEED_BASE`, `BRIDGEY_UPDATE_TRUSTED_PREFIX`,
`BRIDGEY_UPDATE_PUBLIC_KEY` and `BRIDGEY_UPDATE_CURRENT_BUILD` point a separate profile's updater at a test feed (a
normal install ignores them). `BRIDGEY_TEST_CONTROL=<socket>` (a separate profile only) opens the control socket the
smoke test drives.

## Not yet

- Messages, the Calls window, Phone files and the phone's screen (Linux M2).
- This computer's screen on the phone.
- The clipboard offer protocol (images and files on the clipboard itself, rather than as files).
- Pairing data in the Secret Service (GNOME Keyring, KWallet).
- The Bluetooth companion link Android asks for before it shares the text of code messages (Windows advertises it;
  Linux would through BlueZ). Until then Bridgey answers that it is unsupported, and codes show only where the phone
  shares the text anyway.
- A Flatpak, and the portals it would need (the clipboard, a global shortcut for Send copied item).
- Browser extensions (the native messaging host).
- Signed AppImages beyond the update signature (an AppImage signature, or a distribution repository).
- Releases: the release flow builds the AppImages only with `BRIDGEY_RELEASE_LINUX=1`, off until Rahul says Linux
  ships.
