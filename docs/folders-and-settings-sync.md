# Folders and settings sync

Status: draft spec, 2026-10-25. No code yet; the build starts after Beta 4. Written for
Bridgey by Round Robin first and kept unbranded, so the protocol can be proposed upstream
as it stands. The wire summary is in [protocol.md](protocol.md#draft-folders-places-and-settings-sync).

Two features:

1. **Folders.** Put a whole folder from the Mac on the phone as it is: every subfolder, empty
   ones included, and decide where it lands. O+ Connect cannot send folders; Blip can, but
   you cannot choose where they land. Phone to Mac uses the same messages and comes later.
2. **Settings sync.** Keep shared preferences the same on paired devices (where folders land,
   what happens when a folder exists, automatic clipboard, activity previews, reduce motion).
   Names, folders and update channels stay per device.

Both build on the held multi-file queue (`FileSendQueue`, commit `ed2c457`, upstream issue #18):
a folder is one item in that queue. Section 11 covers the port onto `rr/main`.

## 1. Scope

In:

- Folder transfer Mac to phone, then phone to Mac with the same messages.
- Three destination modes, chosen in Settings; "places" on the phone (folders granted once
  through Android's folder picker, plus `Download/Bridgey`).
- A question when the target folder already exists, with a timeout.
- Resume after a disconnect or restart at file level: finished files are not sent again.
- Settings sync with a snapshot on connect, live updates and deterministic conflict rules.

Out:

- Reading or downloading phone files from the Mac. Browsing returns folder names only. The
  roadmap item "download from granted folders" needs its own capability and consent.
- Resume inside a file (a file cut off mid-way restarts from byte 0, as today).
- Broad storage access on Android: no `MANAGE_EXTERNAL_STORAGE`, `READ_EXTERNAL_STORAGE`,
  `WRITE_EXTERNAL_STORAGE` or `READ_MEDIA_*`, ever.
- Modification times, permissions, tags and extended attributes on Android (the Storage Access
  Framework cannot set them). The manifest carries `modified` for receivers that can.
- More than one folder transfer at a time in the same direction. Zip packaging.

## 2. Decisions at a glance

"Rahul" means decided on 2026-10-25. "Call" means a judgement call made in this spec; each one
is open to change (section 13).

| # | Decision | Source |
| --- | --- | --- |
| D1 | Mac to phone first. Phone to Mac uses the same messages, built after settings sync | Rahul (recommended) |
| D2 | Three destination modes, default "Choose on the sending device" | Rahul |
| D3 | The receiving device's setting decides, because it owns the storage. With sync on, both devices hold the same value, so it reads the same everywhere | Call |
| D4 | Folder exists: ask each time by default. Merge (keep both on clashes), Replace files, Save as new folder. A setting can preselect one of them | Rahul; the preselect setting follows from "conflict behaviour" being synced |
| D5 | The question shows where you act: the Mac in mode (a), the phone in (b) and (c) | Rahul |
| D6 | Questions time out after 3 minutes and cancel. Nothing is written, nothing is overwritten | Rahul (cancel); 3 minutes is a call |
| D7 | Symlinks and Finder aliases are skipped on the Mac and counted | Rahul (recommended) |
| D8 | Packages (`.app`, `.photoslibrary`, `.rtfd`) are sent as ordinary folders, with a notice | Call |
| D9 | `.DS_Store`, `._*` and macOS system files are always skipped. Other hidden files are skipped by default; "Include hidden files" on the Mac turns them on | Call (default off, matches what Finder shows) |
| D10 | Files that live only in iCloud or another cloud (not downloaded) are skipped and counted | Call |
| D11 | Partial folders keep what completed and are marked incomplete. Automatic resume within 30 minutes of the disconnect, Resume button until 24 hours | Rahul (keep what completed); times are a call |
| D12 | "Sync settings with paired devices" is on by default, with a per-device switch | Rahul; default on flagged |
| D13 | Sync conflicts: the later timestamp wins; timestamps never go backwards on a device; version and device ID break ties | Rahul (timestamp plus version) |
| D14 | Mode (b) shows a Bridgey "Save to…" sheet listing your places; "Other folder…" opens Android's folder picker | Call |
| D15 | Mode (c) whose folder lost access falls back to asking on the phone, with the reason | Call |
| D16 | `Download/Bridgey` works with no grant through MediaStore, with limits; one tap grants it as a full place | Call |
| D17 | Folder transfers number clashes as "Name (1)" and "name (1).ext" on both platforms | Rahul's wording |
| D18 | The sender makes every name safe for FAT-style storage; the receiver checks and rejects anything else | Call |
| D19 | Limits: 10,000 files, 2,000 folders, depth 32, 220-byte names, 1,024-byte paths | Call |
| D20 | The edition advertises draft feature keys (`folders_draft1`, ...) until upstream accepts the design | Call |

## 3. User experience

### 3.1 Sending a folder from the Mac

- **Drop** one or more files and folders on the File Drop window, or use **Send Files or
  Folders…** (an `NSOpenPanel` with `canChooseDirectories` and multiple selection). Each
  folder becomes one queue item; loose files stay file items, as in the multi-file queue.
- The Mac scans the folder at once (counts, sizes, limits) and starts hashing in the
  background. A folder over a limit is refused before anything is sent, with the reason
  ("Photos has 12,431 files; the limit is 10,000. Send its subfolders separately.").
- **Mode (a)** opens the send sheet (3.2). **Modes (b) and (c)** queue the folder straight
  away, like a dropped file today.
- When the phone has no folder support (an upstream or older client), dropping a folder says
  "OnePlus 11 can't receive folders yet. Update Bridgey on the phone." and sends nothing.

The **send sheet** (mode a), a floating window titled "Send “Photos” to OnePlus 11":

- Left: the phone's places (`Download/Bridgey`, then granted places by label). Places that lost
  access are greyed with "Not available".
- Right: the subfolders of the selected folder, a path bar ("Pictures › Trip") and
  **New Folder**. Hidden phone folders (names starting with ".") are not listed.
- Summary line: "124 files, 9 folders, 2.3 GB · 3 links skipped · 12 hidden items skipped
  (Include)". "Include" flips the Mac's "Include hidden files" for this send.
- "Saves to Pictures/Trip/Photos". Buttons **Send** (default) and **Cancel**.
- The last destination for each phone is preselected (a Mac-only setting).
- Packages get a line: "Xcode.app is an app bundle. On the phone it is an ordinary folder."
- Hashing progress shows under the summary; Send stays enabled and the offer goes out when
  hashing ends.
- The sheet works while other items are still sending; after Send, the folder waits its turn
  in the queue with its destination already chosen.

### 3.2 Where it lands

The receiving device's mode decides (D3). Labels name the actual devices.

| Mode | Wire value | Phone label (folders from the Mac) | Mac label (folders from the phone) | Who chooses | Sender shows |
| --- | --- | --- | --- | --- | --- |
| (a) default | `sender_picks` | Choose on the Mac while sending | Choose on the phone while sending | The sender, in the send sheet | The sheet |
| (b) | `receiver_asks` | Ask on this phone each time | Ask on this Mac each time | The receiver: "Save to…" sheet | "Waiting for OnePlus 11: choose where to save (2:41)" |
| (c) | `fixed` | Always save to: Pictures/Inbox | Always save to: Downloads/Bridgey | Nobody; the receiver's default folder | "Saving to Pictures/Inbox on OnePlus 11" |

Rules:

- Mode (a) needs the receiver to serve places. If it does not (`places` missing), the sender
  sends without a destination and the receiver treats the offer as mode (b).
- An offer without a destination reaching a receiver in mode (a) is also handled as (b).
- Mode (b) on the phone: a high-priority notification "Save folder Photos from MacBook Pro"
  opens the **Save to…** sheet (places as one-tap rows, last choice first, and **Other
  folder…**, which opens `ACTION_OPEN_DOCUMENT_TREE`). If Bridgey is open, the sheet appears
  at once. Android blocks starting activities from the background, so no full-screen prompt.
- A folder picked through "Other folder…" is used for this transfer only; the sheet offers
  "Add to places" as a checkbox (off by default).
- Mode (c) whose default folder lost access asks on the phone for this transfer, with the line
  "Your default folder Pictures/Inbox is no longer available" (D15). It never silently falls
  back to `Download/Bridgey`.
- The default folder is device-specific: `Download/Bridgey` on the phone and the "Received
  files" folder on the Mac until changed.

### 3.3 When the folder already exists

"Exists" means the destination already has an item named like the folder (compared without
case, section 5). The setting "When a folder already exists" decides: **Ask each time**
(default), or always Merge, Replace files or Save as new folder.

| Choice | Wire value | What happens |
| --- | --- | --- |
| Merge | `merge` | Files go into the existing folder; existing subfolders are reused. A clashing file is kept and the new one saved as "name (1).ext". Nothing is overwritten |
| Replace files | `replace` | Like Merge, but a clashing file is replaced, only after the new file is verified. Files that do not clash stay |
| Save as new folder | `new_folder` | Saved as "Photos (1)" (the first free number) |
| Cancel | `cancel` | Nothing is written |

- A clash between a file and a folder (a file named "2019" where the folder has a subfolder
  "2019", or the reverse) always keeps both, renaming the incoming item. A folder is never
  deleted or replaced.
- If the existing item named "Photos" is a file, only **Save as "Photos (1)"** and **Cancel**
  are offered; a preset Merge or Replace becomes Save as new folder.
- Where the question shows (D5): the Mac in mode (a), with the Mac's transfer row waiting;
  the phone in (b), straight after the folder choice, in the same sheet; the phone in (c), as a
  notification and an in-app sheet, while the Mac shows "Waiting for OnePlus 11 (2:41)".
- Wording: "“Photos” already exists in Pictures/Trip. 12 of 124 files have the same names."
  When counting takes longer than 3 seconds: "Some files may have the same names."
- Buttons: **Merge** (default; Return), **Replace Files**, **Save as “Photos (1)”**, **Cancel**
  (Escape). Replace is never the default.
- Phone notification actions: Merge, Replace, New folder. Replace sets
  `setAuthenticationRequired(true)` (Android 12+), so it needs an unlocked phone. Tapping the
  notification opens the full sheet with Cancel. Dismissing the notification does not answer.
- **Timeout: 3 minutes**, counted by the device that asks. When nobody answers, the transfer
  is cancelled (`timeout`), nothing is written, and the sender's row offers **Send again**.

### 3.4 Progress, queue and cancelling

- **One row per folder** in the transfer list (Mac transfer window, or the Stream panel once
  design B lands on the Mac; Android Stream live card and one progress notification).
  Row: "Photos → OnePlus 11 › Pictures/Trip", overall progress bar by bytes, then "37 of 124
  files · 812 MB of 2.3 GB · 12 MB/s · 2 min left".
- **Expand** the row for files: the current file with its own progress, then failures with
  their reason, then the last 200 completed names. Large folders never render every row.
- **Cancel** cancels the whole folder (the current file stops; waiting files are not sent).
  Cancel All also cancels folders. There is no per-file cancel inside a folder.
- **Partial folders** (Rahul): files that completed stay; the file in progress is deleted; the
  folder is marked incomplete in the row and the activity stream. Nobody deletes the
  completed files automatically, because Merge may have mixed them with files that were
  there before.
- **Disconnect:** the row shows "Interrupted, resumes when OnePlus 11 reconnects". It resumes by
  itself if the devices reconnect within 30 minutes; after that, **Resume** stays on the row for
  24 hours. Resuming skips verified files and restarts the file that was cut off.
- The Android notification for a folder is one ongoing notification ("Photos · 37 of 124
  files") with **Cancel**. Queued items get no notification until they start (section 11.1 fixes this
  in the queue port).
- When done: Mac "Photos saved on OnePlus 11 in Pictures/Trip"; phone notification "Folder
  Photos saved to Pictures/Trip (124 files)" with **Open** (opens the folder in the Files app
  when the device supports it).

### 3.5 Activity stream

New kinds: the folder kinds are in category Files, `settings_synced` in Other. Text uses the
platform file-size formatter.

| Kind | Example |
| --- | --- |
| `folder_sent` | Sent folder Photos (124 files, 2.3 GB) to OnePlus 11 › Pictures/Trip |
| `folder_received` | Received folder Photos (124 files, 2.3 GB) from MacBook Pro › Pictures/Trip |
| `folder_incomplete` | Folder Photos incomplete: 37 of 124 files (812 MB) to OnePlus 11 › Pictures/Trip |
| `settings_synced` | Settings synced with OnePlus 11: Reduce motion on |

A detail line adds, when relevant: "Merged, 12 kept as copies", "12 files replaced", "Saved as
Photos (1)", "3 links and 12 hidden items skipped", "Cancelled", "Connection lost", "3 files
failed".

`ActivityItem` gains `fileCount: Int?`, `bytes: Long?` and `destination: String?` (display path,
at most 128 characters). The folder name goes in `fileName`. The test that pins the field set
(`ActivityLogTest.theRecordHasNoContentFields`) is updated on purpose. Folder and destination
names are stored like file names today: on the device only, 200 items, 7 days, never in logs or
diagnostics.

### 3.6 Settings placement

In the agreed order (This device, Devices and permissions, Clipboard, Notifications, Calls,
Files, Media and quick actions, Privacy, Updates, General, About). Synced rows carry a small
sync mark, so it is clear they change the other device too.

**Files** (after the existing File transfer switch):

| Row | Phone | Mac | Synced |
| --- | --- | --- | --- |
| Folders sent to this device | (a) / (b) / (c) radio, labels from 3.2 | Same | Yes |
| Default folder | Place picker (default `Download/Bridgey`) | Existing "Received files" folder | No |
| When a folder already exists | Ask each time / Merge / Replace files / Save as new folder | Same | Yes |
| Places | List: label, storage, "Access lost" state; **Add folder…**; **Remove**; rename the label; `Download/Bridgey` row with **Allow full access** until granted | Not in the first build (comes with phone to Mac) | No |
| Include hidden files when sending folders | Later (phone to Mac) | Switch, off | No |

**General:** "Sync settings with paired devices" (on). Detail: "Keeps folder, clipboard,
preview and motion preferences the same on your devices. Names, folders and update channels
stay on each device."

**Device page** (Devices and permissions › device): "Sync settings with this device" (on).
Shows "Off on OnePlus 11" when the other side turned it off, like feature overrides.

## 4. Protocol

### 4.1 Negotiation

Three new keys in the encrypted `features.update` map. Each is false when missing, so clients
that predate them (upstream 0.6 included) never receive the new messages.

| Key | True when | Own switch |
| --- | --- | --- |
| `folders` | The client implements folder transfers, `files` is on for this peer, Android 10 or newer | No: mirrors `files` |
| `places` | `folders` is true and the client serves `places.*` requests | No: mirrors `files` |
| `settings_sync` | The client implements settings sync and both its global and per-device switches are on | Yes |

- Send `folders.*`, `places.*`, `settings.*`, and `files.offer` with folder fields, only while
  the peer's latest `features.update` shows the key true. Until the first `features.update`
  of a session arrives, all three count as false.
- Receivers also refuse these messages when they did not advertise the key themselves.
- Add the three to the "not enabled by a legacy peer" list on both platforms
  (`featureEnabledByLegacyPeer`). Upstream clients ignore unknown keys: Android reads only
  its own enum, macOS decodes `[String: Bool]`.
- **Draft keys (D20).** Until upstream accepts this design, the edition advertises
  `folders_draft1`, `places_draft1` and `settings_sync_draft1` instead. If upstream later
  ships a different design under `folders`, the two can never be confused. On acceptance,
  clients advertise the final keys and keep reading the draft keys for one release.
- A feature turned off mid-transfer behaves as today for files: an accepted folder transfer
  finishes; the next queue item is refused.

### 4.2 Routing and common rules

- Every new message is an encrypted payload in the current transport, routed like quick
  actions and `features.update`: outer `kind`, `sessionId`, unique `messageId`, base64
  `nonce` and `ciphertext`. `folders.offer`, `folders.rejected`, `folders.cancel` and
  `folders.cancel.ack` repeat the folder transfer ID in the outer `transferId`, so a receiver
  whose Files switch is off can answer `folders.rejected` without decrypting (the
  `files.rejected` pattern) and then resend `features.update`.
- Accepted only in the connected state, for the current session, after the replay check
  (`acceptMessageId`). Unknown fields are ignored. Folder payloads carry `"version": 1`;
  settings payloads carry `"schema": 1`. An unknown version is ignored and answered with
  `unsupported` where a reply is expected.
- A payload that fails decryption keeps today's rule (the session closes). A payload that
  decrypts but fails validation does not close the session: the receiver answers
  `folders.rejected`, `folders.cancel` (`invalid_message`), `places.error` or `settings.error`.
- Plaintext limits: 8 KiB, except `folders.manifest`, `folders.complete`, `folders.result`,
  `places.listed` and `places.children` (32 KiB) and `settings.snapshot` and `settings.update`
  (16 KiB). 32 KiB of plaintext is about 43.7 KB after AES-GCM and base64, inside the
  65,536-byte frame.
- IDs (`folderTransferId`, `requestId`, per-file `transferId`) are lowercase UUIDs, never reused.
  A retry or a fresh resend always gets new IDs.

### 4.3 Messages

| Kind | From | Limit | Answer |
| --- | --- | --- | --- |
| `places.list` | sender | 8 KiB | `places.listed` |
| `places.listed` | receiver | 32 KiB | |
| `places.browse` | sender | 8 KiB | `places.children` or `places.error` |
| `places.children` | receiver | 32 KiB | |
| `places.create_folder` | sender | 8 KiB | `places.folder_created` or `places.error` |
| `places.folder_created` | receiver | 8 KiB | |
| `places.error` | receiver | 8 KiB | |
| `folders.offer` | sender | 8 KiB | after the manifest: `folders.accept`, `folders.waiting`, `folders.conflict` or `folders.rejected` |
| `folders.manifest` | sender | 32 KiB | none |
| `folders.waiting` | receiver | 8 KiB | |
| `folders.conflict` | receiver | 8 KiB | `folders.resolve` |
| `folders.resolve` | sender | 8 KiB | `folders.accept` or `folders.cancel` |
| `folders.accept` | receiver | 8 KiB | |
| `folders.rejected` | receiver | 8 KiB | |
| `files.offer`, `files.chunk`, `files.complete` | sender | existing | `files.accept`, `files.chunk.ack`, `files.complete.ack` |
| `folders.entry_failed` | receiver | 8 KiB | |
| `folders.complete` | sender | 32 KiB | `folders.result` |
| `folders.result` | receiver | 32 KiB | |
| `folders.cancel` | either | 8 KiB | `folders.cancel.ack` |
| `folders.cancel.ack` | either | outer only | |
| `settings.snapshot` | either | 16 KiB | `settings.ack` |
| `settings.update` | either | 16 KiB | `settings.ack` |
| `settings.ack` | either | 8 KiB | |
| `settings.error` | either | 8 KiB | |

"Sender" and "receiver" refer to the folder: the device sending it, and the device it lands on.

### 4.4 Flows

Mode (a), folder exists, user merges:

```text
Mac (sender)                                     Phone (receiver)
places.list                       ----------->
                                  <-----------   places.listed {mode: sender_picks, places}
places.browse {placeId, path}     ----------->
                                  <-----------   places.children {folders, fileCount}
        (user picks Pictures/Trip, presses Send)
folders.offer {destination}       ----------->
folders.manifest x pageCount      ----------->
                                  <-----------   folders.conflict {clashingFiles: 12}
folders.resolve {choice: merge}   ----------->
                                  <-----------   folders.accept {rootName, destinationLabel}
files.offer / files.chunk / files.complete, one entry after another (pipelined, 4.6)
                                  <-----------   files.chunk.ack, files.complete.ack
folders.complete                  ----------->
                                  <-----------   folders.result {status: complete}
```

Mode (b): `places.list` answers `mode: receiver_asks` with no places. The offer has no
destination. After the manifest, the phone sends `folders.waiting {reason: destination}`, shows
the Save to… sheet, checks for an existing folder there (asking in the same sheet when needed),
then sends `folders.accept`.

Mode (c): `places.list` answers `mode: fixed` and `fixedLabel`. The offer has no destination.
The phone checks its default folder; when the folder exists and the setting is Ask, it sends
`folders.waiting {reason: conflict}` and asks on the phone.

The sender sends `places.list` for every folder it is about to send (one round trip), so a mode
changed on the receiver is always seen. Without the `places` key it skips the request and sends
no destination.

### 4.5 Payloads

Short forms such as `{ "version": 1, "requestId" }` list fields without sample values; their
types are in the tables or the text.

**`places.list`**: `{ "version": 1, "requestId": "<uuid>" }`

**`places.listed`**

```json
{
  "version": 1,
  "requestId": "6f1c3a52-...",
  "mode": "sender_picks",
  "places": [
    { "placeId": "default", "label": "Download/Bridgey", "available": true, "freeBytes": 81604378624 },
    { "placeId": "q3Jx0bVv1eG7tq8Wm2l5wA", "label": "Pictures", "available": true, "freeBytes": 81604378624 }
  ],
  "fixedLabel": null
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `mode` | string | `sender_picks`, `receiver_asks` or `fixed` |
| `places` | array | Only in `sender_picks`; otherwise empty. At most 17 (16 granted plus `default`) |
| `placeId` | string | `default`, or 22 characters of base64url (16 random bytes) chosen by the receiver. Never a content URI or file system path |
| `label` | string | At most 64 characters, for display |
| `available` | bool | False when the grant was revoked or the storage is missing |
| `freeBytes` | integer or null | Best effort; null when unknown |
| `fixedLabel` | string or null | Display path of the default folder in `fixed` mode, at most 128 characters |

**`places.browse`**: `{ "version": 1, "requestId", "placeId", "path": "Trip", "cursor": null }`.
`path` is a relative path of existing folders inside the place ("" is the place itself), checked
with the existing-path rules (5.3). `cursor` is the opaque string from a previous page. In modes
other than `sender_picks`, browse and create answer `places.error` (`policy`).

**`places.children`**

```json
{ "version": 1, "requestId": "...", "placeId": "...", "path": "Trip",
  "folders": ["2019", "Beach"], "fileCount": 14, "folderCount": 2, "nextCursor": null }
```

Folder names only, sorted case-insensitively, at most 500 per page. `fileCount` and
`folderCount` count the direct children of this folder (hidden ones excluded). No file names,
sizes, dates or contents.

**`places.create_folder`**: `{ "version": 1, "requestId", "placeId", "path", "name": "Trip 2026" }`.
`name` must already be a portable name (5.1). Answer **`places.folder_created`**
`{ "version": 1, "requestId", "placeId", "path", "name" }`. Repeating a `requestId` within the
session returns the first answer and creates nothing.

**`places.error`**: `{ "version": 1, "requestId", "code" }`, codes from 4.8.

**`folders.offer`**

```json
{
  "version": 1,
  "folderTransferId": "4b0c9d5e-...",
  "rootName": "Photos",
  "fileCount": 124,
  "folderCount": 9,
  "totalSize": 2469606195,
  "pageCount": 2,
  "manifestSha256": "q1f3...base64...=",
  "destination": { "placeId": "q3Jx0bVv1eG7tq8Wm2l5wA", "path": "Trip" },
  "resume": false,
  "skipped": { "links": 3, "hidden": 12, "unreadable": 0, "tooLarge": 0, "notDownloaded": 0, "tooLong": 0, "other": 0 }
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `rootName` | string | Portable name (5.1) |
| `fileCount`, `folderCount` | integer | Entries of each type in the manifest; the root itself is not an entry. Limits in 5.4 |
| `totalSize` | integer | Sum of file sizes, at most 2^40 |
| `pageCount` | integer | 1 to 128 |
| `manifestSha256` | string | Base64 SHA-256 of the canonical manifest (4.5.1) |
| `destination` | object, optional | Only when the sender picked it (mode a). `path` uses the existing-path rules |
| `resume` | bool | True when resuming (4.7); the receiver then uses the destination in its journal and ignores `destination` |
| `skipped` | object, optional | What the sender left out, for the receiver's activity item. Unknown counters are ignored |

**`folders.manifest`**

```json
{
  "version": 1,
  "folderTransferId": "4b0c9d5e-...",
  "page": 0,
  "entries": [
    { "type": "dir", "path": "2019" },
    { "type": "dir", "path": "2019/Empty" },
    { "type": "file", "path": "2019/IMG_0001.jpg", "size": 2481123, "sha256": "base64", "modified": 1561234567000 }
  ]
}
```

- Pages are sent right after the offer, in order from 0, each with 1 to 256 entries.
- An entry's index is its position across all pages. Entries are in depth-first pre-order:
  a folder comes before anything inside it; siblings are sorted by the UTF-8 bytes of their
  names. Every entry's parent is the root or an earlier `dir` entry.
- `size` and `sha256` (base64, 32 bytes) are required for files. `modified` (Unix ms) is
  optional; Android ignores it.

#### 4.5.1 Manifest digest

SHA-256 over this byte string, UTF-8, no trailing data:

```text
"folder-manifest-v1\n" + rootName + "\n"
then for each entry in order:
type + "\0" + path + "\0" + (size as decimal, "0" for dirs) + "\0" + (sha256 or "") + "\n"
```

`modified` is not part of the digest. The receiver recomputes it and rejects a mismatch
(`invalid_manifest`). The digest identifies the transfer for resume.

**`folders.waiting`**: `{ "version": 1, "folderTransferId", "reason": "destination", "timeoutSeconds": 180 }`.
`reason` is `destination` or `conflict`. Sent again when the reason changes.

**`folders.conflict`** (to the sender, only in mode (a) when the receiver's "When a folder already
exists" setting is Ask; a preset choice is applied without asking):

```json
{ "version": 1, "folderTransferId": "...", "existing": "folder",
  "clashingFiles": 12, "clashingFolders": 3, "newFolderName": "Photos (1)",
  "choices": ["merge", "replace", "new_folder"], "timeoutSeconds": 180 }
```

`existing` is `folder` or `file`. `clashingFiles` is null when counting did not finish within
3 seconds. `choices` is `["new_folder"]` when the existing item is a file.

**`folders.resolve`**: `{ "version": 1, "folderTransferId", "choice": "merge" }`. `choice` is one
of the offered `choices` or `cancel`. Valid only while the receiver waits on that question;
otherwise ignored.

**`folders.accept`**

```json
{ "version": 1, "folderTransferId": "...", "rootName": "Photos",
  "destinationLabel": "Pictures/Trip", "choice": "merge", "completedBitmap": null }
```

| Field | Rule |
| --- | --- |
| `rootName` | The final name ("Photos (1)" after Save as new folder) |
| `destinationLabel` | Display path of the parent folder, at most 128 characters |
| `choice` | `none` (no clash), `merge`, `replace` or `new_folder` |
| `completedBitmap` | Resume only: base64 bitmap, bit `i` (least significant bit first) set when entry `i` is done. Null otherwise |

**`folders.rejected`**: `{ "version": 1, "folderTransferId", "code", "entry": null, "neededBytes": null, "freeBytes": null }`.
`entry` names the first bad entry for `invalid_manifest`. The outer-only form (no ciphertext)
means Files is off on the receiver.

**`folders.entry_failed`**: `{ "version": 1, "folderTransferId", "entry": 17, "transferId", "code" }`.
One file could not be saved; the transfer goes on.

**`folders.complete`**: `{ "version": 1, "folderTransferId", "sentFiles": 121, "failedCount": 3, "failed": [{ "entry": 17, "code": "source_changed" }] }`.
`failed` lists at most 500 sender-side failures.

**`folders.result`**

```json
{ "version": 1, "folderTransferId": "...", "status": "complete",
  "savedFiles": 124, "savedBytes": 2469606195, "createdFolders": 9,
  "renamedFiles": 0, "replacedFiles": 0, "failedCount": 0, "failed": [] }
```

`status` is `complete` when every manifest entry was saved, otherwise `incomplete`. `failed`
lists at most 500 entries.

**`folders.cancel`**: `{ "version": 1, "folderTransferId", "reason": "user", "code": null }`.
`reason` is `user`, `timeout`, `policy` or `error`. **`folders.cancel.ack`** is outer only.

### 4.6 Files inside a folder

Each file reuses the existing chunked messages. `files.offer` keeps all its fields (`transferId`,
`name`, `mimeType`, `size`, `sha256`) and adds:

| Field | Type | Rule |
| --- | --- | --- |
| `folderTransferId` | string | An accepted folder transfer of this session |
| `entry` | integer | Index of a `file` entry, strictly greater than the previous entry offered since the folder was accepted or resumed |
| `path` | string | Equal to that entry's `path`; `name` equals its last component; `size` and `sha256` equal the entry's |

Any mismatch: `folders.entry_failed` (`invalid_message`). The standalone rule "paths from a
sender are never accepted" still holds for every `files.offer` without `folderTransferId`.

**Pipelining.** Thousands of small files must not cost three round trips each. Inside a folder
transfer:

- The receiver handles messages in order and creates the file before it reads the next
  message, so the sender sends chunks right after `files.offer` without waiting for
  `files.accept`. The receiver still sends `files.accept`.
- The sender does not wait for the last chunk acknowledgement of a file before the next one.
- At most 64 chunks (1.5 MiB) are unacknowledged across the whole folder, and at most 32
  files wait for `files.complete.ack`.
- Chunks of different files never interleave.
- When the receiver fails a file, it marks that `transferId` cancelled before reading on and
  drops its remaining chunks quietly (today's `cancelledTransferIds` behaviour), then sends
  `folders.entry_failed`. After 50 failed files it cancels the folder (`too_many_failures`).
- Folders are created by the receiver in manifest order as it reaches them: before file entry
  `k`, every `dir` entry below `k` exists. After `folders.complete`, the remaining (empty)
  folders are created, then `folders.result` goes out.
- A file whose content changed on the sender since the manifest is caught by the sender's
  running hash: it sends `files.cancel` for it and reports `source_changed` in
  `folders.complete`.

### 4.7 Resume

- Both devices keep a small journal per folder transfer (section 6.6 and 7.4). On reconnect of
  the same paired device, the sender resends `folders.offer` with the same
  `folderTransferId` and `"resume": true`, then the manifest pages.
- The receiver accepts only when its journal has that ID from the same peer with the same
  `manifestSha256`. It answers `folders.accept` with the stored `rootName`, `choice` and
  `completedBitmap`; nobody is asked again. Otherwise `folders.rejected` (`resume_unavailable`),
  and the sender offers **Send again** (a new transfer, which may then ask about the
  existing folder).
- The sender skips entries set in the bitmap and continues with new per-file transfer IDs.
- Automatic within 30 minutes of the disconnect; then **Resume** until 24 hours; then the
  journals are deleted and the folder stays incomplete. **Forget device** deletes them at once.

### 4.8 Errors and timeouts

| Code | Meaning |
| --- | --- |
| `unsupported` | Feature not negotiated or unknown version |
| `unsupported_schema` | Settings schema newer than the receiver supports |
| `policy` | Files is off for this peer |
| `busy` | Another folder transfer is active in this direction, or the places rate limit was hit |
| `invalid_message` | Decrypted but invalid payload |
| `invalid_manifest` | Pages, counts, digest, order, names or clashes are wrong (`entry` names the first bad one) |
| `limit_exceeded` | Over a limit in 5.4 |
| `insufficient_space` | Known free space is below `totalSize` plus 64 MiB, or the disk filled up |
| `place_unavailable` | Grant revoked, folder missing or storage removed |
| `not_found` | A browse or destination path does not exist |
| `exists` | `places.create_folder` target already exists |
| `invalid_name` | A new folder name is not portable |
| `timeout` | Nobody answered a question within 3 minutes |
| `declined` | The user cancelled the question or the Save to… sheet |
| `io_error` | Storage error on one file or folder |
| `verification_failed` | Size or hash mismatch |
| `source_changed` | The sender's file changed after the manifest |
| `unreadable` | The sender could not read the file |
| `resume_unavailable` | No matching journal |
| `too_many_failures` | 50 files failed |
| `cancelled` | Cancelled by either side |

| Wait | Limit | Then |
| --- | --- | --- |
| Answer to a `places.*` request | 8 s | Sender shows "OnePlus 11 did not answer" |
| First answer after the last manifest page | 15 s | Sender cancels (`timeout`) |
| A question to the user (destination or conflict) | 180 s, counted by the asking device | Cancel (`timeout`), nothing written |
| Sender waiting on a remote question | 195 s | Sender cancels |
| Chunk acknowledgement | 10 s (existing) | File failed, folder interrupted |
| `folders.result` after `folders.complete` | 30 s | Row marked "Not confirmed by OnePlus 11" |
| `folders.cancel.ack` | 5 s, sent up to 3 times | Treated as cancelled |
| Automatic resume | 30 min after the disconnect | Resume button |
| Journals | 24 h | Deleted |

### 4.9 Settings sync messages

**`settings.snapshot`** (sent by each side when `settings_sync` becomes true for the session,
including right after connecting) and **`settings.update`** (local edits, debounced 500 ms):

```json
{
  "schema": 1,
  "maxSchema": 1,
  "records": {
    "display.reduce_motion": { "value": true, "changedAt": 1792900000000, "version": 4, "changedBy": "550e8400-e29b-41d4-a716-446655440000" },
    "files.folder_destination": { "value": "sender_picks", "changedAt": 0, "version": 0, "changedBy": "" }
  }
}
```

| Field | Type | Rule |
| --- | --- | --- |
| `schema` | integer | 1. A receiver that does not support it answers `settings.error` (`unsupported_schema`, its `maxSchema`); the sender then uses the lower schema |
| `maxSchema` | integer | Snapshot only |
| `records` | object | At most 32; keys from 8.1, at most 64 characters of `[a-z0-9_.]` |
| `value` | bool or string | Type and allowed values per key |
| `changedAt` | integer | Unix ms, 0 to 2^53 - 1 |
| `version` | integer | 0 to 2^53 - 1 |
| `changedBy` | string | Device ID of the device where the edit was made; "" for a never-edited default |

A snapshot holds every key of the schema that the device implements. A device may implement a
key before it has a screen for it; it then stores and relays the value. Unknown keys and
records with a wrong type are skipped one by one, not the whole message.

**`settings.ack`**: `{ "schema": 1, "ackOf": "<messageId>", "applied": ["display.reduce_motion"], "kept": [] }`.
`kept` lists keys where the receiver's own record won; the receiver sends those records in a
`settings.update` unless it already sent them to this peer, so both converge. **`settings.error`**: `{ "schema": 1, "code", "maxSchema": 1 }`.

Merge rules are in 8.2.

## 5. Names, paths and limits

### 5.1 Portable names

Every name in a manifest (`rootName`, each path component) and in `places.create_folder` must
be a **portable name**: safe on FAT-style storage (SD cards, USB drives), on Android's shared
storage and on macOS. The sender converts names; the receiver checks that a name does not
change under steps 1 to 6 and is at most 220 UTF-8 bytes, and rejects it otherwise.

1. Normalise to Unicode NFC (macOS often hands out decomposed names).
2. Replace each of U+0000 to U+001F, U+007F, `"`, `*`, `/`, `:`, `<`, `>`, `?`, `\` and `|`
   with `_`. Reject strings with unpaired surrogates.
3. Remove leading spaces, and trailing spaces and dots.
4. If nothing is left, use `_`.
5. If the part before the first dot, compared without case, is `CON`, `PRN`, `AUX`, `NUL`,
   `COM1` to `COM9` or `LPT1` to `LPT9`, add `_` after that part (`CON.txt` becomes `CON_.txt`).
6. If the name ends with `.bridgey-part` (any case), add `_`.
7. Sender only: if the name is longer than 220 UTF-8 bytes, shorten the part before the last
   dot (keep an extension of up to 16 bytes) at a character boundary, then repeat step 3.

220 bytes leaves room for " (9999)" and a partial-file suffix inside the 255-byte limit of
Android and APFS. `.` and `..` are never valid (steps 3 and 4 change them), so they are
rejected.

Test vectors (both platforms run the same table; the protocol commit adds it as
`protocol/test-vectors/folders-v1.json`):

| Input | Portable |
| --- | --- |
| `Trip: Day 1?` | `Trip_ Day 1_` |
| `notes.` | `notes` |
| `  spaced  ` | `spaced` |
| `...` | `_` |
| `CON.txt` | `CON_.txt` |
| `aux` | `aux_` |
| `report.bridgey-part` | `report.bridgey-part_` |
| `e` + U+0301 + `te.txt` (NFD) | `été.txt` (NFC) |
| `a\b\|c` | `a_b_c` |
| `.env` | `.env` |
| 300 × `a` + `.jpg` | 216 × `a` + `.jpg` |

### 5.2 Manifest paths

- Components joined by `/`; no leading or trailing `/`, no empty component; every component
  portable. This excludes absolute paths, `..`, NUL, backslashes and drive letters.
- At most 32 components and 1,024 UTF-8 bytes, not counting `rootName`.
- **Case clashes.** Within one folder, no two entries (files and folders share the namespace)
  may have the same key, where key = NFC then Unicode default lowercase (Kotlin
  `lowercase(Locale.ROOT)`, Swift `lowercased()`). Android shared storage, FAT and default
  APFS ignore case. The sender resolves clashes after step 7: siblings sorted by UTF-8 bytes,
  each later clashing sibling renamed to "base (n)ext" with the smallest free `n` from 1.
  These count as renamed ("2 names changed to fit the phone"). The receiver rejects a manifest
  that still clashes.

### 5.3 Existing paths (browse and destination)

Folders already on the receiver can have any name another app gave them, so these paths are
checked more loosely: components of 1 to 255 bytes, no `/`, NUL or control characters, never
`.` or `..`, at most 32 components and 1,024 bytes. The receiver resolves each component by
exact name among the existing child folders of the previous one and never creates anything
while resolving.

### 5.4 Limits

| Limit | Value | Over the limit |
| --- | --- | --- |
| Files per folder transfer | 10,000 | Refused before sending |
| Folders per transfer (root excluded) | 2,000 | Refused before sending |
| Depth below the root | 32 | Refused before sending |
| Name | 220 UTF-8 bytes | Shortened by the sender |
| Relative path | 1,024 UTF-8 bytes | Entry (and its subtree) skipped, counted as `tooLong` |
| One file | 10 GiB (as today) | Skipped, counted as `tooLarge` |
| Total | 1 TiB, and the receiver's free space | Refused |
| Manifest | 128 pages of at most 32 KiB and 256 entries; 4 MiB in all | Refused before sending |
| Places | 16 granted plus `default` | Add folder disabled |
| Browse page | 500 names | `nextCursor` |
| `places.*` requests | 4 in flight, 20 per 10 s per session | `busy` |
| Folder transfers | 1 active per direction per session | `busy` |

Persisted URI grants are capped by Android (128 before Android 11, 512 from 11); 16 places stay
far below, leaving room for one-off grants.

## 6. Android

### 6.1 Places

- **Add folder…** launches `ACTION_OPEN_DOCUMENT_TREE`, then
  `takePersistableUriPermission(treeUri, READ | WRITE)`. A place stores: random `placeId`,
  tree URI, label (default: the folder's display name; when two clash, add the storage title
  from `Root.COLUMN_TITLE`, as in "Trip (USB drive)"), and the time it was added. Kept in
  owner-only app storage, excluded from backup.
- Android 11 and later do not allow granting the root of internal storage, the root of an SD
  card or the `Download` root; subfolders such as `Download/Bridgey` or `Pictures` are fine.
  The Settings screen says so when the picker returns nothing.
- A place must have `Document.FLAG_DIR_SUPPORTS_CREATE` on its root. Tested on
  `ExternalStorageProvider` (internal storage, SD card, USB drive). Other providers are allowed
  and marked "May be slow".
- **Remove** calls `releasePersistableUriPermission`. Removing the default folder of mode (c)
  makes mode (c) ask on the phone (D15) and says so.
- **Revoked access** (folder deleted or renamed elsewhere, storage removed, app data cleared):
  checked against `contentResolver.persistedUriPermissions` before listing and before
  accepting, and caught as `SecurityException` or `FileNotFoundException` while writing. The
  place shows "Access lost · Grant again"; the Mac sees `available: false`; a running transfer
  stops with `place_unavailable` and keeps what completed; one notification says "Bridgey lost
  access to Pictures".

### 6.2 `Download/Bridgey`

Two backends behind the same `placeId` `default`:

- **Granted (recommended).** Settings › Files › Places › `Download/Bridgey` › **Allow full
  access** opens the folder picker already in that folder (`EXTRA_INITIAL_URI` =
  `DocumentsContract.buildDocumentUri("com.android.externalstorage.documents",
  "primary:Download/Bridgey")`, created first through MediaStore if missing). Two taps. From
  then on it is an ordinary place. The Stream shows a one-time card offering this the first
  time a folder arrives without it.
- **MediaStore fallback** (no grant). Files go through `MediaStore.Downloads` with
  `RELATIVE_PATH = "Download/Bridgey/<root>/<sub>/"` and `IS_PENDING` until verified, as for
  single files today. Limits, stated in Settings:
  - browsing sees only folders that contain files Bridgey saved (Bridgey can see only its own
    Downloads entries); **New Folder** is not offered;
  - empty folders: Bridgey inserts and deletes a pending placeholder so the directory stays.
    Whether the directory survives on current Android versions is checked on the first device
    test; if it does not, empty folders are skipped and counted ("3 empty folders need full
    access to Download/Bridgey");
  - clashes with files Bridgey did not save are invisible, so MediaStore numbers them
    ("name (1).ext"); Replace works only for Bridgey's own files, others are kept as copies.

### 6.3 Writing a folder through the Storage Access Framework

Use `DocumentsContract` directly. `DocumentFile.listFiles()` queries every child again for
its name (one call per child) and `findFile()` lists the whole folder on every lookup; both
fall over at thousands of files.

| Step | Call | Count |
| --- | --- | --- |
| Resolve the destination | One `contentResolver.query` of `buildChildDocumentsUriUsingTree(tree, parentId)` per path component, projection `COLUMN_DOCUMENT_ID`, `COLUMN_DISPLAY_NAME`, `COLUMN_MIME_TYPE`, `COLUMN_FLAGS` | 1 per level |
| Read an existing folder's names (Merge, Replace, clash count) | The same query once, cached as key → (id, isDir) | 1 per existing folder, once |
| Create a folder | `createDocument(parent, Document.MIME_TYPE_DIR, name)`; the returned ID goes in the cache and the journal | 1 per folder |
| Create a file | `createDocument(parent, "application/octet-stream", name)`. The generic type keeps the exact name; a specific type can make the provider append an extension | 1 per file |
| Write | `openFileDescriptor(uri, "w")`, `FileOutputStream` with a 256 KiB buffer | 1 per file |
| Finish a large file | `renameDocument(part, finalName)` | Files over 1 MiB, and every replaced file |
| Replace | After verification: `deleteDocument(old)`, then rename the part | 2 per replaced file |

- **Names.** Bridgey computes every final name from the cached listing ("name (1).ext") and
  creates exactly that name; it never relies on the provider's own numbering, which differs
  between providers. No query after each create.
- **Partial files.** Files over 1 MiB, and every file in Replace, are written as
  `.<name>.bridgey-part` (hidden from most file managers) and renamed after verification.
  Smaller files are written under their final name and deleted if verification fails; that
  saves one call per small file, the common case in big folders.
- **Throughput.** The socket reader hands chunks to a single storage thread through a bounded
  queue (64 chunks). The reader blocks when it is full, which pushes back on TCP, and
  network reads overlap storage calls. Target to verify on the OnePlus 11: 2,000 files of
  10 KB in under 60 s, and large files at the speed of single-file transfers.
- **Free space.** `DocumentsContract.findDocumentPath` gives the root; `Root.COLUMN_AVAILABLE_BYTES`
  of that root is the free space. Unknown free space skips the check; a full disk mid-way
  stops with `insufficient_space`.
- **Media scanning** happens on its own (files written through the provider are indexed). No
  explicit scan.
- **Screen off.** The connection service is already a foreground service. If long transfers
  slow down with the screen off on the test phone, hold a partial wake lock only while a folder
  transfer runs (`WAKE_LOCK` is a normal permission with no prompt; it would be added to
  `ManifestPermissionsTest`). Measure first.

### 6.4 Prompts

- Mode (b): notification in a new channel "Folder questions" (high importance), opening the
  Save to… sheet. Also shown at once when the app is open.
- Conflicts in (b) and (c): the same channel, actions as in 3.3.
- Both expire with the 180 s timeout; the notification is removed and the Stream shows
  "Folder from MacBook Pro cancelled: nobody chose a folder".

### 6.5 Receiving model

- `files.offer` with `folderTransferId` goes to a `FolderReceiveSession` instead of
  `IncomingFileTransfer`; the chunk, complete and cancel paths stay the same.
- `FileTransferState` gains `kind` (`FILE` or `FOLDER`), `queued` (from the port) and a
  `folder` summary (files and bytes done and total, destination label, skipped and failed
  counts, choice). A folder is one state row, so one notification and one Stream card. The
  activity recorder reads an explicit outcome field instead of matching status strings.
- Receiving folders requires Android 10 or newer, as receiving files does today; older
  phones advertise `folders` false.

### 6.6 Journal

`no_backup/folder-transfers/<folderTransferId>.journal`, mode `0600`, append-only text:

```text
v1 <peerDeviceId> <manifestSha256> <createdAtMs> <placeId> <choice> <rootName> <rootDocumentUri>
d <entry> <documentUri>      folder created
f <entry>                    file verified and final
p <entry> <partUri>          part file being written
r <entry> <oldUri>           replace: old file deleted, part not yet renamed
```

- Written with plain `write()` before `files.complete.ack` goes out; that survives the app
  being killed. `fsync` every 100 lines and at the end. After a crash of the whole phone the
  last few files may be sent again and kept as copies; this is rare and documented.
- On start: delete `p` part files, finish pending `r` renames, drop journals older than 24 h.

## 7. macOS

### 7.1 Picking and dropping

- `FileDropView` accepts folders (today it refuses them with "Drop a file, not a folder").
  Copy: "Drop files or folders here to send".
- The menu item becomes **Send Files or Folders…**: `canChooseDirectories = true`,
  `allowsMultipleSelection = true`, `treatsFilePackagesAsDirectories = false`.

### 7.2 Scanning

`FileManager.enumerator(at:includingPropertiesForKeys:options:)` without skipping hidden files
(the filter is ours), keys: `isDirectory`, `isRegularFile`, `isSymbolicLink`, `isAliasFile`,
`isPackage`, `isHidden`, `fileSize`, `contentModificationDate`, `volumeIdentifier`,
`ubiquitousItemDownloadingStatus`.

| Item | Decision | Counted as |
| --- | --- | --- |
| Symbolic link (to a file or folder) | Skipped, never followed (no cycles, nothing outside the folder) | `links` |
| Finder alias | Skipped (meaningless on Android) | `links` |
| Package (`.app`, `.photoslibrary`, `.rtfd`, `.key`) | Sent as an ordinary folder, with the notice in 3.1; links inside are skipped as usual | |
| `.DS_Store`, `._*`, `Icon\r`, `.localized`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`, `.DocumentRevisions-V100`, `*.bridgey-part` | Always skipped, not counted | |
| Other dotfiles and items with the hidden flag | Skipped unless "Include hidden files" is on | `hidden` |
| Not downloaded (iCloud status not current, or `SF_DATALESS` set) | Skipped; reading would start a download of unknown size | `notDownloaded` |
| Unreadable | Skipped | `unreadable` |
| Over 10 GiB | Skipped | `tooLarge` |
| Path over 1,024 bytes after conversion | Skipped with its subtree | `tooLong` |
| Another volume (mount point), socket, pipe, device | Skipped | `other` |

Extended attributes, resource forks, Finder tags, ACLs, permissions and creation dates are not
sent. `modified` is sent. Names are converted to portable names (5.1), case clashes are
resolved (5.2), and the manifest is built and hashed (CryptoKit SHA-256, 1 MiB reads) on a
background queue. The Mac app is not sandboxed, so a dropped or picked folder is readable
directly; the journal keeps its path plus bookmark data so a moved folder is still found on
resume. After an app restart, macOS may ask once for access to a protected folder such as
Documents.

### 7.3 Sending

- A folder is one `FileSendQueue` item. It owns the queue until `folders.result`, a
  cancel, a rejection or an interruption.
- Per file: `OutgoingFileTransfer` takes the manifest hash instead of hashing again up front
  and computes a running hash while sending. The 64-chunk window becomes one window for the
  whole folder (4.6).
- Rows: folder row with expansion (3.4). The last destination per phone is stored as
  `folders.lastDestination.<deviceId>` (`placeId`, `path`), never synced.

### 7.4 Receiving (phone to Mac, later)

Same receiver logic over `FileManager`: folders with `createDirectory(withIntermediateDirectories:
false)`, files through the existing `IncomingFileTransfer` (`name.bridgey-part`, atomic move),
`modified` applied with `setAttributes`. Before descending into an existing folder, `lstat`
it: a symbolic link in the destination counts as a clash and is never followed. Mac places are
the Received files folder plus folders added in Settings (bookmarks). Journal in
`~/Library/Application Support/in.roundrobin.bridgey/FolderTransfers/`, owner-only.

## 8. Settings sync

### 8.1 Synced keys (schema 1)

| Key | Type and values | Default | Android today | Mac today |
| --- | --- | --- | --- | --- |
| `files.folder_destination` | `sender_picks`, `receiver_asks`, `fixed` | `sender_picks` | new | new |
| `files.folder_conflict` | `ask`, `merge`, `replace`, `new_folder` | `ask` | new | new |
| `clipboard.automatic` | bool | set by the automatic clipboard build | coming | coming |
| `pair.clipboard.automatic` | bool, per paired device | set by the automatic clipboard build | coming | coming |
| `activity.previews` | bool | true | `show_activity_previews` | `settings.previews` (design B Mac) |
| `display.reduce_motion` | bool | false | `reduce_motion` | `settings.reduceMotion` (design B Mac) |

- `pair.` keys belong to the two devices of the session: device A's record "automatic
  clipboard with B" is B's record "automatic clipboard with A". Snapshots to B carry only
  A's pair records for B.
- **Never synced:** device name, received-files folder, places and the default folder,
  launch at login, update channel, every feature switch and per-device feature override,
  notification app filters, phone links, shortcuts, the Mac's media player, "Include hidden
  files", the last destination, and the sync switches themselves.
- The `clipboard.*` keys are reserved now; a platform implements them once automatic clipboard
  ships there.

### 8.2 Merge rules

Each synced key has a record: `value`, `changedAt` (ms), `version`, `changedBy`.

- **Local edit** (the only thing that creates a new record):
  `changedAt = max(now, current.changedAt + 1)`, `version = current.version + 1`,
  `changedBy = this device`. Timestamps never go backwards, so an edit made after seeing
  another device's record always wins over it, even when that device's clock runs ahead.
- **Compare** two records: the higher `changedAt` wins; if equal, the higher `version`; if
  equal, the larger `changedBy` (byte order). Records equal in all three are the same record.
- **Apply** a winning remote record as it is (same stamp). Applying never creates a new stamp
  and never triggers an update to anyone. Equal records do nothing.
- This cannot ping-pong: a device only sends records it has not already sent to or received
  from that peer in this session, and a record that loses is answered once with the winner
  (`kept`), which the other side applies without re-stamping.
- **Relaying:** a device synced with two peers passes records on, so all three converge.
- **Example.** Phone sets reduce motion on (changedAt 1000, version 3). The Mac, a moment
  later and before hearing of it, sets it off (1200, 3). Phone receives the Mac's record: 1200
  wins, the phone applies "off". The Mac receives the phone's: its own 1200 wins, it answers
  `kept`, and sends nothing more because its record is already on the way. Both end "off"
  after one update and one acknowledgement each way.
- **Never-edited defaults** are `{default, 0, 0, ""}`, so any real edit wins.
- **Upgrade:** the first build with sync stamps existing values: a value different from the
  default gets `changedAt 1, version 1` (above defaults, below any later edit); a default
  value stays at 0. Two upgraded devices with different non-default values resolve by device ID.
- **First sync** with a device records one activity item listing what changed here
  ("Settings synced with OnePlus 11: Reduce motion on").
- A remote change that shares more (automatic clipboard turned on, destination mode set to
  `sender_picks`, conflict set to `replace`) is applied and always recorded in the activity
  stream, with the device that made it.
- Turning sync off keeps current values; nothing is reset. Forget device removes its `pair.`
  records.

### 8.3 Storage

Android: `SharedPreferences` file `bridgey.sync`, one JSON record per key, `pair.<deviceId>.`
prefix for pair keys. Mac: `UserDefaults` dictionary `sync.records`. The local setting stays
where it is today; the store wraps the setter (`setLocal` stamps, `applyRemote` does not).

### 8.4 As built (v0.10, 2026-10-27)

Settings sync shipped in v0.10 under `settings_sync_draft1`. Where the build differs from 8.1 to
8.3, this section wins. Rahul widened it on 2026-10-27: feature switches sync too, "similar to how
T3 Code works" (a change made in Settings is saved to every connected device that supports it; a
device that was offline or still differs shows it, with Apply to all). That replaces the earlier
rule that sync never turns a feature on.

**What syncs.** An allowlist of 21 schema 1 keys, the same on both platforms. A device that has no
such setting stores the record and relays it, so a phone carries a Mac-only setting between two
Macs.

| Key | Android | Mac | Needs here |
| --- | --- | --- | --- |
| `files.folder_destination` | Files > Folders sent to this phone | Files > Folders from the phone (see below) | |
| `files.folder_conflict` | Files > When a folder already exists | Same | |
| `activity.previews` | Privacy > Show previews in activity | Privacy > Show previews | |
| `display.reduce_motion` | General > Reduce motion | General > Reduce motion | |
| `feature.clipboard`, `feature.files`, `feature.battery`, `feature.find_device`, `feature.ping`, `feature.links`, `feature.media` | The feature's switch | The feature's switch | |
| `feature.notifications` | Notification forwarding | Android notifications | Android: notification access. Mac: notification permission |
| `feature.calls` | Calls | Calls from Mac | Android: phone permissions |
| `feature.remote_input` | Remote control | Remote control (each phone is still granted on the Mac) | Mac: Accessibility |
| `feature.mac_actions` | Mac actions | Mac actions (each phone is still granted on the Mac) | |
| `feature.camera` | Take photos for the Mac | Stored and relayed | Android: camera |
| `clipboard.automatic` | Automatic clipboard (all devices) | Same | |
| `clipboard.files` | Copy images and files | Same | |
| `focus.share` | Share Do Not Disturb with Macs | Share Focus with phones | |
| `focus.follow` | Follow the Mac's Focus | Follow the phone's Do Not Disturb | Android: Do Not Disturb access |
| `codes.enabled` | Stored and relayed | Notifications > Codes from messages | Mac: the consent and model that turning codes on asks for there |

A feature added later joins by adding its key to this table on both platforms; older builds skip
the key, so nothing else changes.

**What never syncs.** Pairing, trust and identity keys, every secret, permissions themselves,
per-device grants and overrides (which phone may use Mac actions or remote control, a feature
turned off for one device, automatic clipboard for one device), device names, paths and folders
(received-files folder, places, the default folder, last destinations), "Allow other devices to
change files here" and "Let other devices browse this phone" (they guard this device against the
others), Update all's "Let paired devices start updates on this device" (a security choice each
device makes for itself), the background clipboard and Keep Wi-Fi awake (they depend on this phone), logging,
update channels, notification app filters, shortcuts, the Mac's media player, launch at login, and
the sync switches themselves. A key outside the allowlist is skipped on receipt, never stored and
never relayed.

**Live changes.** A change made on one device (in Settings, setup, Siri and Shortcuts) goes out
after 500 ms to every connected device it syncs with, which applies it and passes it on. Two
changes to the same setting at the same moment resolve by 8.2: the later edit wins on all devices.

**First connect: ask once (Rahul, 2026-10-27).** The first time two devices sync, the new one
asks "Use the same settings as <device>?":

- **Use these** takes the other device's value for every setting that differs, features included.
- **Keep mine** keeps this device's values; Settings shows "Different on <device>" with Apply to
  all where they differ. On both devices a differing value nobody had chosen is then stamped as
  chosen (`changedAt 1, version 1`) without being sent, so a later connect does not quietly take
  the other device's value.

A device is new when it has never synced with any device. When both are new, the phone asks;
when neither is, nobody asks and the rules below apply at once. Until the answer neither side
takes anything from the other's first snapshot, and nothing syncs with that device. If nothing
differs there is no question. The answer is kept per device (Forget and Reset > Everything clear
it; Reset > Settings keeps it), and from then on sync runs silently. The question waits in the
app; it never posts a notification.

**Later connects.** Each side sends `settings.snapshot` once per session, and again only after sync
went off and on for that device. A snapshot never overwrites a value someone chose:

- A setting nobody chose on this device yet (`version` 0) takes the other device's chosen value.
  A new phone paired with a set-up Mac starts from the Mac's choices; features it turns on may then
  wait for a permission.
- When both devices chose different values (one was offline, or sync was off when the change
  happened), nothing changes. Settings shows "Different on <device>" under that setting, with
  **Apply to all**: it stamps this device's value as a new edit, above the newest record any
  connected device holds for that setting (so a device whose clock runs ahead still takes it), and
  sends it to every connected device that syncs, which applies it.
- Two values nobody chose that still differ (the defaults differ between the devices) also show
  "Different on <device>" until Apply to all or an edit settles them.
- Golden vectors `settingsSnapshot` pin the three outcomes (adopt, different, same).

**Permissions.** Permissions cannot be granted from another device, and neither can a consent.
When a synced feature is on but this device lacks what it needs, the setting reads "On, waiting
for permission" with **Allow** (Android: the Permissions page; Mac: the matching Permissions row).
Where turning a setting on here asks for a consent or terms first (codes from messages on the
Mac: the cloud relay consent, or the on-device model), a remote turn-on does not turn it on: the
setting waits for that consent on this device and counts as on for sync, so nothing is sent back. If a paired device turned it
on, a notification says so ("Calls turned on from Work Mac") with an Allow action. That is the
only notification sync posts (Rahul, 2026-10-27). Each device
lists such keys in a `waiting` array in every snapshot and update (an update with no records when
only the list changes), and the other devices show "Turned on, needs permission on <device>".

**Switches.** Settings > General > "Sync settings with paired devices" (on); setup's summary has the
same switch as "Settings stay the same on your devices". On each device's page,
"Sync settings with this device" (on). The device page shows "Off on <device>" when the other
device's latest `features.update` shows the key false. "Choose what syncs" lists the 21 settings
with a check each; an unchecked setting stays on this device (it is not sent, and records for it
are skipped). Turning sync off keeps every value as it is.

**Activity and notifications.** Every snapshot or update that changed something here records one
item in Other, "Settings synced with Work Mac", with the changes as its detail ("Calls turned on,
Reduce motion turned off"). The changes are stored as tokens, never free text. A remote change that
turns a feature on is in the activity stream only; it notifies (a notification on the phone, a
banner on the Mac) only when this device must give a permission for it.

**More than one device.** Macs never pair with each other, so a phone paired with two Macs is the
hub: it passes one Mac's change to the other. Every device relays to every device it syncs with, so
a Mac with two phones is the hub between them in the same way. A device whose sync is off on either
side is left out. When a device comes back after missing changes, it shows "Different on <device>"
for each setting that still differs, and Apply to all on either side settles it.

**Mac folder destination.** The Mac has two modes for folders from the phone: Ask on this Mac
(`receiver_asks`) and Always save to Received files (`fixed`). It reads `sender_picks` as `fixed`,
because the phone cannot choose a folder on the Mac, and does not count that as different.

**Upgrade and reset.** The first build with sync stamps each setting once: a value the person
stored before gets `changedAt 1, version 1` (chosen); a value never stored stays at 0 (not chosen).
Reset > Settings also clears the sync records, switches and choices but keeps the first-connect
answers, so the device takes the other devices' chosen values again, silently, the next time it
connects. Nothing is pushed to the other devices (Rahul, 2026-10-27).

**Storage.** Android: `SharedPreferences` file `bridgey.sync` (`record.<key>` JSON, `enabled`,
`device.<deviceId>`, `excluded`, `stamped`). Mac: `settings.sync.records`, `settings.sync.enabled`,
`settings.sync.devices`, `settings.sync.excluded` and `settings.sync.stamped` in `UserDefaults`,
under the `settings.` prefix so Reset covers them.

**Wire additions.** `waiting` (array of at most 32 keys) in `settings.snapshot` and
`settings.update`; unknown keys and non-strings in it are dropped. First connect: a snapshot carries
`first` (true while the sender has no answer for the receiver) and `new` (true while the sender has
no answer for any device); both sides pick the asker from the two snapshots alike. The asker's
`settings.update` with `answered: true` ends the wait on the other side. Answers are stored on
Android in `bridgey.sync.answers` (`<deviceId>` = `use`, `keep`, `peer` or `auto`), on the Mac in
`sync.answers`. `settings.error` codes:
`unsupported_schema`, `invalid_message`, `rate_limited`. Only `unsupported_schema` stops sync with
that device until the next session; the others are logged.

### 8.5 Threat model (settings sync)

Self-contained here; [SECURITY.md](../SECURITY.md) points to it.

| Threat | What it could do | Mitigation |
| --- | --- | --- |
| A paired device is compromised or misused | Turn features on here, for example Files (so it can send files), Notification forwarding (so it receives notifications) or Calls | Only authenticated, trusted peers in a live session can send `settings.*`, and only while this device advertises `settings_sync_draft1` to that peer (both switches on). Every applied change is in the activity stream with the device's name, and turning a feature on posts a notification. Permissions are never granted remotely, so notification access, phone, camera, Accessibility and Do Not Disturb still need the person on this device. Turning sync off for that device, or Forget, stops it at once |
| Escalation through per-device grants | A phone turning on Mac actions or remote control for itself | Only the global switch syncs. Which phone may use Mac actions or control the Mac stays a grant made on the Mac and never syncs |
| Opening this device's storage | A Mac turning on writes into places, or browsing | "Allow other devices to change files here" and "Let other devices browse this phone" never sync |
| Starting updates remotely | A peer turning on "Let paired devices start updates on this device" so it can restart this device's Bridgey | That switch never syncs; each device decides it |
| Skipping a consent | A peer turning on codes from messages on a Mac, which would send message text to the cloud relay without the person agreeing there | A remote turn-on waits for the consent (and model) on that Mac; nothing turns on until the person allows it there |
| Secrets or pairing data leaking | Keys, codes or trust read or overwritten | None of them is a sync key; the allowlist is closed and unknown keys are skipped, not relayed |
| A new device overwriting an existing setup | A freshly paired device pushing its defaults over the choices of the devices already in use | The new device asks; nothing moves until the person answers, and Keep mine leaves both sides as they are |
| Flooding | A peer sending many updates to flip settings back and forth or fill the activity stream | At most 20 `settings.*` messages per peer per 10 seconds; more are dropped and answered once per window with `settings.error` `rate_limited`. Payloads are bounded (16 KiB, 32 records, 32 waiting keys) |
| Replay or forgery | An old update applied again, or one from another device | AES-GCM per session, the 256-ID replay window, and records apply only when they win by 8.2 |
| A peer on an older build | Settings it does not know reaching it | It does not advertise the key, so it receives nothing; a newer key reaching an older v0.10 build is skipped |
| Mistaken overwrite after being offline | A stale device pushing old values on reconnect | A snapshot never overwrites a chosen value; differences wait for Apply to all |

What sync cannot prevent: someone with a paired device and the person's trust can change shared
settings by design, as they could by picking up this device. The defence is visibility (activity
item, notification, "Different on" markers) and the switches.

## 9. Security and privacy

| Risk | Mitigation |
| --- | --- |
| The Mac sees the phone's storage | Only places the user granted, plus `Download/Bridgey`. Listing is served only in mode `sender_picks`, and only folder names and two counts per folder. Hidden folders are not listed. No message returns file names, sizes, dates or contents from the phone |
| Broad storage access | None. `ManifestPermissionsTest` already pins the exact permission set; it stays as it is (plus `WAKE_LOCK` only if 6.3 needs it) |
| Path traversal | Strict portable names and manifest paths (5.1, 5.2); the receiver resolves components through document IDs and never builds file system paths from strings; MediaStore `RELATIVE_PATH` is built only from validated components; the Mac receiver never follows a symlink in the destination |
| A compromised paired Mac writes into places | It can already send files to `Download/Bridgey`. Folders add writes into granted places, bounded by free space, visible as transfers and in the activity stream. Replace from the Mac overwrites clashing files without a phone prompt (question 3 in section 13) |
| Crawling by browse requests | Places only in mode `sender_picks`; 4 requests in flight and 20 per 10 s; names only |
| Resource exhaustion | All limits in 5.4 checked before allocation; manifest at most 4 MiB in memory; one folder transfer per direction; every wait has a timeout |
| Replay | Message ID replay cache as today; `places.create_folder` repeats return the first answer; `folders.resolve` is valid only in its waiting state; journals are tied to peer and manifest digest |
| A peer changes my settings | Only the keys in 8.1, never feature switches, permissions, places or names; changes that share more are recorded with the device name |
| Logs and diagnostics | Folder code logs only state, error codes, counts and the first 8 characters of IDs: no names, paths, place labels, place IDs or listings. Diagnostics gain counters (folder transfers started, complete, incomplete, cancelled, by error code; file-count buckets) and nothing else. Today's single-file code logs file names (`PLUGIN file accepted name=...` on both platforms); remove those in the same series, also worth an upstream fix |
| Activity stream | Folder and destination names stay on the device under the existing bounds (200 items, 7 days, owner-only, no backup) |

## 10. Test plan

### 10.1 Unit tests

Shared: `protocol/test-vectors/folders-v1.json` (portable names, path checks, case clashes,
manifest digest of a fixed tree, settings merge cases), run by both platforms.

Android (`testDebugUnitTest`):

- `PortableNameTest`, `FolderPathTest`: the vectors; traversal, absolute, NUL, backslash,
  depth 33, 1,025-byte paths, NFD input, case clashes, idempotence.
- `FolderManifestTest`: page assembly (missing, repeated, out-of-order pages), count and size
  mismatch, digest mismatch, parent order, entry limits, 4 MiB cap.
- `ConflictNamingTest`: "name (1).ext", dotfiles, `archive.tar.gz`, file against folder,
  "Photos (1)" for folders, numbering skipping names already taken in the same transfer.
- `FolderReceiveSessionTest` over a fake `TreeStore` (in memory): every state, timeouts at each
  wait, cancel in each state, 50 failures, place revoked mid-way, resume bitmap, journal replay
  and part cleanup, Replace crash recovery.
- `SettingsSyncTest`: compare, local stamping with a clock behind and ahead, echo
  suppression, unknown keys, wrong types, schema mismatch, pair key mapping, upgrade stamps,
  forget device.
- `FeatureNegotiationTest`: a peer without the keys never gets folder or settings messages;
  draft keys.
- `ActivityLogTest`: new kinds and fields; the pinned field list updated.
- `FileSendQueueTest` (from the port) plus folder items.

macOS (`swift test`):

- `PortableNameTests`, `FolderPathTests`, `FolderManifestTests` (same vectors).
- `FolderScannerTests` on a temporary tree: symlinks to files and folders, a symlink loop, an
  alias, an `.app` bundle, `.DS_Store`, `._x`, other dotfiles with the setting on and off, an
  unreadable file, case clashes (a case-sensitive disk image), NFD names, depth and count limits.
- `FolderSendSessionTests`: pipelining window, `source_changed`, cancel, interruption, resume
  skipping, `folders.result` timeout.
- `SettingsSyncTests` (same cases as Android) and `FileSendQueueTests` with folder items.

### 10.2 Two-device checklist

OnePlus 11 with the personal Mac, then the work Mac. Other phones stay recorded as unverified.

| # | Check | Expected |
| --- | --- | --- |
| 1 | Mode (a): drop a folder with 3 levels, 2 empty folders, 50 files into Pictures/Trip | Same tree in the Files app, empty folders included; activity items on both devices |
| 2 | New Folder in the send sheet, then send into it | Folder created once, even after double clicks |
| 3 | Same folder again: Merge, then Replace files, then Save as new folder | "name (1).ext" copies; replaced files have the new content, others untouched; "Photos (1)" |
| 4 | Existing item is a file named like the folder | Only Save as new folder and Cancel |
| 5 | Leave the question unanswered (Mac in a; phone in b and c) | Cancelled after 3 minutes, nothing written, Send again offered |
| 6 | Mode (b): pick a place, then "Other folder…" with and without "Add to places" | Lands where chosen; no stray grant left when unchecked |
| 7 | Mode (c), then rename the default folder in the Files app | Next folder asks on the phone with the reason; Settings shows Access lost |
| 8 | `Download/Bridgey` without and with full access | Fallback limits as stated; empty-folder placeholder result recorded |
| 9 | 2,000 files of 10 KB; one 4 GB file; a mixed 10 GB folder | Throughput noted; under 60 s for the small files is the target |
| 10 | Wi-Fi off for 30 s mid-transfer | Resumes by itself; no duplicates; the cut-off file restarts |
| 11 | Force-stop the phone app mid-transfer, reopen | Part file removed; Resume works |
| 12 | Cancel from the Mac, then from the phone notification | Both rows incomplete; completed files kept; no partial left |
| 13 | Names: `a:b?.txt`, `CON.txt`, `notes.`, NFD `é`, emoji, 250-byte name, `a.txt` and `A.txt` from a case-sensitive volume | Names as in 5.1; renamed count shown |
| 14 | Symlinks, an alias, an `.app`, `.DS_Store`, `._*`, a `.git` folder with hidden files off and on, an iCloud-only file | Skips and counts as in 7.2 |
| 15 | USB-C stick (FAT32) granted as a place | Names valid on the stick; free space shown |
| 16 | Fill the phone to under the folder size | Refused before sending with needed and free space |
| 17 | Upstream 0.6 phone with the edition Mac, and the edition phone with an upstream Mac | No folder or settings messages either way; the edition Mac says the phone cannot receive folders yet |
| 18 | Sync: change reduce motion and previews on the phone | The Mac follows within a second; activity item on first sync |
| 19 | Sync: change the same setting on both while disconnected, reconnect | The later edit wins on both; no repeated updates in the log |
| 20 | Sync off on one side; forget device | "Off on <device>"; values kept; pair records removed |
| 21 | `adb logcat` and Mac Console during 1 to 20; export diagnostics | No file, folder or place names, paths or listings |

## 11. Build plan

Each step is one small reviewed commit (or a short series), green on RR CI checks before the
next. Size: S about a day, M two to three, L four to five.

| # | Step | Size | Notes |
| --- | --- | --- | --- |
| 1 | Port the multi-file queue onto `rr/main` | S | Below |
| 2 | Protocol and negotiation | M | Final text of the draft in `protocol.md`; schemas in `protocol/schema`; test vectors; feature keys (draft names); portable names, path checks, manifest codec and digest on both platforms; no UI. Update `rr-edition.md` ("unchanged wire protocol" becomes "plus negotiated draft extensions") |
| 3 | Folder send Mac to phone, mode (c) | L | Mac scanner and send session with pipelining; Android receive session, SAF writer, MediaStore fallback, a minimal journal (`p` lines) so a killed app leaves no part files; folder rows, notification, cancel, partial policy, activity items, Places screen with Add and Remove and the default folder picker; README line "Folders are not sent" replaced |
| 4 | Mode (a): places browsing | M | `places.*` on Android with rate limits; Mac send sheet with browse, New Folder and last destination |
| 5 | Mode (b): ask on the phone | M | Save to… sheet, notification channel, waiting state and countdown on the Mac, timeouts |
| 6 | Conflicts | M | Exists check and clash count, the question on both platforms, Merge, Replace (part written first, old file deleted only after verification, `r` journal lines), Save as new folder, the "When a folder already exists" setting |
| 7 | Resume | M | The rest of the journal (`v1`, `d`, `f` lines) on both sides, `resume` offers, bitmap, automatic resume and the Resume button. Not in the original list; it is needed for "resume after disconnect" |
| 8 | Settings sync | M | Store wrappers, messages, merge rules, General and device-page switches, first-sync item; every schema 1 key whose setting exists on at least one platform (the other stores and relays it) |
| 9 | Phone to Mac | M | Android tree picker and scanner, Mac receive session, Mac places in Settings |

Steps 3 to 7 can ship to Beta one by one; until step 6 lands, an existing folder is handled as
Save as new folder, never merged silently.

### 11.1 Porting the multi-file queue (`ed2c457`)

`ed2c457` is based on upstream `main` (`33a398c`), not `rr/main`. A trial merge
(`git merge-tree rr/main ed2c457`) shows `PairingCoordinator.kt`, `Pairing.swift`, both
`FileSendQueue` files, their tests, `FileDropWindow.swift`, `FileTransferWindow.swift`,
`protocol.md` and `README.md` apply cleanly. Conflicts:

- `MainActivity.kt`: `rr/main` deleted the old screens that `ed2c457` edited. Keep `rr/main`'s
  deletion and drop the old `DeviceScreen` and `TransferCard` hunks. The share path already
  merges to `pairing.sendFiles(content.files)`. Change the Stream picker by hand (`MainActivity.kt`
  line 421 on `rr/main`): `ActivityResultContracts.OpenMultipleDocuments()` calling
  `pairing.sendFiles(uris)`.
- `values/strings.xml` and `values-ru/strings.xml`: keep both sides (`file_queued`,
  `transfers_cancel_all` and the design B strings).

Steps: branch `rr/multi-file` from `rr/main`, `git cherry-pick -x ed2c457`, resolve as above,
then add what the new UI needs:

- `ui/Stream.kt` `TransferCardContent`: no progress bar and "Queued" for queued transfers;
  **Cancel all** on the live cards when more than one transfer is active.
- `BridgeyConnectionService.updateTransferNotifications`: skip queued transfers. As written,
  `ed2c457` marks queued files active, so 50 queued files post 50 ongoing "Cancel this file"
  notifications. Fix this on the upstream branch too before it is proposed.
- `ActivityRecorder.transferOutcome`: check that cancelled queued files record nothing and
  interrupted ones stay retryable.
- macOS: if design B's Stream panel has landed, carry `queued` into its transfer cards.

Then `testDebugUnitTest` (`FileSendQueueTest`) and `swift test` (`FileSendQueueTests`) on RR CI,
and the multi-file part of the two-device checklist (several files, cancel one, cancel all,
disconnect).

## 12. Upstream

The roadmap for v0.8 lists "Send multiple files and folders with a visible queue and
deterministic conflict handling", "Resume verified transfers after network interruption or
application restart" and "Browse only Android folders explicitly granted through the system
Storage Access Framework". This design answers those three:

- No branding in message kinds, keys, fields or file names. `bridgey-part` is already the
  upstream suffix.
- Follows upstream's patterns: encrypted payloads with `version`, the `features.update` map,
  the outer transfer ID for policy rejections, the `cancelledTransferIds` behaviour, existing
  chunk messages and limits.
- No new runtime permission on either platform; at most `WAKE_LOCK` (normal, no prompt) if
  6.3 shows it is needed.
- Proposal order: an issue with the protocol section, linking the v0.8 items; then the
  multi-file queue as a PR for upstream issue #18 (with the notification fix); then folders, places and resume as
  separate PRs. Settings sync is not on upstream's roadmap; offer it separately, framed under
  "per-device settings" for multiple devices.
- Until accepted, the edition uses the draft keys (D20), so edition and upstream clients
  never misread each other whatever upstream decides.
- "Upload to and download from granted folders" stays half done on purpose: upload is
  covered; download needs a separate capability and consent.

## 13. Open questions for Rahul

1. **Hidden files default (D9).** Off matches Finder; "as-is" could argue for on. Keep off,
   with the count and the one-click Include in the send sheet?
2. **Settings sync default on (D12).** Decided 2026-10-27: on, and setup's summary mentions it
   (see the settings sync decisions below).
3. **Replace without a phone prompt.** In mode (a) the Mac decides Replace, so a paired Mac can
   overwrite files in granted places. Add a phone-only switch "Allow other devices to replace
   files here" (default on), or leave it?
4. **Timeouts (D6, D11).** 3 minutes for questions, 30 minutes for automatic resume, 24 hours
   for the Resume button. Change any?
5. **Mode (b) sheet (D14).** A Bridgey sheet of places plus "Other folder…", rather than
   jumping straight into Android's picker. Fine?

## Decisions confirmed by Rahul (2026-10-25)

- Hidden files and system files are two separate options in the send sheet (and as defaults in Settings, Files), both off by default:
  - "Include hidden files": user dotfiles and dot-folders (`.gitignore`, `.env`, `.config/`) that are not system files.
  - "Include system files": operating-system clutter, matched by exact name, never by a broad pattern: `.DS_Store`, AppleDouble `._*`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`, `.DocumentRevisions-V100`, `.VolumeIcon.icns`, `.localized`, `Icon\r`, `Thumbs.db`, `ehthumbs.db`, `desktop.ini`, `$RECYCLE.BIN`, `System Volume Information`. The list lives in one shared constant on both platforms with a unit test.
  - A system file is excluded unless "Include system files" is on, even when "Include hidden files" is on. The skipped counts for each group are shown separately in the summary ("Skipped 12 hidden files, 48 system files").
- Settings sync: on by default; every change made by a paired device is recorded in the activity stream.
- Replace safety: a phone-only switch "Allow other devices to replace files here", off by default. Until it is on, a Replace chosen on the Mac asks on the phone first.
- Ask on the phone: a Bridgey "Save to..." sheet with granted folders and recent destinations, plus "Other folder..." for Android's picker.
- Timeouts as proposed: 3 minutes for questions, 30 minutes for automatic resume, 24 hours for the Resume button (not objected to; revisit after use).

## Decisions confirmed by Rahul (2026-10-27, settings sync)

- Feature switches sync too, similar to T3 Code: a change is saved to every connected device that
  supports it; a device that was offline or differs shows it, with Apply to all.
- First connect of a new device: ask once, "Use the same settings as <device>?" with Use these
  (adopt the other device's choices, features included) or Keep mine (keep local values, show
  Different on with Apply to all). After the answer sync runs silently; the answer is kept per device.
- Sync is on by default and setup mentions it: the summary has "Settings stay the same on your
  devices" with a switch, on both apps.
- A remote turn-on is an activity entry only ("Calls turned on from Work Mac"); a notification only
  when this device needs a permission for it.
- Reset > Settings resets only this device, as built: it takes the others' choices back on the next
  connect. No push to all.
- The Mac reads "Let the sending device choose" as Always save to Received files: keep.
- Rate limit of 20 settings messages per device per 10 seconds: keep.
