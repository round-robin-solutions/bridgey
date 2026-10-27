# Files 2.0: phone files, media and folders both ways

Status: built on `rr/files-browse` (2026-10-27), not yet device-tested. Second slice of Files 2.0
after [folders-and-settings-sync.md](folders-and-settings-sync.md). Wire:
[protocol.md](protocol.md#draft-phone-files-media-and-folders-both-ways), draft keys
`files_browse_draft1` and `folders_receive_draft1`, so upstream peers never see any of it.

It covers the rest of the upstream v0.8 items "Browse only Android folders explicitly granted
through the system Storage Access Framework", "Upload to and download from granted folders
without broad storage permissions" and "Improve Finder, Quick Look, Downloads, and
transfer-history integration", plus folders from the phone to the Mac.

Rahul's bar (2026-10-27): very optimised and seamless, as few system pickers as possible, recent
media and documents the way Telegram shows them, and media from the phone that feels instant.

## 1. What the user sees

### Mac

- **Phone files** window (panel button, Devices page): a phone picker and four sections.
  - **Photos and Videos**: the phone's gallery, newest first, date headers, video durations.
  - **Files**: recent documents from the phone's granted folders.
  - **Folders**: the granted places and `Download/Bridgey`, with a breadcrumb, sorting by name,
    date, size or kind, and paged loading.
  - **Recent from phone**: both, mixed.
  - Download (to Received files), Quick Look (space bar), drag out to Finder (file promises;
    each item downloads into the folder Finder names), drag in from Finder (upload into the open
    folder), Show in Finder. Remembers the last phone, section, place, path and sort.
  - Read-only banner while the phone does not allow changes; an explanation for a phone that
    does not allow browsing or runs an older Bridgey.
- **Send to phone** sheet (replaces the system panel for Send Files or Folders): recent files
  from Downloads, Desktop and Documents, recent screenshots, drop anywhere, **Browse…** as the
  fallback, target chips, the optimisation chip.
- **Menu-bar drops** (Settings › Files › "When I drop on the menu-bar icon"): show devices and
  Tray (default; tiles after 0.5 s of hover, a quick drop sends to the last device with a 5 s
  Undo toast and Send to…), always collect in the Tray, or always send at once.
- **Tray**: a floating shelf for files, folders, images, text and links; bookmarks, not copies
  (except in-memory drops), persists, clears after sending with Undo.
- **Before sending** (Settings › Files): photos original or 1280/2048/4096 px as JPEG or WebP at
  quality 60 to 90; strip location (on by default; camera and dates kept); videos original or
  HEVC 1080p/720p balanced or small; folders as-is or zipped; a live side-by-side preview of a
  bundled sample photo. A per-send chip overrides it. Originals are never modified; copies are
  cached by content hash.
- **Folders from the phone** land in Received files by default, or the Mac asks once with a
  Save panel (Settings › Files › Folders sent to this Mac). "When a folder already exists" works
  as on the phone, with the same question window and 3-minute countdown.
- **Finder**: every received file and folder gets "Where from: Bridgey: OnePlus 11"
  (`kMDItemWhereFroms`), optionally the Bridgey tag, and the Downloads stack bounces when the
  item lands in Downloads.
- **History** window: every finished send, receive, download and upload for 30 days (at most
  2,000), with search, filters (direction, device, result, folders) and Show in Finder. Show in
  Finder is also on every finished transfer row.

- **Quick wins** (Rahul, 2026-10-27):
  - **Share › Bridgey** (a share extension built by build-app.sh, sandboxed; new extensions start
    off, so turn it on in System Settings › Extensions › Sharing) and **Services › Send to Phone
    with Bridgey**. Both open a small "Send to" chooser with device tiles, Tray and the chip.
  - **Received-file notifications** with Open and Show in Finder; clicking opens the item; items
    from one phone less than 3 s apart update one notification ("12 files from OnePlus 11").
    While notifications are authorized they replace the automatic Finder reveal.
  - **Phone free space before big sends**: the send sheet, Tray, drop tiles and chooser show
    "Needs 2.3 GB, OnePlus 11 has 1.1 GB free" and block a send that cannot fit (warn when under
    1 GiB would remain). Phones report `defaultFreeBytes` in `places.listed` and `freeBytes` in
    `folders.accept`; the Mac asks at most once per 20 s per phone.

### Android

- **Attach sheet** (Send file, Send folder, the device page): tabs **Photos and videos** (recent
  media grid, numbered multi-select, inline permission card, partial-access banner), **Files**
  (recent documents; a one-time "Let Bridgey see your documents" card grants Documents through
  the folder picker), **Folders** (send a granted place as a folder), and **Browse…** (the
  system pickers, kept for rare cases).
- Settings › Files: **Let other devices browse this phone** (on by default) and **Allow other
  devices to change files here** (the old replace switch, off by default, now also governs
  uploads).
- Stream cards for folders the phone sends and for downloads the Mac asked for.

## 2. Decisions and judgement calls

| # | Decision | Source |
| --- | --- | --- |
| B1 | Browsing and downloading need only "Let other devices browse this phone", on by default; writing (uploads, Replace from the other device) needs "Allow other devices to change files here", off by default | Rahul ("browsing allowed, writing needs the switch"); default on is a call, one line to flip |
| B2 | The write switch reuses the replace switch's preference key, so the current value carries over | Call |
| B3 | Ordinary folders sent from the Mac's send sheet stay governed by "Folders sent to this phone"; the write switch gates only browser uploads | Call (keeps the first slice unchanged) |
| B4 | Downloads, single files included, are `into` folder transfers answering `places.download`: verified, journaled and resumable like folders | Call |
| B5 | Uploads never merge or replace: a clashing top-level item becomes "Name (1)" or "name (1).ext" | Call; deleting and renaming are out of scope |
| B6 | Recent documents come only from granted places (Android has no other way without broad permission); media from MediaStore with `READ_MEDIA_IMAGES` and `READ_MEDIA_VIDEO` (new), partial access handled | Rahul |
| B7 | Thumbnails: batched `media.thumbnails`, WebP (Android 11+) or JPEG, at most 24 KiB each, 256 px, visible first, `replaces` on scroll, a low-priority lane that yields to file chunks and control messages | Rahul's spec; sizes a call |
| B8 | Hover prefetch after 150 ms, at most 3 in flight, kept when more than half arrived, LAN routes only (Tailscale counts as relay) | Rahul |
| B9 | The Mac serves no places: folders from the phone use the Mac's own setting (Received files, or ask) | Call |
| B10 | Metadata stripping default: location only | Call (Rahul asked to choose) |
| B11 | Quick drop Undo: the send starts at once and Undo cancels what it started | Call (more seamless than holding for 5 s) |
| B12 | The menu bar moved from SwiftUI `MenuBarExtra` to an AppKit status item, so the panel can open from code without stealing a drag. The SwiftUI app's only scene is an uninserted `MenuBarExtra`: a lone `Settings` scene is opened by SwiftUI at launch as an empty window | Needed for menu-bar drops |
| B13 | WebP encoding on the Mac uses a bundled libwebp 1.4.0 (BSD), since macOS cannot encode WebP | Call |
| B14 | History keeps names whatever the Logging switch says (it is user-facing), but only in an owner-only file on the Mac; logs and diagnostics never carry names | Rahul |
| B15 | An offer never accepted may be re-offered after a reconnect with the same ID | Call (nothing was written) |
| B16 | The Share extension shows no UI of its own: it hands the items to Bridgey (private pasteboard plus a URL) and Bridgey shows the chooser | Call (one chooser for Share, Services and drops) |
| B17 | No Bridgey switch for local notifications exists; only macOS authorization governs them | Call |
| B18 | Free space unknown never blocks; a value older than 5 minutes only warns | Call |

## 3. Performance

Budgets from Rahul: grid first paint under 150 ms from the cache and under 500 ms cold on LAN;
scrolling at 60/120 fps; thumbnail fetches never block other traffic.

Measured so far (no phone yet; "simulated LAN" means a fake phone with 4 ms round trip, 30 to
40 MB/s, and 3 to 6 ms of phone work per thumbnail):

| Measure | Result | Where |
| --- | --- | --- |
| Grid first paint from the disk cache, 36 thumbnails | 11.9 ms median, 13.0 ms max | Mac, personal M4, `PhoneFilesPerfTests` |
| Grid first paint cold, simulated LAN, real 256 px JPEGs (23.7 KB average) | 100.8 ms median | Mac |
| Scrolling a 5,000-item grid in a real window, 900 frames | p50 0.24 ms, p95 3.25 ms, max 11.3 ms per frame | Mac |
| Hover to open, without prefetch | 73.2 ms median, 77.4 ms p95 | Mac, simulated LAN |
| Hover to open, with prefetch | 0.02 ms median (memory hit) | Mac |
| Controller: first 30 and all 200 thumbnails at 9 KB | 109 ms and 710 ms | Mac engine benchmark, simulated LAN |
| Controller: the same at 20 KB | 143 ms and 804 ms | Mac engine benchmark |
| Phone server: 10,000-entry folder listing | first page 77.5 ms, all 50 pages 631 ms | Android JVM benchmark |
| Phone server: one 64-thumbnail request, packing only | 104 ms | Android JVM |
| Phone sender: 2,000 files, 20 MB, scan, hash and manifest | 562 ms | Android JVM |
| Attach sheet: grid model for 5,000 items, 100 picked | 1.9 ms | Android JVM |
| WebP 3000x2000 to 1280 px on the Mac | 0.117 s | Mac |

Known limit: a 44 KiB batch holds one 24 KiB thumbnail (base64 inside JSON, then the encrypted
payload in base64 again), so batching pays off for thumbnails under about 10 KB. A binary chunk
form for thumbnails would double the density; deferred until device numbers show it matters.

To measure on devices: `BRIDGEY_PERF=1 swift test --filter PhoneFilesPerfTests` on the Mac for
the harness; with the OnePlus 11 connected, open Phone files cold (after clearing
`~/Library/Caches/in.roundrobin.bridgey/Thumbnails`) and warm, and time with
`/usr/bin/log stream --predicate 'subsystem == "in.roundrobin.bridgey"'` (state lines only, no
names). On the phone, Perfetto or `adb logcat` around opening the attach sheet.

## 4. Privacy and security

- Only granted places, `Download/Bridgey` (MediaStore shows only Bridgey's own files without a
  grant) and, with photo access, MediaStore photos and videos are visible. No
  `MANAGE_EXTERNAL_STORAGE`, ever.
- Refs are place, path and exact name, or a MediaStore ID; never URIs or paths. Hidden items
  and part files never resolve.
- Rate limits: browse lane 4 in flight and 40 per 10 s; media lane 4 active and 60 per 10 s.
- A download offer is accepted on the Mac only when the Mac asked for it.
- The Mac's thumbnail cache names files by SHA-256 digests (no names on disk), owner-only,
  about 300 MB, least recently used first. History is owner-only (0600 in a 0700 folder).
- Nothing logs names, paths, place labels or listings unless Privacy › Logging allows file names.

## 5. Deferred

- Phone-side send optimisation (the same options for sends from the phone).
- Streaming video playback from ranges (videos play after the original downloads; the first
  2 MB is cached on hover).
- Drag-out to Finder does not resume after the Mac app restarts (the journal stays, the file
  promise is gone); the Download button path resumes.
- Deleting, renaming and New Folder from the Phone files window.
- Hover prefetch on relay and metered routes (off until routes are classified).
- Several downloads in a row are asked one at a time.

## 6. Device checklist (OnePlus 11 with the personal Mac)

| # | Check | Expected |
| --- | --- | --- |
| 1 | Open Phone files cold, then again | Tinted placeholders, thumbnails within half a second; second open instant from cache |
| 2 | Scroll the gallery fast while a 2 GB file sends | Smooth scrolling; the file's speed does not drop noticeably |
| 3 | Rest on a photo, double click; press Space on a PDF | Preview appears at once; Quick Look opens after the download |
| 4 | Drag a photo and a folder to the Desktop; cut Wi-Fi mid-way | Finder progress; items land; resumes; copies on name clashes |
| 5 | Drop files on an open phone folder with "Allow other devices to change files here" off, then on | Refused with the banner; then uploaded, clashes as copies |
| 6 | Turn "Let other devices browse this phone" off | The Mac explains browsing is off; requests answer `policy` |
| 7 | Send a folder from the attach sheet (place) and through Browse… (tree), Mac on Received files and on Ask | Lands with its structure and Where from; conflict question on the Mac; no stray grant left on the phone |
| 8 | Attach sheet with full, partial and no photo access | Grid, banner with Select more, inline permission card |
| 9 | Menu-bar drop modes, Tray across a restart, Undo | As in section 1 |
| 10 | Optimised send of an iPhone photo (1280 px WebP) | WebP on the phone, no location |
| 11 | History search and Show in Finder; Forget device | Entries found; Forget removes that phone's entries |
| 12 | `adb logcat` and Console during 1 to 11 | No file names, paths or place labels |
