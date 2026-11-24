# Resuming a file from its last verified chunk (`files_resume_draft1`)

Status: draft, November 2026 (roadmap v0.8). The wire rules are in
[protocol.md](protocol.md#draft-resuming-files-files_resume_draft1); the shared vectors are
`protocol/test-vectors/files-resume-v1.json` (written by `protocol/tools/resume_vectors.py`). Built in the session
client (`rust/client`, the engine Windows and iOS use). The Android and Mac apps build it next, against this page and
the vectors. Folders are designed, not built.

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
| The Android and Mac apps retry interrupted single files on reconnect, on by default | The coordinator's call under Rahul's "sensible default with customisation" rule: folders already resume by themselves, and a file that resumes from its offset costs little to retry. Settings > Files, "Resume interrupted files automatically", turns it off. | A file the person gave up on comes back if they do not cancel it; the row says it is resuming. |

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

## For the Android and Mac apps

- **Advertise** `files_resume_draft1` on protocol 2 sessions only, as a capability. Add the two kinds to the contract
  tests' scans and decode `files-resume-v1.json`.
- **Sender**: keep the SHA-256 at every 1 MiB while hashing for the offer (Android: the first pass over the content
  URI; Mac: `OutgoingFileTransfer.init`). Mark single files over 1 MiB `resumable` (not clipboard files). Wait 120
  seconds for the answer. On `files.resume`, answer from the kept hashes, then skip to the offset (Android: `skip()` on
  the input stream, or `position` on a file channel; Mac: `FileHandle.seek(toOffset:)`).
- **Receiver, Android**: single files are pending MediaStore rows opened with `"w"`. Reopen a kept row with `"rw"`
  (never `"w"`, which may truncate), cut it to the recorded length and seek to the end. Persist the row's URI in the
  record (private storage, not SharedPreferences shared with the attach draft). Sweep at start, and delete pending
  rows in `Download/Bridgey` that no record names (they leak today after a process death). If a provider cannot reopen
  `"rw"`, do not keep partials there.
- **Receiver, Mac**: single files are `name.bridgey-part` beside the final name. Keep them on interruption, reopen with
  `FileHandle(forUpdating:)`, `truncate(atOffset:)` and `seekToEnd()`. Records go in Application Support. Choose the
  final name when saving (a kept part already reserves its name today), never overwriting.
- **Both**: call `synchronize()` / `sync()` before writing a record, every 64 MiB and when a session ends. Today
  `cancelTransfers` on a disconnect deletes the partial; change it to keep resumable ones and delete only on cancel,
  verification failure or forget.
- **Folders** (later): replace "delete the in-progress file" in the interruption paths and journal recovery with a
  kept line carrying entry, part, length and prefix SHA-256; add `partial` to `folders.accept` and `offset` to the
  entry's offer.
- **Recommended product default**: retry interrupted single files automatically when the device reconnects within the
  24 hours, as folders do, with a switch to turn it off; the receiver keeps nothing beyond the limits above either way.

## Not covered

- Resuming into another receive folder: the partial stays put and expires.
- Clipboard files and Phone files downloads (folders) until the folder design is built.
- Measured gains on real Wi-Fi and phones; the tests run on loopback.
