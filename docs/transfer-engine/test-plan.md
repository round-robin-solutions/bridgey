# Transfer engine: test plan and release gate

Status: plan for Bridgey by Round Robin, 2026-10-25. It tests the design in [design.md](design.md);
tool facts are in [research.md](research.md#9-testing-prior-art). Rahul's bar: "very, very, very,
very robust", shipped in one release. So the engine ships only when every gate in section 15 is met,
with numbers.

## 1. Approach

| Layer | What is tested | How | Where |
| --- | --- | --- | --- |
| Core (sans-IO) | State machines, scheduler, policies, codecs | Unit tests, property-based state machine tests, deterministic simulation with fault injection, fuzzing, mutation testing | RR CI Linux runners |
| Driver | QUIC streams, ledger, sync ordering, recovery | Real quinn in network namespaces with `tc netem`; kill loops; power-loss simulation (LazyFS, dm-log-writes, dm-flakey) | RR CI Linux runners. Namespaces, netem, device-mapper and FUSE need root: if the fleet cannot run privileged jobs, these run in a disposable VM and the results say so |
| Platform | Android and macOS storage, lifecycle, background rules | Scripted device matrix (`adb`, `pmset`), removable media, OEM settings | Rahul's OnePlus 11, personal Mac, work Mac |
| End to end | Everything together, for days | Soak tests, the cross-platform matrix, a Beta period | Devices plus a Linux host with a large disk |

Rules:
- **Every failure gets a reproduction** (a seed, a script or a device recipe) and a regression test
  before its fix merges.
- **Severity:** S1 is data loss, a mixed version, an unexpected overwrite or a false "verified"; S2 a
  transfer stuck without a reason or a broken re-send bound; S3 wrong or missing text, slowness; S4
  cosmetic. Any S1 blocks the release and resets the counters in section 15 for the code involved.
- **Heavy suites run on RR CI** (AGENTS.md rule 11): the `rust` task on every push (unit, property,
  500 simulation seeds, 10 minutes of fuzzing per target); nightly and weekly long runs as listed
  below; the device matrix on Rahul's devices.

## 2. Invariants

Every layer checks the same invariants. They are the promises of design section 2 turned into
checks.

| # | Invariant | Checked |
| --- | --- | --- |
| I1 | **Durable means present.** Every block the receiver's ledger calls durable reads back from storage with its chaining value | After every simulated crash, after every kill and power-loss iteration, at the end of every test |
| I2 | **Nothing unverified under a final name.** Every file under its final name has the sender's root. (The optional fast mode for small files, question D1, is tested separately with its own rule: an unverified final file exists only between a crash and the next startup sweep) | Destination scan at the end and after every crash |
| I3 | **No unexpected overwrite.** Files that were in the destination before the test are byte-identical afterwards, unless Replace was chosen; then they change only after the new file verified | Pre-test hash of the destination, compared at the end |
| I4 | **Exact copy.** Each saved file equals one version the source actually had (the simulator records every version); never a mix | Simulation; real tests with scripted source edits |
| I5 | **Every item accounted for.** Each item ends in exactly one terminal state on each side; both ledgers agree; saved, failed, skipped and cancelled add up to the item count | End of every run |
| I6 | **Bounded re-send.** A network drop re-sends at most 1 MiB per open stream plus the bytes that were in flight (never more than the connection window); an app kill re-sends only blocks that never reached storage; a power loss re-sends at most the unsynced batch plus blocks the storage cache lost | Byte accounting in the simulator and in real runs |
| I7 | **Liveness.** With the network up for 60 s in a row and nothing paused, every unfinished transfer makes a block durable within 60 s, or shows a blocking reason | Simulation; network matrix |
| I8 | **Waiting is explained.** A transfer without progress for 10 s is in a state other than `active`, with a reason | Simulation; device matrix (screen text) |
| I9 | **Clean-up.** After cancel or expiry no partial, outboard or pending item of that transfer remains after the next sweep; no orphans after the startup sweep | Destination and app-storage scans |
| I10 | **Bounded memory.** At most 32 MiB of buffers per transfer on the phone build and 64 MiB for the engine | Allocator counters in tests; heap dumps on the phone |
| I11 | **Idempotence.** Duplicating, reordering or replaying any control message changes no outcome | Simulation fault types |
| I12 | **Rebuild is safe.** Rebuilding from the side files gives a durable set no larger than what is on storage; after salvage it equals it | Simulation; ledger corruption tests |
| I13 | **Privacy.** Logs and diagnostics never contain file names, paths, checksums or full IDs | Log capture and a grep in every suite |
| I14 | **Responsive API.** Every FFI call returns within 50 ms | Timing in tests and on devices |

## 3. Unit and vector tests

- **BLAKE3 tree.** The root built from 1 MiB chaining values equals `blake3::hash` for sizes 0, 1,
  1,023, 1,024, 1,025, 2^20 - 1, 2^20, 2^20 + 1, 3 * 2^20 + 5 and 2^32 + 7 (generated content), and
  for 1,000 random sizes up to 3 GiB nightly. The vectors go into `protocol/test-vectors/transfer-v1.json`
  and are cross-checked with the `b3sum` command.
- **Range sets:** merge, subtract, intersect, encode and decode; property tests against a bitmap
  model.
- **Manifest:** the folders spec vectors (`protocol/test-vectors/folders-v1.json`: portable names,
  paths, case clashes) plus digest checks, ordering rules, limits (100,000 items, 20,000 folders,
  64 MiB) and malformed JSON Lines (truncated lines, duplicate indexes, a child before its parent).
- **Records:** every type, flag and length, short reads, records split across QUIC frames at every
  byte position.
- **Control messages:** every message at its minimum and maximum values, with unknown fields, wrong
  types and over-limit sizes.
- **Ledger:** schema creation, every migration, a corrupt file, a newer schema (refuse, delete
  nothing).
- **Snapshots:** equality and "racy" rules per platform, including null fields.
- **Policies:** tables for metered, battery, thermal and change policy decisions.

## 4. Property-based state machine tests

- **Tool:** `proptest` with `proptest-state-machine`. A reference model (items, their durable block
  sets, terminal states, who paused what) runs next to the real core with in-memory I/O.
- **Transitions generated:** user actions (pause, resume, cancel, restart, retry, skip, verify again)
  from either device; session up and down; delayed, duplicated and reordered control messages; sync
  errors, `ENOSPC`, `EIO`, short writes; crashes that keep written data or lose unsynced data; source
  edits (modify a block, append, truncate, delete, replace the file); clock steps and jumps; metered,
  battery and thermal changes.
- **After every step:** I1 to I12. Failures shrink to the shortest sequence and are saved in
  `proptest-regressions/`.
- **Budget:** 2,000 cases of up to 200 steps on each push; 200,000 cases nightly.

## 5. Deterministic simulation

`bridgey-transfer-sim` runs two or three engine cores (phone, Mac, CLI) in one thread with simulated
time, as FoundationDB and TigerBeetle do.

| Simulated part | What it can do |
| --- | --- |
| Network | Latency 1 to 500 ms, bandwidth 1 Mbit/s to 1 Gbit/s, loss 0 to 20%, reordering, duplication, partitions, route changes, session drops, a peer offline for simulated days |
| Streams | Ordered delivery per stream, flow-control windows, resets, stop-sending |
| Storage profiles | APFS-like (random access, holes, pre-allocation); FAT-like (sequential only, 4 GiB limit, zero-fill); SAF-like (20 to 100 ms per call, rename may return a new URI, grant can be revoked); MediaStore-like (pending items, 7-day expiry, renames on collision) |
| Crashes | Process kill (written data stays, memory goes); power loss (unsynced data goes; optionally some synced data goes, to model storage caches that lie); torn writes |
| Clocks | Monotonic and wall clocks with forward and backward jumps |
| Sources | Versions over time: edits, appends, truncation, deletion, replacement, files still being written |

- **Fault points.** The driver code carries named fault points (`fault!(sync_error)`,
  `fault!(short_write)`, `fault!(slow_hash)`, `fault!(rename_new_uri)` and so on), compiled only into
  simulation builds. Each run turns on a random subset of fault types (swarm testing); each enabled
  point fires with probability 0.25, following FoundationDB's BUGGIFY defaults.
- **Workloads.** 1 to 3 transfers per run, 1 to 2,000 items, virtual sizes from 0 bytes to 8 GiB.
  Content is generated from the seed, so nothing is stored.
- **A run ends** when every transfer is terminal or a simulated week passes; invariants are checked
  throughout.
- **Seeds:** 500 per push (under 10 minutes), 20,000 nightly, 200,000 weekly. A failure prints its
  seed; `cargo run -p bridgey-transfer-sim -- --seed <n>` replays it exactly.
- **QUIC.** The core does not need QUIC. The stream adapter is tested deterministically with
  quinn-proto's in-memory endpoint pair and a fixed `rng_seed`.

## 6. Fuzzing

| Target | Input |
| --- | --- |
| `control_messages` | Every `xfer.*` payload: decode and validate |
| `manifest_jsonl` | Manifest bytes, with digest and rules |
| `record_stream` | `BXR1` streams cut into arbitrary chunks |
| `cvs_records` | CV records against an item's block count |
| `outboard` | Outboard headers and bodies |
| `ranges` | Range-set encoding |
| `side_files` | `transfer.json`, `partials.log` (with torn last lines) |
| `core_events` | Arbitrary event sequences into the core (`arbitrary` crate), with invariants as assertions |

- **Tools:** `cargo-fuzz` (libFuzzer, nightly Rust with AddressSanitizer); ClusterFuzzLite in CI
  (10 minutes per target on each push, 1 hour nightly). Corpora are checked in; every crash becomes a
  regression test.
- **Gate:** at least 24 hours per target on the release candidate, no crash, hang or out-of-memory.

## 7. Mutation testing

`cargo mutants --in-diff` on `bridgey-transfer-core` for each pull request. Gate: no missed mutant in
the state machine, scheduler, range set and recovery modules, unless a code comment explains why the
mutant cannot matter.

## 8. Real QUIC under bad networks (Linux)

Two network namespaces joined by a veth pair, real quinn, the real driver, and real storage (ext4 on a
loop device). `tc netem` shapes both directions (an IFB device for incoming traffic). Each scenario
runs a 2 GiB file and a folder of 5,000 files, in both directions.

| Scenario | netem settings |
| --- | --- |
| Clean LAN | `delay 1ms rate 1gbit` |
| Wi-Fi-like | `delay 5ms 2ms loss 0.1% rate 400mbit` |
| Mobile data | `delay 60ms 20ms loss 1%`; 20 Mbit/s up, 100 Mbit/s down |
| Long and thin | `delay 150ms loss 1% rate 100mbit` (300 ms round trip) |
| Bursty loss | `loss 5% 25%` |
| Reordering | `delay 10ms reorder 25% 50%` |
| Duplicates and corruption | `duplicate 1% corrupt 0.1%` |
| Relay-like | `rate 50mbit delay 40ms` |
| Black hole | 100% loss for 60 s every 5 minutes |
| Flapping link | Link down and up every 30 s |
| Address change | Source port rotated by nftables masquerade mid-transfer (the quic-network-simulator `rebind` scenario as reference) |
| Relay dies | The staging coturn container killed mid-transfer (Pumba or `docker kill`) |

Every scenario uses a fixed netem `seed` so it repeats. Checks: invariants, goodput against the
shaped rate, time to first byte after recovery.

## 9. Crash consistency

| Test | Method | Iterations |
| --- | --- | --- |
| Kill loop, Linux CLI | Kill the receiver (then, separately, the sender) with `SIGKILL` at a random moment, restart, continue | 1,000 each |
| Kill loop, Mac app | Same, with `kill -9` from a script | 200 each |
| Kill loop, Android | `adb shell am crash in.roundrobin.bridgey` and, on debug builds, `adb shell run-as in.roundrobin.bridgey kill -9 <pid>` | 200 each |
| Power loss, simulated | The CLI on LazyFS; `echo "lazyfs::clear-cache" > <fifo>` at random moments drops unsynced data; torn-write faults | 500 |
| Power loss, replayed | `dm-log-writes` under one 1 GiB transfer, then replay to every flush point and run recovery | Every flush point |
| Sync failures | `dm-flakey` with `error_writes` and `drop_writes` windows during transfers | 100 |
| Power loss, real | Hard restart of the phone (power and volume keys) mid-transfer; forced power-off of the personal Mac only with Rahul's go-ahead (never the work Mac) | 5 each |
| Ledger damage | Truncate, zero or delete `ledger.db` and its WAL between runs | 50 |

After each iteration: invariants I1 to I5, I9 and I12, plus the final `b3sum` of every file.

## 10. Device matrix

### 10.1 Android (OnePlus 11, OxygenOS 16)

| Scenario | How | Expected |
| --- | --- | --- |
| Doze with the screen off | `adb shell dumpsys battery unplug`, `adb shell dumpsys deviceidle force-idle`; later `unforce` and `dumpsys battery reset` | Transfer continues |
| App standby | `adb shell am set-inactive in.roundrobin.bridgey true` | Continues |
| Standby bucket | `adb shell am set-standby-bucket in.roundrobin.bridgey rare` | Continues while the service runs |
| Background restricted | `adb shell cmd appops set in.roundrobin.bridgey RUN_ANY_IN_BACKGROUND ignore` | Paused with the right reason, or continues; the result is recorded |
| Battery Saver | `adb shell settings put global low_power 1` | Continues |
| Data Saver | `adb shell cmd netpolicy set restrict-background true` | Asks before mobile data (question C1) |
| Airplane mode for 2 minutes | `adb shell cmd connectivity airplane-mode enable`, then `disable` | Resumes within 3 s of the network returning |
| Wi-Fi off, onto mobile data | `adb shell svc wifi disable`, later `enable` | Metered policy; resumes; moves back to the LAN |
| Process kill | `adb shell am kill in.roundrobin.bridgey` with the app in the background; `am crash` | Resumes on its own |
| Force stop | `adb shell am force-stop in.roundrobin.bridgey` | No automatic resume; "Paused because Bridgey was stopped" |
| Reboot | `adb reboot` | Resumes after unlock (question C7) |
| An hour with the screen off | `adb shell input keyevent 26`, wait | Continues; battery use recorded |
| Low Power Standby present? | `adb shell dumpsys power` and look for "Low Power Standby" | Recorded |
| Heat | Watch `adb shell dumpsys thermalservice` during long transfers | Thermal policy as designed |
| OnePlus battery settings | Sleep standby optimisation on, Deep optimisation on, overnight runs | Pauses explained; checklist shown after a kill |
| Storage full | `adb shell fallocate -l <size> /sdcard/Download/filler.bin` | Paused with numbers; resumes after the filler is deleted |
| Folder access lost | Debug-build hook releases the SAF grant mid-transfer; also rename the folder in the Files app | Paused; "Choose folder again"; partials adopted |
| USB drive removed | FAT32 and exFAT USB-C sticks unplugged mid-transfer, 10 times each | Paused; resumes on re-insert; FAT32 refuses 4 GiB files up front |
| App update mid-transfer | `adb install -r` a newer build | Resumes after the update |
| Share grant after restart | Share a file, kill the app, check whether the grant survives (T0 question) | Resumes, or asks to share again and re-attaches by root |

### 10.2 macOS (personal Mac and work Mac)

| Scenario | How | Expected |
| --- | --- | --- |
| Sleep and wake loop | `pmset sleepnow` with `pmset relative wake 60`, 20 cycles | Pauses as "MacBook is asleep", resumes each time |
| Lid closed | Close the lid for 5 minutes | Same |
| Kill and quit | `kill -9`; Quit from the menu | Resumes at the next launch |
| External drive removed | APFS and exFAT drives unplugged mid-transfer | Paused; resumes on re-insert |
| Disk full | A 2 GB disk image (`hdiutil create -size 2g -fs APFS -volname BridgeyFull /tmp/full.dmg`, then open it) as the destination | Paused with numbers |
| Wi-Fi off and on | `networksetup -setairportpower en0 off`, then `on` | Resumes |
| Low Data Mode | Turn it on in Wi-Fi details | Metered policy |
| Bad network | dummynet: `dnctl pipe 1 config bw 20Mbit/s delay 100 plr 0.01` with a `pfctl` rule | Throughput and resume as in section 8 |
| App Nap | Background the app during a long transfer; `pmset -g assertions` shows the activity | No throttling |

### 10.3 CLI on Linux

- systemd restart loops (`systemctl --user restart`), `kill -9` loops, inbox on ext4, XFS and an
  exFAT USB drive, a full disk on a loop device.

### 10.4 Cross-platform matrix

- **Directions (6):** phone to Mac, Mac to phone, phone to CLI, CLI to phone, Mac to CLI, CLI to Mac.
- **Routes (5):** LAN, VPN (Tailscale), direct over the internet, own relay, Cloudflare relay.
- **Destinations:** Android `Download/Bridgey` (MediaStore), a granted folder on internal storage, a
  granted folder on a FAT32 and an exFAT USB drive; Mac internal disk and an exFAT external drive;
  Linux ext4.
- **Selection:** an all-pairs selection of about 40 runs, plus every combination for LAN and own relay
  on the main pair (OnePlus 11 and the personal Mac).
- **Interop:** upstream 0.6 phone with the edition Mac, and the edition phone with an upstream Mac:
  `files.v1`, unchanged behaviour, recorded in the ledger.

## 11. Soak tests

| # | Soak | Setup | Pass |
| --- | --- | --- | --- |
| S1 | 500 GB single file | Personal Mac with an external SSD (at least 600 GB free) and the CLI on a Linux host with a large disk, over Gigabit Ethernet; 20 injected faults (drops, kills, sleeps) | Zero integrity failures; final `b3sum` matches; average re-send per fault at most 64 MiB |
| S2 | 100 GB to and from the phone | OnePlus 11 and personal Mac on Wi-Fi, overnight, screen off, 10 faults | Same; battery use recorded |
| S3 | 100,000 files | Mac to phone into MediaStore and into a granted folder; 90% under 100 KB, 9% 1 to 10 MB, 1% 100 MB to 1 GB | Every file verified; time and memory recorded against the T0 targets |
| S4 | 50 GB through the relay | Phone and Mac on different networks through the own relay, 3 forced drops and an app kill | At most 4 MiB re-sent per drop (the connect-anywhere P4 exit criterion); relay caps respected |
| S5 | 72-hour random faults | Phone, Mac and CLI looping transfers, with a random fault every 2 to 10 minutes (script) | No invariant violation; no transfer stuck without a reason |
| S6 | Paused for a week | One transfer paused for 6 days 20 hours, then resumed (MediaStore refresh); one left to expire | Resume works; the expiry warning appears; expiry cleans up |
| S7 | 2 TiB synthetic | A seeded generator as the source and a hashing sink in the CLI | Completes; memory flat; key updates crossed without stalls |

## 12. Performance

- Before each run, measure the path with `iperf3` (TCP, and UDP for relay paths) between the same two
  devices; the engine is judged against that baseline.
- Measure goodput, time to first byte, time to resume, CPU (`adb shell top` and simpleperf on
  Android, `powermetrics` on the Mac), memory and battery (Android Studio's Power Profiler; Battery
  Historian is no longer maintained).
- Record the numbers per release candidate in `docs/transfer-engine/results/<version>.md`, created by
  the T12 phase.

## 13. Upgrades and compatibility

- Start a transfer on build N, update one side to N+1 mid-transfer, then the other; the ledger
  migrates and the transfer resumes.
- Open an N+1 ledger with build N: refused with an explanation; nothing deleted.
- Build N ignores an extra field or an ignorable record type sent by N+1.

## 14. Security tests

- A malicious peer harness, in simulation and over real QUIC, sends wrong chaining values, oversized
  records, paths with `..`, 100,001 items, a manifest that does not match its digest, data nobody
  asked for and a manifest stream that never ends. Each must be rejected within the limits of design
  section 7.5.
- I13 log checks on every suite.
- Agent CLI grants: a CLI device without the files grant is rejected; per-transfer and per-day limits
  hold.

## 15. Release gate

All of these on the release candidate, on RR CI and on the device matrix. An S1 bug resets G2, G5 and
G14 for the code it touched.

| # | Criterion | Threshold |
| --- | --- | --- |
| G1 | Unit, property and integration suites | 100% pass |
| G2 | Deterministic simulation | At least 1,000,000 seeds on the candidate code, the last 200,000 without a single invariant violation |
| G3 | Fuzzing | At least 24 hours per target, no crash, hang or out-of-memory |
| G4 | Mutation testing | No unexplained missed mutant in the core's state, scheduler, range and recovery modules |
| G5 | Crash loops | Every iteration of section 9 passes |
| G6 | Network matrix | Every scenario in section 8 passes the invariants; first byte after recovery within 3 s at p95 |
| G7 | Device matrix | Every scenario in section 10 passes, with the expected text on screen |
| G8 | Throughput | Design 14.7: at least 30 MB/s phone and Mac on the same Wi-Fi and at least 85% of iperf3; at least 105 MB/s on Gigabit Ethernet; at least 90% of the relay cap |
| G9 | Re-send bounds | Per drop: at most 1 MiB per open stream plus the bytes in flight, and at most 4 MiB per drop on relay paths (the connect-anywhere P4 criterion); per kill: at most 16 MiB on average over the kill loop; per power loss: at most 128 MiB |
| G10 | Resources | At most 32 MiB of buffers per transfer on the phone; FFI calls within 50 ms at p99 |
| G11 | Soaks | S1 to S7 pass |
| G12 | Interop | Upstream 0.6 in both directions behaves as today |
| G13 | Privacy | No file name, path or checksum in any log or diagnostics export across all runs |
| G14 | Beta | 14 days on Rahul's devices, at least 200 GB moved, at least 30 real interruptions, no S1 bug, no stuck transfer without a reason, every S2 fixed (question G5) |
| G15 | Review | A security review of the wire parsers and the storage layer, with findings fixed |

## 16. Rigs to build (phase T12)

| Rig | Path |
| --- | --- |
| Network matrix runner (namespaces, netem, seeds) | `tests/net/run-matrix.sh` |
| Kill and power-loss loops (Linux) | `tests/crash/kill-loop.sh`, `tests/crash/lazyfs-loop.sh`, `tests/crash/dm-replay.sh` |
| Android device matrix | `tests/device/android-matrix.sh` (adb commands of 10.1) |
| macOS device matrix | `tests/device/mac-matrix.sh` (commands of 10.2) |
| Soak driver and fault scheduler | `tests/soak/run.sh` |
| Results | `docs/transfer-engine/results/<version>.md` |

Budget: the nightly long runs fit in 2 hours on one RR CI runner; the weekly 200,000-seed run gets its
own slot. Builds keep priority on rr-dev-1 (connect-anywhere section 9.10).
