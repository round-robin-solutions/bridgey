# Changelog

Bridgey by Round Robin releases, newest first. Nightly builds are not listed. From 1.0 the edition has its own version numbers. Before that, versions followed the upstream Bridgey roadmap milestone a release contained, with -rr.N for Round Robin.

## 1.0 Beta 8 (1.0.0-beta.8), 26 November 2026

- Settings search finds everything added lately and lands on the right row, even ones a switch hides; on the phone, going back keeps your search.
- Lists drop the small capitals in their headings.

## 1.0 Beta 7 (1.0.0-beta.7), 26 November 2026

- Send the page you're on, or any link, from Chrome, Edge, Firefox, Brave or Arc to one of your devices: from the toolbar, the right-click menu or Alt+Shift+S. Turn on Browser extensions in Bridgey's Settings, then add the extension from this release's files.

## 1.0 Beta 6 (1.0.0-beta.6), 25 November 2026

- Control your phone from the Mac while you view its screen: tap, type, scroll, and use Back, Home and Recents. It needs Bridgey's accessibility service turned on in Android settings, and a grant on the phone for that Mac, which is off until you choose Ask each time or Allow without asking. The phone shows when a Mac is controlling it, with Stop.

## 1.0 Beta 5 (1.0.0-beta.5), 25 November 2026

- See your Mac's screen on your phone, and control it from there. It's off until you turn it on for a phone in the Mac's Settings, choosing Ask each time or Allow without asking. The Mac shows who is viewing, with Stop.
- After a Mac restarts, it goes straight back to Wi-Fi with your other devices.

## 1.0 Beta 4 (1.0.0-beta.4), 25 November 2026

- An interrupted transfer now picks up where it stopped instead of starting again, and Bridgey sends it again by itself when the device reconnects. Turn this off in Settings > Files.
- Transfers on the Mac stay fast however long your transfer history gets.
- Receiving many files at once on the Mac shows them in Finder once, instead of bringing Finder forward for each file.

## 1.0 Beta 3 (1.0.0-beta.3), 24 November 2026

- A new Transfers window on the Mac: what's moving now, with speed, time left and how your devices are connected, plus your history in the same place.
- Photos and videos show as thumbnails. Filter by type or device, search, and press Space to preview.
- Send files from the window, or drop them on it. Failed transfers have Retry.

## 1.0 Beta 2 (1.0.0-beta.2), 24 November 2026

- On the same Wi-Fi your devices now connect directly, so files and clipboard move at your network's full speed. Before, they often went through the away-from-home connection even at home.
- Pasting between Macs no longer gets stuck on "Pasting from…". If something is still on its way, the paste waits a few seconds and then asks you to paste again in a moment, instead of freezing the app.
- Switching connections no longer stops a transfer or a paste.
- Away from home, Bridgey now relays through Cloudflare, and the connection is faster.
- Windows is in the beta for the first time, for x64 and Arm64.

## 1.0 Beta 1 (1.0.0-beta.1), 15 November 2026

Bridgey by Round Robin now has its own version numbers, starting at 1.0. Betas are 1.0.0-beta.N; Stable comes later.

Also: a CHANGELOG, a shorter version label in the apps, and an updated README.

## 0.11.0-rr.1 Beta 3, 15 November 2026

- Calls window on the Mac: dial, search your phone's contacts, see recent calls, choose the SIM and start a phone or WhatsApp call through your phone. Call audio stays on the phone.
- Off until you turn it on in Settings > Calls on both devices. Each Mac needs your permission on the phone, and Ask on this phone first makes every call wait for your tap.

## 0.11.0-rr.1 Beta 2, 15 November 2026

- Clicking the menu bar icon closes the panel again on macOS 27.

## 0.11.0-rr.1 Beta 1, 15 November 2026

- Calls quieten your media: music and videos on your allowed devices pause (or mute) when a call starts, and come back after the last call.
- Alerts go to the Mac you're using; your other Macs get them quietly. Attach and screen sharing let you choose the device.
- Phone files: Copy or Download Optimised or Original (⌘C optimised, ⌥⌘C original). Pick the default in Settings > Files.
- The menu bar panel drops in from the icon; turn the motion off in Settings > General.
- File selection with Shift-click, ⌘-click and ⌘A, plus fixes to the send preview and the drop toast.

## 0.10.0-rr.1 Beta 27, 11 November 2026

- Send to device from the phone's share sheet goes to the device you're using, with a moment to cancel or pick another. When I share can be set to Always ask.
- Links from other devices open right away unless you turn that off.
- Local agents on a Mac can read new message codes for a few minutes if you allow it in Settings > Notifications. Off by default.

## 0.10.0-rr.1 Beta 26, 7 November 2026

- Trusted servers get only the permissions you choose, for as long as you choose, including a separate Read your notifications permission (off by default).
- Revoking or expiring a permission stops anything still waiting to be delivered.
- Menu panel and Settings improvements, Tailscale setup help, and actions for copied links, phone numbers and email addresses.

## 0.10.0-rr.1 Beta 25, 6 November 2026

- Messages loads conversations straight from your connected phone.
- Stalled file transfers no longer hold up updates.

## 0.10.0-rr.1 Beta 23, 4 November 2026

- Search in Settings on both apps. It understands everyday words ("otp" finds Codes), forgives typos and works in Russian.

## 0.10.0-rr.1 Beta 22, 4 November 2026

- Codes when no Mac is awake: a server you allow can find them, or the phone can use the cloud for text messages only.
- Pair over your tailnet without sharing a Wi-Fi network. Devices paired this way start with everything off.

## 0.10.0-rr.1 Beta 21, 4 November 2026

- Agent devices: pair a server's `bridgey` command with your phone. Each permission starts off and can be time-limited, with an Activity tab for everything it did.

## 0.10.0-rr.1 Beta 20, 3 November 2026

- The Quick Settings tile, Device Controls and the widget send what you copied again.
- Clicking the menu bar icon closes the open panel.

## 0.10.0-rr.1 Beta 19, 1 November 2026

- Fixes from real devices: two Macs pairing at once, stuck reconnects and repeated "Paired with" rows.
- One copy sent to several devices shows as one activity row.
- Let Bridgey handle copy and paste turns Apple Handoff off on this Mac, and puts it back as it was.
- Media controls follow whatever is playing on the Mac.

## 0.10.0-rr.1 Beta 18, 31 October 2026

- Codes from email: Gmail, Outlook, Proton Mail and Spark codes show on the Mac, read only on the Mac.
- The same code from text and email shows once, and the newest code is marked.

## 0.10.0-rr.1 Beta 17, 31 October 2026

- A Copy code card floats on the Mac for 60 seconds when a code arrives. It never takes focus and stays out of screen sharing.

## 0.10.0-rr.1 Beta 16, 31 October 2026

- Connect away from home switches to the relay in about half a second and reconnects in under 2 seconds.

## 0.10.0-rr.1 Beta 15, 30 October 2026

- Much faster file transfers and Phone files downloads.
- Developer menu: tap the version in About five times.

## 0.10.0-rr.1 Beta 14, 30 October 2026

- Update all devices automatically: new builds install on every device, this one last, waiting during calls and transfers. On by default for Beta and Nightly.
- Connect away from home is on by default.

## 0.10.0-rr.1 Beta 13, 30 October 2026

- Connect away from home: phone and Mac stay connected on different networks through an encrypted relay that cannot read your data.

## 0.10.0-rr.1 Beta 12, 29 October 2026

- Settings sync: a switch changed on one device changes on your others. Permissions are never granted remotely.

## 0.10.0-rr.1 Beta 11, 29 October 2026

- Safer pairing: the code can't be forced to match, and a device accepts pairing only while you allow it.
- Security fixes from the 0.10 review. New pairings need 0.10 or newer on both devices.

## 0.10.0-rr.1 Beta 10, 28 October 2026

- Mac windows and the call card always close properly.

## 0.10.0-rr.1 Beta 9, 28 October 2026

- Messages on the Mac: unread first, pin, mute, archive, search and per-message actions.

## 0.10.0-rr.1 Beta 8, 28 October 2026

- Phone files on the Mac rebuilt: faster thumbnails, a built-in viewer and photos grouped by day.

## 0.10.0-rr.1 Beta 7, 27 October 2026

- Phone files thumbnails load again.
- Devices that are away say "Not nearby" instead of reconnecting forever, and are tried less often.

## 0.10.0-rr.1 Beta 6, 27 October 2026

- Text messages on the Mac: reply from the notification and a Messages window. Off until you turn it on.
- See your phone's screen on the Mac (view only).

## 0.10.0-rr.1 Beta 5, 27 October 2026

- Phone files photos show as a clean square grid again.

## 0.10.0-rr.1 Beta 4, 27 October 2026

- Update all: one button updates every connected device, this one last. Android 12 and later install without a tap.

## 0.10.0-rr.1 Beta 3, 27 October 2026

- New installs start with every feature off; setup turns on what you choose. Updates keep your settings.

## 0.10.0-rr.1 Beta 2, 27 October 2026

- Setup asks plain questions and only asks for permissions an answer needs.

## 0.10.0-rr.1 Beta 1, 27 October 2026

- Fixes the Android startup crash in 0.9 Beta 1.

## 0.9.0-rr.1 Beta 1, 27 October 2026

- Mac actions from the phone, Device Controls, a widget and a Lock Mac tile.
- Open on Mac, send the browser tab to the phone, Shortcuts actions, battery alerts, Focus sync and taking a photo with the phone.

## 0.8.0-rr.1 Beta 1, 27 October 2026

- Files: browse phone photos and folders on the Mac, send without system pickers, drop on the menu bar icon, resize or compress before sending, and a transfer history.
- First-run setup, a Permissions page, Reset and What's new after updates.

## 0.6.0-rr.1 Beta 13, 26 October 2026

- Codes from text messages show on the Mac with Copy code. Off by default.

## 0.6.0-rr.1 Beta 12, 26 October 2026

- Phone Settings split into pages with live summaries.

## 0.6.0-rr.1 Beta 11, 26 October 2026

- Calls stay on the Mac until they end; clearer update status; Send copied item sends a recent screenshot.

## 0.6.0-rr.1 Beta 10, 26 October 2026

- Send several files and whole folders from the Mac, with merge or replace choices and resume.

## 0.6.0-rr.1 Beta 9, 26 October 2026

- Control the Mac from the phone: touchpad, keyboard and slides. Off by default.

## 0.6.0-rr.1 Beta 8, 26 October 2026

- Reconnects by itself after sleep or a Wi-Fi change.
- Mac updates show inside Bridgey, and updates stop asking for the Keychain password.

## 0.6.0-rr.1 Beta 7, 26 October 2026

- A performance test for file checks, under About.

## 0.6.0-rr.1 Beta 6, 25 October 2026

- The phone stays connected to several Macs at once.

## 0.6.0-rr.1 Beta 5, 25 October 2026

- Copy images, videos, several files and long text on one device and paste on the other.

## 0.6.0-rr.1 Beta 4, 25 October 2026

- Automatic clipboard, and the Stream design on the Mac.

## 0.6.0-rr.1 Beta 3, 25 October 2026

- New app icon in Round Robin's colours.

## 0.6.0-rr.1 Beta 2, 25 October 2026

- The Stream design on Android: device rings, an activity timeline and redesigned Settings.

## 0.6.0-rr.1 Beta 1, 25 October 2026

- First beta of Bridgey by Round Robin: a separate app with in-app updates on Stable, Beta and Nightly. Built on Bridgey by Semyon Mikhailov (MIT).

## 0.6.0-rc.2-rr.1, 25 October 2026

- Test build: upstream 0.6.0-rc.2 with the call and notification fixes sent upstream.
