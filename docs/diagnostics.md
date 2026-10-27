# Diagnostics

Diagnostics are a small log of what Bridgey did: connects, drops, retries, transfers and similar.
You can export it as a JSON file and send it with a bug report. It is built to leave out what you
copied, what you were notified about and what you sent.

This page describes what the code does today (report `schemaVersion` 2). For the wider
privacy rules see [the edition notes](rr-edition.md#android-activity-stream-and-privacy) and
[SECURITY.md](../SECURITY.md).

## Export diagnostics

### Android

1. Open Bridgey and go to **Settings > Privacy**.
2. In the Logging group, tap **Diagnostics** ("Share a log without clipboard text, notification
   content, file names or addresses").
3. Android's share sheet opens, titled "Export Bridgey diagnostics". Choose where to send the file
   (Files, email, a messaging app).

The file is called `Bridgey-Diagnostics.json`. If Bridgey cannot create it, it shows "Could not
create diagnostics file".

### Mac

1. Open Bridgey's Settings (the gear in the menu-bar panel) and choose **Privacy**.
2. In the **Logging** card, find **Export diagnostics** and press **Export...**.
3. A save panel titled "Export Bridgey Diagnostics" opens, with the name `Bridgey-Diagnostics.json`.
   Choose a folder and save.

If the report cannot be built or written, the Mac app shows no message and no file appears. Try
again, or choose another folder.

## What is inside

The same layout is used on both platforms, with a few platform fields.

| Field | Meaning |
| --- | --- |
| `schemaVersion` | `2`. |
| `generatedAt` | When the export was made (UTC). |
| `appVersion` | The app's version name (Android `versionName`, Mac `CFBundleShortVersionString`). The build number is not included. |
| `platform` | `android` or `macos`. |
| `osApi` (Android) | The Android API level, for example 36. |
| `osVersion` (Mac) | macOS's own version string. |
| `connectionState` | `idle`, `connecting`, `verification`, `connected` or `failed`. |
| `activeTransferCount`, `historyCount` | How many transfers are running, and how many finished or failed entries are in the list. Counts only. |
| `localFeatures`, `remoteFeatures` | One true or false per feature: whether this device has it on, and what the connected peer reports. Both are the same list of feature keys. |
| `power` (Android) | One token with the phone's power state: awake or idle (Doze), screen on or off, battery saver on or off, the app standby bucket (Android 9 and later), and whether Bridgey is exempt from battery optimisation. |
| `devices` | One entry per paired device (see below). |
| `events` | The event log (see below). |

Each entry in `devices` has:

- `device`: the first eight characters of that device's ID, enough to tell devices apart.
- `connected`: true or false.
- `knownAddresses`: how many addresses are known, as a count. The addresses themselves are not included.
- `addressSources`: where those addresses came from (a list of short source names).
- `reconnectAttempts`: a count.
- `lastConnectedAt`: a time, when there is one.
- `nextAttemptAt` (Mac only): the time of the next retry, when one is scheduled.

Device names are not included. The eight-character prefix is part of the device's identity, so it
does appear. The full ID does not.

### Events

Each event has `timestamp`, `category`, `event`, `outcome` and, sometimes, `device` (the
eight-character prefix) and `detail`. `outcome` is `ok` unless the code gives a reason.

Every text value is normalised before it is stored: lower case, any character other than
`a-z`, `0-9`, `_`, `.` and `-` replaced by `_`, and cut to 64 characters. So an event can hold a
word, a short reason or a count, but not a sentence.

Categories seen in the code, with example events (not a complete list):

| Category | Examples |
| --- | --- |
| `discovery` | `restart`, `found_trusted`, `manual`, `manual_done` |
| `pairing` | `connection_started`, `connected`, `failed` (with the reason) |
| `transport` | `listener_started`, `connected` (with the address source and attempt count), `disconnected` (with the reason), `duplicate_closed`, `duplicate_replaced`, `local_network_denied` (Mac) |
| `reconnect` | `dial`, `dial_failed`, `no_address` (with a reason and attempt number) |
| `protocol` | `message_rejected`, `session_failed` |
| `transfer` | `send_started`, `send_completed` (Android), `interrupted`, `retry_started`, `cancelled` |
| `folder` (Android) | the end state of a folder transfer, with its end code |
| `clipboard` | `text_received`, `rich_received`, `offer_sent`, `offer_received`, `paste_fetched`, `paste_failed`, `item_pasted`, `screenshot_sent` |
| `notification` | `dismiss_requested`, `dismiss_sent`, `action_requested`, `reply_requested`, `removed_remotely`, and on the Mac `code_read` (outcome: found, none, or a failure reason), `code_copied`, `code_copied_auto` |
| `call` and `calls` | call state changes with a short reason, and the result of a call request |
| `remote` | remote control session start and end, with a short detail |
| `power` (Android) | screen off, Doze entered and similar, with the `power` token as detail |
| `link` | connection-link changes, with a reason |

On Android, `disconnected` events carry the power token as their detail. This is how a report shows
that Doze or battery saving was involved in an overnight drop.

### Limits and retention

- Each app keeps the newest **1,000** events and drops older ones. There is no time limit.
- The log is saved to disk (at most every two seconds), so it survives the app being closed or
  killed. A report exported the next morning still shows the night's drops.
- Every export contains all stored events, so an export may cover several days.
- Turning a logging category off (Settings > Privacy > Logging) stops that category from being
  recorded. Events already recorded stay until you clear the log.

## What is never included

The diagnostics code stores only the normalised tokens above, counts and times. The report has no
field that can hold:

- clipboard text or images, or a preview of them;
- notification titles, text or app names;
- codes from messages, or message text (the code reader records only an outcome word);
- file or folder names, file contents or file paths;
- phone numbers, caller names or contact names;
- device names, network addresses (IP or Wi-Fi names), pairing codes, keys or session and
  transfer IDs.

### The logging switches and file names

Settings > Privacy > Logging has switches for **Include phone numbers**, **Notification titles
and text**, **Clipboard previews** and **File names**. Checked against the code: these four switches
change only what is written to the device's own local log (Logcat on Android, the unified log on
the Mac). The code that builds the diagnostics report never reads them. Turning one on does not put
names or text into an exported file.

The other switches (Connection, Calls, Notifications, Clipboard, Remote control events) decide
whether that category is recorded at all, in both the local log and in diagnostics.

Two more rules apply whatever the switches say:

- Text messages never reach the local log: no title, no text and no code.
- The Mac's remote control audit is a separate file and is not part of diagnostics.

The activity stream (what moved between your devices) is stored separately and is never included.

## Where it is stored

| | Android | Mac |
| --- | --- | --- |
| Diagnostics log | `no_backup/diagnostics.json` in the app's private storage. Other apps cannot read it, and it is not backed up. | `~/Library/Application Support/in.roundrobin.bridgey/diagnostics.json`, permissions 0600. |
| Exported file | `cache/diagnostics/Bridgey-Diagnostics.json` in the app's private cache, shared through a read-only grant for the app you chose. Each export overwrites the last. | The folder you chose in the save panel. |
| Local log | Logcat, tag `Bridgey` (readable over ADB). | Unified log, subsystem `in.roundrobin.bridgey`. |

To read the Mac's local log:

```sh
/usr/bin/log show --last 12h --predicate 'subsystem == "in.roundrobin.bridgey"'
```

The local logs are not part of the export. They may hold more detail if you turned the content
switches on.

## Delete diagnostics

- **Clear logs:** Settings > Privacy > Logging > **Clear logs** (press **Clear**, then confirm).
  This empties the diagnostics log on that device. The file on disk is rewritten empty within a
  couple of seconds. Your other devices keep their own logs.
- **Exported files:** delete the saved copy yourself on the Mac. On Android, the exported copy in the app's cache stays
  until the next export overwrites it, until Android clears the cache, or until you clear the app's
  storage. Clearing logs does not remove it.
- **Reset Bridgey on this device:** Settings > Privacy > **Reset Bridgey on this device** has an
  "Activity and logs" choice. It asks you to confirm and lists what it deletes. See
  [the user guide](user-guide.md#reset-local-data).
- **Local logs:** the system owns them and removes them on its own schedule.

## Share diagnostics safely

1. Open the file in a text editor first. It is plain JSON. Look through `events` and `devices`.
2. If something looks private, remove it by hand, or do not send the file. Tell the maintainers
   what you removed.
3. Send it only to people who need it: attach it to a
   [GitHub issue](https://github.com/round-robin-solutions/bridgey/issues) or send it to a
   maintainer directly. A public issue is visible to everyone. If you prefer, describe the problem in
   the issue and offer the file privately.
4. Do not paste clipboard text, notification text, codes, phone numbers or file names into an
   issue. Do not turn the content switches on to "help": they do not change the export.
5. Delete the exported file when the issue is closed.

Security problems go through GitHub's private security advisory, not a public issue (see
[SECURITY.md](../SECURITY.md)).

See also: [compatibility](compatibility.md) (how to report a device result), [user guide](user-guide.md).
