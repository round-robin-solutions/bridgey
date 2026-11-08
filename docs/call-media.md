# Quiet media during calls

Implementation in progress, 2026-11-04. This is a v0.6 extension, before later roadmap work.
The local playback engines, transport, settings and live acceptance must all pass before this
feature is described as shipped. Platform research is recorded in PA
`outputs/bridgey/roadmap-run/call-media-research.md` with official source links.

## Agreed behavior

- Default: pause media, then mute media that cannot pause. Also offer Pause only and Mute only.
- After the last call ends, default to restoring sound and resuming only playback Bridgey paused.
  Also offer Restore sound, leave playback paused and Leave both for manual action.
  On Mac, temporary process mutes always release at call end. The old manual-restoration key
  now leaves playback paused while releasing sound, as requested. A separate Restore sound
  button can release Bridgey's mute during a call or retry failed cleanup without playing media.
- Quiet once when a no-call interval becomes an active-call interval. Later manual playback stays
  allowed. Overlapping calls hold the same interval; ending one does not restore under another.
- Include a manual “I'm on a call” action on the Mac and “I'm off the call” to clear that mark.
  It is a local, in-memory source; it does not answer or end an actual call.
- Explicitly enable this optional feature. Keep existing Off choices, and per-device permissions.
  Existing single-player Pause media during phone calls keeps its old no-autoplay contract when
  the new feature is disabled. Do not let it duplicate the new ownership engine when enabled.

Restoration is local and owned: never start an already-paused player, unmute pre-existing mute,
change a later manual volume/playback/route choice, or restore a replaced player session. Normal
last-call end uses the chosen restoration policy. Disable, revoked permission, lost session or
expired source restores owned sound only and does not autoplay.

## Capability and trust

The optional `call_quiet_draft1` feature starts off and is false for old peers. In the existing
feature enums use Android `CALL_QUIET` / Mac `.callQuiet`, with the same wire key. Standard
per-device feature controls apply; restricted CLI/agent peers neither originate nor receive
these effects. This feature must not depend on notification mirroring, a dialer app's ordinary
notification filter, or whichever peer is selected in the remote-media UI.

Accept source state only from the authenticated current protocol-2 session, after envelope tag,
replay, session, decryption, size, strict JSON and both feature/permission checks. Use the
session's device identity; there is no payload origin or forwarding hop. Never send caller,
number, notification text, app title, media metadata or volume in this contract.

Directly connected, permitted paired apps receive current state immediately on feature/session
readiness, including when joining mid-call. Already-paired direct internet/relay sessions use the
same encrypted messages. Transitive mesh forwarding is not implicitly authorized by this draft;
never infer permission to control an unpaired device from another device's claim.

## Wire contract

`calls.quiet_state`, encrypted plaintext, at most 2,048 UTF-8 bytes:

```json
{"version":1,"revision":1,"calls":["opaque_call_id"],"uncertain":false}
```

The object has exactly these keys. `version` is integer 1; `revision` is an integer from 1 to
2,147,483,647; `calls` is an array of at most 16 distinct IDs matching `[A-Za-z0-9_-]{1,64}`.
`uncertain` is a boolean, normally false. It becomes true only when a previously advertised
active local source is lost without a verified end, and clears only after a fresh observation
of that component. An initially unavailable source that never advertised an active call does
not create uncertainty. This distinguishes call end from losing its notification/callback.

An empty array with `uncertain: false` is an explicit end; uncertainty never authorizes
autoplay, including when another known call ends later. Known call IDs can remain alongside
uncertainty. IDs are opaque and meaningful only under the authenticated sending device.
A sender increments revision when its local set or uncertainty changes. Within one session,
older revisions are ignored; the same revision renews only an identical set and uncertainty.
A new authenticated session resets the per-session revision record, not peer identity.

While local calls are active or a source is uncertain, renew the snapshot once per 25 seconds (reuse the
existing heartbeat scheduler when possible). A receiver expires a source after 75 seconds
without a valid renewal, using a monotonic injected clock. Expiry is loss of evidence, not a
confirmed call end: release owned sound without autoplay. No permanent remote mute or per-frame
polling. Peer removal, revoked permission and session loss discard only that source; other
active sources remain.

`calls.quiet_result`, encrypted plaintext, at most 1,024 UTF-8 bytes:

```json
{"version":1,"revision":1,"paused":1,"muted":0,"limited":1,"issues":["unsupported"]}
```

Exactly these keys, version/revision as above; each count is integer 0..64. `issues` contains at
most 16 distinct values from this fixed list: `permission_needed`, `unsupported`,
`call_audio_protected`, `changed_by_user`, `session_gone`, `command_failed`, `cancelled`,
`other_players_limited`, `selective_mute_unavailable`. These are bounded outcomes, not playback
metadata. Match results to this source's latest sent revision/current session. A result reports
observed local effects/capability limits; packet delivery alone never means all media is quiet.
Send updated results after asynchronous confirmations, coalescing unchanged outcomes.

Mode keys: `pause_then_mute` (default), `pause_only`, `mute_only`.
Restoration keys: `restore_and_resume` (default), `restore_sound`, `leave_as_is`.
Policies are local settings, not remote-supplied commands. Per-device permissions never sync.

## Platform boundaries

Android pauses eligible active MediaSessions through its enabled notification-listener access.
The fallback may touch only the media stream when it can establish a safe local route and
ownership. Never mute the voice-call, ring or master stream. A local call, communication audio,
fixed volume or uncertain route may make fallback unavailable; say so.

Mac adapters address Music and Spotify independently and safe compatible media targets. Never
use system/output mute, which could silence the call. Public process taps start at macOS 14.2
and mute only the exact eligible player process. Bridgey creates an input-only private aggregate with no physical subdevices. Its discard
reader handles audio only in memory; no samples or sample pointers are saved or sent, and
player volume is never changed. Inclusive private taps never attach a replacement player
by bundle ID. Missing process identity, active audio input, unavailable routes, older macOS,
permission denial, or failed observation make selective muting unavailable; pausing remains
independent. The tap declares `mutedWhenTapped` at creation and has no reader during
preparation. Starting the reader is the muting transition; validate the current permit,
process and route immediately before and after Start, then stop/release stale work.
No live tap-description writes are made during confirmation or teardown.
That public mode releases sound when reading stops, including owner-process exit; it does
not guarantee release if a control queue hangs while its separate IO queue still runs.
Runtime/resource, signed-app permission and forced-exit proof must pass before shipping.
Output/device changes (including A -> B -> A), input activity, playback notifications, player
exit, sleep and audio-service restart release the owned tap. Later volume values are preserved
because Bridgey never writes them; instant slider-based release is not promised. The explicit
Restore sound action releases only Bridgey's temporary mute and prevents reapplying it within
the same call interval. A failed destruction retains its token for that action/reset to retry. Partial startup
resources retain inactive cleanup tokens without increasing the confirmed-mute count.
Readiness uses a one-time atomic signal; the native callback does not process sample values.
Missing data or arbitrary Core Audio errors are not reported as permission denial.
Successful Start and nonempty callbacks are not proof of recording consent; native
approval/denial behavior remains an explicit acceptance gate.
Browsers can mix a call and media in one process. Unknown/call-host processes stay protected;
report limits instead of claiming every app can be silenced. Existing optional MediaRemote
support is best effort and private, not a public Apple global-media guarantee.

Native macOS has no universal public call observer. Supported phone call/VoIP state and the
manual Mac source are explicit; do not infer an actual call merely from microphone use.

## Acceptance

Native Core Audio graph checks are quarantined after disrupting the Work Mac's shared audio
server. Private taps do not isolate failures in that server. Do not run audio-backed tests or
the native probe on either daily-use Mac. Owner: Bridgey native acceptance. Ordinary CI skips
these checks; only a dedicated isolated audio host may set `BRIDGEY_CALL_AUDIO_ISOLATED=1`.
The backend remains unshipped until the incident is understood and isolated native acceptance
passes. A passing model suite or skipped hardware check is not native proof.

Meaningful checks include all three modes/restoration options, mid-call joining, notifications
Off, per-device permission Off, overlapping calls, stale/forged/replayed/oversized state,
permission revoke, lease expiry, disconnect, manual resume/seek/volume/route changes, process
replacement, unsupported players, call-host audio, and old-peer fallback. Use shared golden
vectors and both platform engines' deterministic async tests on the owned RR CI fleet.

Live acceptance must verify call audio on real devices and permission prompts. Emulators and
unit tests do not certify other OEMs, macOS versions or every browser/app. Keep untested rows
open. No new feature release or v1.0 freeze follows merely from a passing model test.
