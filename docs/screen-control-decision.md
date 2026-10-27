# Controlling the phone from the Mac: decision note

Status: **research and recommendation only, nothing built.** Screen sharing (`screen_draft1`) is view
only. This note compares the two practical ways to let the Mac's mouse and keyboard drive the phone
and recommends one. Building it needs Rahul's go-ahead on the trade-offs below.

## What "control" has to do

Tap, long press, drag and scroll at the point the mouse is over in the screen window; type text;
Back, Home and Recents; ideally the phone's clipboard and a few keys (Enter, Backspace, arrows). It
has to feel immediate (a tap lands within one or two frames of the picture) and must never run
without the person on the phone knowing.

## The two routes

### A. An AccessibilityService that dispatches gestures

Bridgey adds an accessibility service. While a share runs and control is allowed, the Mac sends
pointer and key messages over the same encrypted session (a `screen_control_draft1` key, modelled on
`remote_input_draft1`), and the phone turns them into `dispatchGesture` strokes (taps, long presses,
continued strokes for drags and scrolls, Android 8 and later), `performGlobalAction` (Back, Home,
Recents, notifications) and, on Android 13 and later, typed text through the service's own input
method (`FLAG_INPUT_METHOD_EDITOR`, which commits text into the focused field). On older versions
text falls back to setting the focused field's text.

- **Setup for the person:** once, turn the service on in Settings > Accessibility. Android 13 and
  later block that switch for apps installed from a browser or file manager until the person opens
  App info and allows restricted settings; whether a GitHub or Obtainium install counts as restricted
  has to be checked on the OnePlus. Nothing else: no developer options, no computer.
- **Works wherever the session works:** same network, Tailscale, and later the relay, because it
  rides the existing session. It survives Wi-Fi changes and reboots like the rest of Bridgey.
- **What it cannot do:** no hardware-key-level events (volume, power), text only into fields that
  accept the input method. Some banking apps warn or refuse to run while a third-party accessibility
  service is on.
- **Effort:** small to medium. The pointer and key model, rate limits, indicator and audit log already
  exist in remote input; the phone side is one service and a mapper from window coordinates to screen
  coordinates (the share already knows the captured size and rotation).

### B. Wireless ADB, scrcpy style

The Mac connects to the phone's ADB daemon over Wi-Fi, pushes scrcpy's server (Apache-2.0) and runs
it as the shell user, which may inject input events directly, and can also capture the screen without
MediaProjection.

- **Setup for the person:** turn on Developer options, then Wireless debugging (Android 11 and later),
  pair the Mac with a six-digit code, and repeat after reboots and Wi-Fi changes (Wireless debugging
  turns itself off). Some OEMs need more: Xiaomi requires "USB debugging (Security settings)", which
  needs a SIM and a Mi account, before input injection works.
- **Same Wi-Fi only.** Wireless debugging listens on the local network; it does not work over mobile
  data, and only awkwardly over a VPN.
- **The Mac needs an ADB client.** Either ship Google's `adb` binary (and keep it updated) or
  implement the ADB protocol including its TLS pairing in Swift. scrcpy's own server would replace
  this edition's encoder, or we keep ours and use ADB only for input.
- **What it can do:** everything a person at the phone can, including real key events and the
  clipboard; very low latency; no accessibility switch.
- **Effort:** medium to large, mostly in pairing, the ADB client and keeping the connection alive.

## Security

| | A. Accessibility gestures | B. Wireless ADB |
| --- | --- | --- |
| Power granted | Gestures, Back/Home/Recents and typing into focused fields. The service can be declared **without** `canRetrieveWindowContent` and without event types, so it cannot read anything on screen; the picture still comes only through the consented MediaProjection share | Shell user: install and remove apps, read shared storage, run commands, read logs (which can contain personal data), capture the screen with no consent dialog and no indicator |
| Who holds it | Bridgey on the phone, used only for an authenticated, pinned Mac during a share the person confirmed, with control allowed on both sides | Any program on the Mac that can read the Mac's ADB key, for as long as Wireless debugging stays on, whether or not Bridgey is running |
| Visibility | Android shows the service as on in Accessibility settings; Bridgey adds "MacBook Air is controlling this phone" with Stop, and stops on screen off, like the share | A small "Wireless debugging connected" notification; nothing tells the person what the shell is doing |
| Side effects | Accessibility services are the classic tool of Android banking malware, so Play Protect and some apps treat them with suspicion. In some regions, including India, Play Protect's fraud protection blocks internet-sideloaded apps that ask for sensitive access such as accessibility; Bridgey already asks for notification access, so this needs checking on a fresh install rather than assuming | Developer options and USB or Wireless debugging make many Indian banking and payment apps refuse to open until they are turned off again |
| Blast radius of a bug | Wrong taps on the phone, bounded by rate limits and Stop | Full device compromise from the Mac |

## Recommendation

**Route A, the accessibility service, built gesture only and session bound:**

1. A separate switch on each side, off by default: "Let Macs control this phone" on the phone, "Control
   phone screens" on the Mac, and its own draft key so a Mac can view without being able to control.
2. The service declares no window content access and no accessibility events; it only acts while a
   confirmed share with that Mac runs and drops every message otherwise.
3. Messages and limits copied from remote input (pointer, button, scroll, drag, text, a fixed key
   list), positions as fractions of the shared frame, token buckets, a 6 second idle timeout.
4. A visible "is controlling this phone" notification with Stop; control ends with the share, on
   screen off and on disconnect. A local audit log of control sessions (no text, no positions).
5. If the accessibility switch is blocked as a restricted setting, the Permissions page explains the
   App info step.

Route B gives more power for less setup work in code, but it hands the Mac shell access to the phone
for as long as Wireless debugging is on, only works on the same Wi-Fi, needs developer options that
banking apps refuse, and has to be redone after every reboot. People who want that today can already
run scrcpy next to Bridgey; we should say so in the user guide rather than build it in.

## Open questions for Rahul

- Is the accessibility service acceptable for the edition, given how it reads in Play Protect and to
  security-minded users, even though it cannot read the screen?
- Should control be limited to the same local network at first, like the share is measured today?
- Is "Back, Home, Recents, tap, drag, scroll, type" enough for a first control release, leaving
  volume and hardware keys out?
