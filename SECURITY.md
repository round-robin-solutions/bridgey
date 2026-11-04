# Security policy and model

## Supported versions

Bridgey is pre-release software. Security fixes are applied to the latest main
branch only. Do not use it yet for sensitive production workflows.

## Reporting a vulnerability

Until a private project security address is published, use GitHub's private
security advisory feature rather than a public issue. Include affected commit,
reproduction steps, impact, and any suggested mitigation. Do not include real
clipboard or notification content.

## Threat model

The LAN is hostile. Attackers may advertise arbitrary mDNS records, observe and
modify traffic, replay frames, race connections, and exhaust resources. A
previously paired device may later be compromised. The operating system and its
secure key store are trusted; denial of radio/network service and a fully
compromised local OS are outside the model.

Security goals are mutual peer authentication, confidentiality and integrity in
transit, visible first-pairing consent, replay-resistant side effects, least
plugin privilege, and complete revocation of local trust.

## Current transport and planned hardening

The native 0.5/0.6 clients use bounded newline-delimited JSON over TCP and
application-layer AES-GCM for feature payloads. They do **not** currently use
TLS or WebSockets. Ephemeral P-256 ECDH/HKDF establishes a session key; HMAC
confirmation and signed transcripts bind the stored long-term peer identity.
Routing headers and some acknowledgement/heartbeat messages are not encrypted.
Since protocol 2 (0.10) a first pairing commits to the initiator's key before
the answer, so the six-digit code cannot be forced to match by a man in the
middle, and when both ends speak protocol 2 every frame after pairing carries an
HMAC tag over its whole envelope and its sender, so headers can no longer be
rewritten, replayed under a new message ID or reflected (see `docs/protocol.md`
and `docs/security-review-0.10.md`). Replay caches are bounded and
session-local. `protocolVersion` is not part of the signed transcript, so an
attacker who is on the path every time two devices paired under 0.9 connect can
keep that pair on protocol 1 (no envelope tags) until one session gets through
on protocol 2, after which the pair is pinned. Pairing again under 0.10 avoids
this. First pairing with a protocol 1 device (Bridgey by Round Robin 0.9 and older,
and upstream Bridgey) is refused in both directions, with no fallback (Rahul,
2026-10-27); the user is asked to update the other device. Pairs made earlier
keep reconnecting. This is not a claim of independent cryptographic audit or a
complete active-network-attacker defense.

The following items describe the target security design; in particular TLS,
persistent replay handling, authenticated key rotation, and comprehensive
resource/rate limits are not all implemented. See the current-wire section of
`docs/protocol.md` and automated coverage in `docs/security-testing.md`.

## Target design

- Generate a long-term P-256 signing/authentication key per installation using
  Android Keystore or macOS Keychain/Secure Enclave where available. Private
  keys are non-exportable when the platform supports it.
- Pair with ephemeral P-256 ECDH, HKDF-SHA-256, transcript binding, and a
  six-digit code confirmed on both screens. Use platform cryptographic APIs and
  constant-time comparisons; never implement primitives locally.
- After pairing, use TLS 1.3 where available and pin the peer's long-term public
  key (SPKI SHA-256), rather than trusting mDNS names or the public Web PKI.
- Authenticate the full pairing transcript before persisting trust. TLS session
  resumption must remain bound to the same pinned identity.
- Generate unpredictable message IDs. Keep a bounded replay cache per peer and
  make state-changing handlers idempotent. Reject expired pairing messages and
  impossible protocol transitions.
- Apply frame, string, queue, transfer-size, rate, and connection limits before
  expensive decoding or allocation. Stream file bytes and verify their declared
  SHA-256 before completion.
- Treat clipboard, filenames, and notification data as sensitive. Production
  logs contain only redacted IDs and state transitions; no payload bodies,
  derived keys, verification codes, tokens, or full fingerprints.

The verification code protects first pairing from an active MITM only when the
user actually compares both displays. The UI must not offer a one-sided or
automatic confirmation path.

## Revocation and rotation

"Forget device" deletes its pinned key, permissions, replay state, resumable
sessions, and pending transfers, then closes the connection. Re-pairing is
required afterward. A compromised paired peer can access only capabilities the
user granted until it is revoked.

Key rotation is an authenticated protocol operation signed by both the old and
new keys and explicitly surfaced to the user. If the old key is unavailable,
rotation is not allowed: forget and pair again. Local identity reset invalidates
all pairings.

## Privacy defaults

There is no telemetry, advertising identifier, account, or remote analytics.
LAN features communicate directly between paired devices. "Connect away from
home" (draft `connect_draft1`, on by default since 0.10.0-rr.1; turn it off in
Settings > Devices > Connect away from home, and an explicit off stays off)
keeps a connection to the Round Robin control service at `connect.roundrobin.in`
and uses a Round Robin relay only when the devices cannot reach each other on
the same Wi-Fi. The relay and the control service see only ciphertext: public
addresses, timing and volume, never device names, identity keys or content
(`docs/connect-anywhere.md`, section 5.4). The other exception is opt-in: "Codes from messages" set to the cloud option on the Mac sends the
message text (at most 600 characters) and its sender to a Round Robin Cloudflare
Worker that asks Workers AI for the code; the worker keeps no logs. Codes from email
never use that worker: the preview of a Gmail, Outlook, Proton Mail or Spark notification
(at most 600 characters, only when it looks like it holds a code) travels inside the
encrypted session to the paired Mac and is read by the model on that Mac. Mail text,
previews and codes are never written to logs or diagnostics on either side. Sensitive
OS access requires explicit permission. Global and per-device switches gate
feature execution; permission-light features default on. Mac media control
defaults off and requires a locally selected player and Automation consent. Bridgey
does not weaken platform background/privacy controls to obtain clipboard or
notification data.

Remote call requests are accepted only from an authenticated paired session,
are encrypted and replay-protected, and are subject to per-peer feature policy,
strict phone-number validation, and rate limiting. Android requires local
confirmation by default. The higher-risk direct-call path is a separate local
opt-in and never handles a platform-recognized emergency number directly.

## Bridgey by Round Robin edition: Mac key storage

The Round Robin edition of the Mac app does not keep its pairing state in the
Keychain. Its long-term P-256 signing key (raw bytes, base64) and the list of
trusted phones live in
`~/Library/Application Support/in.roundrobin.bridgey/trust-v3.json`, in a 0700
folder with a 0600 file, written atomically, excluded from backups, and
validated on every load (looser modes are tightened; symlinks and files owned by
another user are refused).

Why: the edition is not signed with an Apple-issued certificate. For such code
the login keychain's partition list records the build's code directory hash
(`cdhash:`), so every update made macOS ask for the login password before the
app could read its own items. A self-signed certificate does not change this;
only an Apple team ID does.

Threat model: the same as `~/.ssh` keys, Syncthing and KDE Connect. Any process
running as the user (or root) can read the file and could impersonate this Mac
to paired phones; such a process could also read the clipboard and files
directly. Other accounts cannot read it. At rest it is protected by FileVault,
and it does not travel in Time Machine backups. Revoke a lost or copied key by
forgetting the Mac on each phone and pairing again.

The first launch after an update from a Keychain build reads the old items once
(macOS may ask once per item), writes the file, verifies it, then overwrites the
old items with a marker and tries to delete them. If the read is denied,
nothing changes, no new identity is created, and the app asks again on the next
launch. Details and test results: `docs/rr-mac-signing.md`.

## Bridgey by Round Robin edition: settings sync

Paired devices can keep settings and feature switches the same (v0.10, draft
key `settings_sync_draft1`, on by default, one switch to turn it off and one per
device). A paired device can therefore turn a feature on here. It cannot grant a
permission or a consent, change a per-device grant (which phone may use Mac
actions or remote control), read or change pairing data or secrets, open this
phone's storage ("Allow other devices to change files here" and "Let other
devices browse this phone" never sync), or change who may start updates here
("Let paired devices start updates on this device" never syncs). The first time
two devices sync, the new one asks before anything moves. Every change a device
makes is listed in the activity stream with its name, a feature that needs a
permission here also posts a notification, and more than 20 settings messages in
10 seconds from one device are dropped. The full threat model is in
`docs/folders-and-settings-sync.md`, section 8.5.

## Bridgey by Round Robin edition: Update all

Update all lets one device ask the devices connected to it to update themselves (draft
`updates_draft1`, `docs/protocol.md`). The decisions and why:

- **The request carries nothing to install.** `updates.start` has a request ID and an optional
  `retry` flag, nothing else: no URL, file, version or channel. The receiver reads its own channel
  feed, picks only a build newer than the installed one, and installs it through its own checks:
  on Android HTTPS from the release repository, size, SHA-256, package name, version code and the
  exact signing certificate of the installed app; on the Mac Sparkle's EdDSA signature against the
  key in the installed app. A paired device can therefore only trigger the update the receiver
  would have offered anyway; it cannot choose what runs, and it can never downgrade.
- **Only paired devices, only when advertised.** The request is accepted only on an authenticated,
  encrypted session with a trusted peer whose latest feature map shows the key, and goes through
  the session's replay window. Upstream peers and older builds never advertise the key and never
  receive these messages.
- **Rate limited.** At most one start every 30 seconds and five an hour from each device; more are
  refused.
- **No retry loops.** A device that started again on its old build records it and refuses further
  starts for that version unless a person tapped Retry for it (`retry: true`) or updates it there.
- **On by default.** "Let paired devices start updates on this device" is on by default. Judgement
  call: the worst a paired device can do with it is make this device install its own signed update
  from its own channel sooner, which it would offer anyway; the cost is a restart of Bridgey (not of
  the device) at a moment the person did not pick. A paired device already has far more reach
  (clipboard, files, notifications). Turning the switch off refuses every request.
- **Android installs without a second tap where Android allows it.** Sessions ask for
  `USER_ACTION_NOT_REQUIRED` and the app declares `UPDATE_PACKAGES_WITHOUT_USER_ACTION`. Android
  grants this only to an app updating itself or the installer of record, only for the same
  package, and the APK still has to pass the checks above and Android's own signature check
  against the installed app. When Android wants a tap, the phone asks with a notification and
  reports "needs you"; nothing is bypassed.
- **The device you are using keeps the say.** Its own restart waits through a countdown with Later;
  a device that was asked by another restarts without asking, because the person asked from there.
- **Update all devices automatically** (on by default for Beta and Nightly, off for Stable) starts
  the same run without a click when a device's own check finds a newer build. It changes nothing in
  what a start can do: still no URL, version or file, the same checks on each device, the same
  switch and rate limits. The start carries `auto: true`, and a device refuses an automatic start
  while its person is busy (a call, a screen share, remote control, a transfer, setup or pairing), so
  an automatic run cannot interrupt a call. What a device is doing travels to its paired devices as
  one word in `updates.status` (`busy`: call, screen_share, ...), never who is calling or what is
  sent; paired devices already see call cards and transfers. Only one device starts a run when
  several find the same build (lowest device ID), and none starts while a run is going, so devices
  cannot ping-pong starts.
- **The command line (`BridgeyMac --update-all`) accepts only the user running Bridgey.** The running
  app listens on a Unix socket in its Application Support folder: the folder is 0700 and the socket
  0600, so other users cannot reach it, and every connection's user is checked again with
  `getpeereid` and refused when it differs. It is deliberately not a URL scheme (a web page could open
  one) or a distributed notification (any process on the Mac can post one). The request is "check
  now, then Update all" and names nothing to install, so it can do no more than clicking Update all
  in that user's own session; it still waits for anyone busy.

## Bridgey by Round Robin edition: mesh pairing and Detect codes

Design and threat table: `docs/mesh-and-codes.md` (sections 3.5, 4 and 7). The decisions that bind future work:

- **A link never decides trust.** Invites stay `v: 1` and server-only: the phone and `bridgey` refuse an invite whose
  `p` is not `cli`, and the phone stores every invite-paired device as `cli`, never with the invite's own field.
  Invites for other device kinds will be `v: 2` with their own derivation labels and no `v: 1` fallback, the received
  fragment hashed into the signed transcript (duplicate and unknown keys refused), the device kind taken from the
  signed `pairing.confirm` from a fixed list, and `pairedBy: invite` stored apart from the platform so every
  link-paired device, Macs included, starts with nothing granted and is labelled. Builds before that refuse `v: 2`.
- **Detect codes** sends code text messages from the default SMS app, after the gate, to one server Rahul allowed on
  the phone, only while no Mac reads codes for the phone and some server has Read codes on. The phone takes back one
  answer per message, from that server, within 30 seconds, runs its own guard on it and names the service itself.
  Only the phone can switch it (a Mac's request is refused). Text and codes are never logged or written on either
  side; each read is in the phone's and the server's activity.
- **The code model.** The Mac and `bridgey` use only a manifest pinned in the build (file, size, SHA-256, name and
  terms); `bridgey` fetches no manifest, and the Mac offers an online manifest only if it is pinned, so a new model
  needs a new build. `bridgey` downloads with `curl -q` (no `~/.curlrc`) and starts again when a resume is refused.
- **A server's peers.** A release `bridgey` cannot join invites, so its only peers are devices that joined its own
  invite and passed the code check: in practice the phone. It reads code candidates only from such a peer that has not
  introduced itself as an agent in the current session. A custom client that joins the invite would be taken for a phone; accepted until
  `v: 2` signs the device kind.

## Bridgey by Round Robin edition: codes over cloud and pairing over the tailnet (phase 2)

- **Codes over cloud on the phone** is off until the person turns on "Use cloud when no Mac is reading" after a consent
  dialog that says the message text goes through Round Robin's relay to Cloudflare. Only text messages, never email
  previews; only when no Mac reads codes, no server with Detect codes is connected, and a server has Read codes on.
  At most 20 an hour, 3 seconds each, no redirects; the answer counts only if the strict guard finds it verbatim; a
  failure does nothing. Each read is in the activity list without the text or the code.
- **Pairing over the tailnet** is the normal protocol 2 first pairing over plain TCP (code on both ends, Allow pairing
  on the receiving side). Tailnet discovery is advisory and never names a device or its kind. Any first pairing made over a
  tailnet address starts restricted on the phone and the Mac (an agent with every grant off on the phone, every feature
  off and every non-session message dropped on a Mac) until the person taps Trust as my device; a server stays
  restricted whatever is chosen. `bridgey pair --allow` accepts only Tailscale's address ranges, three attempts a
  minute, one pairing, ten minutes at most. Being on the tailnet grants nothing by itself.
