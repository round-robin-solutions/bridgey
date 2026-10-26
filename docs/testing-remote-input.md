# Remote control device test (draft `remote_input_draft1`)

For a OnePlus 11 and a Mac, both on the same build of Bridgey by Round Robin. Unit tests cover
validation, bounds, the key allowlist, sequences, rate limits, the gesture state machine, display
clamping and the audit log with fakes; they never post a real event. This list is what only the
devices can show. Note anything surprising with the time, so it can be matched to the session log.

## Setup

1. Install both builds; pair, or keep the existing pairing. Confirm the phone shows the Mac as
   connected.
2. On the phone, open the Mac's device page: there is no Remote control row yet (off on both
   sides by default).
3. On the Mac, Settings > Remote control: turn on Remote control. Nothing is asked yet if no
   phone is allowed. Turn on the OnePlus 11 in "Phones allowed to control this Mac": macOS shows
   its Accessibility prompt once. Allow Bridgey in Privacy & Security > Accessibility. Back in
   Bridgey the row turns to Allowed within a second.
4. Settings > Devices > OnePlus 11 shows "Allow remote control" on, matching the pane.
5. On the phone, Settings > Remote control: turn it on. The Mac's device page now has a Remote
   control row, and a long press on the Bridgey icon shows "Control <Mac name>".

## Touchpad

| Check | Expected |
| --- | --- |
| Open Remote control | Starts at once; the phone says "You are in control"; the Mac shows the pill "OnePlus 11 is controlling this Mac" at the top of the screen with the pointer, and the menu-bar icon changes |
| One finger, slow and fast | The pointer follows smoothly; quick swipes go further. Pointer speed Slow and Fast in phone Settings change the distance |
| Tap; two-finger tap | Left click with a light haptic; right click opens a context menu |
| Double-tap a word in Notes; triple-tap | Selects the word; the line |
| Two-finger scroll in Safari, both directions | The page follows the fingers; no stray click when lifting |
| Touch and hold, then move | Drags a Finder file or a window; lifting drops it. Holding still and lifting is a long click |
| Push the pointer past every screen edge, with an external display attached | It stops at the outer edges, crosses between displays, and never disappears into a gap |
| Keyboard: type "Hello, Привет 👋" and send | The text appears exactly; nothing else happens (no shortcuts) |
| Special keys: Esc, Tab, Shift Tab, arrows, Backspace, Return, Space, Page up/down, Home, End, F5 | Each does what the key does in TextEdit or Safari |
| Previous app | Switches to the previous app, like Command-Tab |
| Type 300 characters | The field stops at 256 and the counter shows 256/256 |

## Presentation (Keynote, then Google Slides in Chrome)

| Check | Expected |
| --- | --- |
| Keynote open, tap Start | The slideshow starts from the current slide |
| Next, Previous; volume keys with "Volume keys change slides" on | Slides move; the volume keys change slides only while the Slides tab shows, and change the volume again after leaving it |
| Black screen, then Next | The screen goes black (B), then continues |
| Touch and hold the laser pad, move, lift | A red dot shows over the slideshow on the display with the pointer, follows the finger, and goes when you lift; the real pointer does not move |
| End | Leaves the slideshow (Escape) |
| Google Slides in Chrome: Start, Next, Previous, Black screen, End | Same behaviour (Start is Command-Return there) |
| Preview or another app: Start | Enters full screen (Control-Command-F) |

## Stop paths

| Check | Expected |
| --- | --- |
| Stop on the phone | The pill goes at once; the phone offers Start again; log: "Stopped on the phone" |
| Stop in the Mac pill (one click, Bridgey not in front) | Ends at once, even over a full-screen slideshow; the phone says "Stopped on <Mac>"; log: "Stopped on this Mac" |
| Control-Option-Escape on the Mac | Same as the pill |
| Press the phone's power button | Ends within a second; log: "Phone screen turned off" |
| Home gesture or switch apps on the phone | Ends; back in Bridgey it shows "Paused when you left this screen" with Start again, and does not restart by itself |
| Turn off Wi-Fi on the phone during a session | The Mac ends the session within about 6 seconds (or at once when the connection drops); the pill goes; no button stays pressed |
| Hold a drag, then stop from the Mac | The drag drops; nothing stays pressed |
| Turn off the phone's permission on the Mac during a session | Ends at once; the phone explains how to allow it again |
| Remove Bridgey from Accessibility during a session | Ends within a second; a new start is refused with "Accessibility access needed" on the phone |
| Allow a second phone and start from it while the first is in control | Refused as busy on the second phone; the first keeps control |

## Session log

| Check | Expected |
| --- | --- |
| Settings > Remote control > Session log after the tests above | One row per session and per refused start: device, time, duration, counts (moves, clicks, scrolls, keys, texts, slide actions) and how it ended |
| Open `~/Library/Application Support/in.roundrobin.bridgey/remote-control-audit.json` | Mode `-rw-------`; contains no typed text, key names or positions |
| Clear log | The list empties and the file is gone |

## After an update

1. Install the next build over this one (Sparkle or by hand).
2. Start remote control again without touching Accessibility.
3. Record whether macOS still honours the Accessibility grant. If the phone says "Accessibility
   access needed", switch Bridgey off and on in Privacy & Security > Accessibility, and note it:
   it decides whether ad-hoc builds need certificate signing for this feature.
