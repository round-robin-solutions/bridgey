# SMS and call integration policy

Reviewed on 2026-08-17 against the current Android and Google Play guidance; the Round Robin
edition section was reviewed on 2026-10-27 against the same Play policy page.

## Bridgey v0.5 decision

Bridgey v0.5 does not declare `READ_SMS`, `SEND_SMS`, `READ_CALL_LOG`,
`WRITE_CALL_LOG`, or `PROCESS_OUTGOING_CALLS`.

- Incoming message content can already be mirrored through the explicitly
  enabled Android notification-listener service.
- A reply is available only when the source notification provides a bounded
  free-form `RemoteInput`; Bridgey returns that reply to the retained action
  token and cannot address an arbitrary recipient.
- `CATEGORY_CALL` notifications are forwarded even when marked ongoing. When
  the optional call integration is enabled, Bridgey uses `READ_PHONE_STATE`
  only to distinguish ringing, active, and ended states and uses
  `ANSWER_PHONE_CALLS` for Answer, Decline, and Hang Up. It does not request
  contacts or call-log access. Without this opt-in, controls remain limited to
  the actions exposed by the phone application and may vary by phone/OEM.
- Bridgey does not read the SMS database or call log and does not make itself
  the default SMS or Phone application.
- A Mac may send a validated phone number to Android. The default path uses
  `ACTION_DIAL` and requires confirmation on the phone. Users may separately
  opt in to call status and controls, which requests `CALL_PHONE`,
  `READ_PHONE_STATE`, and `ANSWER_PHONE_CALLS`. Bridgey blocks direct handling
  of platform-recognized emergency numbers.

This keeps the feature useful without adding broad access to unrelated message
history or telephony metadata.

## Bridgey by Round Robin: Text messages (2026-10-27)

The edition now ships full SMS conversations on the Mac (draft `sms_draft1`, see
[protocol.md](protocol.md#text-messages-sms_draft1)). This replaces the edition's earlier position
that only the hidden Code reader test reads the SMS inbox. Upstream Bridgey's v0.5 decision above
is unchanged; the upstream app declares none of these permissions.

- **Declared in every build, stable included:** `READ_SMS` (the conversation list, conversations,
  sync), `SEND_SMS` (sending from the Mac), `READ_CONTACTS` (names next to numbers, and contact
  search for a new message). `READ_PHONE_STATE` was already declared for calls; on a dual-SIM phone
  Text messages also uses it to list the SIMs so the Mac can pick one. No `RECEIVE_SMS`,
  `RECEIVE_MMS`, `WRITE_SMS` or call-log permission is declared.
- **Asked only when chosen.** Text messages is off by default (the edition's "off until chosen").
  The permissions are asked when the person turns it on, from setup or Settings, on the single
  Permissions page, each with its reason and the features that use it. Refusing SMS access leaves
  Text messages off; refusing contacts keeps it on and shows numbers instead of names.
- **Never the default SMS app.** Bridgey declares no `SMS_DELIVER`, `WAP_PUSH_DELIVER`,
  `RESPOND_VIA_MESSAGE` or `SENDTO` handler and never asks to become the default SMS app. Android
  writes the messages Bridgey sends into the SMS provider itself, so the phone's messaging app shows
  them as usual. A unit test fails if any of those handlers appears in the manifest.
- **Data path.** Message bodies, numbers and names travel only inside the existing encrypted session
  to the person's own paired Macs. There is no cloud and no server. The phone stores nothing; it
  reads the provider when a Mac asks. The Mac keeps a cache of at most 200 conversations and the
  newest 200 messages of each, per phone, in one file under Application Support with permissions
  0600 (or in memory only, if "Keep conversations on this Mac" is off). MMS images stay in memory.
  The cache is deleted when Text messages is turned off on either device, when the phone is
  forgotten, and from Reset. Bodies, numbers and names are never logged, whatever Logging says.
- **Sending limits.** One recipient per message: replies to group conversations stay on the phone.
  Emergency numbers are refused. At most one message per second and 30 in 10 minutes per Mac;
  Android's own premium short code and volume confirmations still appear on the phone.
- **Replies from notifications.** With Text messages on, a text message notification on the Mac has
  a Reply field. The phone answers through the messaging app's own reply when the app offers one
  (so RCS and chat features keep working) and through `SmsManager` when it does not, or always when
  "Send replies as SMS" is on. Without Text messages, the permission-free notification reply
  described above still works for apps that offer one.
- **Codes from messages** still need no SMS permission: they come from the SMS notifications Bridgey
  already receives. The lab-only Code reader test now uses the same `READ_SMS` declaration. It still
  asks at Start, and when it ends it asks Android to drop the permission only if Text messages is
  off for every Mac.

### Marking messages read from the Mac

Feasibility, 2026-10-27 (Rahul then: later, not in that release). What is possible on Android 14
to 16 for an app that is not the default SMS app:

- **Through the SMS provider: no.** Android's reference says "Only the default SMS app (selected by
  the user in system settings) is able to write to the SMS Provider" and other apps "can only read
  the SMS Provider" ([Telephony](https://developer.android.com/reference/android/provider/Telephony)).
  The KitKat change that introduced this lists marking messages read among the writes a
  non-default app cannot make
  ([Getting your SMS apps ready for KitKat](https://android-developers.googleblog.com/2013/10/getting-your-sms-apps-ready-for-kitkat.html)).
  A write such as `read = 1` from another app has no effect, and `WRITE_SMS` does not change that.
  Nothing in Android 14 to 16 relaxes it.
- **Through the messaging app's own notification action: yes, while the notification is there.**
  Messaging apps add a "Mark as read" action, tagged `SEMANTIC_ACTION_MARK_AS_READ` since API 28
  ([Notification.Action](https://developer.android.com/reference/android/app/Notification.Action)).
  Bridgey's notification listener already keeps each notification's actions and can fire one for
  the Mac (that is how replies through the app work). On the API 35 emulator each Google Messages
  message notification carried two actions, which should be its usual Reply and Mark as read (the
  titles were not checked, an assumption). Limits: it only
  covers messages that still have a notification, so not older unread conversations; and on
  Android 15 and later an unlinked listener gets the notification with its text and actions removed
  when Android detects a one-time code
  ([Android 15 behavior changes, OTP redaction](https://developer.android.com/about/versions/15/behavior-changes-all)).
  On the emulator, Google Messages' notifications reached the unlinked listener without any
  actions. The phone-to-Mac companion link, which Text messages now asks for, exempts Bridgey.
- **Anything else: no.** Becoming the default SMS app would allow it, which this edition rules
  out. Accessibility automation of the messaging app would be fragile and is not something
  Bridgey does.

So a later "mark read" from the Mac can fire the messaging app's own Mark as read on the matching
notification (which also clears it on the phone), with the companion link in place, and must say
plainly that older conversations stay unread on the phone.

Built 2026-10-28 (`sms.mark_read`, docs/protocol.md, "Managing conversations from the Mac"):

- Reading a conversation on the Mac marks it read on the Mac, and the Mac then asks the phone. The
  phone fires the action tagged `SEMANTIC_ACTION_MARK_AS_READ` on the conversation's notification
  if one is still showing, and answers marked, not shown, no action or failed for each conversation.
  The Mac says how many reached the phone. The action is kept on the phone and never sent to the
  Mac as a button. On the API 36 emulator Google Messages posts it as its first action, titled
  "Mark as read" (Reply is the second); firing it set `read = 1` in the provider and cleared the
  notification.
- A notification is matched to its conversation by the newest unread message from that sender
  around the notification's time. Google Messages posts the notification of an older conversation
  again with its time set to that conversation's newest message, so matching also looks around the
  message's own time.
- After Bridgey is updated, Android connects the listener again without posting the notifications
  again, so the listener reads the notifications still showing and matches them then. Matching
  needs to know the default SMS app, and on Android 11 and later that package is hidden from
  Bridgey unless the manifest's `<queries>` names what an SMS app handles (`SENDTO smsto:` and
  `SMS_DELIVER`). Those are lookups only: Bridgey declares no SMS component and never asks to
  become the default SMS app.
- Mark as unread, pin, mute, archive and delete stay on the Mac. Deleting removes the conversation
  or message from this Mac only, as the window says.

**Blocking a number.** Only the system, the default SMS app, the default phone app and carrier apps
may read or change Android's blocked numbers
([BlockedNumberContract](https://developer.android.com/reference/android/provider/BlockedNumberContract)).
Bridgey can only open the system's Blocked numbers screen
(`TelecomManager.createManageBlockedNumbersIntent`), which needs no permission. "Block on phone…"
on the Mac (`sms.blocked_numbers`) opens it when Bridgey is in front on the phone, with a short
note naming the number to add, and otherwise posts a notification that opens it (Android stops
apps in the background from opening screens). The person adds the number there.

### Distribution and Google Play

The edition is distributed through GitHub releases, not Google Play, so no Play declaration applies
today. If it is ever published on Play, these notes stay accurate as of 2026-10-27:

- Play restricts the SMS permission group to the default SMS handler, with temporary exceptions
  when there is no alternative way to provide the core function. Two listed exceptions fit this
  feature: "Cross-device synchronization or transfer of SMS or calls" (apps that sync texts across
  the user's devices, eligible for `READ_SMS` and `SEND_SMS`) and "Connected device companion apps".
- An exception needs a Permissions Declaration Form in the Play Console and review; an app without
  one may be removed. Play's User Data policy also requires a privacy policy and a prominent
  in-app disclosure with consent before the request. `READ_CONTACTS` is not in the restricted group
  but falls under the same disclosure rules.
- The Text messages page and the Permissions page already give the disclosure (what is read, where
  it goes, that nothing leaves the person's devices). A privacy policy page and the declaration form
  would still be needed for Play.

## Future work

Group conversations (MMS to several people), sending pictures and RCS chats are out of scope:
RCS messages are not in the Android SMS provider, and group MMS sending needs default-handler
access. The permission-free notification reply remains the fallback for those.

Primary references:

- [Google Play: Use of SMS or Call Log permission groups](https://support.google.com/googleplay/android-developer/answer/10208820?hl=en)
- [Android: Permissions used only in default handlers](https://developer.android.com/guide/topics/permissions/default-handlers)
- [Android: CallStyle notifications](https://developer.android.com/develop/ui/compose/notifications/call-style)
