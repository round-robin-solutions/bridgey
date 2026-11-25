# Stress tests: cancel, reconnect and multi-gigabyte transfers

Roadmap v0.8, and phase 2 of moving tests off our own devices: a scripted peer stands in for the phone (against the
Mac app) or for the Mac (against the Android app), so each app is tested without the other device.

## The pieces

| Piece | What it is |
| --- | --- |
| `rust/client/examples/stress.rs` | The driver. A Bridgey device built on the session client that pairs or reconnects with the app, runs the scenarios with assertions and writes a JSON report and an event log. |
| `scripts/rr/stress-mac.sh` | Builds the debug Mac app and the driver, makes a throwaway test instance of the app and runs the driver against it. |
| `scripts/rr/stress-android.sh` | Builds (or takes) the stress APK, installs it on a running emulator, forwards its port and runs the driver against it. |
| `stress` build type (Android) | Minified like release, app ID `in.roundrobin.bridgey.stress`, the local debug key, no update feed and no relays. Its own source set adds a control receiver that only the shell can reach (senders need `DUMP`). |
| Mac test instance hooks | Debug builds with `BridgeyTestInstance` only: `cancel-files`, `send-file` with several paths, transfer rows in `status.json`, and `BridgeyTestServiceType` for a Bonjour type no real Bridgey browses. |
| `stress serve` | The session client standing in for the app, with the apps' automatic retry. It checks the harness itself on any machine, with no device. |

Every connection goes through a TCP proxy inside the driver. A scenario can cut it, so both ends see the socket close,
or hold it, so nothing moves until both ends' heartbeats give up, like Wi-Fi going quiet. The driver does not listen,
so the app cannot dial around the proxy; the driver redials through it.

The app is driven through a control program with a small set of verbs (`pair-prepare`, `pair-confirm`, `send`,
`cancel`, `kill`, `start`, `status`, `received`, `partials`, `clean`), listed at the top of `stress.rs`. Each runner
script provides them: files in `/tmp/<bundle id>-control/` on the Mac, `adb shell am broadcast` to the stress build on
Android. Files are deterministic bytes from a seed (SplitMix64, the same in Rust and Kotlin), so either end knows a
file's SHA-256 without reading it from the other.

## Scenarios

| Name | What it checks |
| --- | --- |
| `pair` | Pairs (the app allows pairing and confirms the code) or reconnects; the app shows `files`, `files_fast_draft1` and `files_resume_draft1`. |
| `send-big`, `recv-big` | 1 GiB and 4 GiB (`--big`) to the app and from it; SHA-256 at the receiving end, no partial left, throughput. |
| `small-send`, `small-recv` | 200 files (`--small`) from 0 bytes to 3 MiB in one batch, including exactly 1 MiB and 1 MiB plus one byte. |
| `cancel-peer-send`, `cancel-app-recv`, `cancel-peer-recv`, `cancel-app-send` | A cancel at a random point from either end, in either direction. Both ends must agree: the right reason, nothing running and no partial on either side, no resume record kept, a cancelled file not sent again after a reconnect, and the same file sent again starts from zero and arrives whole. |
| `drop-send`, `drop-recv` | The connection cut mid-file. The file resumes from a whole 1 MiB block at most what the receiver could have verified: this end as receiver loses at most 2 MiB, the app as receiver at most 40 MiB (its verified bytes less a block, and the sender's window). Files the app sends must come back by themselves on reconnect. |
| `stall-send`, `stall-recv` | Nothing moves until both heartbeats end the session, then the link returns; the same resume checks. |
| `restart-app-send`, `restart-app-recv` | The app's process killed mid-file and started again. As receiver it keeps its last 64 MiB checkpoint (at most 104 MiB lost); as sender it forgets the file (its retry list is in memory), so the runner sends it again and it still resumes here. |
| `restart-peer-send`, `restart-peer-recv` | The driver stops and starts with the same identity and storage; the app sends its file again by itself, or the driver does. |
| `multi-drop-send`, `multi-drop-recv` | One file cut five times on its way, resuming each time. |
| `reconnect-loop` | Cut and reconnect 20 times (`--loops`); each time a 4 KiB file must go through. Reconnect and probe times. |

`--scenarios quick` runs a shorter set; `--mid` sets the file size for the cancel, cut and restart scenarios (1 GiB by
default), `--rounds` how many random points each gets (2), `--seed` repeats a run's random choices. A scenario's
first send of a file must not resume, which also proves a cancel or a clean left nothing behind. A file that finishes
before the cut lands is tried once more, cut nearer its start.

Not covered: folders (the session client has no folder transfers, so folders resuming at file boundaries stays with
the apps' own tests), Connect anywhere tunnels (the driver speaks LAN TCP only) and real radios.

## Running them

On a Mac (the personal Mac now, GitHub's hosted macOS runner later):

```sh
scripts/rr/stress-mac.sh --out /tmp/stress-mac            # everything, about an hour
scripts/rr/stress-mac.sh --scenarios quick --mid 256M --big 1G
```

The instance (`in.roundrobin.bridgey.test.stress`, port 42497, Bonjour type `_bridgeyst._tcp`) has its own support
folder, Keychain items, preferences and receive folder, so an installed Bridgey, its data and its pairings are never
touched. The script deletes all of it at the end (`--keep` leaves it). Building holds `/tmp/app-build-mac.lock`
(a directory: `mkdir` to take it, `rmdir` to release it, never a file).

Against the Android emulator, on the host that runs it, with the emulator already up (and its lock held):

```sh
cd android && ./gradlew :app:assembleStress          # or let the script build it
scripts/rr/stress-android.sh --apk android/app/build/outputs/apk/stress/app-stress.apk --out /tmp/stress-android
```

adb installs and removes the stress build, forwards `tcp:42496` to its port 42458, starts it, force-stops it for the
restart scenarios, sends its control broadcasts and reads its log. Other Bridgey builds on the device listen on the same
port, so they are force-stopped for the run (their data is untouched). The emulator itself is never wiped or reconfigured.

Without a device, the harness can check itself against the session client:

```sh
cargo build -p bridgey-client --example stress
target/debug/examples/stress serve 42600 42601 /tmp/standin &
target/debug/examples/stress run --app "target/debug/examples/stress app-control 42601" --target 127.0.0.1:42600 \
  --work /tmp/stress-peer --mid 64M --big 128M --small 30
```

## The report

`report.json` has one entry per scenario: `ok`, `seconds`, `failures` (each a sentence), `metrics` and, for scenarios
with rounds, each round's cut point, reasons, resume offset, bytes lost and timings. `events.jsonl` next to it is every
event the driver saw, with times. The runners also keep the app's log (`app.log`) and, on Android, the crash buffer.
