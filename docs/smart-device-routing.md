# Choose the Mac you are using

Implementation branch: `rr/smart-device-routing`. Unreleased; owned compilation, device checks and three-Mac acceptance must pass before this is called ready.

Phone notifications can appear on several Macs because forwarding previously sent the same alert to every connected device. Smart notification routing chooses one place to interrupt you, while compatible other Macs receive the notification quietly. Notification history still follows each Mac's existing local-history setting; this does not turn on stored history.

## Notification destination

On the phone, open **Settings → Notifications → Smart notification routing**. It starts on. **Preferred Mac** is an explicit, local choice on this phone, with **None** available; it is not selected by connection order and is not synced to another phone.

1. Choose the connected, eligible Mac with the most recent input, using fresh activity samples. It must be unlocked and have input within the last two minutes.
2. If activity is unclear, use the connected preferred Mac. A known locked preferred Mac is excluded. An explicitly preferred older Mac can work without activity support.
3. If neither is available, the notification stays on the phone. Another idle Mac is not silently substituted.

The route explains its choice with **Active now**, **Preferred Mac**, or a phone-only status. Incoming calls follow the same single-Mac alert rule. Quiet media during calls still receives its independent call state on every linked device allowed to participate.

A notification's alert destination is captured in an immutable dispatch plan and pinned until that notification is removed. Removal invalidates queued work, and posts/removals share one ordered notification lane. Routing ownership is reconciled independently of the listener's bounded history, so evicted bookkeeping cannot permanently suppress future alerts. An update to the same notification or an ongoing call does not create a new alert on a different Mac when you move. This does not queue historical alerts for replay after reconnect. Notification replies, dismissals, call controls and per-device grants keep their existing checks.

Quiet means no system banner or sound, ringing or automatic call overlay, floating code card or automatic code copying. The notification can still appear in Bridgey's panel/history and its code can still be read and reported to the phone, subject to the existing permissions and code settings. SMS/server fallback is evaluated after dispatch and counts only successful, still-current recipients whose code-reading capability remains enabled, including quiet compatible readers.

Older Macs cannot understand quiet presentation. They receive an alert only when chosen; upgrade them to retain quiet history on the other Macs. Existing permission checks continue to limit every destination. Restricted agent devices do not publish activity or become automatic notification destinations.

## Sharing from the phone

Generic Share → Bridgey, Open on Mac, Attach and the generic Share screen tile show a device list, including a single available device. The active Mac is suggested first, with the preferred Mac as a fallback suggestion. A suggestion does not send anything: choose a row and confirm the named destination. Explicit device-page actions remain addressed to that device.

Offline paired devices remain visible with an explanation. If the chosen device disconnects or its feature is turned off, sending is blocked and the draft/selection remains. Reconnection, a different active Mac, or a newly arrived device does not redirect the share. Returning from the system file/folder picker also waits for the final Send action. Pending Browse choices, their named destination and visibility survive activity recreation in bounded private metadata, with retained read access. Dismissing the sheet preserves the draft; explicit Cancel clears it. Only accepted queued items leave the draft. A provider that cannot retain read access asks for a new selection without silently replacing the existing draft; files are never copied merely to keep a draft. Screen sharing chooses the destination before Android asks for capture consent; a running screen stream never switches with activity.

Home's named device control and configured widgets remain explicit controls. Notification preference is a notification fallback, not an invisible replacement for the device you selected for an action.

On Mac, Share/Services already show a destination chooser. Menu-bar quick drop retains its existing setting under **Settings → Files → When I drop on the menu-bar icon**. Quick drop uses the last connected device you sent to, then the selected connected device, then the first connected device. Dropping on a named device tile changes the last-used destination; **Always collect in the Tray** avoids immediate sending.

## Activity and privacy

**Share my activity status** starts on for trusted paired devices, as requested, and can be turned off in this Mac's Notifications settings. It sends only a coarse active/idle/locked/unknown state and whole seconds since input. It does not capture keys, foreground application names, screenshots or browsing history, and needs no event tap or Accessibility grant.

Samples use the encrypted, authenticated protocol-2 session and are kept in memory. The phone measures freshness using its own monotonic clock; it never compares wall clocks on different Macs. Samples expire after 20 seconds. Per-session sequence fences reject reordered samples and survive same-session activity-sharing off/on cycles even when the activity sample is discarded; replacement, disconnect, revocation and forgetting invalidate prior activity. The Mac samples aggregate idle time only while a trusted compatible phone subscribes, at approximately two-second intervals, and sends changes or a ten-second keepalive. Lock/sleep events report unavailable immediately. No server chooses the active device or stores this activity.

Wire details: optional `device_presence_draft1` and `notification_routing_draft1`; bounded `presence.state` and negotiated `notifications.post.presentation`. See the [protocol contract](protocol-contract.md). Both native parsers consume [shared presence vectors](../protocol/test-vectors/device-presence-v1.json).

## Acceptance still required

- Three-Mac transitions: typing/mouse use, idle, lock/unlock, sleep/wake, a preferred Mac offline, simultaneous activity and reconnect.
- Ordinary alerts, notification updates, SMS and email codes, delayed code reads, overlapping calls, call ending and all-device media quieting.
- Generic text/file/link shares, one/three/offline devices, changes during the chooser, permission revocation and return from the Android picker; named confirmation and no redirect.
- Light/dark native screenshots, long device names, reduced motion, mid-transition samples and interaction/performance measurements. Model tests do not prove these UI checks.
