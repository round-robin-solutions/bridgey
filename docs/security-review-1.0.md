# Security and privacy review, 1.0

What we checked in Bridgey by Round Robin before 1.0, what we found and what changed. It covers `rr/main` at
`b5b39cf2` (2026-11-26) and everything added since the [0.10 review](security-review-0.10.md): Connect anywhere
(core, control service, relays, Cloudflare credentials and the usage cap), LAN first, file resume, fast transfers and
the speed test, the stress build and test hooks, the Transfers window, screen sharing both ways and phone control,
browser extensions, agent CLI codes, the updaters, the Windows app and iOS. Accessibility and localisation are reviewed
separately. This is our own review of our own code, not an outside audit.

## Scope and method

The threat model is [SECURITY.md](../SECURITY.md): the network is hostile (it can watch, change, replay, race and
flood), a paired device may later be compromised, other local apps and other local users are not trusted, and the
operating system and its key store are. For Connect anywhere we added two parties: anyone on the internet can use the
control service and the relays (the app is open source), and the operator of the control service or a relay may be
curious.

Four reviewers each took one surface (Connect anywhere and LAN first; files, resume, the Transfers window and test
hooks; screen sharing and control; local IPC, CLI, updaters, Windows and iOS), threat-modelled it, read the code and
wrote a scratch test or exploit for each suspected issue. The lead confirmed each finding against the code, wrote the
fixes and a regression test for each, and checked that the 0.10 fixes still hold in the new code paths.

Severity:

- **Critical:** code execution or trust taken over at scale without pairing.
- **High:** someone who is not paired, a web page, another user or a local app gets code execution, data, trust or
  spend past the never-a-charge cap; or a paired device writes outside what it was given.
- **Medium:** a paired device gets more than it was granted, a resource attack that needs a restart, a meaningful
  privacy leak, or an update verification gap.
- **Low:** defence in depth.
- **Info:** noted, no change needed now.

Paths are relative to `android/app/src/main/java/dev/bridgey/android/` (Android) and `macos/Sources/BridgeyMac/` (Mac)
unless they start at the repository root. Line numbers are from `b5b39cf2`. IDs: C Connect anywhere, F files and test
hooks, S screen and control, I IPC, updaters, Windows and iOS.

## Summary

| | Found | Fixed in this branch | Open |
| --- | --- | --- | --- |
| Critical | 0 | 0 | 0 |
| High | 3 | 3 | 0 |
| Medium | 9 | 7 | 2 |
| Low | 27 | 14 (C5 and C11 in part) | 15 (including the rest of C5 and C11) |

Seven follow-ups from the 0.10 review are still open (O1).

The fixes need no wire change. Three need a deploy after merge: the control service (C1, C2, C6), the relays (C4, C8)
and the codes worker (I4); see [Needs Rahul](#needs-rahul).

| ID | Severity | Surface | Finding | Status |
| --- | --- | --- | --- | --- |
| C1 | High | Control service | Cloudflare credentials for anyone, and the hard cap did not stop credentials already out | Fixed, deploy pending |
| F1 | High | Mac, session client | A link put where a kept partial waits was written through on resume | Fixed |
| I1 | High | Windows | Another Windows user could reach the browser pipe | Fixed |
| C2 | Medium | Control service | One client could stall the service's single lock; memory grew without bound | Fixed, deploy pending |
| C3 | Medium | Core, apps | Dials to addresses learned on another network are not pinned (privacy) | Open, needs a wire change |
| C4 | Medium | Relays | coturn could relay to its own host's addresses | Fixed, deploy pending |
| F2 | Medium | Windows | Received files had no mark of the web; one click ran them | Fixed |
| F3 | Medium | Android, Mac | Any paired device could start speed tests without limit | Fixed |
| S1 | Medium | Mac | The touchpad could press Allow on the screen prompt | Fixed |
| S2 | Medium | Mac, Android | A controlling device could raise its own grants in Settings | Fixed |
| I2 | Medium | Updaters | Update feeds are not signed (Mac, 0.10 F7; Windows) | Open, separate PR |
| I4 | Medium | Codes worker | 0.10 F1: one client could use up the relay; unbounded chunked read | Fixed, deploy pending |
| C5 | Low | Core | Unauthenticated direct tunnels could crowd out ICE tunnels | Fixed (QUIC Retry open) |
| C6 | Low | Control service | `X-Real-IP` believed from any peer | Fixed, deploy pending |
| C7 | Low | Control service | `/v1/status` is public | Open, needs Rahul |
| C8 | Low | Relays | Relay logs kept without a limit | Fixed, deploy pending |
| C9 | Low | Core | Timing events carried IP addresses | Fixed |
| C10 | Low | Core, Mac | Learned addresses not checked against their kind; restricted devices get a pair secret | Open |
| C11 | Low | Core, control service | Signalling replay after a session ends; TURN answers matched by ID only; chunk size overflow | Overflow fixed, rest open |
| F4 | Low | Mac | No back-pressure from the main queue on fast chunk floods | Open |
| F5 | Low | Mac | Reset > Activity leaves resume records and kept partials | Open |
| F6 | Low | Session client | No free-space check for received files | Fixed |
| F7 | Low | Mac | Core library path from the environment in release builds | Fixed |
| F8 | Low | Mac | Debug test instance control folder in shared `/tmp` | Open (debug only) |
| F9 | Low | Scripts | The stress script picked any adb device | Fixed |
| S3 | Low | Android | Phone control grants survived Reset > Everything | Fixed |
| S4 | Low | Mac | Lock state came only from notifications | Fixed |
| S5 | Low | Mac | An old input session or stream could be replayed once the memory rolled over | Fixed |
| S6 | Low | Android | Consent prompts can be raised again and again | Open |
| S7 | Low | Android, Mac | Prompts show the name the peer reports | Open |
| S8 | Low | Mac | Settings sync can turn Remote control back on globally | Open, decision |
| I5 | Low | Session client | Windows device names with more than one dot | Fixed |
| I6 | Low | Extensions | The Firefox add-on ID is not reserved | Open, needs Rahul |
| I7 | Low | iOS | A sharing app's suggested name could leave the outbox item | Fixed |
| I8 | Low | iOS | App and share extension each save the whole trust record | Open |
| I9 | Low | Windows | Update feed read in full before its size check | Fixed |
| I10 | Low | Windows | Update zip checked by path then reopened; unzip folders others can write | Open |
| I11 | Low | Windows | Browser pipe can still be squatted (refusal of service only) | Open |
| I12 | Low | Mac | A restored code model is checked by size only (0.10 F6 remainder) | Open |
| O1 | Low | Several | 0.10 follow-ups F2, F3, F4, F5, F8, F9, F10 | Still open |

## High

### C1. Cloudflare credentials for anyone, and the hard cap did not stop credentials already out

- **Where:** `rust/rendezvous/src/hub.rs:596-652` (`warm`), `:547-549` (session grants), `:231-248` (`cf_tier`, read
  only when minting); `config.rs:64-65` (2 h session and 12 h warm credentials); no revocation anywhere.
- **What:** a warm Cloudflare grant needs only a sign-in with a self-made node key and the `relay.cloudflare`
  capability: no pairing and no peer online. New keys get around the per-node limit. Usage is read every 15 minutes
  (5 near the cap); crossing the hard cap stopped new grants, but every credential already handed out kept working
  until it expired, for up to 12 hours, and a modified client need not keep to the 40 Mbit/s pace.
- **Evidence:** a scratch test gave 500 fresh keys 500 twelve-hour credentials, about 108 TB of capacity at the
  client pace against the 50 GB between the hard cap and the free 1,000 GB, and none could be revoked after usage
  passed the hard cap. A 59-minute-old reading still counted as fresh.
- **Fix:** the service now keeps every Cloudflare credential it mints (memory only) and mints another only while all
  of them, each at 50 Mbit/s (Cloudflare's own per-allocation limit) until the next reading plus 15 minutes, would
  stay under `hard_gb`. At each reading the newest credentials beyond that budget are revoked through Cloudflare's
  revoke API, warm ones first; at the hard cap, or once the reading is too old, all of them; failed revocations are
  tried again. Each address (IPv4, or IPv6 /64) gets at most 30 Cloudflare credentials an hour. Past the budget or the
  address limit a grant goes to the own pool, as for any client without the capability. Settings `budget_kbps`,
  `budget_extra_s`, `mints_per_ip_hour`; `/v1/status` shows `credentialsOut` and `budget`. Details in
  [connect-anywhere.md](connect-anywhere.md#94-cloudflare-realtime-turn).
- **Tests:** `cloudflare_credentials_out_stay_within_the_budget`, `cloudflare_credentials_are_revoked_when_readings_stop`,
  `cloudflare_credentials_per_address`, `revokes_through_the_api` (`rust/rendezvous`).
- **Assumption to confirm:** Cloudflare's documentation does not say whether an allocation ends when its credential
  is revoked; it can no longer be refreshed, so it ends within its lifetime (the core asks for 10 minutes). The 15
  minutes in the budget cover that and the analytics delay.

### F1. A link put where a kept partial waits was written through on resume (Mac, session client)

- **Where:** Mac `Pairing.swift:7323` (kept partial opened with `FileHandle(forUpdating:)`), `:7376`, `:7391`
  (`truncate`), `FileResume.swift:112` (re-read by path), `Pairing.swift:7301-7302` (new part created with
  `createFile`, which follows a dangling link), `:7437-7438` (move into place); session client
  `rust/client/src/session.rs:1680`, `:1779`, `rust/client/src/resume.rs:339`, `client.rs:996`.
- **What:** a kept partial stays in the receive folder for up to 24 hours. Anything that can write to that folder but
  not to the target (a sandboxed app with access to Downloads, for example) could replace it with a link. When the
  same file was sent again, the re-read no longer matched, the restart cut the link's target to zero and wrote the
  incoming file into it. A paired device that is compromised chooses that content. Android is not affected (partials
  are MediaStore rows).
- **Evidence:** a scratch test against the session client turned a 61,000-byte file outside the receive folder into
  a copy of the sent file, and the "saved" file was the link.
- **Fix:** new parts are created with `O_CREAT | O_EXCL | O_NOFOLLOW` (a dangling link at the name counts as taken, so
  the file gets the next free name); kept parts are reopened with `O_NOFOLLOW` and taken only as a plain file of this
  user with one name; the re-read goes through the transfer's own descriptor; a part is published only if its name
  still points at the file that was written. The session client does the same on Unix and opens reparse points
  themselves (and refuses them) on Windows.
- **Tests:** `a_partial_swapped_for_a_link_is_never_written_through` (Rust), `testAPartialSwappedForALinkIsNeverWrittenThrough`
  and `testADanglingLinkAtAPartsNameIsNeverFollowed` (`FileResumeMatrixTests`).

### I1. Another Windows user could reach the browser pipe

- **Where:** `windows/src/Bridgey.App/Platform/BrowserHost.cs:114`, `:126-134`.
- **What:** the pipe name contains the user's SID, which is not secret, and pipe names are shared by every session.
  .NET adds `FILE_FLAG_FIRST_PIPE_INSTANCE` only for a single-instance pipe, and `CurrentUserOnly` only sets the DACL of
  an instance this process creates first. A second user who created the name first (at sign-in, or while Bridgey
  restarts for an update) owned its DACL, could connect to Bridgey's instances, list paired devices and send links and
  text to them. The helper side was already safe: it checks the server's user.
- **Evidence:** code path and documented Windows behaviour; a two-account test was not run.
- **Fix:** each connection's user is checked with `RunAsClient` (the helper connects at identification level) and a
  client of another user, or an anonymous one, is refused.
- **Tests:** the check compiles against .NET 10 on rr-dev-1 and in the Windows lane; there is no automated test with a
  second Windows account (the hosted runner has one user). Recommended: a manual check with two accounts before
  Stable.

## Medium

### C2. One client could stall the control service; memory grew without bound

- **Where:** `rust/rendezvous/src/hub.rs:395` (every message swept every pending grant under the one lock), `:519`,
  `:599` (per-node grant windows never removed), `:546` (pending grants anyone can create, kept 2 h), `:397`, `:402`
  (register and release not rate limited), `:498-507` (a signal fans out to every connection on an ID).
- **Evidence:** a scratch test left 20,000 grant windows and 20,000 pending entries after 20,000 nodes had gone, and
  1,000 messages then held the lock for 1.75 s (debug build). The container has 256 MiB.
- **Fix:** 600 messages a minute per connection (then dropped; past twice that the connection closes); expired
  entries swept at most once a second; quiet nodes' windows forgotten; at most 100,000 pending grants; at most 8
  connections on one rendezvous ID.
- **Tests:** `one_connection_cannot_hold_the_lock`, `quiet_nodes_and_expired_grants_are_forgotten`,
  `a_rendezvous_id_holds_a_pair_not_a_crowd`.

### C3. Dials to addresses learned on another network are not pinned (privacy), open

- **Where:** `rust/core/src/node.rs:773-800` (`dial_direct` without a certificate pin), `:666-677`, `:1957-1980`;
  `LanFirst.kt:168-189`, Mac `Pairing.swift:4861-4880`.
- **What:** a device away from home keeps dialling addresses it learned elsewhere, including private ones. The
  connection's identity is still proven by the inner handshake, so nothing more than the first message is exposed, but
  whoever answers at that address on the current network receives the reconnect offer, which names the devices. This
  contradicts [connect-anywhere.md](connect-anywhere.md#54-what-each-party-sees) 5.4 for an active party on the
  device's network.
- **Proposed fix (wire change, separate PR):** send the current certificate hash inside the session with
  `connect.addresses` and pin learned-address dials to it, or prove the pair secret before the first stream carries
  anything; dial a learned LAN address only on the network it was learned on (a keyed network tag); leave the device
  name out of reconnect offers.

### C4. coturn could relay to its own host's addresses

- **Where:** `server/relay/turnserver.conf.template:25-36`, `entrypoint.sh:54-56`.
- **What:** the denied ranges covered private and special addresses but not the relay host's own public address, so
  a client with credentials could reach UDP services bound on that host. Confidence: likely; coturn's own handling and
  the hosts' listening ports were not checked from here.
- **Fix:** the entrypoint denies the host's public and private addresses, and the template denies 240.0.0.0/4.
  Checked by rendering the template with test values. Needs a relay redeploy; check `ss -ulpn` on each relay host.

### F2. Windows received files had no mark of the web; one click ran them

- **Where:** `windows/src/Bridgey.App/Platform/Shell.cs:12-19`, `Notifications.cs:107-114`, `App.xaml.cs:240-242`; no
  `Zone.Identifier` anywhere in `rust/client`.
- **What:** the Windows form of 0.10 M3. A compromised paired device with Files on could send a program, script,
  shortcut or installer, and one click on the "file received" notification or Open ran it with no SmartScreen or
  Protected View check.
- **Fix:** every received file gets `Zone.Identifier` with zone 3 before it is placed, and Open shows programs,
  scripts, shortcuts, installers and disk images in Explorer instead of opening them (as Android never opens a
  package, 0.10 L3).
- **Tests:** `ReceivedFilesTests` (15 cases, run on rr-dev-1 and in the Windows lane); the stream is written on Windows
  only.

### F3. Any paired device could start speed tests without limit (Android, Mac)

- **Where:** `SpeedTest.kt:494-509`, `:535-538`; Mac `SpeedTest.swift:485-505`, `:523-526`.
- **What:** the receiving side answered `ready` to every `speed.start` with no gate, so a compromised device could keep
  the other one sending at full speed, over mobile data or a relay too, and learn its screen and network state from
  each answer.
- **Fix:** a test another device starts needs Files on for it, at most one every 10 seconds and six an hour; a refusal
  carries nothing about this device's network.
- **Tests:** `SpeedTestIncomingTest` (Android), `SpeedTestIncomingTests` (Mac).

### S1. The touchpad could press Allow on the screen prompt (Mac)

- **Where:** `RemoteInputHost.swift:302-311` (a session ends, then held buttons are released), `MacScreenShare.swift:283`,
  `MacScreenConsentPanel.swift:18-25`.
- **What:** Allow was refused while a phone controlled the Mac, but the check ran when SwiftUI fired the action, on
  mouse-up. A phone with Remote control could hold the button down on Allow and end its session; the release Bridgey
  injects as the session ends then arrived after the check had stopped applying. Confidence: likely; the timing was
  not run on a Mac.
- **Fix:** every event Bridgey injects for another device carries a mark (`eventSourceUserData`), and Allow ignores
  marked clicks, whatever the session state.
- **Tests:** `testAnInjectedClickNeverPressesAllow` (`MacScreenShareTests`).

### S2. A controlling device could raise its own grants in Settings (Mac, Android)

- **Where:** Mac `MacScreenShare.swift:210-218`, `SettingsWindow.swift:2250-2277`, `BridgeySettings.swift:503-506`;
  Android `BridgeySettings.kt:383`, `:488-496`.
- **What:** a phone controlling a Mac could open Settings and set its own screen grant to Allow without asking, or turn
  on Remote control, Mac actions or Calls for itself or other phones. Android already refused raising phone control
  grants during control, but a controlling Mac could turn on browsing this phone, changing files here and starting
  updates, the switches that never sync so that only the person on the phone decides.
- **Fix:** while a device controls this one, those grants cannot be raised; lowering always works.
- **Tests:** `testAGrantCannotBeRaisedWhileAnythingControlsThisMac`, `testGrantsCannotBeRaisedWhileThisMacIsControlled`
  (Mac), `ControlledPhoneSettingsTest` (Android).

### I2. Update feeds are not signed (Mac and Windows), open

- **Where:** `macos/Resources/Info.plist:45-53` (no `SURequireSignedFeed`, 0.10 F7), `scripts/rr/rrrelease.py:308-338`;
  `rust/client/src/update.rs:74-80`, `:106-125` (Windows: the Ed25519 signature covers the zip bytes only).
- **What:** HTTPS stops a network attacker, and every installed build is signed. But someone who can write the release
  assets without holding the signing key (a leaked repository token) could offer an older signed build as newer, a
  Nightly on Stable, or the other Windows architecture. Android is not affected: it checks the APK's own version code
  and signer.
- **Proposed fix (release tooling, separate PR):** sign the appcast and set `SURequireSignedFeed`; on Windows sign
  `(app, channel, arch, version, build, sha256)` instead of the bare zip, or sign the feed, and keep accepting unsigned
  feeds only until one signed release has gone out on each channel.

### I4. The codes relay (0.10 F1)

- **Where:** `services/otp-proxy/wrangler.toml:14-22`, `src/index.js:118-121`, `:184`.
- **What:** the per-address limit equalled the global one, a chunked body was read in full before the size check, and
  the worker did not check that the code appears in the message.
- **Fix:** 10 calls a minute per address against 30 in all; the body is read only up to 2 KiB; a code not found in the
  message as written is never returned. Needs a worker deploy.
- **Tests:** `a chunked body is read only up to the limit`, `a code that is not in the message is never returned`.

## Low

### Fixed

| # | Finding | Fix | Test |
| --- | --- | --- | --- |
| C5 | 16 unauthenticated direct tunnels from the local network (or a global IPv6 address) refused every ICE tunnel too; sources counted per exact IPv6 address; handshakes not counted (`node.rs:1685-1693`) | ICE tunnels have their own allowance; IPv6 sources counted per /64; at most 32 handshakes | `incoming_tunnels_cannot_crowd_out_ice` |
| C6 | `X-Real-IP` taken from any peer, so a client reaching the published port directly chose its own address for the per-address limit (`main.rs:273-275`) | Believed only from loopback or private (proxy) peers | `real_ip_only_from_the_proxy` |
| C8 | coturn session lines (client and peer addresses) kept in Docker's log without a limit | 10 MB, three files | Config |
| C9 | Dial and accept errors in timing events carried the peer's address, which the Mac logs as public (`node.rs:778-789`, `:1711-1715`) | Route kind and reason only | Code review |
| C11 | `size + 2` in the chunked-answer parser could overflow on a huge chunk size (`cloudflare.rs:296`) | `checked_add` | `huge_chunk_sizes_are_refused` |
| F6 | The session client (Windows) took any file up to 10 GiB with no free-space check (`session.rs:1647`) | The 0.10 M6 rule: the file, what arriving files still need, and 64 MiB | `free_space` covered in the F1 test |
| F7 | `BRIDGEY_CONNECT_DYLIB` honoured in release Mac builds (`ConnectCore.swift:27`) | Debug builds only | Code review |
| F9 | `stress-android.sh` used the first adb device, real or emulator, granted every permission and stopped the person's Bridgey | Emulators only unless `--serial` names a device | `sh -n` |
| S3 | Android phone control grants survived Reset > Everything, so a re-paired Mac got its old grant back (the Mac's Everything removes its support folder and held) | Removed with the pairings | `LocalDataResetTest` |
| S4 | The Mac learnt the lock state only from notifications: started while locked, it accepted control; any process could post "unlocked" (`RemoteInputHost.swift:87`, `MacScreenShare.swift:182`) | The session state is read at start and on every notification | Live path only |
| S5 | The Mac remembered 64 ended input sessions and 16 phone screen streams, so a recorded one could be replayed later in the same connection | 4,096 and 1,024 | `testAnEndedSessionStaysRefusedAfterManyMore` |
| I5 | `NUL.tar.gz` and similar names passed `safe_name` (`transfer.rs:49`) | The device name is checked up to the first dot | `names_are_safe` |
| I7 | The share extension used the sharing app's `suggestedName` as given, so `../` left the item folder (`ShareViewController.swift:148-151`) | One plain name; the Outbox refuses anything else | `testSuggestedNamesStayInsideTheItemsFolder` |
| I9 | The Windows feed was read in full before its 256 KiB check (`Updater.cs:27`) | Capped while it arrives | Code review |

### Open

| # | Finding | Proposed fix |
| --- | --- | --- |
| C5 | No QUIC Retry under load, though the spec promises it | `incoming.retry()` when the source is not validated |
| C7 | `/v1/status` is public and shows usage, tier and mint errors | Serve only `/health` publicly; keep the rest on the tailnet or behind Access (needs Rahul) |
| C10 | `connect.addresses` entries are not checked against their kind; restricted tailnet devices and agents get a pair secret on the Mac | `lan` private, `vpn` CGNAT or Tailscale, `public6` global; decide whether restricted devices may connect from anywhere |
| C11 | Sealed signalling can be replayed by the operator after a session ends (refusal of service only); TURN answers matched by transaction ID only | Remember ended session IDs for 5 minutes; check the source and integrity of TURN answers |
| F4 | The Mac decrypts chunks off the main queue and queues writes without back-pressure | Read the next batch only when the main queue has drained, or cap queued bytes |
| F5 | Reset > Activity leaves `file-resume.json` and kept partials; Everything removes the records but not the partials in the receive folder | Forget every peer's partials in both |
| F8 | The debug test instance's control folder is in shared `/tmp` without an owner check | A 0700 folder under `$TMPDIR` |
| S6 | A Mac can raise the phone's control prompt again and again; Allow has no tap delay; the capture dialog opens at once while Bridgey is in front | Back off after a decline; ignore Allow for 600 ms; route requests through a card |
| S7 | Prompts and pills show the name the peer reports | Show the stored name of the pinned device |
| S8 | Settings sync can turn the global Remote control switch back on while per-device grants persist (documented; now refused while controlled) | Ask on this Mac before a remote turn-on of a grant-gated feature (decision) |
| I6 | The Firefox add-on ID `bridgey@roundrobin.in` is not reserved on AMO | Reserve it with an unlisted upload (needs Rahul) |
| I8 | The iOS app and share extension each save the whole trust record, so one can write back what the other removed | Re-read and merge before saving, or give the extension read-only storage |
| I10 | The Windows update zip is checked by path and reopened to unpack (same user only); an unzip folder under `C:\` lets other users replace files | Check and unpack the same bytes; warn when the install folder is writable by others |
| I11 | The Windows browser pipe can still be created first by another user, which blocks it (refusal of service only) | Keep one instance always open created with `FirstPipeInstance` |
| I12 | A restored Mac code model is checked by size only (0.10 F6 remainder; the manifest is now pinned in the build) | Hash it again before loading |
| O1 | 0.10 follow-ups still open: F2 (companion link kept after Forget), F3 and F4 (product decisions), F5 (merge under a home receive folder), F8 (drag-out names), F9 (discovery maps unbounded), F10 (listener rebind after an update) | As in the 0.10 review |

### Info

- The own coturn relays accept any client's credentials request through the control service; this costs bandwidth,
  not money. With C1 fixed, a client can still use up the Cloudflare budget, after which grants go to the own pool:
  availability, not cost.
- A warm relay username is per node and lasts 12 hours, so a relay or Cloudflare can link one device's addresses over
  that time. QUIC Initial packets show `bridgey` (SNI) and `bridgey/1` (ALPN), so the traffic is recognisable.
- Any process of the same user can read codes from the Mac's local agent codes socket while that switch is on
  (documented); `WM_COPYDATA` from the same desktop can send files on Windows; the CLI's typed confirmation is checked
  by the client only (the phone still confirms).
- The phone shows the Mac's screen in an activity without `FLAG_SECURE`, so it can appear in Android's recents; the
  Mac's phone screen window is not excluded from screen capture. Product decision.
- Windows release builds honour `BRIDGEY_DATA_DIR`, `BRIDGEY_RECEIVE_DIR` and `BRIDGEY_PORT` (same user only).
- The outer-only `files.resume.wait` has no message ID and can be repeated within a session (refusal of service
  only). Android kept partials expire only at start or the next claim; MediaStore's 7-day pending expiry is the
  backstop.

## Checked and found sound

- **Control service sign-in:** challenge signature, the single-flight sign-in bound to host, time and nonce, the
  nonce memory cap; signals and claims need the rendezvous ID registered, and IDs are 128-bit HMACs, so no node can
  act in another pair's name.
- **Sealed signalling:** associated data binds rendezvous ID, side and session; the side and the 5-minute window are
  checked; bodies bounded.
- **Cloudflare grants** only for clients with the capability, for a session only when every node on it has it; only
  URLs the settings list go out; the API client uses the Web PKI, plain HTTP only to loopback, bounded answers and
  errors without secrets.
- **Tunnels:** protocol 2, trusted offer, no prompt, envelope tags on every frame, the core's peer must match the
  offer; the pin is stored before the answer goes out and no tunnel starts without one; Forget removes the pair secret,
  learned addresses and the core peer; the loopback bridge needs a one-time token compared in constant time. LAN first
  cannot move a session to an attacker: a new session must still authenticate.
- **Earlier Connect review fixes** (`b97d39b8`, `e078e804`) hold; so do the fast-transfer fixes (`204eef76`) and the
  mesh and codes fixes (`160562f6`, `d582a99d`, `36f8bfe8`, `395b66eb`, `8aed719f`).
- **File resume:** a partial is chosen by the authenticated device, size, hash and current receive folder, never a
  path from the peer; the receiver picks the offset and a prefix hash leaves only when it matches, so there is no hash
  oracle; record part names are validated; limits of 4, 16, 20 GiB and 24 hours on all three; Forget removes partials.
  The 0.10 fixes H2, M3, M5, M6 and M11 hold in the resume paths.
- **Binary frames** are capped before allocation on all three; replay across sessions fails (fresh key, associated
  data, message ID window).
- **Stress build and test hooks:** the stress build type has its own app ID and debug signing, its receiver exists
  only in `src/stress` behind `DUMP`, and nothing in release scripts or CI refers to it; release, play and qa manifests
  and ProGuard rules are clean; the `CONNECT_DEBUG` receiver needs `BuildConfig.DEBUG` and `DUMP`; Mac `TestInstance`
  and settings test hooks are compiled out of release builds.
- **Transfers window:** Reveal, Quick Look and Open act on local final paths, never on strings from the peer.
- **Android control:** the accessibility service is not exported, binds only through `BIND_ACCESSIBILITY_SERVICE` and
  reads no window content; the controlling Mac cannot answer the phone's prompt; input is bound to transport, stream,
  geometry and arrival nonce and rebuilt per packet; Control, Alt and Meta never reach the phone; text is capped.
- **Mac control:** Control, Option and Command are never posted from the touchpad; positions are fenced to the shared
  display; revoking a grant or locking ends things at once (0.10 L9 holds).
- **Browser helper:** 8 KiB limit before allocation, strict JSON, `javascript:`, credentials, bad ports and USSD
  refused; the Mac and Linux sockets check owner, mode and peer user; the extension checks `sender.id` and has no
  content scripts.
- **CLI:** 0600 socket with peer credentials, files written atomically with `O_NOFOLLOW`, no codes in logs, invites
  other than `p: cli` refused.
- **Updaters:** Android checks HTTPS, size, SHA-256, package, version code and signer before installing; Windows
  checks HTTPS prefix, size, SHA-256 and Ed25519 before installing and cannot elevate; Sparkle verifies EdDSA before
  extraction.
- **Windows and iOS storage:** DPAPI with CurrentUser scope and entropy; iOS Keychain items `AfterFirstUnlockThisDeviceOnly`
  in the app group; no URL schemes or universal links on iOS.

## Privacy summary

What each party can see after this branch, and what it keeps.

| Party | Sees | Keeps |
| --- | --- | --- |
| Control service (`connect.roundrobin.in`) | Each node key and its address while connected; the app name, platform and version; the rendezvous IDs a node registers (so which node keys share a pair while online); per-relay round trips (coarse location); size and timing of sealed signals; relay grants | Memory only: connections while open, pending grants for 2 hours, grant windows for an hour, Cloudflare credentials until they expire or are revoked, per-address counts for an hour. Logs carry no addresses or IDs; nginx access logs are off. Never sees device names, device IDs, identity keys, candidates, pins or content |
| Own relays (coturn) | Both devices' public addresses and ports, timing, volume, the TURN username; QUIC packets | Session lines in Docker's log, at most about 30 MB (C8) |
| Cloudflare TURN | The same as a relay, plus the usernames it minted | Cloudflare's own retention; the mint request carries only the lifetime |
| Codes worker (Cloudflare Workers AI) | Only when the person chose the cloud option: message text (600 characters), sender (64), a random install ID and the address | Nothing (observability off, no logs) |
| GitHub | Update feed and download requests: address, version, channel, timing; model downloads | GitHub's own retention |
| Someone on the device's network | The same as a relay on relayed or direct paths. Open (C3): an active party at an address the device learned on another network | |
| Paired device | What the person granted it, as before; a speed test answer shows the other device's network type and screen state only once it is accepted | |
| This device | Transfer history (Mac, up to 2,000 entries over 30 days, 0600), resume records (file names, up to 16, 24 hours), kept partials in the receive folder (24 hours), grants bound to identity keys, logs without content | Reset and Forget remove them, with the gaps in F5 |

## Needs Rahul

1. **Deploy the control service** (C1, C2, C6) after merge, and watch `credentialsOut`, `budget` and `cfOverBudget` in
   `/v1/status`. Recommendation: deploy soon; Cloudflare spend is not bounded until then. The budget keeps 84
   Cloudflare credentials out at zero usage, 48 at 400 GB, fewer past the soft cap; devices beyond it use the own
   relays. If that is too tight once more devices are online, lower `budget_kbps` (it assumes the worst case) rather
   than turn it off.
2. **Redeploy the relays** (C4, C8) and check `ss -ulpn` on each relay host for UDP services on public addresses.
3. **Deploy the codes worker** (I4). The per-address limit is now 10 a minute; many phones behind one carrier address
   share it.
4. **Restrict `/v1/status`** (C7) to the tailnet or Cloudflare Access at nginx, and bind the published port 18450 to
   127.0.0.1.
5. **Approve signing the update feeds** (I2) in a separate release-tooling PR: Sparkle appcast with
   `SURequireSignedFeed`, and a signed Windows tuple.
6. **Reserve the Firefox add-on ID** (I6) on AMO with an unlisted upload.
7. **Approve the C3 wire change** (certificate hash in `connect.addresses`, network-tagged LAN addresses) for a
   separate PR.
8. **Product decisions:** whether restricted tailnet devices may connect from anywhere (C10), a confirmation before a
   synced turn-on of Remote control (S8), `FLAG_SECURE` for the Mac's screen on the phone (Info), and the 0.10 F3 and F4
   decisions.

## Tests and where they ran

- **Rust** (rr-dev-1): `cargo test --workspace`, all passing; `cargo clippy --all-targets` on the control service,
  core and session client, clean. The Windows-only code in the session client was type-checked for
  `x86_64-pc-windows-msvc`.
- **Windows C#** (rr-dev-1, Linux, against `libbridgey_core.so`): `Bridgey.Core.Tests`, 88 passing including the 15
  new cases. The WinUI app (pipe check, Open) builds and its UI tests run only in the RR CI Windows lane.
- **Android** (rr-dev-1, JVM): `SpeedTestIncomingTest`, `SpeedTestThreadTest`, `ControlledPhoneSettingsTest`,
  `LocalDataResetTest`, `FolderSettingsTest`, `BridgeySettingsTest` and the `control` tests, all passing. Lint and the
  full unit suite run in RR CI.
- **Mac and iOS:** the personal Mac did not answer (ssh timed out twice during the review), so the Swift changes and
  tests were not built locally; they run in the RR CI macOS lane (`swift test -Xswiftc -warnings-as-errors`) and the
  iOS lane.
- **Codes worker** (rr-dev-1): `node --test`, 27 passing.
- **Scripts and config:** `sh -n` on the stress script; the relay entrypoint rendered with test addresses.
- Nothing was run against production servers, real devices or installed apps.
