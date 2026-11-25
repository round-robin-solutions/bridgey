# Resuming a file from its last verified chunk (`files_resume_draft1`)

Status: draft, November 2026 (roadmap v0.8). The wire rules are in
[protocol.md](protocol.md#draft-resuming-files-files_resume_draft1); the shared vectors are
`protocol/test-vectors/files-resume-v1.json` (written by `protocol/tools/resume_vectors.py`). Built in the session
client (`rust/client`, the engine Windows and iOS use), the Android app and the Mac app, which all check the same
vectors. Folders are designed, not built.

## What it does

A file interrupted by a disconnect, a timeout or either app quitting continues after the bytes the receiver already
holds, instead of from byte zero. A retry (by the person, or by an app that retries on reconnect) sends a normal offer
marked `resumable`; a receiver holding a verified partial of that content from that device answers `files.resume` with
its verified length and the SHA-256 of those bytes; the sender checks the hash against its own file and answers
`files.resume.ack` with that offset, or 0. Chunks follow from there and the whole file's SHA-256 is checked before the
file is saved, as for any file.

## Decisions and why

| Choice | Why | Cost |
| --- | --- | --- |
| A contiguous verified prefix, not a map of blocks | One offset covers every interruption a single stream can have; chunks, pacing and acknowledgements stay as they are, JSON or binary. | A gap in the middle cannot happen, so nothing is lost by this. |
| The receiver decides the offset | It is the only side that knows what is on its disk. The sender can accept the offset or start from zero, nothing else, so a sender cannot make a receiver write anywhere new. | None. |
| Content identity (device, size, SHA-256), with a fresh `transferId` per attempt | Transfer IDs keep their replay guards and ownership rules (a reused ID would collide with the binary-frame sequence guard and the ended list). The sender keeps no resume state, so a resume works after the sender restarts and on any platform that hashes before offering, which all three do. | Two sends of the same file from the same device share a partial; the result is the same file, so that is harmless. |
| Offsets in whole 1 MiB blocks | The sender keeps the hash at every 1 MiB while hashing the file for the offer, so it checks a prefix without reading the file again. On Android the source may be a cloud document provider, where a second read could cost as much as the transfer. | 32 bytes per MiB on the sender (320 KiB for a 10 GiB file); up to 1 MiB less than the receiver held is resent. Files of 1 MiB or less are never resumable. |
| The receiver reads its prefix again before every resume | Proves the bytes on disk are the ones recorded, whatever happened to them meanwhile. Portable, unlike saving a SHA-256 implementation's internal state, which no platform library supports. | Reading up to 10 GiB at disk speed (seconds on a desktop, under a minute on a phone), off the session's thread; the sender waits up to 120 seconds for the answer. |
| `files.resume.wait` every 30 seconds while the receiver reads | A read longer than the 120 seconds (10 GiB on a slow external disk or a network share) would otherwise end in the sender's timeout and `files.cancel`, and a cancel deletes the partial; the next attempt would time out the same way. Each wait starts the sender's 120 seconds again, so the sender waits exactly as long as the read lasts. Simpler than a cancel that sometimes keeps the partial, and it cannot loop. | One outer message every 30 seconds during a long read. A receiver whose read hangs keeps the sender waiting until someone cancels. |
| The sender checks the receiver's prefix hash | A receiver whose partial and record are both wrong (a bug, or something with write access to the app's storage) gets the whole file instead of a doomed tail and a failed check at the end. | Nothing: the hash is already kept. |
| Fall back inside the same transfer (`offset: 0`) | One round trip and no new transfer ID when the prefix does not match. | None. |
| The partial stays where it was written; only the record is private | Saving stays an atomic rename in the same folder, with no copy of up to 10 GiB and no second free-space check. The record, in the app's private storage, is what the receiver trusts, and it checks the partial against it before use. | A hidden part file can sit in the receive folder for up to a day. Its bytes are the file the person was being sent, so it exposes nothing the finished file would not. |
| 24 hours, 4 per device, 16 and 20 GiB in all | The folders journal's window (Rahul, 26 October). Bounded disk even with a misbehaving paired device. | A partial older than a day starts again from zero. The older engine proposal's seven days was not adopted. |
| Record every 64 MiB and on every clean end, only synced bytes | A crash loses at most 64 MiB; the sync cost is spread out. A record written as a resumable file starts lets the next start sweep partials a crash left behind. Acknowledgements stay flow control: acknowledging is not syncing. | A sync every 64 MiB on the receiver. |
| Cancel and forget delete; interruptions keep | A cancel is the person saying they do not want the file. | None. |
| No automatic retry in the session client | The host decides when to send again (`FileFailed` with `interrupted`), as today. | Apps that want automatic resume on reconnect add it (recommended below). |
| The Android and Mac apps retry interrupted single files on reconnect, on by default | The coordinator's call under Rahul's "sensible default with customisation" rule: folders already resume by themselves, and a file that resumes from its offset costs little to retry. Settings > Files, "Resume interrupted files automatically", turns it off. | An interrupted file the person no longer wants comes back on reconnect unless they cancel it or turn the setting off. |

## Security in one paragraph

Protocol 2 sessions only; both messages are encrypted and pass the replay window. The receiver finds a partial by the
authenticated device and the content the offer states, in its own receive folder: no path, name, size or transfer ID
from the peer selects it, and a device reaches only partials it sent itself. The receiver proves what it holds with a
hash the sender checks against its own file; the receiver in turn trusts nothing the sender says beyond what the final
whole-file SHA-256 confirms. Records only accept partial names the client generates (`.bridgey-<uuid>.part`), so a
damaged record cannot point a deletion elsewhere.

## In the session client

- `rust/client/src/resume.rs`: the record store (claim, save, release, sweep, forget and the limits), the running
  hash with block checkpoints, the sender's answer, and both payloads. Unit tests check every vector.
- `rust/client/src/session.rs`: `resumable` on offers, `files.resume` and `files.resume.ack`, re-reading a partial on
  a blocking task, checkpoints, keeping partials when a session ends.
- `rust/client/src/client.rs`: records in the host's `Storage` under `file-resume`, the sweep at start,
  `Config::file_resume` and `Client::set_file_resume` (on by default), forgetting a device drops its partials.
- `rust/client/tests/files_resume.rs`: resume after the sender drops and restarts, after the receiver drops, after the
  receiver restarts (JSON chunks), a whole file kept, the source changed, a tampered partial, an expired partial, a peer
  without the key, cancels and forgetting, a re-read longer than the answer window (the waits keep the sender
  waiting) and a sender that hears no wait (it gives up at its window and the cancel takes the partial).
- `rust/client/src/vectors.rs` records `protocol/test-vectors/session-client-resume-v1.json`, a reconnect that
  resumes (the resumable offer, `files.resume.wait`, `files.resume`, `files.resume.ack` and only the tail in binary
  frames). The Android and Mac suites open every frame with their own code.

## In the Android and Mac apps

Both apps run the same rules as the session client, identical on the wire; the reference is `rust/client`.

- **Advertising.** `files_resume_draft1` on protocol 2 sessions only, never to agent devices; its place in the known
  draft keys is right after `files_fast_draft1` on both.
- **Sender.** The hashing pass keeps the SHA-256 at every 1 MiB (Android: `RunningHash.of` over the content URI; Mac:
  `ResumeHasher` in `OutgoingFileTransfer.init`). Single files over 1 MiB to a device with the key are offered
  `resumable`. The wait for the answer is 120 seconds and starts again at each `files.resume.wait` (Android: the offer
  coroutine; Mac: the row the 120-second stall sweep watches, refreshed by each wait). The answer comes from the kept
  hashes; the source then skips to the offset (Android: `skip()`, read through when a provider cannot seek; Mac:
  `FileHandle.seek(toOffset:)`), and a source that cannot reach it starts from zero with `unreadable`.
- **Receiver, Android.** Single files are pending MediaStore entries in `Download/Bridgey`, now always opened `"rw"`;
  a kept one is reopened `"rw"` (never `"w"`), re-read through a read-only descriptor, cut to the recorded length with
  its file channel and written from there. A provider that cannot open `"rw"` gets `"w"` and nothing is kept there.
  Records are `noBackupFilesDir/file-resume.json`, written atomically, naming each entry by its URI. Once per process,
  before any file arrives, the sweep drops records that can no longer be resumed and deletes this app's pending
  entries directly in `Download/Bridgey` that no record names (folders write below it and keep their own).
- **Receiver, Mac.** Single files are `name.bridgey-part` beside the name they reserve, opened with
  `FileHandle(forUpdating:)`; a kept one is reopened the same way, re-read, then `truncate(atOffset:)` and
  `seekToEnd()`. Records are `file-resume.json` in the Application Support folder (owner-only). The final name is
  chosen when the file is saved: the reserved one while it is free, else the next free one, never overwriting.
- **Both.** The partial is synced before a record names its bytes: at the start of a resumable file (nothing verified),
  every 64 MiB, and when it is kept. A disconnect, this end's own stall timeout or quitting keeps a resumable partial
  (`cancelTransfers` and the stall sweep now do); a cancel from either side, a failed check, an invalid answer or
  chunk, a changed source and forgetting the device delete it. The re-read runs off the session's thread, with
  `files.resume.wait` every 30 seconds, and it keeps the row alive so the stall sweep never ends a check. A resumable
  send that stops moving (no acknowledgement in time, or a failed write, while the session still looks alive) ends as
  interrupted without `files.cancel`, so the receiver keeps its partial and automatic retry picks the file up; seen in
  the live check, where a receiver killed over a Connect anywhere tunnel left the session up for another 50 seconds.
- **Resume interrupted files automatically** (Settings > Files, on by default; Android `files.auto_resume`, Mac
  `settings.files.autoResume`, on that device only, not synced). Single files a disconnect interrupted to a device that
  showed the key (the one in flight and the queued ones) go again, in their order, through the same path as Retry
  when that device reconnects with Files on within 24 hours. Off, they wait for Retry as before. The list lives in
  memory: a sender that restarts forgets it (the receiver's partial still resumes when the file is sent again).
- **Tests.** Android: `FileResumeVectorTest` (every vector), `SessionClientResumeVectorTest` (the recorded resume,
  frame by frame) and `FileResumeSessionTest` (the real coordinator against a fake Mac over loopback and a fake
  MediaStore: both directions, drop and restart on either side, a whole file kept, mismatch and invalid answers,
  tampered, expired and orphaned partials, a changed source, a peer without the key, cancels, forgetting, the waits
  and automatic retry on and off). Mac: `FileResumeVectorTests`, `SessionClientResumeVectorTests` and
  `FileResumeMatrixTests` (the same matrix through the app's transfer classes, connected in process).
- **Folders** (later): replace "delete the in-progress file" in the interruption paths and journal recovery with a
  kept line carrying entry, part, length and prefix SHA-256; add `partial` to `folders.accept` and `offset` to the
  entry's offer.

## Not covered

- Resuming into another receive folder: the partial stays put and expires.
- Clipboard files and Phone files downloads (folders) until the folder design is built.
- Measured gains on real Wi-Fi and phones; the tests run on loopback.
- In `rust/client` a sender's own stall timeout mid-transfer still sends a plain `files.cancel`, which deletes the
  receiver's partial. The apps end a resumable send that stops moving as interrupted instead (below).
