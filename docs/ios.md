# Bridgey on iPhone and iPad

What the iOS app does, what iOS doesn't let it do, and where screen viewing and control will fit. The app's
build and layout are in [ios/README.md](../ios/README.md).

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
  into other apps. Bridgey doesn't offer it.
- **Away from home.** Connect anywhere (the relay and tunnels) isn't in the shared client yet, so iOS works on
  the local network only.

## Screen viewing and control (I2)

Planned, not built. The boundary, so I1 doesn't get in the way:

- **iPhone or iPad as viewer and controller** of a Mac or Android screen. The stream and its control messages
  come from the shared screen/control contract ([screen-control-core.md](screen-control-core.md)) in Rust. The
  app decodes frames with VideoToolbox on a hardware surface; frames never pass through JSON or the event queue.
  Touches on the view become pointer and key messages to the host, which checks its own grant.
- **iPhone or iPad as a screen source.** A Broadcast Upload extension (ReplayKit) is the only way to capture the
  whole screen. iOS shows its own consent sheet each time, a red status indicator while it runs, and stops it on
  lock. The extension has a small memory budget (about 50 MB), so it encodes with VideoToolbox and hands frames
  to the session with no copies. It never offers input.
- **Capabilities** are advertised per device (viewer, controller, screen source; never input host on iOS), as
  [platform-architecture.md](platform-architecture.md) describes, so the other apps hide what iOS can't do.

## Not covered yet

- A run on a real iPhone or iPad: the tests run on the simulator, and the app isn't signed until the Apple
  Developer enrolment is confirmed.
- Pairing with the shipping Mac, Android and Windows apps: the UI test pairs with the scripted peer that speaks
  the same protocol, and the shared client has paired with the Android app before (session-client.md).
- Notifications, battery, media, codes, phone files and Connect anywhere.
- Self-update: iOS apps update through TestFlight and the App Store.
