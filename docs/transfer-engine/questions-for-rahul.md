# Transfer engine: questions for Rahul

You asked to be asked as many questions as needed. These are every decision the design leaves to you,
grouped and ordered by how much they change the product. Each has 2 to 4 options; the first is the one
we recommend, and each option has one line on what it means for you.

**How to answer:** reply with the ID and the option number, for example "A1 1, A2 2, C3 3". Anything
you skip is built with the recommended option and listed as an open call in the release notes, so you
can still change it. The design is in [design.md](design.md); the words "piece" and "block" below mean
a 1 MB part of a file.

## The 10 that matter most

| | Question | Recommended |
| --- | --- | --- |
| 1 | [A2](#a2-how-much-checking-before-a-file-counts-as-saved) How much checking before a file counts as saved | Check every piece on arrival and read the saved file back once |
| 2 | [A3](#a3-the-original-file-changes-during-the-transfer) The original file changes during the transfer | Send the new version, re-sending only what changed |
| 3 | [A4](#a4-how-long-bridgey-keeps-resuming-on-its-own) How long Bridgey keeps resuming on its own | Until the unfinished data expires |
| 4 | [A5](#a5-how-long-unfinished-transfers-are-kept) How long unfinished transfers are kept | 7 days after the last progress |
| 5 | [A6](#a6-what-restart-transfer-does) What "Restart transfer" does | Unfinished files start over; saved files stay |
| 6 | [A1](#a1-when-a-transfer-counts-as-complete) When a transfer counts as complete | Only when every file was saved and verified |
| 7 | [B1](#b1-the-largest-single-file) The largest single file | No product limit, tested to 1 TB |
| 8 | [C1](#c1-wi-fi-drops-and-the-phone-moves-to-mobile-data) Wi-Fi drops and the phone moves to mobile data | Pause and ask above your 100 MB setting |
| 9 | [G2](#g2-when-the-engine-ships) When the engine ships | With Connect anywhere's new connection |
| 10 | [D1](#d1-many-small-files-into-a-phone-folder-you-granted) Many small files into a granted phone folder | Temporary name, then rename, for every file |

## A. What "very robust" means

### A1. When a transfer counts as complete

Some files of a folder can fail (one was deleted on the Mac while sending), and you can skip a file
yourself.

1. **Recommended: only when every file was saved and verified.** Anything else shows "Incomplete",
   with the list and a Retry button. Files you skipped yourself are listed but do not make it
   incomplete.
   → The card tells the truth at a glance: 1 failed file out of 1,250 shows as Incomplete.
2. Complete when every file was saved, verified or skipped for any reason; failures appear only in the
   details.
   → Calmer cards, but failures are easy to miss.
3. Complete only when every file was saved; even files you skipped make it incomplete.
   → The strictest reading: skipping a file always leaves the transfer marked incomplete.

### A2. How much checking before a file counts as saved

1. **Recommended: check every piece when it arrives, and read the saved file back once to check it
   again.**
   → About a minute extra per 50 GB on the phone, mostly hidden while the transfer runs; catches
   faults in saving and in the storage itself.
2. Check every piece when it arrives, nothing more.
   → No extra time; a fault while saving, or in the phone's storage, would go unnoticed.
3. Option 1, plus the sending device reads the original once more at the end.
   → The slowest; also catches edits to the original that leave no trace in its date.

### A3. The original file changes during the transfer

For example, you export a video again, or a log file keeps growing. This also covers changes while a
transfer is paused.

1. **Recommended: send the new version.** Bridgey waits until the file stops changing, then re-sends
   only the parts that changed.
   → You always end with the latest version; the changed parts cost a little extra time.
2. Stop that file and ask: "Send new version" or "Skip".
   → Nothing happens without you, but a long transfer can sit waiting for your answer.
3. Mark the file as failed ("changed while sending") and carry on with the others; Retry sends the new
   version.
   → The report shows exactly what happened; you retry by hand.

### A4. How long Bridgey keeps resuming on its own

The folders plan you confirmed resumes automatically for 30 minutes, then shows a Resume button for
24 hours. That was set when a file cut off half-way had to start again from zero. The engine keeps the
unfinished data, so it can afford to wait longer.

1. **Recommended: keep resuming automatically whenever both devices can reach each other, until the
   unfinished data expires (A5).**
   → A laptop closed over the weekend carries on by itself on Monday; your mobile data setting still
   applies.
2. Automatically for 30 minutes, then a Resume button until the data expires.
   → You decide about late resumes; after a longer break you tap Resume.
3. Automatically for 24 hours, then a Resume button.
   → A middle way.

### A5. How long unfinished transfers are kept

1. **Recommended: 7 days after the last progress, with a reminder a day before.**
   → Matches Android's own clean-up of hidden unfinished downloads; at most a week of space used.
2. 30 days.
   → Very long breaks can still resume; unfinished data can hold space for a month.
3. 24 hours.
   → Space comes back quickly; a weekend away means starting again.

### A6. What "Restart transfer" does

1. **Recommended: the unfinished files start again from the beginning; files already saved stay as
   they are.**
   → Fixes a transfer you don't trust without sending everything twice.
2. Send everything again and replace what already arrived.
   → A completely fresh copy; doubles the work for a large folder.
3. Send everything again as new copies ("Photos (1)"), leaving the first ones.
   → Nothing is replaced; you get duplicates to clean up.

### A7. A file that is still being written

A video export or a download that keeps changing.

1. **Recommended: wait up to a minute for it to settle; if it keeps changing, mark it "still being
   written" with Retry.**
   → Avoids sending half-finished exports; at most a minute's delay for that file.
2. Send it as it is at that moment and warn in the report.
   → Quicker; you may receive an unfinished export.
3. Wait as long as it takes.
   → Never sends a moving file; one that never settles holds up the transfer.

### A8. The other device lost the unfinished data

For example, Bridgey was reinstalled there or its data was cleared.

1. **Recommended: start again from zero automatically if less than 1 GB is left; above that, ask.**
   → Small transfers recover by themselves; big ones never re-send gigabytes without you.
2. Always start again automatically.
   → No questions; can re-send many gigabytes unasked.
3. Always ask.
   → Full control; even tiny transfers wait for you.

## B. Sizes and storage

### B1. The largest single file

Today the limit is 10 GB.

1. **Recommended: no product limit, tested up to 1 TB.** Only free space and the drive's format limit
   it (FAT32 drives cannot hold files over 4 GB).
   → Matches "any size"; we test files of 500 GB to 1 TB.
2. 100 GB.
   → Less to test; large video archives won't fit in one file.
3. Keep 10 GB.
   → No change; Bridgey won't replace Blip for big files.

### B2. The most files in one transfer

The folders plan allows 10,000 files and 2,000 folders.

1. **Recommended: 100,000 files and 20,000 folders.**
   → A whole photo library in one go; very large folders take a few minutes to scan and check first.
2. Keep 10,000 files and 2,000 folders.
   → Simpler; big libraries go in parts.
3. 1,000,000 files.
   → Almost anything fits; slower to scan, more memory on the phone.

### B3. Free space Bridgey always leaves on the receiving device

1. **Recommended: at least 2 GB or 5% of the storage, whichever is larger.**
   → The phone never fills to the brim; the transfer pauses with "needs 3.2 GB more".
2. 500 MB.
   → More room for transfers; the phone can get uncomfortably full.
3. No reserve.
   → Every byte usable; apps and the system misbehave on a full phone.

### B4. When space runs low, may Bridgey delete other unfinished transfers to make room?

1. **Recommended: no, never.** It pauses the new transfer and says how much space it needs.
   → Progress is never thrown away without you.
2. Yes, the oldest paused transfers first.
   → New transfers keep going; old ones may have to start over.
3. Ask each time.
   → You decide; the transfer waits for your answer.

### B5. Reserve a file's full size when it starts

1. **Recommended: yes, where the storage allows it (phone storage, Mac, Linux).**
   → A file never runs out of space half-way; free space drops as soon as the file starts.
2. No, take space as the data arrives.
   → Free space shrinks gradually; a full disk can stop a file half-way (it then pauses).

## C. Network, battery and data

### C1. Wi-Fi drops and the phone moves to mobile data

Your setting from Connect anywhere: ask before using mobile data above 100 MB.

1. **Recommended: pause and ask if more than your threshold is left; with Data Saver on, always ask.**
   → No surprise data use; a long transfer waits for a tap when you leave home.
2. Carry on over mobile data if you already approved this transfer once.
   → Fewer taps; one approval can cost many gigabytes.
3. Always pause on mobile data and continue on Wi-Fi.
   → Transfers never use mobile data.

### C2. Large transfers through the relay

When no direct route works, data goes through our relay servers, which have daily limits.

1. **Recommended: use the relay within its limits, and pause with a clear reason when the limit is
   reached.**
   → Transfers work from anywhere; very big ones can take days over the relay.
2. Ask before relaying more than 1 GB.
   → Protects the relay budget; one more question when you are away from home.
3. Never relay large transfers; wait for a direct route or the same Wi-Fi.
   → Saves relay capacity; a transfer from a cafe may never start.

### C3. Battery

1. **Recommended: pause big transfers below 15% when not charging; continue at 20% or on the charger.**
   → A transfer never empties your phone; "Continue anyway" is one tap.
2. Never pause for battery.
   → Transfers always continue; a 50 GB upload over 4G can use about half the battery.
3. Pause below 30%.
   → Kinder to the battery; pauses more often.

### C4. The phone gets hot

1. **Recommended: slow down when Android says the phone is warm, pause when it says it is too hot,
   continue when it cools.**
   → Protects the phone on hot days; transfers are slower then.
2. Never slow down or pause.
   → Full speed always; the phone may get uncomfortably hot.

### C5. When to ask for permission to run in the background

OnePlus phones close apps aggressively. Android's "don't optimise battery" permission helps Bridgey
keep long transfers going.

1. **Recommended: at the first transfer that will take longer than 10 minutes, with a short
   explanation; and show a OnePlus checklist once if the phone closes Bridgey during a transfer.**
   → You are asked only when it matters; the first long transfer has one extra screen.
2. During onboarding.
   → Set up from day one; one more onboarding step for everyone.
3. Never ask; explain it in Settings only.
   → No prompts; long transfers get interrupted more often on OnePlus.

### C6. Keep the Mac awake during transfers

1. **Recommended: yes, the Mac doesn't fall asleep on its own while bytes are moving.** Closing the lid
   still sleeps it.
   → Long transfers finish overnight; the Mac stays awake while it transfers.
2. No, let it sleep and continue when it wakes.
   → Saves the Mac's battery; transfers stop whenever the Mac idles.

### C7. After the phone restarts

This adds Android's "start at boot" permission, which shows no prompt.

1. **Recommended: start Bridgey in the background after a restart when a transfer is waiting.**
   → Transfers continue after restarts and updates without you opening the app.
2. Only continue when I open Bridgey.
   → Nothing starts by itself after a restart.

## D. Folders and where files land

### D1. Many small files into a phone folder you granted

Android's folder access is slow per file (tens of milliseconds per call), and writing each file under
a temporary name and renaming it doubles the calls.

1. **Recommended: temporary name, then rename, for every file.**
   → A half-written file never appears, even after a crash; folders of many small files take up to
   twice as long.
2. Files up to 1 MB go straight to their real name, after they were checked in memory.
   → Up to twice as fast for photo-sized files; after a crash, one small file can show half-written
   until Bridgey starts again and cleans it up.

### D2. A file over 4 GB going to a FAT32 USB drive or SD card

FAT32 cannot store such files.

1. **Recommended: refuse that one file before sending, with the reason, and send the rest.**
   → Clear, and nothing is wasted.
2. Refuse the whole transfer and suggest another folder.
   → All or nothing; you pick another place.

### D3. Files added to a folder after you pressed Send

1. **Recommended: send what was there when you pressed Send; list any newer files in the report.**
   → Predictable; a quick second send picks up the rest.
2. Include files added before the transfer finishes.
   → Catches late additions; a folder that keeps growing may never finish.

### D4. Where the Mac keeps unfinished files

1. **Recommended: in Bridgey's own folder on the same disk, moved into place once verified.**
   → Nothing half-finished appears in Downloads; iCloud and Dropbox never upload partial files; Time
   Machine skips them.
2. Next to the final file as a hidden ".name.bridgey-part" file, as today.
   → Familiar; hidden partial files sit in the folder and sync apps may pick them up.

## E. Reports and history

### E1. How long full reports of finished transfers are kept

A full report has every file's name and checksum. The activity stream keeps 7 days.

1. **Recommended: 30 days, then only counts and sizes, for a year.**
   → Enough to check last month's transfers; names don't linger.
2. 7 days, like the activity stream.
   → The least kept.
3. 90 days.
   → Longer proof of what moved; names kept for three months.

### E2. Checksums in the report

1. **Recommended: a short BLAKE3 checksum per file in the details, with "Copy checksums" and "Export
   report"** (a file anyone can check with the free `b3sum` tool).
   → Anyone can verify independently; technical, but tucked into the details.
2. Also a standard SHA-256 for every file.
   → Familiar to more tools; one more full read of every file on the sending device.
3. No checksums shown, only "verified".
   → The simplest screen; no independent check.

### E3. Notifications

1. **Recommended: one progress notification per transfer while it runs, and one when it ends.**
   → You always know where things stand; a busy day means a few notifications.
2. Only when it ends or needs you.
   → Quieter; progress only inside the app.
3. Only when something needs you.
   → Quietest; finished transfers are silent.

## F. Several transfers and devices

### F1. Several transfers to the same device at once

1. **Recommended: up to 3 at once in each direction; the rest wait their turn.**
   → A quick photo doesn't wait behind a 50 GB file.
2. One at a time.
   → The simplest to follow; a big send blocks small ones.
3. No limit.
   → Everything starts at once; each one is slower.

### F2. The same files to several devices at once

1. **Recommended: allowed.** Pick more than one device; Bridgey reads the files once and sends to each
   in parallel.
   → One action for two Macs.
2. One device at a time.
   → Simpler; you send twice.
3. Later, not in this release.
   → Less to build now.

### F3. The order of files in a folder

1. **Recommended: the folder's own order, as Finder lists it.**
   → Early files are usable first; progress is easy to follow.
2. Smallest first.
   → Many files finish quickly; big ones come last.
3. Largest first.
   → The longest wait comes first.

### F4. You send a file that is already on its way to the same device

1. **Recommended: ask, "Already sending video.mp4 to MacBook. Send another copy?"**
   → Avoids accidental duplicates from a double tap.
2. Send another copy without asking.
   → No question; double taps make duplicates.
3. Ignore the second send.
   → No duplicates; you can't send a second copy on purpose while the first is running.

### F5. A transfer paused on one device: who can resume it?

1. **Recommended: either device.**
   → Pause on the Mac, resume later from the phone.
2. Only the device that paused it.
   → No surprises if someone else is using the other device.

## G. Release and compatibility

### G1. The other device runs an older or upstream Bridgey that can't resume

1. **Recommended: an interrupted file under 1 GB starts again from zero automatically; bigger files show
   Retry.**
   → Small files just work; big ones never re-send gigabytes silently.
2. Always start again automatically.
   → No taps; a large file can be re-sent many times.
3. Never; always show Retry.
   → Every interruption needs a tap.

### G2. When the engine ships

The engine needs Connect anywhere's new connection (QUIC) for its speed and its resume.

1. **Recommended: in the same release as Connect anywhere's new connection.**
   → One way of moving data to test and support.
2. Earlier, on home Wi-Fi only, over a separate connection built for it.
   → Resume arrives sooner; we build and test a data path that is thrown away later.
3. Later, once Connect anywhere has shipped and settled.
   → The least risk; Blip-level resume arrives last.

### G3. Testing before the release

You said this ships in one release.

1. **Recommended: Nightly builds carry the engine behind a hidden developer switch, off by default; the
   release turns it on for everyone.**
   → Weeks of testing on real devices without exposing it.
2. Separate test builds only, never in Nightly.
   → Nightly stays clean; fewer real-use test hours.
3. Beta builds too, switched on.
   → More real-world testing; Beta users meet bugs first.

### G4. Offer the engine to upstream Bridgey

1. **Recommended: yes, after our release: the protocol text, the Rust crate and its tests, as
   Connect anywhere plans.**
   → Good for the project; upstream may not want Rust inside its apps.
2. The protocol text only.
   → Less to maintain together.
3. Keep it edition-only.
   → No coordination needed; the two apps drift apart.

### G5. The Beta period before Stable

1. **Recommended: 14 days on your devices, with at least 200 GB moved and no serious bug** (test plan
   gate G14).
   → A measured bar before everyone gets it.
2. 7 days.
   → A faster release; less time to find rare problems.
3. 30 days.
   → More confidence; a later release.

### G6. Faster Mac networking through Apple's private APIs

The QUIC library can use undocumented macOS calls that send packets in batches (several times faster in
its own benchmark), but its authors warn they "may crash on unsupported OS versions".

1. **Recommended: not now; measure the normal path first and decide with numbers.**
   → Safe; on very fast networks the Mac may be the slower side.
2. Yes, use them.
   → Faster Mac transfers; a macOS update could break networking until we ship a fix.

## H. Safety and privacy

### H1. Big transfers arriving from your own devices

Today a paired device can send files without a prompt on the phone.

1. **Recommended: keep it that way for your own devices.** Agent devices follow their grants (2 GB per
   transfer and 5 GB a day by default).
   → No prompts between your own devices.
2. Ask on the phone above 5 GB.
   → Protects space from surprise huge sends; one tap for big transfers.
3. Always ask.
   → Full control; every transfer needs a tap.

### H2. What an exported report contains

1. **Recommended: file names, sizes, checksums and status.**
   → Useful proof of what moved; treat the file as private.
2. Checksums and sizes only, without names.
   → Safer to share; harder to read.

## Already decided elsewhere

These come from earlier decisions and are built in as they stand:
- **Mobile data:** "Ask before using mobile data above", default 100 MB, adjustable (Connect anywhere,
  decision 7).
- **Relay pool and caps,** Cloudflare as backup with USD 0 of paid spend (Connect anywhere).
- **Folders:** the three destination modes, the clash question (Merge, Replace files, Save as new
  folder), the phone-only "Allow other devices to replace files here" switch (off by default), the
  3-minute question timeout, hidden and system files as separate options (folders spec). A4 proposes
  replacing its 30-minute and 24-hour resume times now that partial files survive.
- **Clipboard:** items up to 25 MB are sent right away; the clipboard cache keeps data for 24 hours and
  at most 2 GB (clipboard-files spec).

Judgement calls made in the design without asking are listed in
[design.md section 20](design.md#20-calls-made-in-this-design).
