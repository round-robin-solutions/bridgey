# Transfer engine: design

Status: proposed design for Bridgey by Round Robin, 2026-10-25. Design only; nothing is built.
Findings and sources: [research.md](research.md). Robustness plan and release gate:
[test-plan.md](test-plan.md). Decisions needed: [questions-for-rahul.md](questions-for-rahul.md).
Phases: [build-plan.md](build-plan.md). Where this differs from the large-transfer section of
[connect-anywhere.md](../connect-anywhere.md#8-large-file-transfer-transferv1), this document
replaces it. Values marked "(question X)" are proposals waiting for Rahul's answer.

## 1. Summary

- **One engine for every bulk byte.** A Rust crate, `bridgey-transfer`, moves single files,
  multi-file sends, folders, clipboard items and agent CLI sends between paired devices. Android
  and the Mac call it through UniFFI; the CLI links it directly; Windows and Linux reuse it in v2.
- **Resume inside a file.** Files are cut into 1 MiB blocks. The receiver keeps a ledger of the
  blocks that are on storage and synced. After a dropped connection, an app kill, a reboot or a
  power cut, only missing blocks move again.
- **The receiver drives.** It asks for ranges, decides what is durable and tells the sender. The
  sender serves.
- **BLAKE3 everywhere.** Every 1 MiB block has a 32-byte tree hash; the whole-file hash equals
  what `b3sum` prints. Each block is checked before it is written, the saved file is read back and
  checked again before it gets its real name, and the report lists every file's hash and can be
  exported for `b3sum --check`.
- **Source changes are caught block by block.** The sender re-hashes every block it sends. A file
  that changed is sent as its new version, reusing the blocks that did not change (question A3).
- **A ledger people can see.** Every transfer and every file has a state and, when something did
  not arrive, a reason in plain words: "1,248 of 1,250 files verified; 2 failed". Resume, Restart,
  Retry failed, Pause and Cancel act on it.
- **Atomic finalise on every platform**, with recovery of steps that were cut off half-way.
- **On the connect-anywhere tunnel.** Control messages travel on the existing encrypted session;
  bulk data on QUIC unidirectional streams. Upstream and older peers keep today's `files.v1`, and
  those transfers are recorded in the same ledger.
- **Built to survive phones.** It runs inside the existing `connectedDevice` foreground service,
  resumes after OEM battery killers and reboots, and holds the Mac awake only while bytes move.
- **Tested to a gate.** The core is sans-IO, so it runs under deterministic simulation with fault
  injection; property tests, fuzzing, kill and power-loss loops, a real-network matrix and soak
  tests feed a measurable release gate.

## 2. What the engine promises

These are the properties every test in [test-plan.md](test-plan.md) checks.

| # | Promise |
| --- | --- |
| P1 | **Nothing goes missing silently.** Every item ends in exactly one of: saved and verified, failed (with a reason), skipped (with a reason), or cancelled. A transfer that cannot move shows why within 10 seconds. |
| P2 | **No half-written file under a real name.** A file gets its final name only after it is verified (one optional exception: question D1). |
| P3 | **No overwrite unless Replace was chosen**, and then only after the new file is verified. |
| P4 | **Exact copy.** A saved file is byte for byte the sender's file as the sender read it. If the source changed during the transfer, the engine notices and follows the change policy; it never saves a mix of two versions. |
| P5 | **Progress survives.** A network drop re-sends at most the partly received block on each stream (up to 1 MiB each) plus the data that was still on the network (about one round trip's worth, never more than the connection's flow-control window: 16 MiB, or 32 MiB on a Mac or Linux LAN). An app kill re-sends only blocks that never reached storage. After a power cut, recently written blocks are re-checked by hash. |
| P6 | **Resume is automatic** while the partial data exists, unless someone paused the transfer. |
| P7 | **Bounded resources.** At most 32 MiB of buffers per transfer on a phone; partial data never pushes free space below the reserve. |
| P8 | **Both sides agree.** The sender marks a file done only after the receiver confirms it saved and verified it. After reconnecting, both devices show the same counts. |
| P9 | **Names stay private.** File names and checksums live only in the local ledgers, never in logs or diagnostics, and go away with history and Forget device. |

## 3. Plain words

| Term | Meaning |
| --- | --- |
| Block | A 1 MiB (1,048,576-byte) piece of a file. The last block is shorter. |
| Chaining value (CV) | BLAKE3's 32-byte hash of one block, as part of the whole file's hash tree. |
| Root | The BLAKE3 hash of the whole file: the same value `b3sum` prints. |
| Outboard | A file's list of chaining values, kept next to the ledger: 32 bytes per MiB. |
| Ledger | Each device's own record of its transfers: an SQLite database plus small side files. |
| Partial | The unfinished file on the receiving device, hidden until it is verified. |
| Durable | Written, synced to storage and recorded in the ledger. |
| Finalise | Giving a verified file its real name in its real folder, in one atomic step. |
| Snapshot | What the sender noted about a source file: size, modification time and file identity. |
| Place | A phone folder the user granted once (folders spec). |
| Attempt | One run of a transfer between two interruptions. |

## 4. Architecture

### 4.1 Where it sits

```text
 Android app (Kotlin)            Mac app (Swift)              bridgey CLI (Rust)
  share sheet, Stream,            drop window, Stream,          bridgey send,
  folders, clipboard              folders, clipboard            bridgey transfers
         \  UniFFI                      /  UniFFI                      |
          +----------------------- bridgey-transfer -------------------+
          | engine: scheduler, policies, ledger (SQLite), hash workers  |
          | core (sans-IO): state machines, codecs, manifest, BLAKE3    |
          | host adapters: sources, destinations, power, network (native)|
          +-------------------------------+-----------------------------+
                                          | control: encrypted session messages (stream 0)
                                          | data: QUIC unidirectional streams
                                 bridgey-connect (routes, ICE, TURN, QUIC)
```

### 4.2 Crates

| Crate | Contents | Does I/O |
| --- | --- | --- |
| `bridgey-transfer-core` | State machines (transfer, item, block), request scheduler, policies, wire codecs, manifest validation, BLAKE3 tree helpers, the ledger model in memory, event and action types. `Core::handle(Event) -> Vec<Action>` | No: no sockets, files, clocks, threads or randomness |
| `bridgey-transfer` | Driver: tokio tasks, quinn streams through `bridgey-connect`, the SQLite ledger (`rusqlite`, bundled SQLite), hash worker pool, host adapter traits, platform sync rules, startup recovery | Yes |
| `bridgey-transfer-sim` | Deterministic harness: simulated network, storage and clock, fault injection, invariant checker | Simulated only |
| `bridgey-ffi` | UniFFI API for Kotlin and Swift, adapter callbacks | |
| `bridgey-cli` | Uses `bridgey-transfer` directly | |

The connect-anywhere and agent CLI specs already plan `bridgey-connect`, `bridgey-transfer`,
`bridgey-ffi` and `bridgey-cli` ([agent-cli.md](../agent-cli.md#12-how-it-maps-to-the-v2-rust-core));
this adds the `-core` and `-sim` split so the logic can be simulated.

### 4.3 API

Rust signatures; the UniFFI names mirror them. Every call returns within 50 ms; long work runs on
engine tasks and reports through the observer.

```rust
pub fn open(config: TransferConfig, host: Arc<dyn Host>) -> Result<Engine>;

impl Engine {
    // Start work
    pub fn send(&self, to: Vec<PeerId>, items: Vec<SourceItem>, opts: SendOptions) -> Result<Vec<TransferId>>;
    pub fn fetch(&self, from: PeerId, req: FetchRequest) -> Result<TransferId>;            // clipboard lazy paste
    pub fn read(&self, id: TransferId, item: u32, offset: u64, len: u32) -> Result<Vec<u8>>; // waits for verified bytes

    // User actions
    pub fn pause(&self, id: TransferId) -> Result<()>;
    pub fn resume(&self, id: TransferId) -> Result<()>;
    pub fn cancel(&self, id: TransferId) -> Result<()>;
    pub fn restart(&self, id: TransferId, scope: RestartScope) -> Result<()>;               // Unfinished | Items(Vec<u32>)
    pub fn retry_failed(&self, id: TransferId) -> Result<()>;
    pub fn skip(&self, id: TransferId, items: Vec<u32>) -> Result<()>;
    pub fn verify_again(&self, id: TransferId) -> Result<()>;

    // The ledger
    pub fn list(&self, filter: ListFilter) -> Vec<TransferSummary>;
    pub fn report(&self, id: TransferId) -> Result<TransferReport>;
    pub fn export(&self, id: TransferId, format: ExportFormat) -> Result<String>;          // B3sum | Csv | Json

    // Environment, called by the platform layer
    pub fn session_up(&self, peer: PeerId, session: Arc<dyn Session>);
    pub fn session_down(&self, peer: PeerId);
    pub fn network_changed(&self, net: NetworkState);     // route kind, metered, constrained, data saver
    pub fn power_changed(&self, power: PowerState);       // battery level, charging, thermal status
    pub fn will_sleep(&self) -> Result<()>;               // returns after the ledger and partials are synced
    pub fn did_wake(&self);
    pub fn storage_event(&self, event: StorageEvent);     // unmounted, mounted, grant revoked
    pub fn shutdown(&self) -> Result<()>;                 // orderly stop: commit, mark clean

    // files.v1 transfers moved by native code (no resume), recorded in the same ledger
    pub fn record_legacy(&self, event: LegacyEvent);
}
```

`Host` is implemented natively: `Sources` (open, snapshot, persist and release grants),
`Destinations` (capabilities, free space, create and reopen partials, finalise, delete, watch),
`Observer` (events for the UI and the CLI) and `KeepAwake` (wake lock or activity assertion
requests). File descriptors cross the boundary as raw fds that the engine owns and closes.

### 4.4 Who uses it

| Client | How |
| --- | --- |
| Share sheet (Android), drop window and Send Files (Mac) | `send(peers, items)` with purpose `files` |
| Folders ([folders spec](https://github.com/round-robin-solutions/bridgey/blob/rr/folders-spec/docs/folders-and-settings-sync.md)) | `places.*` and the destination and conflict questions run first: `places.*` unchanged, `xfer.waiting` in place of `folders.waiting`, and `folders.conflict` and `folders.resolve` unchanged with `folderTransferId` set to the engine's `transferId`. Then `send` with purpose `folder`; on the receiver the folder layer supplies the destination plan (place, path, choice). The manifest keeps the folders spec's rules: portable names, depth-first order, case-clash checks |
| Clipboard (branch `rr/clipboard-files`) | `clipboard.offer` stays. Eager items are a `send` with purpose `clipboard` into the receiver's clipboard cache. A lazy paste sends `clipboard.fetch` with a `transferId`, then the receiver `fetch`es with interactive priority. On Android a seekable read for apps comes from `StorageManager.openProxyFileDescriptor`, whose `onRead(offset, size)` calls `read` |
| Agent CLI ([agent-cli.md](../agent-cli.md)) | `bridgey send` calls `send`; `bridgey transfers` and `bridgey transfer resume|cancel|restart|report ID` map to the API; JSON Lines events come from the observer |
| Upstream and older peers | Today's native `files.v1` code keeps moving the bytes and reports each transfer through `record_legacy`; no resume |

One transfer has one sender, one receiver and one direction. Sending to two devices makes two
transfers that share the sender's hash pass.

## 5. Identifiers and units

| Item | Format |
| --- | --- |
| `transferId` | UUIDv7 chosen by the sender. A string in JSON; 16 raw bytes in stream headers |
| Item index `i` | u32, the entry's position in the manifest. Folders and files share the index space |
| Block index `b` | u32, offset divided by 1 MiB. A file of at most 4 TiB (2^42 bytes) has at most 4,194,304 blocks |
| `reqId` | u32 chosen by the receiver, unique per transfer within one session |
| Attempt | Counter, incremented on every resume after an interruption |
| Purpose | `files`, `folder` or `clipboard` |

## 6. Integrity

### 6.1 Hash and tree

- **Algorithm:** BLAKE3-256 in its default (unkeyed) mode, through the `blake3` crate 1.8.7 or
  later and its `hazmat` module.
- **Blocks:** block `b` covers bytes `[b * 2^20, min((b + 1) * 2^20, size))`, that is 1,024
  BLAKE3 chunks. Because a block starts at a multiple of 1 MiB, it is a complete BLAKE3 subtree.
- **Chaining value:** `CV_b` is computed with `Hasher::new()`, `set_input_offset(b * 2^20)`,
  `update(block)` and `finalize_non_root()`.
- **Root:** the CVs are merged in BLAKE3's own tree shape (`left_subtree_len`), with
  `merge_subtrees_non_root` inside the tree and `merge_subtrees_root` at the top. A file of at most
  one block has no CVs; its root is `blake3::hash(content)`.
- **Property:** `root == blake3::hash(file) == b3sum`. A unit test checks it for sizes 0, 1,
  1,023, 1,024, 1,025, 2^20 - 1, 2^20, 2^20 + 1, 3 * 2^20 + 5 and 2^32 + 7 bytes of generated
  content, and the vectors go into `protocol/test-vectors/transfer-v1.json`.
- **Outboard:** only the leaf CVs (32 bytes per block, 16 MB for 500 GB). Upper tree nodes are
  recomputed when needed; merging 512,000 CVs takes well under a second (inference).
- **Workers:** on the Mac and Linux, rayon for parallel blocks; on Android, two hash workers at
  background thread priority.

### 6.2 The chain of checks

| Step | Where | Catches |
| --- | --- | --- |
| 1. Hash pass: read the whole file once, produce its CVs and root | Sender, ahead of sending | Fixes the exact version being sent |
| 2. Serve: re-read each block, re-hash it, compare with the hash pass | Sender, every block | The source changed after the hash pass (P4) |
| 3. Arrival: hash the received block, compare with the CV already received | Receiver, every block, before writing | Bugs or memory errors on either side; a misbehaving peer |
| 4. Root: merge all CVs, compare with the sender's root | Receiver, end of each file | A damaged or inconsistent CV list |
| 5. Read-back: read the saved partial from storage, hash each block, compare | Receiver, during and after the transfer (default on) | Write-path bugs, lost writes, storage corruption, provider bugs such as "w" not truncating |
| 6. Finalise: atomic rename or publish | Receiver | Half-written files under real names (P2) |
| 7. Confirmation: `xfer.item.ok` carries the root | Receiver to sender | Both sides agree (P8) |
| Later: Verify again | Receiver, on demand | Files changed or damaged after saving |

**Hash-ahead pipelining.** The hash pass runs ahead of sending. The sender serves block `b` only
once the hash pass has produced `CV_b`, and the CVs travel to the receiver just before their blocks
(CVS records, section 7.3). The hash pass runs at about 1.65 GB/s on one big phone core against
about 40 MB/s of Wi-Fi, so it is ahead after the first block: the first byte leaves within
milliseconds (inference). The root of a multi-block file travels in `xfer.item.sealed`, sent once
every block has been served or was already durable, and a final snapshot shows the source did not
change; the receiver
finalises a multi-block file only after the seal, so a late change still meets the change policy.
For folders, file `k + 1` hashes while file `k` sends; roots of small files come out of the scan
itself.

**Cost.** For a 50 GB file on the OnePlus 11: about 60 s of one big core for the two hashes and
about 12 s for AES-GCM, spread over a transfer of about 20 minutes on Wi-Fi (inference from
[research 2.2 and 2.4](research.md#22-blake3-versus-sha-256-on-our-hardware)).

**Single-read mode.** Sources that cannot be read twice (a pipe from a cloud provider) and CLI
sends with `--single-read` (slow disks) merge steps 1 and 2: the sender hashes while it sends and
sends the root at the end. Change detection then relies on snapshots (section 11). The report says
"single read".

**Small items.** For files of at most 1 MiB the root is in the manifest. The file travels as one
DATA record, and the receiver checks `blake3::hash(payload) == root` before writing anything.

### 6.3 Verification levels (question A2)

| Level | Steps | Extra cost |
| --- | --- | --- |
| `readback` (proposed default) | 1 to 7 | One extra read of each received file, mostly hidden behind the transfer: read-back runs one commit behind the writer. Worst case at the end of a 50 GB file on the phone, about 30 s |
| `arrival` | 1 to 4, 6, 7 | None |
| `paranoid` | `readback` plus a third read of the source after the last block, compared with the hash pass | One extra read on the sender |

The sender asks for a level in `xfer.offer`; the receiver may raise it, never lower it.

### 6.4 What "verified" means in the report

"Verified" means every block matched the sender's BLAKE3 tree when it arrived and again when it
was read back from storage, and the file's BLAKE3 hash equals the sender's. At level `arrival` the
report says "Checked on arrival" instead.

### 6.5 Legacy peers

`files.v1` keeps today's whole-file SHA-256 computed before the offer. The report says "Checked with
SHA-256 (older Bridgey on MacBook); can't resume".

## 7. Wire protocol (`transfer.v1`)

### 7.1 Negotiation

- The capability `transfer.v1` goes in the `capabilities` array of `features.update`, as planned in
  connect-anywhere. The engine is used when both peers advertise it and the session runs on the QUIC
  tunnel (`connect.v1`).
- Feature switches still decide: `files` for purposes `files` and `folder` (Files off means
  `xfer.reject` with `disabled`), and `clipboard_files_draft1` for purpose `clipboard`.
- An edition pair on the same LAN normally moves to QUIC within a second. If no QUIC path appears
  within 10 s, the transfer falls back to `files.v1` and says so (failure catalogue row 11).
- Peers without `transfer.v1` use `files.v1` (section 16).
- The engine therefore ships with, or after, connect-anywhere's QUIC tunnel (question G2).

### 7.2 Control messages

All are encrypted payloads in today's session format (outer `kind`, `sessionId`, unique
`messageId`, base64 `nonce` and `ciphertext`). `xfer.offer`, `xfer.reject` and `xfer.cancel` also
repeat `transferId` in the outer message, so a receiver whose Files switch is off can reject without
decrypting, as `files.offer` does today. Plaintext is UTF-8 JSON, at most 16 KiB, except
`xfer.offer` and `xfer.state` pages (32 KiB). Every payload carries `"v": 1`. Unknown fields are
ignored. Every handler is idempotent: messages describe state, not deltas that must not repeat.

| Message | Direction | Payload |
| --- | --- | --- |
| `xfer.offer` | Sender to receiver | `transferId`; `purpose` (`files`, `folder`, `clipboard`); `rootName` (at most 220 bytes); `items` (1 to 100,000), `files`, `dirs`; `totalBytes`; `largestBytes`; `blockSize` (1048576; other values rejected in v1); `hash` (`blake3`); `manifest` {`bytes` (at most 64 MiB), `digest` (base64 BLAKE3 of the manifest bytes), `inline` (the entries, when the manifest is at most 8 KiB)}; `verify` (`readback`, `arrival`, `paranoid`); `change` (`new_version`, `ask`, `fail`); `created` (Unix ms); `folder` {`destination` ({`placeId`, `path`} or null), `skipped` (counters)} for folders; `clipboard` {`offerId`, `eager`} for clipboard items; `from` (at most 64 characters, CLI) |
| `xfer.accept` | Receiver to sender | `transferId`; `maxRequests` (1 to 8); `rootName` (final, for example "Photos (1)"); `destinationLabel` (at most 128 characters); `choice` (`none`, `merge`, `replace`, `new_folder`); `verify` (effective level); `state` (on resume, same body as `xfer.state`) |
| `xfer.waiting` | Receiver to sender | `transferId`; `reason` (`destination`, `conflict`, `space`, `confirm`); `timeoutSeconds` |
| `xfer.reject` | Receiver to sender | `transferId`; `code` (`disabled`, `not_granted`, `declined`, `busy`, `too_large`, `too_large_for_destination`, `no_space`, `limit_exceeded`, `invalid_manifest`, `unsupported`, `timeout`); optional `item`, `neededBytes`, `freeBytes`, `retryAfterMs` |
| `xfer.want` | Receiver to sender | `transferId`; `reqId`; `prio` (0 interactive, 1 normal, 2 background); `cvs` (bool: include CV records for blocks the receiver lacks); `cvsOnly` (bool: CV records only, no data, used after a rebuild or a root mismatch); `ranges`: `[i]` (whole item) or `[i, from, to]` (blocks `from` up to, not including, `to`). At most 512 ranges and 64 MiB per want |
| `xfer.unwant` | Receiver to sender | `transferId`; `reqIds` (at most 64). The receiver also stops those streams |
| `xfer.have` | Receiver to sender | `transferId`; `durable`: `[{i, ranges: [[from, to], ...]}]` that became durable since the last `have`; `ok`: index ranges of items finalised since then. After each ledger commit, at most once a second |
| `xfer.item.sealed` | Sender to receiver | `transferId`; `i`; `size`; `root` (base64, 32 bytes). Multi-block files only: the last block was served and the end-of-item snapshot matches, so the receiver may finalise |
| `xfer.item.changed` | Sender to receiver | `transferId`; `i`; `size`; `mtime`; `keep` (block ranges whose CV is unchanged); `action` (`new_version`, `ask`, `fail`) |
| `xfer.item.verifying` | Receiver to sender | `transferId`; `i`; `bytes` read back so far. Every 5 s while one item's verification takes longer than 5 s |
| `xfer.item.ok` | Receiver to sender | `transferId`; `i`; `root`; `name` (final display name, at most 255 bytes); `readback` (bool); `renamed` (bool); `replaced` (bool) |
| `xfer.item.failed` | Either | `transferId`; `i`; `code` (section 7.6); `final` (bool: no automatic retry) |
| `xfer.state` | Receiver to sender (sender to receiver when asked) | `transferId`; `page`; `pages`; `done` (index ranges of finalised items); `durable` (`[{i, ranges}]` for unfinished items); `failed` and `skipped` (`[{i, code}]`); `paused` ({`by`, `reason`} or null) |
| `xfer.status` | Either | `transferId`: asks for `xfer.state` |
| `xfer.resume` | Either | `transferId`; `attempt`. From the sender after any reconnect: the receiver answers `xfer.state` and starts wanting, or `xfer.unknown`. From the receiver (a user or policy resume there): followed by its `xfer.state` and wants |
| `xfer.unknown` | Either | `transferId`: no record of it here |
| `xfer.pause` | Either | `transferId`; `by` (`user`, `policy`); `reason` (`user`, `metered`, `battery`, `thermal`, `storage_full`, `ledger_full`, `io_error`, `destination_unavailable`, `sleeping`, `quota`, `app_stopped`, `peer_errors`, `needs_update`) |
| `xfer.cancel` | Either | `transferId`; `reason` (`user`, `policy`, `error`, `timeout`). Answered by `xfer.cancel.ack` (outer fields only) |
| `xfer.restart` | Either | `transferId`; `scope` (`unfinished`, `items`); `items` (for `items`) |
| `xfer.retry` | Either | `transferId`; `items` (failed items; empty means all failed items) |
| `xfer.skip` | Either | `transferId`; `items` |
| `xfer.verify` | Either | `transferId`: asks the receiver to run Verify again |
| `xfer.verified` | Receiver to sender | `transferId`; `checked`; `matched`; `missing` and `differ` (at most 500 indexes each) |
| `xfer.done` | Sender to receiver | `transferId`; `sent`; `failed` (at most 500 `{i, code}`); `skipped` |
| `xfer.done.ack` | Receiver to sender | `transferId`; `saved`; `verified`; `failed` (at most 500); `skipped`; `renamed`; `replaced`; `bytes` |

**Manifest.** At most 8 KiB goes inline in the offer. Larger manifests travel on a manifest stream
(section 7.3) as JSON Lines, one entry per line, in index order:

```json
{"i":0,"t":"d","p":"2019"}
{"i":1,"t":"f","p":"2019/IMG_0001.jpg","s":2481123,"m":1561234567000,"mime":"image/jpeg","r":"q1f3...base64...="}
```

`t` is `d` (folder) or `f` (file); `s` size; `m` modification time in Unix ms (optional); `mime`
optional; `r` the root when the sender already knows it (always for files of at most 1 MiB). Paths
follow the folders spec ([5.1 and 5.2](https://github.com/round-robin-solutions/bridgey/blob/rr/folders-spec/docs/folders-and-settings-sync.md#5-names-paths-and-limits)):
portable names, at most 32 levels and 1,024 bytes, no case clashes, parents before children. For
purpose `files` every path is a single name. The receiver checks the digest and every rule before
accepting.

### 7.3 Data streams

QUIC unidirectional streams, always opened by the sender, all multi-byte integers big-endian.

```text
manifest stream:   "BXM1" (4) | transferId (16) | reserved u32 (0)              then manifest bytes, FIN
response stream:   "BXR1" (4) | transferId (16) | reqId u32 | flags u16 (0) | reserved u16 (0)    (28 bytes)
                   then records, then FIN
record header:     type u8 | flags u8 | reserved u16 | item u32 | block u32 | length u32          (16 bytes)
                   then `length` payload bytes
```

| Type | Name | Payload |
| --- | --- | --- |
| 1 | DATA | The block's bytes; `length` is the block length (at most 1,048,576). A zero-length file is one DATA record with length 0. Flag `0x01` marks the item's last block |
| 2 | CVS | `count x 32` bytes: the CVs of blocks `block` to `block + count - 1`, count at most 1,024 |
| 3 | ITEM_ERROR | ASCII error code, at most 64 bytes. The rest of that item in this request is not sent |
| 4 | END | Empty. Every range was served; FIN follows |

- One response stream per `xfer.want`. Ranges are served in the order asked, and DATA records in
  ascending block order. When the want asked for CVs and the item has more than one block, every
  DATA record comes after a CVS record in the same stream that covers its block; the sender may
  split CVS records, so a hash pass that is only a little ahead never holds data back.
- Flag `0x80` marks a record type the receiver may skip by length if it does not know it. An
  unknown type without that flag ends the stream with `0x13`.
- A block whose hash does not match is discarded quietly and asked for again in a later want, up to
  3 times per block per attempt. Mismatches do not reset streams.

| Stream error | Sent by | Meaning |
| --- | --- | --- |
| `0x11 cancelled` | Receiver (STOP_SENDING) | Unwanted, paused or cancelled |
| `0x13 protocol_error` | Receiver | Malformed records, unknown mandatory type, wrong item or block |
| `0x14 too_much` | Receiver | More bytes than wanted |
| `0x20 source_error` | Sender (RESET_STREAM) | The source failed; `xfer.item.failed` or `xfer.item.changed` follows |
| `0x21 shutting_down` | Sender | The app is stopping or the Mac is going to sleep |

### 7.4 Flows

New transfer:

```text
Sender                                              Receiver
xfer.offer (manifest inline, or on a BXM1 stream) ->
                                                 <- (folders: xfer.waiting, folders.conflict, folders.resolve)
                                                 <- xfer.accept {maxRequests: 8}
                                                 <- xfer.want {reqId: 1, cvs: true, ranges: [[0], [1], ..., [40]]}
                                                 <- xfer.want {reqId: 2, cvs: true, ranges: [[41, 0, 16]]} ... up to 8
BXR1 reqId 1: DATA i=0, DATA i=1, ... END, FIN   ->
BXR1 reqId 2: CVS i=41 b=0..15, DATA b=0 ... END ->
xfer.item.sealed {i: 41, size, root} (after its last block) ->
                                                 <- xfer.have {durable, ok}      (after each commit)
                                                 <- xfer.item.verifying {i: 41}  (long read-back)
                                                 <- xfer.item.ok {i: 41, root, name}
xfer.done {sent, failed, skipped}                ->
                                                 <- xfer.done.ack {saved, verified, failed, ...}
```

Resume after a drop, an app restart or a reboot:

```text
(session up with the same peer, any route)
xfer.resume {attempt: 2}                         ->
                                                 <- xfer.state {done, durable, failed, paused: null}
                                                 <- xfer.want ... (only what is missing)
```

Source changed, policy `new_version`:

```text
BXR1 reqId 7: DATA i=41 b=40 ... RESET 0x20      ->   (the serve re-hash of block 52 did not match)
xfer.item.changed {i: 41, size, mtime, keep: [[0, 52], [53, 90]], action: new_version} ->
                                                 <- xfer.want {ranges: [[41, 52, 53], [41, 90, 120]]}
(serving continues with the new CVs)             ->
xfer.item.sealed {i: 41, size, root'}            ->
```

Other flows:
- **Peer lost its state.** `xfer.resume` gets `xfer.unknown`. Under 1 GB of remaining data the
  sender restarts from zero on its own; above, it asks (question A8). A transfer the receiver never
  accepted is simply offered again.
- **Pause.** Either side sends `xfer.pause`. The receiver stops its wants; both ledgers record who
  paused and why. Either device can resume (question F5). Each device applies its own metered,
  battery, thermal and storage policies, and a policy pause on either side pauses the transfer.
- **Cancel.** `xfer.cancel`: both sides delete partials and keep finalised items; `xfer.cancel.ack`.
- **Restart** (question A6). `xfer.restart {scope: unfinished}`: the receiver deletes the partial data
  of unfinished items, the sender runs a fresh hash pass for them, and wants start from block 0.
- **Retry failed.** `xfer.retry`: failed items go back to pending; the sender checks the source
  again; the receiver asks for the item.
- **Completion lost.** If `xfer.done.ack` or `xfer.item.ok` never arrives, the next session's
  `xfer.resume` or `xfer.status` exchange reconciles both ledgers.
- **Actions while the other device is away.** Pause, resume, cancel, restart, retry and skip are
  applied locally at once, kept in the ledger and sent when the session comes back.
- **Crossing actions.** Cancel always wins. A pause and a resume that cross: the pause wins, and the
  user can resume again. Restart and retry take effect once no pause is left.

### 7.5 Limits

| Limit | Value | Over the limit |
| --- | --- | --- |
| Items per transfer | 100,000 (question B2) | Refused before sending |
| Folders per transfer | 20,000 | Refused before sending |
| Depth, path, name | 32 levels, 1,024 bytes, 220 bytes (folders spec) | Sender converts or skips; receiver rejects |
| File size | 4 TiB technical limit; product limit question B1 | Skipped, `too_large` |
| Manifest | 64 MiB | Refused |
| Active transfers per peer and direction | 3 (question F1); others queue | Queued |
| Wants in flight per transfer | 8 on LAN, 4 direct or VPN, 2 relay | Receiver's choice within these |
| Wants in flight per session | 12 (quinn allows 16 unidirectional streams) | Receiver holds back |
| Want size | At most 64 MiB; 16 MiB by default for large files; at most 512 items or 8 MiB for small ones | `protocol_error` |
| Hash mismatches | 3 per block per attempt; 20 per transfer per attempt | Item `integrity`; transfer paused (`peer_errors`) |
| Control payload | 16 KiB; `xfer.offer` and `xfer.state` 32 KiB | Session error |

### 7.6 Item codes

| Code | Plain words in the report |
| --- | --- |
| `source_changed` | Changed on MacBook while sending |
| `source_busy` | Still being written on MacBook; try again when it's finished |
| `source_missing` | Deleted or moved on MacBook before it was sent |
| `source_unreadable` | MacBook can't read this file (permission) |
| `source_grant_lost` | Share the file again to continue |
| `too_large` | Bigger than Bridgey's limit |
| `too_large_for_destination` | Too big for this drive (FAT32 limit, 4 GB) |
| `invalid_name` | Name not allowed on this device |
| `no_space` | Not enough space |
| `destination_unavailable` | Folder no longer available |
| `io_error` | Couldn't be written (storage error) |
| `integrity` | Arrived damaged three times |
| `storage_corrupt` | Saved data didn't read back correctly twice; the storage may be failing |
| `skipped_link`, `skipped_hidden`, `skipped_system`, `skipped_not_downloaded` | Skipped on the Mac: link, hidden file, system file, not downloaded from iCloud |
| `skipped_user` | Skipped by you |
| `cancelled`, `expired` | Cancelled; removed after waiting 7 days |
| `peer_lost_state` | MacBook lost the partial data |
| `too_many_failures` | Stopped after 50 files failed (transfer-level, folders spec) |

## 8. State machines

### 8.1 Transfer

```text
 sender:   preparing --offer--> offered --accept--> active <-----------------------+
 receiver:             offered --(question)--> waiting_user --answer--> active     |
                          |                                   |  |   |            |
                    reject, timeout                           |  |   +-session down or stall--> interrupted
                          v                                   |  |                 |  (auto-resume while the
                       rejected                               |  +-pause--> paused-+   partial data exists)
                                                              |     (user or policy; resume by either side,
                                                              |      or when the policy clears)
                                                              v
                                              finishing --done.ack--> complete | incomplete --retry--> active
 any non-terminal state --cancel--> cancelled          interrupted or paused --retention passed--> expired
```

| State | Meaning | Leaves when |
| --- | --- | --- |
| `preparing` | Sender is scanning and hashing the first items | The offer goes out |
| `offered` | Waiting for the receiver | `xfer.accept`, `xfer.reject`, `xfer.waiting`; no answer in 15 s: resend, 3 times, then `interrupted` |
| `waiting_user` | The receiver is asking where to save, or what to do about a clash | An answer; 180 s without one: cancelled, nothing written (folders spec) |
| `active` | Data is moving or about to | Every item terminal: `finishing`; session down or stall: `interrupted`; pause: `paused` |
| `interrupted` | Not paused and not finished, but no session or no progress | Session back: `active` (automatic); retention passed: `expired` |
| `paused` | Paused by the user or by a policy, with a reason | Resume by either device, or the policy condition clears (policy pauses only): `active` |
| `finishing` | `xfer.done` sent, waiting for `xfer.done.ack` | Ack: `complete` or `incomplete`; no ack in 30 s: stays, reconciled on the next session |
| `complete` | Every item saved and verified; items skipped by the user listed (question A1) | Terminal |
| `incomplete` | Finished, but some items failed | `xfer.retry`: `active` |
| `cancelled`, `rejected`, `expired` | Terminal | |

### 8.2 Items

Receiver:

| State | Meaning | In the ledger |
| --- | --- | --- |
| `pending` | Not started | Yes |
| `allocating` | Creating the partial (destination calls) | Yes, with `partial_ref` once created |
| `receiving` | Blocks arriving; the durable set grows | Yes, durable ranges |
| `received` | Every block durable; a multi-block file waits for `xfer.item.sealed` | Yes |
| `verifying` | Root check and read-back | Yes, `readback_upto` |
| `finalising` | Rename or publish under way; `final_ref` recorded before the call | Yes |
| `replacing` | Replace: the old file is gone, the new one not renamed yet; `old_ref` recorded | Yes |
| `done` | Final name recorded, `xfer.item.ok` sent | Yes |
| `failed`, `skipped`, `cancelled` | Terminal for this attempt; `failed` can be retried | Yes, with `code` |

Sender:

| State | Meaning |
| --- | --- |
| `pending` | Not hashed yet |
| `hashing` | Hash pass running; CVs being produced |
| `ready` | Root known |
| `serving` | Blocks being served and acknowledged |
| `sent` | Every block acknowledged as durable |
| `done` | `xfer.item.ok` received |
| `changed` | Source changed: settling, then hashing again |
| `failed`, `skipped`, `cancelled` | Terminal for this attempt |

### 8.3 Blocks (receiver)

`missing` -> `wanted` -> `arrived` (verified against its CV) -> `written` (in the partial, not
synced) -> `durable` (synced and committed) -> `read_back` (checked from storage).

Only `durable` (as ranges) and `readback_upto` are persisted. After a restart, `wanted`, `arrived`
and `written` count as `missing`, except blocks the salvage step proves are on storage
(section 9.5).

### 8.4 Timers

| Timer | Value | When it fires |
| --- | --- | --- |
| Offer answer | 15 s, 3 resends | `interrupted` |
| User question (destination, clash) | 180 s (folders spec) | Cancelled, nothing written |
| Sender waiting on a remote question | 195 s | Cancelled |
| First record of a want | 10 s | Unwant and want again; counts as a stall |
| Stall | No block arrives for 60 s while connected and not paused | Unwant everything, want again; after 3 stalls in 10 minutes, ask the connect layer for a new session |
| Resume after session up | First want within 3 s (target) | |
| Ledger commit | Every 64 MiB written or every 2 s, whichever comes first | |
| `xfer.have` | After each commit, at most once a second | |
| `xfer.done.ack` | 30 s, 3 resends | Stays `finishing`; reconciled on the next session |
| Reconnect backoff | Existing rule: full jitter, 1 s base, 60 s cap | |
| Retry after a transient item error | 5 s, 30 s, 2 min, then every 10 min | |
| Settling a changing source | Check every 2 s; continue after 5 s unchanged; give up after 60 s with `source_busy` | |
| Free space re-check while paused | Every 5 minutes while connected, and when the app comes to the foreground | |
| Partial retention | 7 days after the last progress (question A5) | `expired` |
| MediaStore pending refresh (Android 11+) | Every 3 days while a partial is kept | |
| Full reports in history | 30 days (question E1) | Names and checksums dropped |

### 8.5 Retry policy

| Error class | Examples | Automatic retry |
| --- | --- | --- |
| Network | Drop, stall, relay switch | Always, while the partial data exists (question A4) |
| Peer limits | `busy`, `rate_limited`, relay caps | After `retryAfterMs` or the cap reset |
| Integrity on arrival | Hash mismatch | Ask for the block again, 3 times; then item `integrity` |
| Integrity on read-back | Read-back mismatch | Fetch the bad blocks again, twice; then item `storage_corrupt` |
| Storage | EIO on write or sync | The batch counts as lost; reopen and retry once; then pause (`io_error`) |
| Space | ENOSPC, reserve reached | Pause (`storage_full`); resume when space is back |
| Source | Changed, missing, unreadable | Change policy (section 11); missing and unreadable need the user |
| Permission | Grant lost | Pause the item or the transfer; needs the user |

## 9. Durable state: the ledger

### 9.1 Where it lives

| Platform | Location | Notes |
| --- | --- | --- |
| Android | `noBackupFilesDir/transfers/` | The app already sets `allowBackup="false"`. Credential-encrypted storage, so resuming after a reboot waits for the first unlock |
| macOS | `~/Library/Application Support/in.roundrobin.bridgey/Transfers/` | `isExcludedFromBackup` set on the folder |
| CLI on Linux | `~/.local/share/bridgey/transfers/` (agent-cli.md) | Folder `0700`, files `0600` |
| CLI on macOS | `~/Library/Application Support/in.roundrobin.bridgey.cli/transfers/` | |
| Windows (v2) | `%LOCALAPPDATA%\Round Robin\Bridgey\Transfers\` | |

```text
transfers/
  ledger.db, ledger.db-wal, ledger.db-shm   live state, history, reports (SQLite)
  <transferId>/
    transfer.json      peer, direction, purpose, options, destination plan (rewritten atomically)
    manifest.jsonl     the manifest exactly as offered (its digest is in transfer.json)
    sources.jsonl      sender only: one source reference per item (path, bookmark, content URI)
    partials.log       receiver only: "i <ref> <crc32c>" per partial created, synced before its first write
    <i>.cvs            outboard for each item larger than 1 MiB
```

There is one writer: the engine inside the app process (Android, Mac) or the `bridgey agent`
process (CLI). SQLite holds the live state the UI reads. The side files hold what is needed to
rebuild a receive transfer if SQLite is ever lost (section 9.5).

### 9.2 Schema (SQLite, `user_version` 1)

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;          -- one WAL sync per commit; commits are at most every 2 s
PRAGMA fullfsync = OFF;             -- macOS: the data barrier (9.4) already orders the ledger after the data
PRAGMA checkpoint_fullfsync = ON;   -- macOS: checkpoints flush the drive cache
PRAGMA foreign_keys = ON;

CREATE TABLE meta (                 -- engine_version, clean_shutdown, last_boot_id, last_wall_ms, last_elapsed_ms
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE transfer (
  id              BLOB PRIMARY KEY CHECK (length(id) = 16),
  peer_id         TEXT NOT NULL,
  direction       TEXT NOT NULL CHECK (direction IN ('send', 'receive')),
  purpose         TEXT NOT NULL CHECK (purpose IN ('files', 'folder', 'clipboard')),
  protocol        INTEGER NOT NULL,          -- 1 = transfer.v1, 0 = files.v1 (recorded only)
  state           TEXT NOT NULL,             -- section 8.1
  pause_by        TEXT,                      -- user | policy
  pause_reason    TEXT,
  root_name       TEXT NOT NULL,
  final_root_name TEXT,
  items           INTEGER NOT NULL,
  files           INTEGER NOT NULL,
  dirs            INTEGER NOT NULL,
  total_bytes     INTEGER NOT NULL,
  manifest_digest BLOB NOT NULL CHECK (length(manifest_digest) = 32),
  verify          TEXT NOT NULL,
  change_policy   TEXT NOT NULL,
  destination     TEXT,                      -- receiver: JSON plan (place id, label, choice)
  attempt         INTEGER NOT NULL DEFAULT 1,
  created_ms      INTEGER NOT NULL,
  updated_ms      INTEGER NOT NULL,
  progress_ms     INTEGER NOT NULL,          -- last time a block became durable
  finished_ms     INTEGER,
  expires_ms      INTEGER,                   -- partial retention deadline
  done_items      INTEGER NOT NULL DEFAULT 0,
  failed_items    INTEGER NOT NULL DEFAULT 0,
  skipped_items   INTEGER NOT NULL DEFAULT 0,
  done_bytes      INTEGER NOT NULL DEFAULT 0,
  resent_bytes    INTEGER NOT NULL DEFAULT 0,
  route_bytes     TEXT                       -- JSON {"lan": n, "vpn": n, "direct": n, "relay": n}
);
CREATE INDEX transfer_by_state ON transfer(state);
CREATE INDEX transfer_by_peer  ON transfer(peer_id, state);

CREATE TABLE item (
  transfer_id   BLOB NOT NULL REFERENCES transfer(id) ON DELETE CASCADE,
  idx           INTEGER NOT NULL,
  kind          TEXT NOT NULL CHECK (kind IN ('file', 'dir')),
  path          TEXT NOT NULL,               -- relative, portable, '/'-separated
  size          INTEGER NOT NULL DEFAULT 0,
  mtime_ms      INTEGER,
  mime          TEXT,
  blocks        INTEGER NOT NULL DEFAULT 0,
  root          BLOB CHECK (root IS NULL OR length(root) = 32),
  state         TEXT NOT NULL,               -- section 8.2
  code          TEXT,                        -- failure or skip reason (section 7.6)
  durable       BLOB,                        -- receiver: durable ranges; sender: acknowledged ranges
  durable_count INTEGER NOT NULL DEFAULT 0,
  recent        BLOB,                        -- receiver: ranges made durable by the last 2 commits
  readback_upto INTEGER NOT NULL DEFAULT 0,  -- receiver: blocks read back so far
  snapshot      TEXT,                        -- sender: JSON identity at hash time (section 11.1)
  partial_ref   TEXT,                        -- receiver: path or content URI of the partial
  old_ref       TEXT,                        -- receiver: the file being replaced
  final_ref     TEXT,                        -- receiver: final path or URI
  final_name    TEXT,                        -- both: name as saved on the receiver
  mismatches    INTEGER NOT NULL DEFAULT 0,
  attempts      INTEGER NOT NULL DEFAULT 0,
  updated_ms    INTEGER NOT NULL,
  PRIMARY KEY (transfer_id, idx)
) WITHOUT ROWID;
CREATE INDEX item_open ON item(transfer_id, state)
  WHERE state NOT IN ('done', 'failed', 'skipped', 'cancelled');

CREATE TABLE event (                         -- timeline for the report; never names or paths
  transfer_id BLOB NOT NULL REFERENCES transfer(id) ON DELETE CASCADE,
  seq         INTEGER NOT NULL,
  at_ms       INTEGER NOT NULL,
  kind        TEXT NOT NULL,                 -- started, route, interrupted, resumed, paused, changed,
                                             -- item_failed, restarted, verified, finished
  idx         INTEGER,
  code        TEXT,
  detail      TEXT,                          -- JSON: route kind, bytes, durations
  PRIMARY KEY (transfer_id, seq)
) WITHOUT ROWID;

CREATE TABLE name_reservation (              -- receiver: final names chosen but not yet published
  dir_key     TEXT NOT NULL,                 -- identity of the destination folder
  name_key    TEXT NOT NULL,                 -- NFC, lowercased
  transfer_id BLOB NOT NULL,
  idx         INTEGER NOT NULL,
  PRIMARY KEY (dir_key, name_key)
) WITHOUT ROWID;

CREATE TABLE source_grant (                  -- Android persisted URI grants to release later
  uri         TEXT PRIMARY KEY,
  transfer_id BLOB NOT NULL,
  taken_ms    INTEGER NOT NULL
) WITHOUT ROWID;
```

- **Ranges** (`durable`, `recent`) are BLOBs of little-endian u32 pairs `(from, to)`, sorted and
  merged. Usually a few bytes; worst case 8 bytes per gap.
- **Events** are capped at 2,000 per transfer; older routine events fold into counters.

### 9.3 Outboard files

```text
header (80 bytes): "BXCV" | version u16 (1) | flags u16 | transferId (16) | item u32 | blocks u32
                   | size u64 | root (32 bytes, zero until known) | header check (8: first 8 bytes of
                   BLAKE3 over the preceding 72 bytes)
body:              blocks x 32 bytes; CV of block b at offset 80 + 32 * b; all zeros = not known yet
```

Written with `pwrite` as CVs arrive (receiver) or are computed (sender), synced in the same batch as
the data they describe. The sender's outboard holds the hash pass; the receiver's holds the CVs it
received. With the partial, it lets the engine prove by hashing which blocks are really on storage.
Deleted when the item is done (receiver) or the transfer ends (sender).

### 9.4 Write ordering: data first, then the ledger

For each batch (64 MiB or 2 s, whichever comes first):
1. `pwrite` the verified blocks into the partial; CVs go into the outboard as they arrive.
2. Sync the partial, then the outboard:
   - Linux and Android: `fdatasync`.
   - macOS, partial on the same device as the ledger: `fcntl(F_BARRIERFSYNC)`, which orders the
     writes without the cost of a cache flush; the ledger can never be persisted ahead of the data.
   - macOS, partial on another device (external drive): `fcntl(F_FULLFSYNC)`, falling back to
     `fsync` on `ENOTSUP`, `EOPNOTSUPP` or `EINVAL`.
   - Windows: `FlushFileBuffers`.
3. Commit one SQLite transaction: durable ranges plus the batch, `recent` set to this and the
   previous batch, `progress_ms`.
4. Send `xfer.have`.

**A sync error loses the batch.** After a failed `fsync` the kernel may already have marked the pages
clean ("retrying fsync() is not OK", research 3.1). The engine never retries and trusts: it closes
the fd, reopens the partial, marks the batch's blocks missing and asks for them again. A second sync
error within 10 minutes pauses the transfer with `io_error`.

**Small files group commit.** Up to 256 small files or 250 ms: write and sync each file, finalise
each one, then one SQLite commit and one `xfer.have` for the group. On macOS each file gets a plain
`fsync`, and one `F_FULLFSYNC` per group makes all of them durable ("data that had been fsync'd on
the same device before is guaranteed to be persisted").

### 9.5 Startup recovery

1. **Open the ledger.** After an unclean shutdown, run `PRAGMA quick_check`. If opening or the check
   fails, move the files aside as `ledger.db.broken-<ms>`, create a new ledger and rebuild (step 7).
2. **Find out what happened.** `clean_shutdown` (1 after `shutdown()`, set to 0 at start); a boot
   change (Android `Settings.Global.BOOT_COUNT`, Linux `/proc/sys/kernel/random/boot_id`, macOS
   `kern.boottime`); on Android 11 and later `ApplicationExitInfo`. After `REASON_USER_REQUESTED`
   (force stop, Task Manager Stop), transfers are marked `paused` with `app_stopped`: nothing resumes on
   its own. Android 8 to 10 cannot tell a force stop from a kill, so there every unexpected stop counts as a
   kill.
3. **Finish half-done steps.** `finalising`: if the final file exists with the expected size (and
   root, for small files), mark it done, otherwise finalise again. `replacing`: rename the partial
   into the old name. MediaStore: query `IS_PENDING` of the stored URI. After a reboot or power loss,
   the same check runs for items marked done in the 60 s before the last commit: a rename or a
   MediaStore publish that did not reach storage is redone from the partial.
4. **Salvage after any unclean stop.** For each item in `receiving`, every block whose CV is known
   (non-zero in the outboard) but which is not durable is read from the partial and hashed; a match
   means the data reached storage before the stop, so the block becomes durable after one sync. This
   costs at most the blocks wanted but not committed (at most 128 MiB per item, inference). It
   brings the re-send after an app kill close to zero.
5. **Re-verify after a reboot or power loss.** For items with `recent` ranges, re-hash those blocks
   (at most 128 MiB) plus 16 random older durable blocks. Any mismatch re-hashes the item's whole
   durable set and drops bad blocks. This covers devices whose storage cache loses synced data
   (research 3.1).
6. **Resume.** Mark `clean_shutdown = 0`, then resume eligible transfers as sessions come up.
7. **Rebuild** (only when SQLite was lost). Receive transfers come back from `transfer.json`,
   `manifest.jsonl`, `partials.log` and the outboards, with empty durable sets; salvage (step 4)
   then proves which blocks are on storage. Send transfers come back from `transfer.json`,
   `manifest.jsonl` and `sources.jsonl`. The UI says once: "Bridgey repaired its transfer records".

### 9.6 Retention and clean-up

| What | Kept | Removed |
| --- | --- | --- |
| Partial data of interrupted or paused transfers | 7 days after the last progress (question A5); a notification 24 h before | At expiry: transfer `expired`, partials and outboards deleted |
| MediaStore pending partials (Android 11+) | `IS_PENDING=1` set again every 3 days, which moves Android's own 7-day expiry | |
| Outboards | Until the item is done (receiver) or the transfer ends (sender) | Then |
| Full reports of finished transfers | 30 days, at most 1,000 transfers (question E1) | Then names, paths and checksums are dropped; counts stay for a year |
| Orphans: partials, staging files, `.bridgey-part` files and our own pending MediaStore items with no ledger entry | 1 hour of grace | Startup sweep and a daily sweep. Android 10 never expires pending items, so this sweep is the only clean-up there |
| Persisted URI grants (Android sender) | While the transfer needs them | Released when it ends (the 512-grant cap prunes old grants silently) |
| Everything with a peer | | Forget device (SECURITY.md) |
| Finished reports | | Clear history |

**Clock safety.** Expiry uses wall-clock time, but the ledger stores `last_wall_ms` and
`last_elapsed_ms`. If the wall clock moved forward more than 48 hours beyond the elapsed time since
the last check, expiry waits another day and records `clock_jump`.

### 9.7 Size

| Case | Ledger | Outboards |
| --- | --- | --- |
| One 500 GB file | 1 item row; ranges under 1 KB | 16 MB on each side |
| 100,000 small files | About 25 MB of item rows (inference: about 250 bytes each) | None |
| History | At most 2,000 events per transfer, 1,000 transfers | |

## 10. Storage and finalise per platform

### 10.1 Destination capabilities

Detected when an item starts, from the open partial.

| Capability | Detected by | Effect |
| --- | --- | --- |
| `random_access` | Regular file (`fstat`, `S_ISREG`) on APFS, ext4, f2fs, XFS, btrfs, NTFS | Blocks written at their offsets, several streams at once |
| `sequential_only` | FAT32 or exFAT (`fstatfs` type on Linux and Android, `f_fstypename` on macOS), a pipe from a SAF provider, SMB | Blocks written in order; wants in order; reorder buffer at most 32 MiB; read-back per file at its end |
| `prealloc` | `fallocate` (ext4, f2fs, XFS, btrfs) or `F_PREALLOCATE` (APFS) works | The full size is reserved when the item starts, so space runs out at the start, never half-way |
| `max_file_size` | FAT32: 4 GiB minus 1 byte | Larger items are `too_large_for_destination` before any byte moves |
| `rename_noreplace` | Linux `renameat2(RENAME_NOREPLACE)`; macOS `renamex_np(RENAME_EXCL)` where `VOL_CAP_INT_RENAME_EXCL` is set; else `link` plus `unlink`; else check, then rename | |
| `full_sync` | macOS `F_FULLFSYNC` supported | |
| `same_device_as_ledger` | `st_dev` comparison | macOS barrier or full sync (9.4) |

### 10.2 macOS

- **Partial location** (question D4). When the destination folder is on the same volume as
  `~/Library/Application Support`, the partial is `Transfers/<transferId>/<i>.part`: nothing
  half-finished appears in Downloads, iCloud Drive and Dropbox never upload it, and Time Machine
  skips it. On another volume it sits beside the target as `.<name>.<id8>.bridgey-part`, hidden and
  excluded from backup (`id8` is the first 8 characters of the transfer ID, so two transfers never
  share a partial).
- **Writes.** `F_PREALLOCATE` at item start, `pwrite` at offsets, batch syncs (9.4). Read-back uses
  `F_NOCACHE` so it reads from storage rather than from memory.
- **Finalise.** `F_FULLFSYNC` the partial (fallback `fsync`), `renamex_np(part, final, RENAME_EXCL)`,
  on `EEXIST` the next free name, `fsync` the destination folder, then one more `F_FULLFSYNC` so the
  rename itself is on storage before `xfer.item.ok` goes out (one per group for small files), and
  record `final_ref`.
  Single files keep today's Mac naming ("name 2.ext"); folders use the folders spec's
  "name (1).ext".
- **Replace** (folders): after verification, plain `rename(part, existing)`, which replaces
  atomically.
- **Volume removed** (`NSWorkspace.didUnmountNotification`): pause `destination_unavailable`; when a
  volume with the same `volumeUUIDString` mounts again, re-verify the `recent` blocks, then resume.
- **Folder moved or renamed:** the stored bookmark resolves to the new place and the transfer
  continues there; if it does not resolve, the transfer pauses and asks.

### 10.3 Linux and the CLI

- Partial beside the target as `.<name>.<id8>.bridgey-part`, or in `<inbox>/.bridgey-staging/` when
  the inbox is the destination.
- `fallocate` at item start where supported, `pwrite`, batch `fdatasync`. Read-back calls
  `posix_fadvise(POSIX_FADV_DONTNEED)` on synced ranges first, so it reads from storage.
- Finalise: `fdatasync`, `renameat2(RENAME_NOREPLACE)` (on `EEXIST` the next free name; on `EINVAL`
  `link` plus `unlink`), then `fsync` of the folder.

### 10.4 Android: `Download/Bridgey` through MediaStore

1. Insert into `MediaStore.Downloads` with `DISPLAY_NAME`, `MIME_TYPE`, `RELATIVE_PATH`
   `Download/Bridgey/` (plus subfolders for folders) and `IS_PENDING = 1`.
2. Append the URI to `partials.log` and the ledger before the first write.
3. `openFileDescriptor(uri, "rw")`, `detachFd()`, hand the fd to the engine; check it is a regular
   file; `fallocate` (f2fs supports it).
4. Batch syncs with `fdatasync` on that fd (it reaches the file under the FUSE layer).
5. Finalise: `fdatasync`, update `IS_PENDING = 0`, re-query `DISPLAY_NAME` (MediaStore may have
   renamed it "name (1)"), record it. MediaProvider does not sync its rename, so the engine calls
   `syncfs` on the file's fd once per file or small-file group before `xfer.item.ok` (allowed for apps:
   to be confirmed in T0; recovery step 3 in 9.5 is the safety net).
6. While paused on Android 11+, update `IS_PENDING = 1` again every 3 days, which recomputes the
   7-day expiry, then check the URI still opens. To be confirmed on the OnePlus 11 (T0).
7. Android 10 never expires pending items, so the startup sweep deletes our pending items that have
   no ledger entry (`QUERY_ARG_MATCH_PENDING` on Android 11+, a direct URI query on 10).

### 10.5 Android: granted folders through the Storage Access Framework

1. Resolve the parent document level by level, as the folders spec does, with a cached listing.
2. Create the partial `.<name>.<id8>.bridgey-part` with
   `createDocument(parent, "application/octet-stream", partName)` and record the returned URI.
3. `openFileDescriptor(uri, "rw")`. If `fstat` says it is not a regular file, reopen with `"wt"`
   (never `"w"`, which stopped truncating in Android 10) and switch to `sequential_only`.
4. Writes and syncs as in 10.4; `ParcelFileDescriptor.checkError()` before finalising a pipe.
5. Finalise: `renameDocument(partUri, finalName)`. Use the URI it returns and re-query the name
   (ExternalStorageProvider may add " (n)"). Replace: record `old_ref`, `deleteDocument(old)`, then
   rename (the `replacing` state covers a crash in between). Then `syncfs`, as in 10.4.
6. Providers without `FLAG_SUPPORTS_RENAME`: write under the final name and mark the place "May
   show unfinished files".
7. **Grant revoked, folder moved or deleted** (`SecurityException`, `FileNotFoundException`): pause
   `destination_unavailable`; notification "Bridgey lost access to Pictures" with "Choose the folder
   again". If the chosen folder contains this transfer's `.bridgey-part` files, the engine adopts them
   after re-hashing their blocks against the CVs.
8. **SD card or USB drive removed** (`StorageVolumeCallback` on API 30+, `ACTION_MEDIA_EJECT` and
   `ACTION_MEDIA_UNMOUNTED` before): pause; resume when the volume with the same
   `StorageVolume.getUuid()` returns.
9. **Small files** (question D1): either partial plus rename (two extra SAF calls per file) or the
   final name directly, written only after the content was verified in memory.

### 10.6 Clipboard cache

The clipboard spec's cache (`<root>/<offerId>/<index>/data` with a `complete` marker) becomes an
engine destination. The `data` file is the partial (sparse, filled range by range); finalise writes
the `complete` marker after verification. `read` returns verified bytes from durable or arrived
blocks. Its rules (supersede, 24 hours, 2 GB, never logged) stay as specified.

### 10.7 Windows (v2)

Partial `.<name>.<id8>.bridgey-part` with `FILE_ATTRIBUTE_HIDDEN` and
`FILE_ATTRIBUTE_NOT_CONTENT_INDEXED` (never `TEMPORARY`), shared for read, write and delete;
`FlushFileBuffers` per batch; finalise with `SetFileInformationByHandle(FileRenameInfo)` and
`ReplaceIfExists = FALSE` on a write-through handle; retry `ERROR_SHARING_VIOLATION` and
`ERROR_ACCESS_DENIED` with backoff for 2 s (antivirus and indexers hold files briefly). Replace uses
`FILE_RENAME_FLAG_REPLACE_IF_EXISTS` with POSIX semantics (Windows 10 1709 or later).

### 10.8 Space

- **At accept:** needed = bytes not yet durable plus the reserve, the larger of 2 GB and 5% of the
  volume (question B3). Free space comes from `statvfs`, SAF `Root.COLUMN_AVAILABLE_BYTES` or macOS
  `volumeAvailableCapacityForImportantUsageKey`. When it is unknown, the check is skipped.
- **At each item start:** free space at least the item's remaining bytes plus the reserve, otherwise
  pause `storage_full` with both numbers.
- **Pre-allocation** where cheap (`prealloc`), so a full disk shows up at the start of an item
  (question B5).
- **Never delete other partials to make room** (question B4).

## 11. Change detection

### 11.1 The snapshot

Taken when the hash pass starts, and again when it ends.

| Platform | Fields |
| --- | --- |
| Linux | `st_dev`, `st_ino`, `st_size`, `st_mtim` (ns), `st_ctim` (ns) |
| macOS | The same, plus `generationIdentifierKey` and `documentIdentifierKey` where the volume supports them, plus bookmark data to re-find a moved file |
| Windows | Volume serial, `FILE_ID_INFO`, size, `LastWriteTime` |
| Android content URI | `fstat` of the opened fd when it is a regular file (dev, ino, size, mtime in ns); provider `SIZE`; SAF `COLUMN_LAST_MODIFIED` when present; for MediaStore URIs `DATE_MODIFIED`, `GENERATION_MODIFIED` and `MediaStore.getVersion()` |

A snapshot is **racy** if its modification time is within 2 s of the moment the hash pass started
(FAT stores times in 2-second steps, and this also covers coarse timers), or if any field is
unknown. The two snapshots must be equal; if not, the file changed while it was being hashed.

### 11.2 During a transfer

1. Every served block is re-hashed and compared with the hash pass (6.2 step 2), so every block that
   changed before it was sent is caught exactly.
2. When an item's last block has been served, the sender takes a third snapshot. If it matches, it
   sends `xfer.item.sealed`; if it differs, the file changed during sending even if every served
   block matched (an append past the end, or a change to a block already sent), and the item is
   `changed`. The receiver finalises only after the seal, so this check always comes first.
3. Level `paranoid` re-reads the whole file once more, before the seal.
4. A folder is sent as it was when Send was pressed: files added later are listed in the report, not
   sent (question D3).

### 11.3 Between attempts

1. Reopen the source (path, bookmark or persisted URI). Missing: `source_missing`. Denied:
   `source_unreadable`, or `source_grant_lost` for an Android share whose grant ended. Sharing a file
   again with the same name and size makes the engine hash it; if the root matches a waiting item,
   the new URI is attached to it and the transfer continues.
2. Snapshot equal and not racy: fast resume, after a spot check that re-hashes the 2 highest
   acknowledged blocks and 8 random acknowledged blocks (at most 10 MiB read) against the stored CVs.
3. Snapshot different, racy or unknown, or the spot check fails: a full hash pass and a block-by-block
   comparison with the stored CVs. All equal: resume (only the metadata changed). Otherwise the change
   policy applies.

### 11.4 Change policy (question A3)

| Policy | Behaviour | Report |
| --- | --- | --- |
| `new_version` (proposed default) | Wait until the file stops changing (5 s quiet, at most 60 s), hash it again, keep every block whose CV is unchanged at the same position, and send the rest. The receiver ends with the new version | "Newer version sent (changed during the transfer)" |
| `ask` | Other items continue; this one waits for "Send new version" or "Skip" | "Waiting for you: changed on MacBook" |
| `fail` | The item fails with `source_changed`; the partial is kept until expiry, so a Retry reuses the unchanged blocks | "Changed on MacBook while sending" |

A file still changing after 60 s fails with `source_busy` ("Still being written; try again when it's
finished"), and Retry is offered (question A7).

### 11.5 Changes at the destination

| Change | Detected by | Response |
| --- | --- | --- |
| The partial was deleted | Reopen fails or the size shrank | Recreate it and restart that item from zero; the report says so |
| The partial was modified | Read-back or recent-block check | Fetch the bad blocks again |
| The destination folder moved or was renamed (Mac) | The bookmark resolves to a new path | Continue there |
| The destination folder moved, was renamed or deleted (SAF) | `FileNotFoundException` | Pause, ask to choose it again, adopt our partials if found |
| The volume was removed | Unmount events or `EIO` | Pause; resume on the same volume after re-checking recent blocks |
| A file appeared with the final name meanwhile | The no-replace rename fails | Next free name; `renamed` in the report |
| The file to replace changed after the user answered the clash question | Its size or modification time differ from the time of the answer | Keep both instead; the report says why |
| Saved files were moved or deleted later | Not tracked | Verify again reports them as missing |

## 12. Failure catalogue

"Device" in the examples is the other paired device. Wording is a first draft for the apps.

### 12.1 Network

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 1 | Connection drops mid-transfer | QUIC idle timeout (45 s) or path failure; session down | Wants in flight are dropped; blocks that arrived are kept; the connect layer reconnects (1 to 60 s backoff); on session up the sender sends `xfer.resume` and the receiver asks only for missing blocks. Sent twice: at most 1 MiB per stream plus the data that was in flight | "Waiting for MacBook…", then progress continues; the details list the interruption |
| 2 | Route changes: Wi-Fi to mobile data to relay | QUIC migration (connect-anywhere) plus `network_changed` | Continue on the same connection; the metered policy runs: if the rest is over the "ask above" setting, pause `metered` (question C1) | The route chip changes; "Paused on mobile data: 1.2 GB left · Continue on mobile data" |
| 3 | NAT rebinding | QUIC path validation | Nothing for the engine | Nothing |
| 4 | Connection migration fails | Session down | As 1 | As 1 |
| 5 | Relay cap reached (per-device or pool cap) | `relay.denied` (`node_capped`, `pool_exhausted`) | Pause `quota` with the reset time; resume on its own on a direct or LAN route or after the reset | "Paused: relay limit for today reached · continues on Wi-Fi or at 05:30" |
| 6 | Relay server dies | connect-anywhere fails over within 10 s | Continue; if the session drops, as 1 | Route chip shows the new relay |
| 7 | Cloudflare free tier used up | Pool skips Cloudflare | As 5 if nothing else is left | As 5 |
| 8 | Connected but nothing moves | No block arrives for 60 s | Unwant and want again; after 3 stalls in 10 minutes, a new session | "Slow connection"; then "Reconnecting" |
| 9 | Heavy loss, reordering, duplication | Handled inside QUIC | Nothing; speed drops | Speed only |
| 10 | UDP blocked, captive portal | connect-anywhere network check | Wait; TURN over TLS on 443 | The connect layer's reason, for example "This network blocks direct connections" |
| 11 | No QUIC path to an edition peer for 10 s on the LAN | Session stays on TCP | A transfer that has not started falls back to `files.v1`, without resume, and says so; one that already ran on the engine waits for QUIC | "Sending with the older method on this network (can't resume)" or "Waiting for a faster connection" |

### 12.2 Devices and processes

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 12 | Receiving app killed (kill -9, low memory) | Next start finds `clean_shutdown = 0` | Salvage (9.5), resume on reconnect | Progress continues; details "Bridgey restarted" |
| 13 | Sending app killed | Same | Reopen sources (persisted grants), spot check, resume | Same |
| 14 | Phone or Mac restarts | Boot change | Recovery with recent-block re-verification. Android starts the connection service from `BOOT_COMPLETED` when transfers are waiting (question C7) | "Resumed after the phone restarted" |
| 15 | Power cut | Boot change and unclean shutdown | As 14; the re-verification finds blocks lost by the storage cache and fetches them again | As 14; the details count bytes fetched again |
| 16 | The user force-stops Bridgey or uses Task Manager Stop (Android) | `ApplicationExitInfo` `REASON_USER_REQUESTED` | No automatic resume: the stop is respected | "Paused because Bridgey was stopped · Resume" |
| 17 | The phone's battery manager kills Bridgey (OnePlus) | Process death without a user request during a transfer | Resume on restart; after the second such death in 24 hours, show the OnePlus checklist once | "Your phone closed Bridgey to save battery. Allow it to run in the background: [steps]" |
| 18 | Doze, screen off | The service keeps network access; wake lock while bytes flow | Continue | Nothing |
| 19 | OnePlus "Sleep standby optimization" cuts the network at night | Android reports no network while the screen is off | As 1; the checklist names the setting | "Waiting for network (the phone is in sleep mode)" |
| 20 | Battery low | `power_changed` | Pause large transfers below 15% when not charging; resume at 20% or on the charger (question C3) | "Paused: battery at 14% · Continue anyway" |
| 21 | Phone too hot | `PowerManager.getCurrentThermalStatus()`: at `MODERATE` one want at a time, at `SEVERE` pause (question C4) | Pause, then resume at `LIGHT` | "Paused: the phone is too hot" |
| 22 | Mac goes to sleep (lid, menu, idle) | `NSWorkspace.willSleepNotification` | Commit and sync within the 30 s Apple allows, send `xfer.pause` (`sleeping`), resume on wake | Phone: "MacBook is asleep · resumes when it wakes" |
| 23 | Mac app quits | `applicationWillTerminate` | Orderly checkpoint; resume at the next launch | As 1 on the other device |
| 24 | The other device is offline for days | No session | Stay `interrupted`; expire after 7 days without progress, with a warning a day before | "Waiting for MacBook · last seen 2 days ago · kept for 5 more days" |
| 25 | App updated mid-transfer | Process restart; Android restarts the service on `MY_PACKAGE_REPLACED` | Ledger migration, resume | Nothing |
| 26 | Protocol change in an update | Capabilities per session; each transfer keeps the protocol version it started with | Continue if both still support it, else pause (`needs_update`) | "MacBook needs a newer Bridgey to continue · Send with the older method" |

### 12.3 Storage

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 27 | Receiving device full | `ENOSPC`, or the free-space check | Pause `storage_full`; re-check every 5 minutes and on foreground | "Paused: phone storage full · needs 3.2 GB more · Free up space" |
| 28 | Free space below the reserve | Space check before writing | As 27, before anything is written | As 27 |
| 29 | No space for the ledger itself | `SQLITE_FULL` | Pause every receive (`ledger_full`) | "Paused: no space left for Bridgey's records" |
| 30 | Write or sync error | `EIO` | The batch counts as lost (9.4); reopen; retry once; then pause (`io_error`) | "Paused: couldn't write to the USB drive" |
| 31 | Folder access revoked (SAF) | `SecurityException` | Pause; ask to choose the folder again; adopt our partials | "Bridgey lost access to Pictures · Choose folder again" |
| 32 | Destination folder renamed or moved | Mac: bookmark; Android: `FileNotFoundException` | Mac continues in the new place; Android pauses and asks | As 31 on Android |
| 33 | SD card or USB drive removed | Unmount events, `EIO` | Pause; resume when the same volume returns | "Paused: USB drive removed · resumes when it's back" |
| 34 | FAT32 drive and a file of 4 GiB or more | `max_file_size` | That item is refused before any byte moves; the others continue (question D2) | "Too big for this drive (FAT32 limit, 4 GB)" |
| 35 | Name not allowed at the destination | Portable-name rules; provider errors | The sender converts names; the receiver rejects what is still invalid | "Renamed to fit the phone" or "Name not allowed on this device" |
| 36 | A MediaStore partial expired while paused | The URI no longer opens | Restart that item from zero | Details: "partial expired on the phone" |
| 37 | The user deleted the partial | Reopen fails or the size shrank | Restart that item from zero | Details line |
| 38 | Storage changes data after it was written | Read-back mismatch | Fetch those blocks again, twice; then `storage_corrupt` | "Saved data didn't read back correctly twice: the storage may be failing" |
| 39 | The storage cache lost synced data in a power cut | Recent-block re-verification | Fetch again | Details count it |
| 40 | Ledger database damaged | Open or `quick_check` fails | Rebuild from the side files (9.5) | "Bridgey repaired its transfer records", once |

### 12.4 Sources

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 41 | Source changed during the transfer | Serve re-hash mismatch, or the end-of-item snapshot | Change policy (11.4) | Per policy |
| 42 | Source changed between attempts | Snapshot, spot check | Change policy | Per policy |
| 43 | Source still being written | Keeps changing while settling | Wait up to 60 s, then `source_busy` | "Still being written · Retry" |
| 44 | Source deleted | `ENOENT` | That item fails `source_missing`; the rest continue | "Deleted or moved on MacBook before it was sent" |
| 45 | Source unreadable | `EACCES`, `SecurityException` | That item pauses `source_unreadable` | "MacBook can't read this file · Allow access" |
| 46 | Android share grant lost after a restart | `SecurityException` on reopen | Item pauses `source_grant_lost`; sharing the file again re-attaches it by root | "Share the file again to continue" |
| 47 | Source is a pipe (cloud provider) | `fstat` says not a regular file | Single-read mode; on resume, read again from the start and skip blocks the receiver has | Details: "single read" |
| 48 | File not downloaded locally (iCloud, a cloud provider) | macOS dataless flag (folders spec); provider pipe | Folders: skipped `skipped_not_downloaded`; single files: single-read mode | "Not downloaded on the Mac" |

### 12.5 Data and integrity

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 49 | A block does not match its hash on arrival | CV comparison | Discard and ask again, 3 times; then `integrity` | "Arrived damaged three times" (rare: a bug or a failing device) |
| 50 | The CVs do not add up to the root | Merge result differs from `root` | Ask for the CVs again (`cvsOnly` want), compare, fetch blocks that differ; otherwise `integrity` | As 49 |
| 51 | Duplicate records | Block already durable or arrived | Ignore after checking | Nothing |
| 52 | Records out of order across streams | Normal | Written at their offsets; sequential destinations reorder in memory | Nothing |
| 53 | Malicious or broken peer data | Hash checks, field validation, limits | Reject blocks, fail items; after 20 mismatches pause `peer_errors` | "Stopped: MacBook sent data that didn't check out" |
| 54 | Malformed or oversized wire input | Validation before allocation | Session error; the transfer becomes `interrupted` | A reconnect at most |

### 12.6 Scale

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 55 | 100,000 small files | | Batched wants, group commits, parallel SAF calls (14.3) | Count-based progress: "37,201 of 100,000 files" |
| 56 | One 500 GB file | | 16 MB outboard; read-back resumes from `readback_upto`; about 43 QUIC key updates on the way (tested) | Normal |
| 57 | A transfer longer than a day | | Runs in the connected-device service, which has no time limit | Nothing |

### 12.7 Concurrency and lifecycle

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 58 | Two transfers want the same final name | `name_reservation` | The second takes the next free name | "Renamed: name (1).jpg" |
| 59 | The same file sent twice at once | A non-terminal transfer to that peer has an item with the same root | Ask; the default is not to send a second copy (question F4) | "Already sending video.mp4 to MacBook · Send another copy?" |
| 60 | The user pauses | | `xfer.pause`; nothing resumes on its own | "Paused by you" |
| 61 | The user cancels | | Both sides delete partials; finished files stay | "Cancelled · 37 files were saved" |
| 62 | The user restarts | | Unfinished items start over (question A6) | "Started over at 14:20" |
| 63 | Forget device during a transfer | | Cancel and delete all transfer state with that peer | The transfer disappears with the device |
| 64 | The receiver lost its state (reinstall, cleared data) | `xfer.unknown` | Under 1 GB left: restart on its own; otherwise ask (question A8) | "MacBook lost the partial data · Start over" |
| 65 | The sender lost its state | The receiver's partials wait; nobody resumes | They expire; if the same file is sent again, the receiver adopts the orphaned partial by root | Nothing; the next send is quicker |
| 66 | Peer on an older edition without `transfer.v1` | Capabilities | `files.v1` | "Older Bridgey on MacBook: can't resume" |
| 67 | Upstream Bridgey peer | Capabilities | `files.v1` | As 66 |

### 12.8 Clocks

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 68 | The two devices' clocks disagree | Not needed: nothing depends on the peer's clock | | Nothing |
| 69 | The local clock jumps forward | `last_wall_ms` against elapsed time | Expiry waits a day | Nothing |
| 70 | The local clock goes backwards | Timers are monotonic | Display only | Nothing |

### 12.9 Folders

| # | Mode | Detection | Response | What the user sees |
| --- | --- | --- | --- | --- |
| 71 | A folder transfer stops part-way | Session down, kill, pause | Saved files stay where they are; unfinished files keep their partials and resume inside the file; Cancel deletes only the partials (folders spec: completed files are never removed) | "Photos: 37 of 124 files saved · Waiting for MacBook" |
| 72 | Some files of a folder fail | Item states | The others continue; the transfer ends `incomplete`; Retry failed sends only those | "122 of 124 files verified · 2 failed · Retry failed" |
| 73 | The destination folder changes while a folder transfer is paused (files added, a clashing name appears) | `name_reservation` and the no-replace rename at finalise | The folders spec's Merge, Replace and Save-as-new rules apply at finalise time; a new clash gets the next free name; Replace keeps both if the existing file changed after the user's answer | "Renamed: IMG_0001 (1).jpg" |
| 74 | A folder or file entry cannot be created (invalid name, provider error) | Destination error | That entry fails (`invalid_name` or `io_error`); after 50 failed entries the folder transfer stops (folders spec `too_many_failures`) | The failures list in the details |

## 13. Recovery UX

### 13.1 States in plain words

| State | Card title | Detail line (example) | Main action |
| --- | --- | --- | --- |
| `active` | Sending / Receiving | "37 of 124 files · 812 MB of 2.3 GB · 12 MB/s · 2 min left" | Pause |
| `interrupted` | Waiting for MacBook | "Continues on its own when MacBook is back · 812 MB already there" | Pause |
| `paused` (user) | Paused | "Paused by you on the phone" | Resume |
| `paused` (`metered`) | Paused on mobile data | "1.2 GB left · you asked to be asked above 100 MB" | Continue on mobile data |
| `paused` (`storage_full`) | Phone storage full | "Needs 3.2 GB more" | Free up space |
| `paused` (`destination_unavailable`) | Can't reach Pictures | "Bridgey lost access to this folder" | Choose folder again |
| `paused` (`battery`) | Paused for battery | "Battery at 14%" | Continue anyway |
| `paused` (`thermal`) | Paused: phone too hot | | Continue anyway |
| `paused` (`quota`) | Relay limit reached | "Continues on Wi-Fi or at 05:30" | |
| `paused` (`sleeping`) | MacBook is asleep | "Continues when it wakes" | |
| `paused` (`app_stopped`) | Paused | "Bridgey was stopped" | Resume |
| `paused` (`io_error`) | Can't write to the drive | "Couldn't write to the USB drive twice" | Resume |
| `paused` (`ledger_full`) | No space for Bridgey's records | "Free some space so Bridgey can keep track" | Free up space |
| `paused` (`peer_errors`) | Stopped: data didn't check out | "MacBook sent data that failed its checks 20 times" | Details |
| `paused` (`needs_update`) | MacBook needs an update | "Update Bridgey on MacBook to continue this transfer" | Send with the older method |
| `verifying` | Checking | "Checking video.mp4 (62%)" | |
| `complete` | Sent / Received | "124 files · 2.3 GB · all verified" | Details |
| `incomplete` | Incomplete | "122 of 124 files verified · 2 failed" | Retry failed |
| `cancelled` | Cancelled | "37 of 124 files were saved" | Send again |
| `expired` | Removed | "Waited 7 days; the unfinished data was removed" | Send again |

### 13.2 The Stream

- One card per transfer in the Stream on Android and in the Mac's Stream panel; a folder is one card
  (folders spec). The card shows the route chip ("Same Wi-Fi", "Relay (Mumbai)").
- Activity stream kinds (edition, 200 items, 7 days): `transfer_sent`, `transfer_received`,
  `transfer_incomplete`, `transfer_cancelled`, alongside the folders spec's folder kinds. The detail
  line adds "all verified", "resumed 2 times" or "2 failed". The full record lives in the ledger.

### 13.3 Details: the ledger view and the verification report

```text
Photos -> MacBook Pro · Pictures/Trip                                   [Export report]
Complete · all verified
124 files · 9 folders · 2.31 GB · 25 Oct 14:02 to 14:09 (7 min) · 5.5 MB/s on average
Route: Same Wi-Fi 6 min, Relay (Mumbai) 1 min
Checked: every file piece by piece on arrival and again after it was saved (BLAKE3)
Interrupted 2 times: Wi-Fi lost at 14:05 (resumed after 40 s); Bridgey restarted at 14:07
Sent twice: 3 MB of 2.31 GB

[All 124] [Failed 0] [Skipped 15] [Renamed 2]
IMG_0001.jpg          2.4 MB   Verified   b3 9f2c…e41a
IMG_0002 (1).jpg      2.1 MB   Verified   renamed: a file with this name was already there
...
Skipped on the Mac: 3 links, 12 hidden files                               [Copy checksums]
```

Report sentences:
- "All 124 files verified."
- "1,248 of 1,250 files verified; 2 failed: 1 changed on MacBook while sending, 1 too big for the USB
  drive (FAT32 limit, 4 GB)."
- "Skipped on the Mac: 3 links, 12 hidden files, 48 system files."
- "Interrupted 3 times (Wi-Fi lost, MacBook asleep, Bridgey restarted); 6 MB sent twice."

Both devices show the report: the sender's ledger holds the receiver's confirmations (`xfer.item.ok`
with the saved name and root). Checksums in the report: question E2.

### 13.4 Actions

| Action | Where | What it does | Confirmation |
| --- | --- | --- | --- |
| Pause | Card, notification, CLI | Both sides stop; nothing resumes on its own; partials kept | None |
| Resume | Card, notification, CLI | Continues from what is saved | None |
| Cancel | Card, notification, CLI | Stops; deletes partial data on both sides; saved files stay | "Cancel? 37 files already saved stay on the phone. Unfinished data is deleted." |
| Restart | Details, CLI (`bridgey transfer restart`) | Unfinished files start over from zero; saved files untouched (question A6) | "Start the unfinished files over? 812 MB already on MacBook will be sent again." |
| Restart this file | A failed or unfinished file in the details | The same for one file | None |
| Retry failed | Card when incomplete, CLI | Failed files go back to the queue; sources checked again | None |
| Skip this file | A waiting or failed file | Marks it skipped by you | None |
| Send again | Cancelled, expired or complete transfers | A new transfer of the same items (new copies at the destination) | None |
| Verify again | Details on either device | The receiving device re-reads the saved files and checks them against the recorded hashes | Result: "1,250 checked: 1,248 match; 2 not found (moved or deleted)" |
| Export report | Details | Saves the report as `.b3`, `.csv` or `.json` | Share sheet or save panel |
| Copy checksums | Details | Copies the `b3sum` lines | None |

### 13.5 Notifications

Android (question E3):
- One ongoing notification per active transfer, inside the connection service's notification set;
  `Notification.ProgressStyle` on Android 16 and later, a plain progress bar before. Actions: Pause,
  Cancel. Queued transfers have no notification (the fix in folders spec 11.1).
- Interrupted: the same notification, quietly, "Waiting for MacBook…".
- Paused by a policy: its reason and action, for example "Continue on mobile data".
- Finished: one notification. Sender: "Photos saved on MacBook · 124 files, all verified". Receiver:
  "Saved Photos to Pictures/Trip · 124 files, all verified · Open".
- Incomplete: "Photos: 2 files couldn't be sent · Retry".
- A day before expiry: "Paused transfer of Photos will be removed tomorrow · Resume".
- Never more than one notification per transfer.

Mac: rows in the menu bar panel; a system notification only for finished, incomplete and
about-to-expire transfers, when notifications are allowed.

### 13.6 CLI

- JSON Lines events (`--jsonl`): `transfer.started`, `progress`, `interrupted` (`resumable`,
  `reason`), `resumed`, `paused` (`by`, `reason`), `item.failed` (`i`, `path`, `code`), `item.ok`
  (`i`, `path`, `b3`), `verifying`, `result` (`state`, `saved`, `verified`, `failed`).
- `bridgey transfers` lists the ledger; `bridgey transfer report ID [--json | --b3]` prints the
  report or `b3sum` lines.
- Exit codes from agent-cli.md: 0 complete; 9 incomplete or failed (the JSON lists the failures);
  11 interrupted but resumable; 3 unreachable.

### 13.7 Export formats

- `b3sum`: one line per verified file, `<64 hex digits>  <relative path>`. In the destination
  folder, `b3sum --check Photos.b3` re-checks everything with a standard tool.
- CSV: `path,size,status,code,b3,saved_name`.
- JSON: the whole report, including the timeline.

## 14. Throughput and scheduling

### 14.1 Wants and streams

| Route | Wants in flight | Want size, large files | Small files per want |
| --- | --- | --- | --- |
| LAN | 8 | 16 MiB | At most 512 files or 8 MiB |
| VPN, direct | 4 | 16 MiB | Same |
| Relay | 2 | 16 MiB | Same |
| Sequential-only destination | 2, in order | 16 MiB | Same |

The receiver adapts within these numbers: one fewer when its write queue stays above 75% for 2 s,
one more (up to the route's maximum) when the queue is below 25% and the last increase helped. Order
is the manifest's (question F3); within a file, ascending blocks.

### 14.2 Backpressure and memory

- **Receiver:** QUIC windows of 4 MiB per stream and 16 MiB per connection (connect-anywhere 7.4);
  write queue at most 16 MiB; reorder buffer at most 32 MiB, only for sequential destinations (and
  then smaller stream windows); hash workers read one block at a time.
- **Sender:** at most 2 blocks read ahead per response stream; the hash pass reads with 4 MiB buffers;
  at most 16 MiB in all.
- **Totals:** at most 32 MiB per transfer on the phone, at most 64 MiB for the engine.

### 14.3 Small files

- Roots come out of the folder scan (one read per file). Each file is one DATA record; one want covers
  up to 512 files.
- The receiver group-commits (256 files or 250 ms, 9.4).
- SAF: up to 4 `createDocument` and `renameDocument` calls in parallel (to be measured in T0: the
  provider may serialise them).
- MediaStore: inserts batched with `ContentResolver.applyBatch` where the results return the URIs (to
  be measured in T0).
- Targets: the folders spec's 2,000 files of 10 KB in under 60 s into a SAF place; the 100,000-file
  number is set after T0 measures the per-file cost on the OnePlus 11.

### 14.4 Writes

`pwrite` in 1 MiB units at 1 MiB-aligned offsets (today's code writes 24 KiB at a time); pre-allocate
where cheap; sequential order for FAT and exFAT; read-back one commit behind the writer.

### 14.5 Fairness and priorities

- Up to 3 active transfers per peer and direction share that peer's want budget round-robin; others
  wait in order (question F1).
- Interactive clipboard reads (`prio` 0) get their own stream with the highest quinn stream priority
  and are served first.
- Hashing and read-back run at background priority (`THREAD_PRIORITY_BACKGROUND` on Android, `.utility`
  QoS on macOS).
- Two peers at once (the phone sending to two Macs): each peer has its own budget, and the hash pass
  is shared.

### 14.6 quinn settings for transfers

| Setting | Value |
| --- | --- |
| `stream_receive_window` | 4 MiB; 8 MiB on a Mac or Linux LAN. The phone stays at 4 MiB everywhere (memory budget, 14.2) |
| `receive_window`, `send_window` | 16 MiB; 32 MiB on a Mac or Linux LAN. The phone stays at 16 MiB, which still covers its LAN and 5G round trips |
| ACK frequency extension | On, threshold 10 packets, when both peers are quinn (fewer ACKs cut the receiver cost that slows QUIC on fast links, research 7.2) |
| UDP socket buffers | 4 MiB send and receive where the OS allows |
| GSO and GRO | On (quinn-udp default); segment counts logged at startup on each platform |
| macOS datapath | quinn-udp default; the private-API `fast-apple-datapath` only if Rahul accepts the risk (question G6) |
| Congestion control | Cubic (connect-anywhere) |

### 14.7 Targets

| Path | Target | Gate (test-plan.md) |
| --- | --- | --- |
| Phone and Mac on the same Wi-Fi 6 access point | 250 to 350 Mbit/s (31 to 44 MB/s) | At least 30 MB/s, and at least 85% of iperf3 TCP between the same two devices |
| Phone on Wi-Fi, Mac on Ethernet | 450 to 550 Mbit/s | At least 45 MB/s and 85% of iperf3 |
| Mac and Linux on Gigabit Ethernet | At least 900 Mbit/s | At least 105 MB/s |
| Phone to Mac over mobile data | At least 90% of the measured uplink | Same |
| Own relay with a 50 Mbit/s cap | 45 to 48 Mbit/s | At least 90% of the cap |
| Resume after reconnecting | First byte within 3 s | p95 within 3 s |
| Phone CPU at 40 MB/s | Hashing, crypto and QUIC within 25% of one big core (inference) | Measured and reported |
| Memory | At most 32 MiB per transfer on the phone | Same |

## 15. Platform notes

### 15.1 Android

1. **Where it runs.** All engine work runs in the app process inside `BridgeyConnectionService`,
   already a `connectedDevice` foreground service. Call
   `startForeground(id, notification, FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)` explicitly, and
   never add `dataSync` to that service: a service declared with both and started without a type
   inherits `dataSync`'s 6-hour limit.
2. **Bridgey turned off.** Sharing files while "Turn off Bridgey" is in effect starts the service in
   transfer-only mode (allowed: the app is on screen at share time). It stops when the last transfer
   ends or is paused by the user, or after 10 minutes without reaching the other device; waiting
   transfers then continue the next time Bridgey runs. The setting itself does not change.
3. **Wake lock.** `PARTIAL_WAKE_LOCK` only while bytes flow, released after 30 s without progress.
   No Wi-Fi lock: on Android 14 and later the only working mode needs the screen on and the app in
   front.
4. **Battery optimisation.** At the first transfer expected to take more than 10 minutes, Bridgey
   explains why and offers the system dialog `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (allowed
   outside Google Play), question C5. Checked again at every launch, because OnePlus phones reset it.
5. **OnePlus checklist,** shown once after the first unexpected death during a transfer, and always
   reachable from Settings > Files > "Keep transfers running": Battery > don't optimise Bridgey; App
   battery management > "Allow background activity" and "Allow auto launch"; Battery > More settings
   > "Sleep standby optimization" off; lock Bridgey in Recents. The exact OxygenOS 16 labels are
   checked on Rahul's phone in T0.
6. **Resume triggers.** `START_STICKY` restarts; `BOOT_COMPLETED` when transfers are waiting
   (new normal permission `RECEIVE_BOOT_COMPLETED`; `connectedDevice` may start from it on Android 15
   and later), question C7; `MY_PACKAGE_REPLACED` after an update; opening the app; the network
   callback. After `REASON_USER_REQUESTED`, nothing resumes on its own.
7. **User-initiated data transfer jobs: not in the first release.** The connected-device service has
   no time limit and keeps network in Doze; a second execution container adds failure modes. Decision
   gate in T0 and T11: if kill tests on the OnePlus 11 show sticky restarts failing while jobs
   survive, add one persisted job per phone-initiated transfer (`setUserInitiated(true)`, a custom
   `NetworkRequest` without `VALIDATED` for LAN routes, `setNotification` within 10 s,
   `updateTransferredNetworkBytes`).
8. **Metered networks.** `NET_CAPABILITY_NOT_METERED` or `NET_CAPABILITY_TEMPORARILY_NOT_METERED`
   count as Wi-Fi. Otherwise the connect-anywhere setting "Ask before using mobile data above"
   (default 100 MB) applies to the bytes still to move; with Data Saver on, Bridgey asks below the
   threshold too (question C1).
9. **Sources.** Grants are persisted at pick time (`takePersistableUriPermission` for documents and
   photo picker items) and released when the transfer ends. Share-sheet items cannot be persisted:
   they are passed to the service with `FLAG_GRANT_READ_URI_PERMISSION`, and if the grant is gone
   after a restart, the item asks to be shared again (row 46). Whether a redelivered start intent
   keeps the grant across a kill is tested in T0.
10. **Notifications:** section 13.5. Without the notification permission, progress shows only in the
    Task Manager and in the Stream.
11. **Android 17 (target 37).** The local network permission (`ACCESS_LOCAL_NETWORK`) becomes
    mandatory for LAN routes (a connect-anywhere item); buffers are already bounded for the new memory
    limiter.

### 15.2 macOS

1. `ProcessInfo.beginActivity(options: .userInitiated, reason: "Transferring files")` while bytes
   flow: no App Nap, no idle system sleep, no sudden termination. Ended after 30 s without progress.
   Question C6 decides whether the Mac may idle-sleep during transfers
   (`.userInitiatedAllowingIdleSystemSleep`).
2. `willSleepNotification`: commit, `F_FULLFSYNC` the partials, send `xfer.pause` (`sleeping`), all
   inside the 30 s Apple allows. `didWakeNotification` plus a satisfied `NWPathMonitor`: resume, and the
   session reconnects through connect-anywhere.
3. Closing the lid sleeps the Mac unless it is in closed-display mode; transfers pause and resume.
4. Quitting: orderly checkpoint in `applicationWillTerminate`; "Launch at login" brings Bridgey back.
5. Sources: the app is not sandboxed; bookmark data is kept anyway to find moved files. macOS may ask
   again for access to protected folders such as Documents after a restart.
6. Metered: `NWPath.isExpensive` (an iPhone hotspot) and `isConstrained` (Low Data Mode) follow the
   mobile data policy.

### 15.3 The CLI

1. `bridgey agent` (one per profile) owns the ledger and the sessions; other commands talk to it over
   the agent socket (agent-cli.md). It stays alive while any transfer is not terminal, instead of
   exiting after 10 idle minutes.
2. Phase 2 `bridgey daemon` runs as a systemd user unit with `Restart=on-failure` (plus
   `loginctl enable-linger` on servers) or a launchd agent; transfers resume when it restarts.
3. On laptops a logind `delay` inhibitor lets it checkpoint on `PrepareForSleep`.
4. `--single-read` avoids the second read on slow disks.

### 15.4 Windows and Linux apps (v2)

- **Windows:** a per-user tray app, not a service. During transfers, `PowerSetRequest` with
  `PowerRequestSystemRequired` and `PowerRequestExecutionRequired`, and an opt-out of EcoQoS
  (`PROCESS_POWER_THROTTLING_EXECUTION_SPEED` off). Modern Standby pauses transfers; they resume on
  wake. `ConnectionCost` feeds the metered policy. Storage rules in 10.7.
- **Linux desktop:** a systemd user service, or a Flatpak with the Background portal; a sleep delay
  inhibitor; NetworkManager's `Metered` property; document portals for file access under Flatpak.

## 16. Compatibility and upgrades

| Other device | What runs | Resume | Report |
| --- | --- | --- | --- |
| Edition with `transfer.v1` | The engine | Yes | Full |
| Edition build without `transfer.v1`, or upstream 0.6 | Today's `files.v1` code | No: an interrupted file starts again from zero, automatically for files under 1 GB, otherwise with a Retry button (question G1) | "Older method": SHA-256 checked, no resume |
| Edition build with folders but no engine | Folders spec over `files.v1`, with its own journal (file-level resume within 30 minutes, button for 24 hours) | Per file | Recorded in the ledger |

- **Legacy recording.** `record_legacy` events (`started`, `progress`, `finished`) keep `files.v1`
  transfers in the same ledger and the same report screen.
- **Ledger upgrades.** `PRAGMA user_version`; migrations only go forward and copy `ledger.db` to
  `ledger.db.v<N>.bak` first (kept 7 days). An older app that finds a newer schema opens nothing,
  deletes nothing and says "Transfers are paused until Bridgey is updated".
- **Protocol evolution.** Unknown JSON fields are ignored; unknown record types with the ignorable
  flag are skipped; a later `transfer.v2` is negotiated per session. Each transfer records the
  protocol version it started with and continues only with a peer that supports it.
- **Behaviour that changes for edition peers.**
  - README: "retrying creates a new transfer and starts from byte zero" becomes Resume.
  - The 20 in-memory history entries per client become the ledger.
  - Folders spec: "the file in progress is deleted" after an interruption becomes "kept, and resumed
    inside the file".
  - connect-anywhere section 8 is replaced by this document.

## 17. Security and privacy

The threat model in SECURITY.md stands. Additions:

| Risk | Mitigation |
| --- | --- |
| A compromised paired device fills the disk | Free-space reserve; agent grants (2 GB per transfer, 5 GB a day by default, agent-cli.md); every transfer is visible |
| Path traversal through manifests | Folders spec name and path rules; paths built only from validated components; the Mac never follows symlinks in the destination |
| Resource exhaustion | Limits in 7.5 checked before allocation; manifests streamed with a 64 MiB cap; wants bounded per transfer and per session |
| Data tampering | Per-block and root checks; nothing unverified gets a final name |
| Replay | The session's replay cache; idempotent handlers |
| Partial data at rest | App-private or hidden partials; MediaStore pending items readable only by Bridgey; deleted on cancel, expiry and Forget device |
| The ledger | Names and checksums stay on the device, owner-only, no backup; never in logs or diagnostics; logs show 8-character ID prefixes |
| Exported reports | Contain names and checksums; made only when the user asks |

Diagnostics gain counters only: transfers by outcome, error-code counts, resumes, re-sent bytes in
buckets, verification failures.

## 18. Upstream

- **Offer:** the `transfer.v1` text with the connect-anywhere protocol discussion; the
  `bridgey-transfer` crates (MIT) with their test vectors (BLAKE3 tree, manifest, ledger recovery
  fixtures); the simulation harness.
- **Unbranded on the wire:** `xfer.*`, `BXR1`, `BXM1`, `BXCV`, `.bridgey-part`.
- **Risk:** a native (non-Rust) implementation needs a BLAKE3 library with subtree hashing for
  per-block checks; the Rust crate has it, others are unverified (inference). Mitigation: the crate is
  the reference implementation; a native client can still check whole files with any BLAKE3 library.

## 19. Configuration defaults

One `TransferConfig` struct holds the engine's defaults, so tests and builds read them from one place.
User-facing values come from Settings and are listed in the questions.

| Key | Default |
| --- | --- |
| `block_size` | 1 MiB (fixed in v1) |
| `want_bytes` | 16 MiB |
| `max_wants_lan`, `_direct`, `_relay` | 8, 4, 2 |
| `small_want_items`, `small_want_bytes` | 512, 8 MiB |
| `commit_bytes`, `commit_interval` | 64 MiB, 2 s |
| `group_commit_files`, `group_commit_interval` | 256, 250 ms |
| `verify_level` | `readback` |
| `change_policy` | `new_version` |
| `settle_quiet`, `settle_max` | 5 s, 60 s |
| `stall_timeout` | 60 s |
| `offer_timeout` | 15 s, 3 resends |
| `question_timeout` | 180 s |
| `partial_retention` | 7 days |
| `pending_refresh_interval` | 3 days (Android 11+) |
| `history_retention` | 30 days, 1,000 transfers |
| `reserve` | The larger of 2 GB and 5% |
| `auto_restart_legacy_below`, `auto_restart_lost_state_below` | 1 GB |
| `max_items`, `max_dirs` | 100,000, 20,000 |
| `max_file_size` | 4 TiB |
| `active_per_peer_direction` | 3 |
| `battery_pause_below`, `battery_resume_at` | 15%, 20% |
| `mismatch_limit_block`, `mismatch_limit_transfer` | 3, 20 |
| `quic_fallback_after` | 10 s |

## 20. Calls made in this design

Judgement calls made without asking; each is open to change.

1. BLAKE3 instead of SHA-256, which changes connect-anywhere 8.2.
2. 1 MiB blocks, with leaf chaining values as the outboard rather than bao's format.
3. Receiver-driven wants instead of a sender push, which changes connect-anywhere 8.3 to 8.6.
4. Two reads on the sender by default (hash pass, then a re-hash while serving).
5. Read-back verification on by default (question A2).
6. An SQLite ledger plus small side files that allow a rebuild.
7. Mac partials staged in Application Support when they are on the same volume as the destination.
8. The engine needs the QUIC tunnel; without it on the LAN for 10 s, `files.v1` is used.
9. No user-initiated data transfer jobs in the first release, with a decision gate.
10. A new permission, `RECEIVE_BOOT_COMPLETED` (question C7).
11. Single files on the Mac keep "name 2.ext"; folders keep "name (1).ext".
12. The folders spec's "the file in progress is deleted" becomes "kept and resumed".
13. `files.v1` transfers recorded in the ledger while native code still moves their bytes.
14. 3 active transfers per peer and direction (question F1).
15. Partials are never deleted before expiry to make room (question B4).
16. Manifests over 8 KiB travel on a QUIC stream as JSON Lines.
17. Retention and history values (questions A5 and E1).
