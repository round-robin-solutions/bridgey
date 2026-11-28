# 1.0 acceptance: upgrades and long runs

Roadmap v1.0. Three tests on top of the stress harness ([testing-stress.md](testing-stress.md)): an upgrade in place
from an older release, the two apps talking across versions, and a soak of several hours of mixed traffic. Each runs
against test builds with their own app IDs and data folders (the Android `stress` build type, a throwaway Mac test
instance), never against an installed Bridgey.

## The tests

### Upgrade acceptance (Android and Mac)

`stress accept` (`rust/client/examples/stress/accept.rs`) drives one app through its control program. On a fresh
install of the older build it:

1. pairs (the older build must ask: a fresh install), turns Clipboard on, sends two texts each way (each read back on
   the other side) and a file each way, so the activity stream and the Mac's transfer history have items;
2. sets per-device grants away from their defaults (`grants`): on Android, Share screen with Macs on for the peer,
   phone control Allow without asking, Unattended access off; on the Mac, this Mac's screen Allow without asking,
   Remote control on for the phone, Unattended access off;
3. sets settings away from their defaults (`settings`) and restarts the app so it reads them: device name, Keep Wi-Fi
   awake, hidden files in folders, the clipboard eager limit, Reduce motion, activity previews off and the Nightly
   channel on Android; device name, Reduce motion, previews off, ring off, hidden files, menu bar drop to the tray and
   the Nightly channel on the Mac;
4. leaves a kept partial: a 192 MiB file to the app, cut at about 40 % (the app keeps the part and its resume record);
5. takes a snapshot (`snapshot before.json`), starts a second 192 MiB file and upgrades the app in place once more than
   80 MiB of it moved (`upgrade`): `adb install -r` on Android, which ends the old process mid-file as an update does;
   on the Mac the app quits (TERM), its bundle is replaced and it opens again.

Then, on the newer build, it checks: a snapshot straight away (`after.json`); the peer reconnects with no pairing
prompt and the same device ID; the app shows both partials; the kept partial resumes from its verified bytes (no
further back than a clean cut allows, 40 MiB) and the file the upgrade cut resumes from the app's last checkpoint (at
most 104 MiB back); both arrive whole (SHA-256 on the app); texts and files still move both ways
(`after-traffic.json`).

`scripts/rr/acceptance.py compare` then compares the snapshots. It fails when the version did not go up, the process
did not restart, any setting was removed or changed (the reconnect address book and the What's new markers, which
must move to the new version, aside), trusted devices, per-device switches, grants or Unattended access changed, the
Mac's identity key or trust file changed, any history item from before is gone, the kept partial's resume record was
lost, or a resume record is left once both files finished.

### Cross-version (the two apps)

`scripts/rr/accept-cross.py` pairs an older build of one app with the newer build of the other, both ways round:
older Android with the newer Mac, then the newer Android with the older Mac. The Mac instance dials the phone through
the emulator's port redirect, as a tap in the nearby list would. In each case texts go both ways (read back on the
receiving app) and files of 3 MiB and 40 MiB go both ways (SHA-256 at the receiving app). Then the older side is
upgraded in place: the two must reconnect without pairing again, the phone must still trust exactly the one Mac, and
texts and files must move again.

### Soak

`stress soak` (`rust/client/examples/stress/soak.rs`) runs for `--minutes`:

- a clipboard thread sends a text every 3 to 8 seconds, alternating direction; every one must be delivered (the app's
  ack, or the text arriving here), and every fifth one sent to the app is read back from it;
- the main loop picks a stress scenario at random every 15 to 60 seconds: whole files to and from the app (4 KiB to
  `--max-file`, mostly small and medium), batches of 8 to 32 small files, cancels from either end in either direction,
  connection cuts and silent stalls with resume, bursts of three reconnects, and idle periods of 3 to 6 minutes;
- a 10-minute quiet period every hour (the first one early enough that a short run has one), with no traffic at all
  but heartbeats;
- a sampler asks the app for its process figures every `--sample-every` seconds (`proc`): resident memory, threads,
  open files and CPU time on both, and the physical footprint on the Mac; Java heap (after a garbage collection every
  fifth sample), native heap and wake locks and alarm wakeups the system holds for the app on Android; idle wakeups on
  the Mac. The driver's own memory, threads and files are sampled too.

No app restarts in a soak: they would reset the figures it watches (the upgrade test covers them). Every scenario keeps
its own checks, so a soak fails exactly as a stress run would.

## Running them

Builds first: the stress APK (`cd android && ./gradlew :app:assembleStress`) and the debug Mac app
(`cd macos && ./build-app.sh`), for both the older and the newer revision. The older build needs this revision's test
hooks: copy `android/app/src/stress` over the older tree, and on the Mac apply
`scripts/rr/testdata/acceptance/mac-test-pasteboard.patch` to releases from before it (1.0 Beta 12 and older).
`scripts/rr/acceptance-ci.sh` does all of this from a release tag.

```sh
# Upgrade acceptance, against an emulator with its lock held, and on a Mac
scripts/rr/stress-android.sh --driver accept --apk old/app-stress.apk --new-apk new/app-stress.apk --out /tmp/accept-android
STRESS_MAC_BID=in.roundrobin.bridgey.test.accept STRESS_MAC_PORT=42498 STRESS_MAC_SERVICE=_bridgeyac._tcp \
  scripts/rr/stress-mac.sh --driver accept --app old/Bridgey.app --new-app new/Bridgey.app --out /tmp/accept-mac --proxy-port 42493

# Cross-version, on a Mac that runs the emulator
python3 scripts/rr/accept-cross.py --mac-old old/Bridgey.app --mac-new new/Bridgey.app --apk-old old/app-stress.apk \
  --apk-new new/app-stress.apk --peer rust/target/release/examples/stress --out /tmp/cross

# Soak (6 hours here); a second Mac instance of its own, so another run can share the Mac
scripts/rr/stress-android.sh --driver soak --apk new/app-stress.apk --out /tmp/soak-android --minutes 360 --max-file 64M
STRESS_MAC_BID=in.roundrobin.bridgey.test.soak STRESS_MAC_PORT=42495 STRESS_MAC_SERVICE=_bridgeysk._tcp \
  scripts/rr/stress-mac.sh --driver soak --app new/Bridgey.app --out /tmp/soak-mac --proxy-port 42492 --minutes 360 --max-file 256M

# Everything a CI job runs, from the newest release tag before this revision
scripts/rr/acceptance-ci.sh android --out /tmp/acceptance --soak-minutes 20
```

Without a device, the harness checks itself against the session client's stand-in, which knows the soak and
acceptance verbs too:

```sh
target/debug/examples/stress serve 42600 42601 /tmp/standin &
target/debug/examples/stress accept --app "target/debug/examples/stress app-control 42601" --target 127.0.0.1:42600 --work /tmp/peer --mid 96M
target/debug/examples/stress soak --app "target/debug/examples/stress app-control 42601" --target 127.0.0.1:42600 --work /tmp/peer --minutes 5 --max-file 32M
```

Each run writes `accept.json` or `soak.json` (every step or operation with its failures and figures), `events.jsonl`,
the app's log, and for an acceptance run the three snapshots and `compare.json`, for a soak `samples.jsonl`,
`soak-summary.json` and the graphs. Snapshots hold no secrets: preference values that could be credentials, and the
Mac's identity key, appear as SHA-256 only.

The Mac instance's clipboard is a pasteboard of its own (`AppPasteboard`, debug test instances only). Before this,
a test instance wrote received texts to the Mac's clipboard, where the real Bridgey's automatic clipboard would have
sent them on to the person's devices.

## Soak thresholds

Windows leave out the first 20 minutes (or the first 15 % of a shorter run). "First" and "last" windows are an hour
each on runs of three hours or more, a third of the rest on shorter ones. Slopes are judged on runs of two hours or
more; a shorter run is mostly warm-up (buffers and caches filling with the first large files), so it is judged on how
much the last window grew over the first.

| Check | Pass when |
| --- | --- |
| The soak report | every operation passed its scenario's checks; every transfer ended done, cancelled or interrupted; no clipboard text lost while the link was up; no event dropped |
| No crash | one app process ID for the whole run; no Bridgey line in Android's crash buffer |
| Memory | least-squares slope at most 8 MiB an hour, and the last window's median at most 48 MiB above the first's: resident size on Android, the physical footprint on the Mac (Activity Monitor's Memory; resident size there also counts shared code and pages malloc keeps after a free, so it is charted, not judged) |
| Java heap after GC (Android) | slope at most 2 MiB an hour, last window at most 12 MiB above the first |
| Open files | last window's median at most 8 above the first's; never more than 48 above it |
| Threads | last window's median at most 8 above the first's, on runs of 2 hours or more (on shorter runs the dispatcher's on-demand threads follow the load); never more than 96 above it on any run (batches raise it for a moment by design: Kotlin's IO dispatcher alone may grow to 64 threads) |
| Driver memory (session client) | slope at most 16 MiB an hour, last window at most 48 MiB above the first |
| CPU while idle | at most 2 % of one core across the quiet periods on Android, 3 % on the Mac (the test instance's control timer, five status files a second, takes about 1.6 % by itself) |
| Wakeups | Android: at most 12 alarm wakeups an hour for the app; Mac: at most 20 idle wakeups a second while quiet |
| Notifications (Android) | at most 20 shown at once (Android refuses an app's notifications past 50, which would hide pairing, call and control prompts) |
| Notification updates shed (Android) | none: no "Package enqueue rate is ... Shedding" line for the app in the device log. Android drops an app's notification updates while it posts more than 5 a second; it logs at most one such line every 5 seconds, so the count is a floor. `stress-android.sh` keeps NotificationService's errors in `app.log` and passes it to the judge (`--device-log`) |
| Throughput | per direction, the last window's median speed for files of 16 MiB or more at least half the first's (smaller files measure per-file round trips more than the link) |

## Results, 27 November 2026

Older build: 1.0 Beta 11 (`v1.0.0-beta.11`, a85698c6, build 263302157) with this branch's test hooks. Newer build:
this branch from rr/main baf26a8a, version `1.0.0-nightly.20261127`, build 263310530 (higher than any published
build, as a release would be). Android: the stress build on bridgey-api36 (Android 16, arm64) on the personal Mac,
reached through `adb emu redir`. Mac: throwaway test instances of the debug app on the personal Mac, over loopback.
Files and logs: `outputs/bridgey/acceptance/` in PA.

### Upgrade acceptance: passed on both

| | Android | Mac |
| --- | --- | --- |
| Paired with the older build | asked, 1.2 s | asked, 0.4 s |
| Upgrade (install or replace, until it listens again) | 1.3 s | 2.1 s |
| Reconnect afterwards | 0.03 s, no pairing prompt, same device ID | under 0.03 s, no pairing prompt, same device ID |
| Settings kept | 52 of 52 | 25 of 25 (What's new moved to the new build; the reconnect address book refreshed) |
| Grants kept | screen on, control Allow without asking, Unattended access off | screen Allow without asking, Remote control on, Unattended access off |
| History kept | 7 activity items, all there after more traffic (15) | 7 activity items (15 after), 2 transfer history entries (6 after) |
| Kept partial (cut at 86.0 / 78.5 MiB) | resumed at 82 MiB, 4 MiB sent again | resumed at 74 MiB, 4.5 MiB sent again |
| File the upgrade cut (at 101.5 / 97.3 MiB) | resumed at the 64 MiB checkpoint, 37.5 MiB again | resumed at the 64 MiB checkpoint, 33.3 MiB again |
| Texts and files afterwards | both ways | both ways |
| Resume records left at the end | none | none |

The first Android try failed one check, a harness gap since fixed: after the upgrade the new process missed the first
text because the control receiver only started listening at its first command (it now listens from every start).

### Cross-version: passed both ways

| Case | Pair | Texts | Files (3 MiB, 40 MiB, both ways) | Upgrade of the older side | Reconnect | After the upgrade |
| --- | --- | --- | --- | --- | --- | --- |
| Beta 11 Android with the newer Mac | 1.5 s | both ways | all whole, 1.2 to 2.9 s | Android to the newer build | 2.2 s, no pairing, one trusted Mac | texts and files both ways |
| Newer Android with the Beta 11 Mac | 1.6 s | both ways | all whole, 1.2 to 4.0 s | Mac to the newer build | 1.7 s, no pairing, one trusted Mac | texts and files both ways |

### Soak

Both ran for 380 minutes at the same time on the personal Mac, from 05:47 and 05:51 UTC, against this branch's build
before the notification fix below (the fix was checked on its own afterwards).
Android: files up to 64 MiB (the AVD has about 650 MB free). Mac: files up to 256 MiB.

| | Android | Mac |
| --- | --- | --- |
| Operations | 315, none failed: 140 whole files, 37 batches of small files, 40 cancels, 40 cuts, 10 stalls, 19 reconnect bursts, 29 quiet periods | 339, none failed: 153 whole files, 40 batches, 53 cancels, 33 cuts, 14 stalls, 18 reconnect bursts, 28 quiet periods |
| Transfers | 1,066: 976 done, 40 cancelled, 50 interrupted and resumed, none left unfinished | 1,254: 1,154 done, 53 cancelled, 47 interrupted and resumed, none left unfinished |
| Clipboard | 1,143 texts each way; 1,130 and 1,130 arrived, 26 lost while the link was cut or held, none with it up; 226 read back on the app, all right | 1,143 and 1,142; 1,127 and 1,119 arrived, 39 lost in cuts, none with the link up; read-back: see below |
| Reconnects | 137, no pairing prompt after the first | 122, none |
| Crashes | none (one process ID for the whole run, empty crash buffer) | none |

Against the thresholds (first window 20 to 80 minutes, last window the final hour):

| Check | Android | Mac |
| --- | --- | --- |
| Memory | pass: resident size 149.9 MiB median in the first hour, 124.6 in the last, slope -4.0 MiB an hour | pass: footprint 70 MiB, then 74; slope +2.9 MiB an hour (resident size 116 to 486 MiB, mostly freed pages malloc keeps) |
| Java heap after GC | pass: 6.26 then 6.31 MiB, slope +0.07 MiB an hour, at most 8.6 | |
| Open files | pass: 172 then 172, at most 174 | pass: 71 then 71, at most 74 |
| Threads | pass: 52 then 57, at most 86 during batches | pass: 11 then 11, at most 20 |
| Driver memory | pass: 8.5 to 15.8 MiB, slope +0.6 MiB an hour | pass: 8.3 to 35.5 MiB, slope -0.2 MiB an hour |
| CPU while idle | pass: 0.08 % of one core over 2 h 15 min of quiet periods | pass: 2.2 % (the test instance's own control timer is about 1.6 %, sampled; the installed app measured 0.6 % idle) |
| Wakeups | pass: no wakeup alarms registered, no wake lock held at any sample | pass: 4.8 idle wakeups a second (the control timer adds 5 a second by design) |
| Throughput | pass: from the phone 19.1 then 17.1 MiB/s (ratio 0.90); to the phone too few large files per window to compare, median 38 MiB/s | pass: from the Mac 742 then 695 MiB/s (0.94); to the Mac 674 then 367 MiB/s (0.55, near the 0.5 bar; see below) |
| Report | pass | failed on the clipboard read-back: a harness timing gap, fixed and rerun (below) |

Graphs (`rss.svg`, `java-heap.svg`, `fds.svg`, `threads.svg`, `throughput.svg`, `idle-wakeups.svg`), every sample and
every operation are in `outputs/bridgey/acceptance/android-soak/` and `mac-soak/` in PA.

**The Mac clipboard read-back.** The Mac acknowledged every text it was read back for, but 147 of 225 read-backs saw the
text before it. The Mac test instance reports its pasteboard in a status file it rewrites five times a second, and the
soak read it once, straight after the ack. Every miss held the immediately previous text, never an older one. The soak
and the acceptance run now poll the read-back for up to 3 seconds. A 25-minute rerun with that change: 35 operations,
134 files done, 112 texts each way delivered (6 lost in cuts), 23 of 23 read-backs right, the slowest after 0.37 s (one
status file rewrite), every other check passed (`mac-soak-confirm/`). A 20-minute Android run on the fixed build passed
every check with at most 11 notifications up (`android-soak-confirm/`).

**Speed to the Mac late in the run.** Large files to the Mac ran at about 700 MiB/s for four hours, then about 400 for
the last 90 minutes, while other jobs on the personal Mac (a video encode, a browser and Syncthing) raised its load to 8
to 10. It is not the transfer history: straight after the soak, a fresh instance took 1 GiB at 742 to 923 MiB/s with
1,500 history entries and 791 to 977 MiB/s with none (`mac-history-*`). Files from the Mac kept their speed.

### Session client across versions

The 1.0 Beta 11 session client (`rust/client`, as Windows, iOS and the CLI use it) against this branch's stand-in, and
this branch's against the Beta 11 stand-in: the quick stress set (pair, 128 MiB both ways, 30 small files both ways,
cancels, cuts, an app restart, 20 reconnects) passed 11 of 11 both ways.

### Bugs found

1. **Android: one notification per received file, until Android refuses Bridgey's notifications (fixed here).**
   `ReceivedFileNotifier.show` posted a notification for every file, each with its own ID, none ever withdrawn. Android
   keeps at most 50 per app: after a batch of 50 files, the system log reads "Package has already posted or enqueued
   50 notifications. Not showing more." and every later Bridgey notification is dropped, including pairing codes,
   calls and phone control prompts. The soak ran into it (49 received-file notifications up and that line in the log
   when checked), and the system UI process used about half a core while files kept arriving. Now at most 8 stay up,
   the oldest cancelled first (the files stay in Download/Bridgey and the activity stream): after 60 files on the
   fixed build, 8 showed and nothing was refused (`android-notifications/`). The soak now samples the count (at most
   20).
2. **Mac test instances wrote to the person's clipboard (fixed here).** A debug test instance put received texts on
   the Mac's clipboard, where the installed Bridgey's automatic clipboard would send them to the person's devices.
   Test instances now have a pasteboard of their own (`AppPasteboard`); release builds are unchanged.
3. **Harness gaps the first runs found (fixed here):** the Android control receiver heard texts only after its first
   command in a new process; the Mac read-back raced the status file; the attach sheet's draft names its process, so
   it differs after any restart; What's new markers move to the new version by design.

No crash, lost setting, lost grant, lost history item, lost resume record, unfinished transfer or corrupted file in any
run.

## RR CI

| Task | What | When | Runner | Time |
| --- | --- | --- | --- | --- |
| `accept-android` | `scripts/rr/acceptance-ci.sh android --soak-minutes 20`: upgrade from the newest release tag before the revision, then a 20-minute soak | nightly with the stress set (21:00 UTC on rr/main) | `ubuntu-latest` with the stress job's emulator set-up | about 55 minutes |
| `accept-macos` | `scripts/rr/acceptance-ci.sh macos --soak-minutes 20` | nightly, the same | `xcode-27`, the work Mac as fallback | about 50 minutes |
| `soak-android` | `scripts/rr/acceptance-ci.sh android --no-accept --soak-minutes 240` | weekly | `ubuntu-latest` | about 4 h 40 min |
| `soak-macos` | `scripts/rr/acceptance-ci.sh macos --no-accept --soak-minutes 240` | weekly | `xcode-27` | about 4 h 30 min |

GitHub's hosted jobs stop at 6 hours, so the weekly soak runs 4 hours there; the 6-hour runs stay manual. Artifacts:
everything under the job's output folder (`rrci-acceptance-out/`). Failures go through the existing forwarding: the
n8n workflow "RR CI: Bridgey stress failures" runs `crew-check bridgey-stress`, which only reports rr/main release runs
whose tasks are all in its `STRESS_TASKS`; the new task names must be added there in the same change, or a nightly run
that holds them would be skipped whole (stress failures included). The coordinator's schedules run daily, so the weekly
soak needs either a weekday on schedules or an n8n weekly trigger that submits the run. The requests to the CI owner
are in `outputs/bridgey/acceptance/ci-request.md` in PA.

## Not covered

- Upgrades from releases before 1.0 Beta 6: the stress build's control receiver needs the phone control grants that
  Beta 6 added. Older formats stay covered by the migration fixtures and tests ([upgrade-policy.md](upgrade-policy.md)).
- The real release signatures and app IDs, Sparkle and the Android package installer prompts: the test builds have
  their own IDs and the local debug key, and the update is done by `adb install -r` or a bundle swap.
- Connect anywhere tunnels and radios (as the stress tests), folder transfers (the session client has none), and
  screen sharing in the soak (the session client has no screen stream; the apps' own tests cover it).
- A Mac update quits the app gracefully through Sparkle; here it gets TERM, a harder stop.
