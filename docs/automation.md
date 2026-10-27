# Automation and connection health (roadmap 0.9, first part)

Bridgey by Round Robin edition. This covers Mac actions, Shortcuts from the phone, Android
Device Controls, the widget and tiles, link handoff, and the connection health view. The wire
contract is in [protocol.md](protocol.md): "Mac actions (`mac_actions_draft1`)", "Open links right
away (`links_open_draft1`)" and "Connection health".

## Principles

- **No remote shell.** The phone picks an entry from a list the Mac published for that phone. The
  Mac maps it to a fixed local operation. The only operand on the wire is the 0 to 100 level of
  `volume_set`. There is no free-form text, no arguments and no command string.
- **Off by default, three gates on the Mac.** Mac actions has to be on for this Mac, each action
  has its own switch (Lock screen, Sleep, Start screen saver, Volume), and each phone needs its own
  grant. Apps and Shortcuts are opt-in lists the person builds on the Mac.
- **Rate limits and an audit log.** Volume: 10 at once, then 5 a second. Everything else: 3 at
  once, then one every 2 seconds. One Shortcut at a time. Every run and refusal goes to a private
  log on the Mac (`mac-actions-audit.json`, owner-only, 30 days, 500 entries), like the remote
  control session log.

## Where the settings live

- **Mac:** Settings > Media and actions (the agreed order is unchanged). It holds the Mac
  actions card (the switch, one switch per action, and Accessibility when Lock needs it), "Apps a
  phone can open", "Shortcuts a phone can run", "Phones allowed to use Mac actions" and the
  "Action log". Each phone's grant also shows in Settings > Devices, under remote control's. "Open
  links from phones right away" is under Web links in the Quick actions card.
- **Phone:** Settings > Media and quick actions has a Mac actions switch (on by default on the
  phone, because the Mac is the gate). The Mac's page has a Mac actions card and a Connection tab.

## How each Mac action works (public interfaces only)

| Action | macOS route | Permission |
| --- | --- | --- |
| Lock screen | Posts the system Lock Screen shortcut, Control-Command-Q, with `CGEvent` | Accessibility (the same access remote control uses), asked once when Lock is turned on |
| Sleep | IOKit `IOPMSleepSystem` (what `pmset sleepnow` calls) | none: allowed for the logged-in user, no admin rights, no Automation prompt |
| Start screen saver | Opens `/System/Library/CoreServices/ScreenSaverEngine.app` with `NSWorkspace` | none |
| Volume up, down, mute, level | CoreAudio on the default output device (virtual main volume, mute) | none |
| Open an app | `NSWorkspace.openApplication` by bundle identifier from the local list | none |
| Run a Shortcut | `/usr/bin/shortcuts run <name>` with no input | none for Bridgey; the Shortcut's own actions may ask |

**Why Lock uses the keyboard shortcut.** macOS has no public "lock now" call. `SACLockScreenImmediate`
in `login.framework` is private. The old `CGSession -suspend` binary no longer ships (it went in
macOS 11), and it switched users rather than locking. `pmset displaysleepnow` only locks when
"Require password after the display is turned off" is set to Immediately. The Lock Screen shortcut
is documented by Apple, works on macOS 13 to 27, and needs only Accessibility. If someone remapped
that shortcut in System Settings > Keyboard, Lock does nothing (it reports done, because macOS
gives no feedback).

**Why sleep answers first.** The Mac sends `actions.result` and sleeps one second later, so the phone
sees "done" instead of a timeout. The phone reconnects when the Mac wakes.

**Why `shortcuts run` and not the URL scheme.** `shortcuts://run-shortcut?name=` brings the Shortcuts
app to the front and reports nothing back. The command line tool runs without a window and returns
an exit status, so the phone hears done or failed. The name comes from the Mac's own list (the
phone sends only a random handle the Mac made when the person added it) and is passed as one
process argument, never through a shell. No input is passed. A run is stopped after 60 seconds.

## Android Device Controls, widget and tiles

- **Device Controls** (Android 11 and later, power menu or Quick Settings): per paired Mac, Lock,
  Sleep, Screen saver, a volume slider, Mute, the listed apps and Shortcuts, Ping, Find (a toggle
  that shows ringing), and Send copied item. A control service cannot read the clipboard, so Send
  copied item opens Bridgey's clipboard reader aimed at that Mac. Controls stay listed while the Mac
  is offline, using the last list it sent, and show Offline.
- **Widget** ("Bridgey Mac"): one Mac, its state, and Lock, Sleep, Volume down, Volume up, Ping and
  Send copied item. Setup is optional; an unconfigured widget follows the Mac selected in Bridgey.
- **Quick Settings tile** "Lock Mac", aimed at the selected Mac. It asks to unlock the phone first.

## Link handoff

- **Phone to Mac:** "Open on Mac" in the share sheet. It shows only the link's host and the Mac
  (a picker when several are connected) and sends nothing until Open is tapped, because any app in
  the foreground could start it. If the Mac's "Open links from phones right away" is on (off by
  default), the link opens in the Mac's default browser, at most one per phone every 3 seconds.
  Otherwise it waits on the Mac like any received link.
- **Mac to phone:** the panel's Link button is now a menu: Send the Copied Link, and Send the
  Current Safari (or Chrome) Tab. A fixed AppleScript asks the browser used last for the front
  tab's address. macOS asks for Automation access to that browser the first time it is used, never
  before.
- **Future: a browser extension.** A small Safari Web Extension and a Chrome extension could offer
  "Send to phone" in the toolbar and the page menu without the Automation prompt, and could also
  catch links the phone sends. They would talk to the app through native messaging (Chrome) or the
  containing app (Safari), and need packaging and store review, so they are not built yet.

## Connection health

Per paired device, on both apps: the route class (same network, a private network such as
Tailscale's 100.64.0.0/10, or another network), who connected, how long it has been up, the
heartbeat round trip (last and typical of the last ten), the last disconnect reason, reconnect
attempts since local midnight and whether discovery sees the device now; the phone adds whether
battery optimisation is off. The round trip uses the existing heartbeat ping and pong. Nothing new
goes on the wire, and the view and its part of the diagnostics report (`health` per device) hold no
addresses, names or content. The reconnect count is kept in memory, so it starts again when the app
restarts.

## Testing on devices

Unit tests use fakes for every operating system call: they never lock, sleep, change the volume,
open apps or run Shortcuts. On real devices:

1. Mac: Settings > Media and actions, turn on Mac actions, Lock screen, Sleep and Volume, add an
   app and a Shortcut, and allow the phone. Turning Lock on asks for Accessibility once.
2. Phone: open the Mac's page. The Mac actions card lists the entries. Try volume, an app and a
   Shortcut, then Lock. Check the Action log on the Mac. Turn the phone's grant off: the card goes.
3. Tap Lock six times quickly: the fourth is refused as too many at once.
4. Device Controls, the widget and the Lock Mac tile: see the Android steps in the report.
5. Share a page from Chrome on the phone, choose Open on Mac, then Open. With "Open links from
   phones right away" on, the Mac's browser opens it; off, it waits in the panel.
6. On the Mac, open a page in Safari, then panel > Link > Send the Current Safari Tab. Allow
   Automation when asked. The phone shows the link.
7. Settings > Devices on the Mac and the Connection tab on the phone: route, round trip, last
   disconnect after toggling Wi-Fi, reconnects today. Export diagnostics and check `health`.

## Shortcuts and Siri on the Mac

Bridgey offers six App Intents actions in the Shortcuts app, Spotlight and Siri: Send Clipboard to
Phone, Send Files to Phone, Send Text to Phone, Ring My Phone, Ping Phone and Get Phone Battery
(it returns the phone, its level and whether it is charging). Each has an optional Phone
parameter; without it the action uses the phone selected in the panel. If Bridgey was not running,
macOS starts it and the action waits up to 10 seconds for the phone to connect. The phone's own
switches still apply: an action for a feature that is off says so. Four of them are App Shortcuts,
so they appear without any setup. Their spoken phrases are English only for now (titles and
messages are translated).

**SwiftPM and the metadata.** Shortcuts only sees actions listed in `Metadata.appintents` inside
the app, which Xcode makes with `appintentsmetadataprocessor`. Swift 6.4's SwiftPM already writes
the compiler's `.swiftconstvalues` files, so `build-app.sh` runs the processor itself with the
flags Xcode uses, before signing. It is best effort: if a toolchain lacks the files or the tool,
the build prints a warning and the app works without Shortcuts actions. macOS indexes the actions
only for an app in a normal location such as /Applications, not under /tmp.

## Phone battery alerts on the Mac

"OnePlus 11 at 15%" when the phone runs low and "OnePlus 11 fully charged" when it is full (or
"OnePlus 11 at 80%" for a lower charge limit). Thresholds are per phone in Settings > Devices,
under Battery status: Low (default 20%, or 10, 15, 30, Off) and Charged (default 100%, or 80, 90,
Off). Each alert shows once per charge cycle: the low alert again only after the phone was plugged
in or climbed 5 points above the threshold, the charged alert again only after it drained 5 points
below. Nothing new goes on the wire; the alerts come from `battery.update`. The memory is in
memory only, so restarting Bridgey may show a current alert once more.

## Focus and Do Not Disturb sync

Both directions are off by default and set on the device that changes: the phone in Settings >
Notifications > Focus, the Mac in Settings > Notifications > Focus. Wire contract: protocol.md,
"Focus and Do Not Disturb sync".

| Direction | Read on the source | Set on the target |
| --- | --- | --- |
| Phone to Mac | Android `NotificationManager.getCurrentInterruptionFilter` and its change broadcast (no permission needed to read) | macOS has no public interface to turn a Focus on or off. Bridgey runs a Shortcut the person picks for "on" and one for "off"; the Shortcuts app's own Set Focus action does it |
| Mac to phone | macOS reads Focus only through `INFocusStatusCenter`, which needs the Communication Notifications entitlement and so a paid Apple developer account (an ad-hoc signed app cannot use it). Bridgey instead offers a **Focus filter** (System Settings > Focus > a Focus > Focus filters > Bridgey, "Share this Focus with my phones") and a **Share Focus with Phones** Shortcuts action for a Focus automation | Android `setInterruptionFilter` with Do Not Disturb access (`ACCESS_NOTIFICATION_POLICY`, granted by the person in Android settings). On Android 15 and later this becomes an app-owned mode. Bridgey only turns off what it turned on |

Not possible without private interfaces: reading the Mac's Focus automatically (without the filter
or an automation), and changing the Mac's Focus without a Shortcut. A device that follows does not
send the resulting change back for 10 seconds, so two devices following each other cannot loop.
Turning Follow off hands the quiet mode back (runs the "off" Shortcut on the Mac; on the phone,
removes the Do Not Disturb Bridgey set).

## Phone camera to Mac

"Take Photo with OnePlus 11" is in the menu bar panel's File menu and is a Shortcuts action (Take
Photo with Phone, which waits up to two minutes and returns the photo). The phone shows a
full-screen camera with one shutter button; it asks for the camera permission the first time. It
opens only when the phone is unlocked and the person taps (Android does not let an app start an
activity from the background): a locked phone shows "Unlock your phone to take the photo" and the
Mac shows "Unlock OnePlus 11 to take the photo". The photo arrives as an ordinary file in Received
files; Settings > Files > "Copy photos from the phone camera to the clipboard" (off by default)
also puts it on the clipboard. The ML Kit document scanner is not included, because it needs
Google Play services, which this edition does not depend on.

## Setup, Permissions and Reset (v0.10)

- **Off until chosen.** Fresh installs start with every optional feature off; setup, a bundle or
  Settings turns them on. Each install records a defaults generation once (Android
  `bridgey.install/defaults_generation`, Mac `install.defaultsGeneration`): 1 for an install that
  ran before (its device ID already existed), keeping the old on-by-default values; 2 for a fresh
  install. Stored values always win and Reset > Settings keeps the generation, so updates never
  switch anything off. An off feature is sent as false in `features.update`, as when a person
  switches it off.
- **Get started quickly** turns on Essentials: pairing, the clipboard when you tap Send and phone
  notifications (only features that are off change), and says so on its card and on Done.
- **Advanced setup** is short: the start (five bundles named like their Settings pages, and an
  optional "Type what you want" box with keyword rules on the device), a follow-up only for the
  features picked or typed, one page of plain switches for every other feature ("Change details in
  Settings"), one Permissions page for what the chosen features need (runtime permissions in one
  system dialog, special access rows each with Allow, Allow all walking through them; anything not
  allowed leaves its feature off and setup goes on), then the summary. Typically 5 to 8 steps; the
  steps-left count comes from the actual path. Back goes to the previous step; leaving part way asks
  once. Settings that lost their question are under their Settings page (the coverage tests list
  them). Catalogue: `android/.../setup/SetupQuestions.kt`, `SetupTyped.kt`,
  `macos/Sources/BridgeyMac/SetupQuestions.swift`.
- **Permissions.** Phone: Camera (needed while Take photos for the Mac is on) and Do Not Disturb
  access (needed while Follow the Mac's Focus is on). Mac: Accessibility is needed for remote
  control and for Lock; Automation (Safari, Chrome) for Send the Current Browser Tab, a separate
  row from the music player's Automation. Turning Lock on and the first browser tab send show the
  explainer before macOS asks.
- **Reset.** Activity and logs deletes the Mac actions log and clears connection health on both.
  Models and caches deletes the phone's saved lists of Mac actions and waiting camera photos.
  Settings resets the Mac actions list and switches, Open links right away, battery alert
  thresholds, Focus and the camera options (all `settings.*` on the Mac; `bridgey.settings` and
  the widgets' Macs on the phone), and first hands back any Do Not Disturb or Focus that following
  turned on.
