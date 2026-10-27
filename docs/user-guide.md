# User guide

Bridgey by Round Robin connects an Android phone and a Mac over your own Wi-Fi. It has no
account and no cloud service for normal use. This guide covers the common tasks. For what has
been tried on which devices, see [compatibility](compatibility.md).

Contents: [install](#install), [pair](#pair-a-phone-and-a-mac), [clipboard and files](#send-the-clipboard-and-files),
[notifications](#notifications), [calls](#calls), [codes from messages](#codes-from-messages),
[remote control](#remote-control), [updates](#update-channels-and-updates), [permissions](#permissions),
[reset](#reset-local-data), [uninstall](#uninstall), [troubleshooting](#troubleshooting).

## Install

Both apps are on the
[releases page](https://github.com/round-robin-solutions/bridgey/releases) of
`round-robin-solutions/bridgey`. Each release has an Android APK, a Mac DMG and ZIP, and a
`SHA256SUMS` file.

Quick ways in: on a Mac, `brew install --cask round-robin-solutions/tap/bridgey-rr`; on Android,
[Obtainium](#android-with-obtainium) keeps the app updated from the same releases. The steps below
use the files directly.

### Android

1. On the phone, open the releases page and download the file ending in `-Android.apk` from the
   newest release without a "Pre-release" label.
2. Open the file. Android asks you to allow installs from that app (your browser or Files). Allow it
   for this install.
3. Open **Bridgey RR** (the launcher name) and follow the welcome screen.

To check the download, compare its SHA-256 with the line for that file in `SHA256SUMS`.
Android requires every update to be signed with the same key as the installed app, so Bridgey only
installs updates from its own releases.

Bridgey supports Android 8.0 and later.

#### Android with Obtainium

[Obtainium](https://obtainium.imranr.dev) installs and updates apps straight from GitHub releases.
With it installed, open one of these links on the phone. It adds Bridgey with the right release
filter for the channel, and Android still shows its own confirmation for every install. There is no
Stable release yet, so use Beta for now.

<!-- obtainium:start markdown -->
[Stable](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522in.roundrobin.bridgey%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fround-robin-solutions%252Fbridgey%2522%252C%2522author%2522%253A%2522Round%2520Robin%2522%252C%2522name%2522%253A%2522Bridgey%2520by%2520Round%2520Robin%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522includePrereleases%255C%2522%253Afalse%257D%2522%257D) | [Beta](https://apps.obtainium.imranr.dev/redirect?r=obtainium%3A%2F%2Fapp%2F%257B%2522id%2522%253A%2522in.roundrobin.bridgey%2522%252C%2522url%2522%253A%2522https%253A%252F%252Fgithub.com%252Fround-robin-solutions%252Fbridgey%2522%252C%2522author%2522%253A%2522Round%2520Robin%2522%252C%2522name%2522%253A%2522Bridgey%2520by%2520Round%2520Robin%2522%252C%2522additionalSettings%2522%253A%2522%257B%255C%2522includePrereleases%255C%2522%253Atrue%252C%255C%2522filterReleaseTitlesByRegEx%255C%2522%253A%255C%2522-rr%255B.%255D%255B0-9%255D%252B%28-beta%255B.%255D%255B0-9%255D%252B%29%253F%2524%255C%2522%257D%2522%257D)
<!-- obtainium:end -->

Stable follows releases not marked "Pre-release". Beta follows Stable and Beta releases. Nightly
(`python3 scripts/rr/obtainium.py links --channels nightly`) follows every build.

### Mac

With Homebrew:

```sh
brew install --cask round-robin-solutions/tap/bridgey-rr
```

The cask comes from [round-robin-solutions/homebrew-tap](https://github.com/round-robin-solutions/homebrew-tap).
It installs the newest Stable release (until there is one, the newest Beta) and removes the download
quarantine flag from the app, because the app is ad-hoc signed and not notarised yet. Homebrew 6 and
later asks you to trust a third-party tap; naming the full cask as above trusts just that cask. The
app updates itself afterwards, so `brew upgrade` leaves it alone; `brew uninstall --cask --zap
bridgey-rr` removes the app and its data.

With the DMG:

1. Download the file ending in `-macOS.dmg` and open it.
2. Drag **Bridgey by Round Robin** to Applications.
3. The first time, right-click the app and choose **Open**, or open System Settings > Privacy &
   Security and press **Open Anyway**. The app is not yet signed with an Apple Developer ID, so macOS
   asks once.
4. Allow **local network** access when macOS asks. Bridgey needs it to find and reach your phone.

Bridgey needs macOS 13 or later.

The edition installs next to the original Bridgey. Both listen on the same port, so quit one
before you run the other on a Mac.

## Pair a phone and a Mac

Keep both on the same Wi-Fi. Open Bridgey on both.

1. On the Mac, the menu-bar panel lists nearby phones. On the phone, open **Settings > Devices and
   permissions > Pair a new device** (or tap **Add** on the home screen).
2. Choose the other device. Either side can start.
3. Both screens show a six-digit code. Press **Codes Match** (Mac) and confirm on the phone only if
   the two codes are the same. If they differ, cancel: someone else may be on the network.

After this the devices reconnect on their own. To stop trusting a device, open it and choose
**Forget** (it must be forgotten on both sides to be gone everywhere).

## Send the clipboard and files

### Clipboard

- **Mac to phone:** copy on the Mac. With "Automatic clipboard" on (default), it reaches the phone
  without a tap. The Mac shortcut for "Send clipboard" is Control-Option-C (you can change it in
  Settings).
- **Phone to Mac:** while Bridgey is open it is automatic. Otherwise tap **Send copied item** in the
  Bridgey notification, or add the **Send copied item** tile to Quick Settings. Android does not
  let an ordinary app read the clipboard in the background (Android 10 and later); see
  [why](rr-edition.md#automatic-clipboard-and-why-it-is-not-fully-automatic-from-the-phone).
- **Images and files:** with **Copy images and files** on in Settings > Clipboard, copied images,
  videos and files move when you paste. This works between two Round Robin edition apps. With
  the original Bridgey only text up to 32 KiB moves.
- **Fresh screenshot:** if you took a screenshot in the last minute, **Send copied item** sends
  it instead. This needs access to all photos.

Anything marked sensitive (for example by a password manager) is not sent.

### Files

- **From the Mac:** drop files on the panel, or use the send bar.
- **From the phone:** tap the attach button in the send bar, or use Android's **Share** menu and
  choose Bridgey.
- Several files go one after another in a queue. Each can be cancelled on its own. An interrupted
  send can be retried once the devices reconnect.
- **Where they land:** Android saves to `Download/Bridgey`. The Mac saves to `Downloads/Bridgey` by
  default; change it in Settings > Files (Received files). A file never replaces an existing one.

## Notifications

Phone notifications can appear on the Mac.

1. On the phone, open **Settings > Notifications** and turn on **Notification forwarding**.
2. Choose **Notification forwarding** and allow **notification access** for Bridgey in Android's
   own screen.
3. On the Mac, allow notifications for Bridgey when asked.
4. Under **Notification apps**, choose which apps may be shown on the Mac.

You can dismiss, act on or reply to a notification from the Mac when the phone app offers that.
Dismissals sync both ways. A notification history on the Mac is off by default.

## Calls

- **Call from the Mac:** copy a phone number and press **Call** in Bridgey or Control-Option-P. In
  apps with macOS Services, select a number and choose **Services > Call with Bridgey RR**. By
  default the phone shows a notification; tap it to review the number in the dialer.
- **Call status and answer controls on the Mac:** on the phone open **Settings > Calls** and turn on
  **Call status and controls**. Android asks for Phone permissions. After that the Mac shows incoming
  and active calls with **Answer**, **Decline** and **Hang Up**. Bridgey does not ask for contacts or call
  history and never dials emergency numbers itself.
- **Phone links:** on the Mac, Settings > Calls > **Phone links** > **Use Bridgey** sends `tel:` links
  from your browser to Bridgey.

## Codes from messages

When a text message has a one-time code, the Mac can show "Code 482913 from HDFC Bank" with **Copy
code**. It is off by default.

1. **On the Mac:** Settings > Notifications > **Codes from messages** > turn on **Show codes from text
   messages**. Choose **Read codes**: **On this Mac (private)** downloads a small model (253 MB, one
   time) and reads messages on the Mac. **Cloud (Cloudflare)** sends the message text to Round Robin's
   relay. See [the edition notes](rr-edition.md#codes-from-text-messages-draft-protocol) for the details.
2. **On the phone (Android 15 and later):** Android hides code text from apps it does not trust. Open
   **Settings > Notifications > Codes from messages** and tap **Link this phone to the Mac**. The
   Mac advertises over Bluetooth for a minute, Android's own dialog finds it, and you tap **Allow**
   once. Turn on Bluetooth (and, if Android finds no Mac, Location) on the phone. The Mac asks for
   Bluetooth permission the first time.
3. **With more than one Mac:** the phone shows which Mac it is linked to and lets you pick which Mac
   to link.
4. The phone shows **Code access: allowed**, **hidden by Android** or **not linked**.

If linking does not work, the phone shows a one-time ADB command to run from a computer, with a Copy
button. Removing the link in Android settings may also turn off Bridgey's notification access.

Copied codes stay on the Mac, are marked so clipboard managers skip them, and are cleared after 60
seconds. Codes and message text are never written to logs or diagnostics.

## Text messages

Read and answer your phone's text messages on the Mac. It is off until you turn it on.

1. On the phone, open **Settings > Text messages** and turn it on for your Mac. Allow SMS access
   when asked; contacts access is optional (without it you see numbers instead of names).
2. On the Mac, open **Settings > Notifications > Text messages** and turn it on.

Then:

- A text message notification on the Mac has a **Reply** field. Your reply goes through your
  messaging app when it can, or as an SMS. If replies from your messaging app do not arrive, turn
  on **Send replies as SMS** on the phone.
- **Messages** (from the menu bar panel, or by clicking a text notification) shows your
  conversations. Pick a conversation to read it and reply; use **New message** to write to a
  contact or a number. On a phone with two SIMs, choose the SIM next to the send button.
- Group conversations can be read on the Mac; answer them on the phone.
- Your messages go only to your own paired Macs, encrypted. Bridgey never becomes your default SMS
  app. Turning Text messages off, or forgetting the phone, deletes the copy on the Mac.

## Remote control

The phone can act as a touchpad, keyboard and slides remote for a Mac. It is off on both sides
until you turn it on, and only works between two Round Robin edition apps.

1. **Mac:** Settings > **Remote control**: turn it on, and allow the phone. macOS asks for
   Accessibility access when it first becomes usable.
2. **Phone:** Settings > **Remote control**: turn it on. The Mac's device page then shows a **Remote
   control** entry.
3. Start a session. While it runs, the Mac shows a pill at the top of the screen with **Stop**, and
   the menu-bar icon changes. Control-Option-Escape on the Mac also stops it.

The Mac keeps a 30-day session record (device, times and counts, never what you typed) that you can
clear in the same pane.

## Update channels and updates

Bridgey updates itself. Open **Settings > Updates** on either device.

| Channel | For |
| --- | --- |
| **Stable** (default) | Tested releases. Best for most people. |
| **Beta** | New features before they reach Stable. |
| **Nightly** | Built from every change. Expect rough edges. |

Switching to a steadier channel never downgrades; it waits for that channel's next newer build.
The apps check daily, and **Check now** checks at once. Nothing installs silently: Android always shows its own
confirmation screen, and the Mac shows each step with **Install**, **Later** and **Skip**.
On Android the download must match its published checksum and be signed with the same certificate as the
installed app. On the Mac the update must carry a valid EdDSA signature. Details are in
[the edition notes](rr-edition.md#channels-and-feeds).

## Permissions

Bridgey asks for each optional permission only when a feature needs it.

On the phone, **Settings > Privacy > Permissions** lists every optional permission with its state
(allowed or not) and a **Manage** button that opens the right Android screen. The first time a
feature needs a permission, Bridgey explains why and what stops working without it. If you decline,
only that feature stays off.

If you do not see this screen, you are running a build from before it was added; update first.

What the optional permissions are for:

| Permission | Used for |
| --- | --- |
| Notifications (Android 13+) | The connection notification, transfer progress and Send copied item |
| Notification access | Forwarding phone notifications; reading code messages |
| SMS | Text messages: your conversations on the Mac and sending replies (only if you turn it on) |
| Contacts | Text messages: names instead of numbers, and finding a contact for a new message |
| Phone | Call status and Answer, Decline, Hang Up (only if you turn on Call status and controls); choosing the SIM for Text messages on a dual-SIM phone |
| Photos | Sending a fresh screenshot (needs all photos) |
| Battery optimisation | Staying connected while the phone sleeps |
| Install unknown apps | Installing Bridgey's own updates |
| Companion link (Bluetooth dialog) | Android 15+ code access |
| Logs (ADB only) | The optional "Background clipboard (advanced)" |

On the Mac: Local network (always), Notifications (for phone alerts), Bluetooth (linking for
codes), Accessibility (remote control) and Automation (Music or Spotify control). Bridgey does not
ask for location, contacts, SMS, call history, camera, microphone or screen recording in the normal
build.

## Reset local data

On the phone, open **Settings > Privacy > Reset Bridgey on this device**. There are four choices.
Each asks you to confirm and lists what it will delete. In short:

- **Activity and logs:** the activity stream and the diagnostics log.
- **Downloaded models and caches:** downloaded files and cached items that Bridgey can fetch again.
- **Settings:** your preferences, back to defaults.
- **Everything, including pairings:** all of the above, and the trust records. You must pair again.

Each choice's confirmation screen is the source of truth for what it deletes. If you do not see this
screen, you are running a build from before it was added. The Mac has its own **Clear** buttons in
Settings > Privacy (Activity, Logging). Resetting one device does not change the other.

## Uninstall

1. On each device, **Forget** the other, so no stale trust record is left.
2. **Android:** uninstall Bridgey RR from Android's app settings. If you linked the phone for codes,
   also remove the link in Android's companion-device settings.
3. **Mac:** quit Bridgey, move **Bridgey by Round Robin** from Applications to the Bin. Then, if you want
   the data gone, delete `~/Library/Application Support/in.roundrobin.bridgey` (pairing keys, activity,
   diagnostics, models) and `~/Library/Caches/in.roundrobin.bridgey`.

Files you received stay in `Download/Bridgey` and `Downloads/Bridgey`.

## Troubleshooting

**The devices do not find each other.** Check both are on the same Wi-Fi. Some guest or office
networks block devices from seeing each other. On the Mac, check System Settings > Privacy &
Security > Local Network allows Bridgey. Press **Look for devices again** (the refresh button on the phone's home screen, or in the Mac panel), or
**Retry now** on a paired device. Check the original Bridgey is not running on the Mac.

**It disconnects overnight or when the phone sleeps.** Allow Bridgey to stay connected: Settings >
General > "Stay connected while the phone sleeps". Many phones add their own limit; see
[compatibility](compatibility.md#phone-makers-and-skins). On OnePlus, open App info > Battery usage and
allow background activity.

**Phone notifications do not appear on the Mac.** Check Notification forwarding is on, Bridgey has
notification access on the phone ("Needs notification access" means it does not), the app is chosen
under Notification apps, and the Mac allows Bridgey notifications.

**Copying on the phone does not reach the Mac.** This is Android's limit. Open Bridgey, or tap **Send
copied item**.

**No code appears for a text message.** Check Codes from messages is on at the Mac, the code model is
downloaded (or Cloud chosen), and on Android 15 and later that the phone shows **Code access: allowed**.
If it says hidden by Android or not linked, link the phone.

**Remote control says Accessibility is needed.** Allow Bridgey in System Settings > Privacy & Security >
Accessibility. After an update you may need to switch it off and on again in that list.

**Something else is wrong.** Export [diagnostics](diagnostics.md) from both devices, then open an issue at
[github.com/round-robin-solutions/bridgey/issues](https://github.com/round-robin-solutions/bridgey/issues).
Do not paste private content into the issue.
