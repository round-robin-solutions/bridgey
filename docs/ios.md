# Bridgey on iPhone and iPad

What the iOS app does and what iOS doesn't let it do. The app's build and layout are in
[ios/README.md](../ios/README.md).

## First slice (I1)

- Setup: the name other devices see, then why Bridgey needs Local Network access, before iOS asks.
- Discovery and pairing (protocol 2) with the Mac, Android and Windows apps: devices on the same Wi-Fi, or an
  address typed in. While a pairing screen is open, other devices can pair with this one.
- The device home: paired devices with their status, live cards (pairing requests, links, files on the way), the
  activity stream and the send bar.
- Clipboard text both ways. Received text goes onto the clipboard (Settings > Copy received text).
- Files both ways: the Files picker to send; received files land in the app's Documents folder, which the Files
  app shows as On My iPhone > Bridgey.
- Links both ways. A received link waits on a card (Settings > Open links right away opens it at once).
- Share > Bridgey in any app: text, a link or up to 20 files. If the device can't be reached, the items are kept
  and sent the next time Bridgey connects to it.
- Settings and About (version, build, the upstream credit, and the limits below).

The session runs in `bridgey_core` (rust/client). Files and links were added there for this slice, on the wire
the apps already speak (`files.v1` JSON chunks, `quick.request` with feature `links`), so the Windows app can
use them too.

## What iOS doesn't allow

- **Background.** Bridgey connects while it is open. iOS suspends an app soon after it leaves the screen, so the
  session ends then (files already on their way get the short time iOS grants to finish). It reconnects when the
  app comes back. Nothing arrives while Bridgey is closed; there is no background networking mode for this.
- **Clipboard.** iOS lets an app read the clipboard without asking only when the person taps a system Paste
  control, so sending the clipboard is a tap on Paste in the send bar. There is no automatic clipboard sending
  from iOS. Writing received text is allowed at any time the app runs.
- **Local Network.** iOS asks once. If it's refused, Bridgey can't find or reach anything and says so, with a
  button for Settings. Multicast needs an Apple entitlement, so discovery goes through the system's Bonjour.
- **Input.** Other devices can't control an iPhone or iPad: there is no public API for injecting touches or keys
  into other apps. Bridgey doesn't offer it, and never sends a key or capability that would make another app offer it.
- **Phone features in the background.** Notifications, messages, calls and ringing show only while Bridgey is open;
  nothing arrives, rings or is announced while it is closed, for the reason above.
- **Calls.** The call card answers, declines and hangs up on the phone. There is no CallKit: the iPhone itself
  doesn't ring for the phone's calls and the call's audio stays on the phone.
- **Media.** iOS doesn't let an app see or control what other apps play, so the phone's media controls aren't
  offered (`media` is always off).
- **Bluetooth.** Linking for codes advertises the phone's service while Bridgey is open, and iOS lets an app
  advertise only service UUIDs. The simulator can't advertise, so this is untested on hardware.
- **This device's screen.** Sharing the iPhone's or iPad's own screen needs a Broadcast Upload extension
  (ReplayKit): iOS shows its consent sheet each time and a red indicator, stops on lock, and gives the extension
  about 50 MB. It isn't built ([below](#not-covered-yet)).

## Second slice (I2)

Everything here works while Bridgey is open, as the rest of the app does.

- **Screens.** An Android phone's screen and a Mac's screen, full screen, letterboxed, and control of it when that
  device allows: touches, Back, Home and Recents and typing on a phone; clicks, right clicks, drags, scrolling and
  typing on a Mac. The phone or Mac decides who may look and control (its grants and Unattended access); Bridgey here
  only asks. A phone that shares by accessibility screenshots shows "Slower mode". The session's `bridgey_screen_frame`
  hands each whole H.264 frame to a thread of its own; VideoToolbox decodes it onto an AVSampleBufferDisplayLayer, so
  frames never pass through JSON or the event queue. The library numbers, coalesces and paces the input (the shared
  contract in [screen-control-core.md](screen-control-core.md)).
- **The phone's text messages.** Conversations (unread first), a conversation, replies, a new message, pictures,
  Mark as read. Off until chosen, as on the Mac and Windows; Keep conversations keeps them in a protected file.
- **The phone's files.** Places, folders, photos and recent documents; downloads to this device's Bridgey folder in
  the Files app, and uploads from the Files picker into the folder being browsed.
- **Notifications, codes and calls.** The phone's notifications as cards with its own actions and replies, Dismiss,
  and Copy code for one-time codes found on this device. A call shows on a card with the phone's own Answer, Decline
  and Hang up.
- **Battery and find device.** Each device's battery on its chip, this device's battery on theirs; Ring a device, and
  a loud sound here when another device rings this one.
- **Connect away from home.** The shared client's Connect anywhere runs on iOS too, so paired devices are reachable
  off this Wi-Fi while Bridgey is open.
- **Russian.** Every string in English (UK) and Russian; the build fails on one without Russian.

**Who sees what.** The same feature key means different things to different apps: a Mac reads `screen_draft1` and
`phone_control_draft1` from any device as "this phone shares its screen and can be controlled", and an Android phone
reads `screen_control_draft1` as "this Mac shows its screen". So iOS sends `screen_draft1` and `phone_control_draft1`
only to Android phones, `screen_control_draft1` only to Macs, and no screen key to anything else, going by the
platform the device announced on the network. The screen requests say the same in the shared contract's
capabilities: a viewer and controller, never a source or an input host. No app is offered an iPhone's or iPad's
screen or input.

## How I2 is checked

On a Mac, by `scripts/rr/build-ios.sh` (the RR CI ios lane):

- Unit tests of each feature's model against a fake client.
- Real bridgey_core sessions through the Swift wrapper in the simulator, against a client that answers as a phone
  and a Mac (`simulatePhoneForTests`): the phone's and the Mac's screen with frames decoded by VideoToolbox and the
  input arriving at the other end; conversations, a send to delivered, contacts and a picture; places, a folder, a
  download checked byte for byte and an upload; notifications with a code and a reply, removal, battery and find
  device both ways; Connect anywhere starting, exchanging `connect_draft1` and setting up the pair secret with no
  control service (nothing leaves the Mac).
- The touch mapping against the `letterbox` vectors of `display-v1.json`.
- UI tests against the scripted phone (`peer --phone`) and Mac (`peer --mac`): pairing through the Pair sheet, the
  phone's screen with Slower mode and control, the Mac's screen with a click, Text messages turned on and a reply
  delivered, a folder browsed and a file downloaded, notifications with a reply, the call card, ringing both ways,
  battery on the chip. The script then checks the peers' side: the text, the touch, the click and the ring arrived.
- Every string has Russian (`scripts/rr/ios-l10n.py`), and screenshots in light and dark on iPhone and iPad.

## Not covered yet

- A run on a real iPhone or iPad: the tests run on the simulator, and the app isn't signed until the Apple
  Developer enrolment is confirmed. Hardware decoding speed, Bluetooth advertising and the battery reading are
  therefore unmeasured.
- Pairing with the shipping Mac, Android and Windows apps: the UI tests pair with scripted peers that speak the
  same protocol through the same shared client, and the shared client has paired with the Android app before
  (session-client.md).
- Typing into a screen from the UI tests: typing is covered by the unit and real-session tests only.
- Connect anywhere's tunnel with the local network cut: the switch that cuts it isn't in the C ABI, so that path is
  covered by `cargo test -p bridgey-client --test connect` only.
- **This device's screen on another device.** It needs a Broadcast Upload extension with a VideoToolbox encoder
  inside about 50 MB, a way to hand frames to a session (the app is suspended while another app is on screen, so the
  extension would need its own client, as the Share extension has), and the source side of `screen_control_draft1`
  or `screen_draft1` in the shared client, which only the Mac and Android implement today. It never offers input.
- The Calls window (placing calls through the phone) and media controls.
- Self-update: iOS apps update through TestFlight and the App Store.
