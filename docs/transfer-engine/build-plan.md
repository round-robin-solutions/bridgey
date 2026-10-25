# Transfer engine: build plan

Status: plan for Bridgey by Round Robin, 2026-10-25. It builds [design.md](design.md) to the gate in
[test-plan.md](test-plan.md). Rahul's process: research with Opus at max effort (done), then build with
Sonnet where Sonnet can do the job, otherwise Opus at medium effort. The engine ships in one release,
so every phase below lands behind a developer switch and goes out together (question G3).

Sizes are relative and use the connect-anywhere scale: S is about 1 unit, M about 2 to 3, L about 4
to 6; one unit is roughly one focused week of one builder. This plan replaces connect-anywhere's
phase P4 ("Resumable transfer", sized L), which assumed a smaller engine.

## 1. Phases at a glance

| Phase | What | Size | Builder | Needs |
| --- | --- | --- | --- | --- |
| T0 | Spikes and device measurements | S | Sonnet | connect-anywhere P0 for the QUIC item only |
| T1 | Core foundations: identifiers, codecs, manifest, BLAKE3 tree | M | Opus medium | |
| T2 | Core state machines, scheduler, policies | L | Opus medium | T1 |
| T3 | Deterministic simulation harness and property tests | M | Opus medium | T2 (starts on its skeleton) |
| T4 | Ledger, sync ordering and recovery | M | Opus medium | T1 |
| T5 | Storage and sources for Mac, Linux and the CLI | M | Sonnet | T4 |
| T6 | QUIC binding and the network matrix | M | Opus medium | T2; connect-anywhere P1 |
| T7 | Android storage and sources | L | Opus medium | T4, T5; connect-anywhere P1 |
| T8 | Android lifecycle and policies | M | Opus medium | T6, T7 |
| T9 | App UI: Stream cards, details, actions, notifications | L | Sonnet | T1 (mock engine); T6 to T8 for real data |
| T10 | Clients on the engine: folders, clipboard, CLI | M | Sonnet | T6; folders build; clipboard-files merged; connect-anywhere P5 for the CLI |
| T11 | Legacy bridge for `files.v1` | S | Sonnet | T4 and the FFI |
| T12 | Robustness campaign | L | Sonnet builds and runs; Opus medium triages failures | T0 to T11; connect-anywhere P3 for relay rows |
| T13 | Beta and release | M | Opus medium for fixes; Sonnet for release steps | T12 |

Total: about 40 units of work. The longest chain is T1, T2, T6, T8, T12, T13 (about 20 units), once
connect-anywhere P1 is in place; everything else runs beside it as parallel agents in their own
worktrees.

```text
T0 ----------------------------------------------.
T1 --> T2 --> T3 (simulation)                      \
   |      `--> T6 (QUIC) --. --> T8 (Android life) --> T12 (campaign) --> T13 (Beta, release)
   `--> T4 --> T5 --------> T7 (Android storage) -'     ^
               T9 (UI, mock first) ---------------------|
               T10 (folders, clipboard, CLI) -----------|
               T11 (legacy bridge) ---------------------'
connect-anywhere: P0 -> T0 (QUIC item); P1 -> T6, T7; P3 -> T12 relay rows; P5 -> T10 CLI part
```

## 2. Phases

### T0. Spikes and device measurements (S, Sonnet)

**Why Sonnet:** each item is a scripted measurement with a fixed procedure and a number to report.
Opus reviews any result that changes the design.

Measure on the OnePlus 11 and both Macs, and write the numbers to
`docs/transfer-engine/results/t0.md`:
- BLAKE3: the 1 MiB subtree tree equals `blake3::hash`; hashing speed on the phone's big and middle
  cores and on both Macs.
- quinn: goodput phone to Mac on Rahul's Wi-Fi, GSO and GRO segment counts, CPU use (needs the
  connect-anywhere P0 spike build).
- Android storage: MediaStore insert and `applyBatch` cost; SAF `createDocument` and `renameDocument`
  cost, one at a time and 4 in parallel; `fdatasync` cost; whether MediaStore hands out a FUSE or a
  lower-filesystem fd; whether setting `IS_PENDING=1` again keeps the URI working; `"rw"` on a USB
  stick.
- macOS: `F_FULLFSYNC` and `F_BARRIERFSYNC` cost; `renamex_np(RENAME_EXCL)` on APFS and exFAT.
- Android lifecycle on OxygenOS 16: sticky restart after `am kill`; behaviour with deep optimisation;
  whether a share grant survives a kill through a redelivered intent; whether Low Power Standby exists;
  the exact battery setting labels for the OnePlus checklist.

**Done when:** the results note exists and the design's small-file target, SAF parallelism and the
user-initiated-job decision gate are set from real numbers.

### T1. Core foundations (M, Opus medium)

**Why Opus:** the wire codecs, identifiers and BLAKE3 tree are what everything else stands on;
mistakes here become protocol bugs that both apps would have to carry.

- The `bridgey-transfer-core` crate skeleton and `TransferConfig` (design 19).
- Range sets; the manifest model and validation, reusing `protocol/test-vectors/folders-v1.json`.
- Control message types with a JSON schema in `protocol/schema/transfer-v1.schema.json`; the record
  codec (`BXR1`, `BXM1`, `BXCV`).
- BLAKE3 tree helpers on `blake3::hazmat` and the vectors in `protocol/test-vectors/transfer-v1.json`.
- Unit tests and the codec fuzz targets (test plan 3 and 6).

**Done when:** vectors pass in CI and each codec fuzzer has run 1 hour clean.

### T2. Core state machines and scheduler (L, Opus medium)

**Why Opus:** this is where robustness lives. Idempotent handlers, the state tables, the change policy
and the interaction of pauses, retries and resumes need judgement at every step.

- Transfer, item and block state machines (design 8); `Core::handle(Event) -> Vec<Action>`.
- The want scheduler: windows per route, adaptation, priorities, fairness across transfers (design 14).
- Policies: metered, battery, thermal, change (design 11); timers and retries (design 8.4 and 8.5).
- The reference model for property tests (test plan 4).

**Done when:** 200,000 property cases pass and every row of the failure catalogue (design 12) is
mapped to a test or a simulation fault type.

### T3. Deterministic simulation (M, Opus medium)

**Why Opus:** the harness decides what the tests can find; a weak fault model gives false confidence,
which is worse than no harness.

- `bridgey-transfer-sim`: simulated network, storage profiles (APFS-like, FAT-like, SAF-like,
  MediaStore-like), crashes, clocks and source versions (test plan 5).
- Fault points, the invariant checker (I1 to I12), seed replay.
- CI: 500 seeds per push, 20,000 nightly, 200,000 weekly on RR CI.

**Done when:** the harness catches 5 bugs planted on purpose (one per invariant family), and 100,000
seeds pass on T2's code.

### T4. Ledger, sync ordering and recovery (M, Opus medium)

**Why Opus:** crash consistency (data before ledger, fsync errors, salvage, rebuild) is subtle, and
it is the most expensive place to be wrong: an error here loses or corrupts users' files.

- SQLite schema, migrations and settings (design 9.2); side files and outboards (9.1, 9.3).
- Batch commits with the per-platform sync rules (9.4); group commits for small files.
- Startup recovery: finish half-done steps, salvage, re-verify after a reboot, rebuild (9.5).
- Retention and clean-up (9.6).
- The Linux crash suites: kill loop, LazyFS, dm-log-writes, dm-flakey (test plan 9).

**Done when:** the Linux parts of test plan section 9 pass.

### T5. Storage and sources for Mac, Linux and the CLI (M, Sonnet)

**Why Sonnet:** the calls and their order are spelled out in design 10.2, 10.3 and 11.1, and the
tests are concrete.

- The POSIX destination adapter: partial placement, pre-allocation, syncs, finalise without replace,
  read-back with `F_NOCACHE` or `POSIX_FADV_DONTNEED`.
- Capability detection (design 10.1), including FAT and exFAT sequential mode and the 4 GiB limit.
- Snapshots (11.1), macOS bookmarks and volume events.

**Done when:** tests pass on Linux (ext4, XFS and exFAT loop devices) and macOS (APFS and exFAT disk
images).

### T6. QUIC binding and the network matrix (M, Opus medium)

**Why Opus:** stream lifecycles during connection migration, flow control and throughput tuning need
debugging judgement and measurement.

- Manifest and response streams on `bridgey-connect`; control messages on stream 0 through the
  existing session crypto.
- quinn settings (design 14.6), stream priorities, stall detection, session up and down, the
  fallback to `files.v1` after 10 s without QUIC.
- The network-namespace matrix (test plan 8).

**Done when:** the section 8 matrix passes and LAN goodput between two Linux hosts reaches 85% of
iperf3.

### T7. Android storage and sources (L, Opus medium)

**Why Opus:** MediaStore and the Storage Access Framework behave differently across Android versions
and providers, and the design carries many edge rules (pending expiry, "wt" instead of "w", renamed
URIs, grants that end).

- MediaStore adapter: the pending flow, the 3-day refresh, the Android 10 sweep (design 10.4).
- SAF adapter: partials, rename, replace, pipes, volume callbacks, lost grants and re-adoption of
  partials (10.5).
- Source adapter: persisted grants, photo picker items, share grants, snapshots, pipes (11, 15.1).
- Small-file batching and parallel SAF calls, sized by T0's numbers (14.3).

**Done when:** instrumented tests on the OnePlus 11 pass for the storage rows of test plan 10.1.

### T8. Android lifecycle and policies (M, Opus medium)

**Why Opus:** foreground-service type rules, restarts, exit reasons and OEM behaviour only fail on real
devices, and the rules differ between Android 10 and 17.

- Integration with `BridgeyConnectionService` (explicit `connectedDevice` type), transfer-only mode,
  wake lock (design 15.1).
- The battery optimisation prompt and the OnePlus checklist (questions C5); `RECEIVE_BOOT_COMPLETED`
  (C7); `MY_PACKAGE_REPLACED`; `ApplicationExitInfo`.
- Metered, battery and thermal feeds into the engine (C1, C3, C4).
- The decision gate for user-initiated data transfer jobs, from T0 and the kill tests.

**Done when:** the lifecycle rows of test plan 10.1 pass on the OnePlus 11.

### T9. App UI (L: Android M, Mac M, Sonnet)

**Why Sonnet:** UI work against a fixed API, the copy in design 13 and the existing Stream design. It
starts on a mock engine and switches to the real one when T6 to T8 land.

- Android: Stream cards, the details screen and report, actions, export, notifications
  (`ProgressStyle` on Android 16+), Settings rows for the answers to the questions.
- Mac: Stream panel rows, the details window, export, sleep and wake hooks, the activity assertion.
- The design rules in AGENTS.md (one main action per screen, light and dark, no layout shift).

**Done when:** screens are checked on the phone and both Macs, and every catalogue message appears
with the right wording.

### T10. Clients on the engine (M, Sonnet)

**Why Sonnet:** each client follows an existing spec, and the adapters are thin.

- Folders: the destination plan and the question messages from the folders spec, mapped onto
  `xfer.offer` (design 4.4).
- Clipboard: eager items and lazy paste with ranges, Android's `openProxyFileDescriptor` reader.
- CLI: `bridgey send`, `bridgey transfers`, `bridgey transfer resume|cancel|restart|report`, JSON
  Lines and exit codes (needs connect-anywhere P5).

**Done when:** the folders two-device checklist is re-run on the engine, a 2 GB video pasted from the
clipboard plays with seeking, and the CLI tests pass.

### T11. Legacy bridge (S, Sonnet)

**Why Sonnet:** small, well-defined hooks in existing native code.

- `record_legacy` calls from the Android and Mac `files.v1` paths; the automatic restart rule
  (question G1); the "older method" labels.
- Interop runs with upstream 0.6 in both directions.

**Done when:** gate G12 passes.

### T12. Robustness campaign (L: Sonnet runs, Opus medium triages)

**Why both:** building the rigs and running them follows the test plan step by step, which Sonnet
does well. Finding the root cause of each failure needs judgement and evidence (AGENTS.md rule 5), so
every failure goes to an Opus medium agent.

- The rigs of test plan 16; soaks S1 to S7; the device matrix; performance tables in
  `docs/transfer-engine/results/<version>.md`.
- Relay rows need connect-anywhere P3; direct-route rows need P2.

**Done when:** gates G1 to G13 are met.

### T13. Beta and release (M: Opus medium for fixes, Sonnet for release steps)

**Why both:** bugs from real use need debugging judgement; the release itself is scripted
(`scripts/rr/release.sh`, RR CI tags).

- The engine in Nightly behind the developer switch (question G3); the Beta period (question G5).
- Fixes with regression tests; release notes in plain words; Stable release with the switch on.

**Done when:** gates G14 and G15 are met and the release is published.

## 3. How builders work

- **One worktree per phase,** on a branch from the engine's integration branch; pull requests go
  through RR CI (`rust`, `android`, `macos` tasks).
- **Every brief carries:** the design sections for the phase, the invariants from the test plan, and
  the AGENTS.md rules that apply (root cause before a fix, exactly the ask, scoped checks, keep
  existing conventions, ask about product decisions, no em dashes, Round Robin branding).
- **Every phase's pull request gets a Claude review agent** before merge, and the simulation seeds run
  on it. S1 bugs block the merge.
- **Questions:** phases T2, T7, T8 and T9 depend on Rahul's answers in
  [questions-for-rahul.md](questions-for-rahul.md). Unanswered questions are built with the
  recommended option and listed as open calls.

## 4. Fit with connect-anywhere

| connect-anywhere phase | What the engine needs from it |
| --- | --- |
| P0 spike | quinn on Android, for T0's throughput item |
| P1 routes and the Rust core | The core skeleton, UniFFI in both apps and the QUIC tunnel on the LAN, before T6, T7 and T8 |
| P2 direct over the internet | Direct-route rows in T12 |
| P3 relay pool | Relay rows and soak S4 in T12 |
| P4 resumable transfer | Replaced by T1 to T12 |
| P5 CLI phase 1 | The CLI part of T10 |
| P6 CLI phase 2 | The daemon, which keeps CLI transfers running across restarts |

The engine ships in the same release as connect-anywhere's QUIC tunnel (question G2). Until then, every
transfer keeps today's `files.v1` behaviour.
