# Mesh pairing and codes without a Mac

Status: design, 2026-11-04, with phase 1 built on branch `rr/mesh-codes` ([As built](#as-built-phase-1-2026-11-04)).
Bridgey by Round Robin only. Rahul, 2026-11-03: "What if all Macs are offline? All devices should be able to pair
with each other. There is no central device."

Two changes:

1. **Peer pairing.** Any two Bridgey devices can pair: phone and Mac, Mac and Mac, Mac and server, server and
   server, phone and server. Each pair has its own trust, grants and audit. No device is the hub.
2. **Codes without a Mac.** Finding one-time codes no longer depends on a Mac being awake. The code reader (the
   guard, the prompt and the llama.cpp model runner) moves into the shared Rust core, so any device with the model
   can read codes: a server with the `bridgey` command now, the phone itself next.

## 1. Where we are (rr/main a1a332c)

| Topic | Today | Source |
| --- | --- | --- |
| Pairing | Protocol 2 (commit and reveal, `bridgey-sas-v2` code, envelope tags). Phone and Mac on the local network; phone and server by invite (the server invites, the phone joins). A phone refuses an invite whose `p` is not `cli` | protocol.md "Pairing flow", "Remote pairing by invite" |
| Mac and Mac | **Works on the local network already.** A Mac lists every Bridgey it discovers, other Macs included, and since beta 19 two Macs that tap each other pair (the crossed pairing fix). The MacBook Pro trusts both other Macs today. The pages that said "Macs never pair" (protocol.md Update all, user-guide.md, folders-and-settings-sync.md 8, rr-edition.md) were corrected in phase 2 | rr/devices-fix notes, plan.md 2026-11-01 |
| Server and server | A debug-only test hook (`bridgey pair --join`) | rust/cli |
| Hub | Settings sync relays through the phone; Update all from a phone reaches its Macs; agent grants, the codes broker and the agent audit live on the phone; Connect anywhere tunnels are per pair | protocol.md |
| Codes | Only the Mac finds codes (Swift CodeReader, CodeGuard, CodeText, EmailCodeRules, LlamaRunner; Gemma 3 270M fine-tuned, 253 MB GGUF). The phone gates mail previews and brokers codes the Macs send back (`codes.found`) to servers with Read codes | codes-from-email.md, agent-cli.md |

So with every Mac asleep, nothing new is found, and `bridgey codes --wait` on a server waits in vain.

## 2. One reader: `rust/codes`

The crate `bridgey-codes` is the code reader every device shares, ported line by line from the Mac's Swift:

| Part | Swift it replaces | Notes |
| --- | --- | --- |
| `text`: digit-box join, gate, links and copyright years blanked | CodeText.swift, `looksLikeOtpTraffic` | Lengths in UTF-16 units, as the Mac and Android count |
| `email`: pre-check and second-pass snippets | EmailCodeRules.swift | Passes all 477 vectors of `email-codes-v1.json` (written by the research's email_guard.py) |
| `guard` | `CodeGuard` (Swift and Kotlin) | Can only refuse |
| `prompt` | `CodeModelPrompt` | The trained prompt; only a string code counts |
| `service` | `codeServiceKey`, `codeSender` | The broker's key for a bare number is the sender lowercased |
| `candidate` | `codeCandidate` | Which notification is read and which text |
| `reader` | `CodeReader` | One budget for all passes; a mail gets up to two snippet passes |
| `engine` | `LocalCodeEngine` | Own thread, loads on first use, unloads after 15 idle minutes, `shutdown` before exit |
| `llama` (feature) | LlamaRunner.swift | Raw llama.cpp calls through `llama-cpp-sys-2` 0.1.161 (pinned): 512-token context, greedy, the model's chat template, stops when the JSON closes. Features `metal` (Apple GPU) and `android` (libc++ linked in) |
| `ffi` | none | One JSON call: C `bridgey_codes_call` for the Mac, JNI `RustCodes.nativeCall` for Android, the crate directly for the CLI |

**Single source of truth.** `rust/codes/examples/vectors.rs` writes `protocol/test-vectors/codes-reader-v1.json`
(guard, join, guard text, gate, service key, sender, prompt, parse, candidate, snippets). The Rust tests check the
file against the crate; the Android tests (`CodeReaderVectorsTest`) and the Mac tests check their copies against
the same file. A rule changes in Rust first; the vectors then fail every copy that differs, until phase 2 removes
the copies and the apps call the crate.

**Accuracy guard.** The production path of the crate, end to end (candidate rule, gate, join, model, guard, the
mail second pass), on the research's synthetic sets, same model file (`bridgey-otp-v1.gguf`, SHA-256 `69fe14b2...`):

| Set | Before (Mac, Swift, Metal) | Rust reader, Metal (personal Mac M4) | Rust reader, CPU (rr-dev-1, 4 threads) | Rust reader, Android arm64 (emulator, 4 threads) |
| --- | --- | --- | --- | --- |
| bench (42) | 30/30, 0 wrong, 0 false | 30/30, 0, 0 | 30/30, 0, 0 | 30/30, 0, 0 |
| synth (2,000) | 1,127/1,130, 0, 0 | 1,127/1,130, 0, 0 | 1,126/1,130, 0, 0 | not run (time) |
| hard2 (200) | 106/110, 0, 1 | 106/110, 0, 1 | 106/110, 0, 1 | 104/110, 1, 1 |
| hard3 (240) | 118/120, 0, 5 | 118/120, 0, 5 | 118/120, 0, 7 | 118/120, 0, 7 |
| hard4 (240) | 103/120, 5, 17 | 103/120, 5, 17 | 103/120, 5, 18 | not run (time) |
| mail blind (240) | 116/120, 0, 0 | 116/120, 0, 0 | 117/120, 0, 0 | not run (time) |
| mail blind2 (240) | 118/120, 0, 0 (116 with the rule frozen before it) | 118/120, 0, 0 | 118/120, 0, 0 | 118/120, 0, 0 |
| Median per message | 106 ms | 77 to 117 ms | 442 to 805 ms (shared, busy host) | 334 to 414 ms |

"wrong" is a wrong code on a code message, "false" a code shown for a no-code message. **On the same backend the Rust
reader gives exactly the Mac's numbers on every set.** CPU builds of llama.cpp differ from Metal by a hair, because
the arithmetic differs, not the code path: on x86, one code fewer on synth, two more expired codes in Indian languages
shown on hard3, one more on hard4, one more code found on mail blind; on arm64 (the phone's CPU), the same two on
hard3 and, on hard2, two codes fewer and one wrong code. The research's own CPU run gave 8 false on hard3. A busy host
also matters: with Gradle and cargo saturating rr-dev-1, 7 of 2,000 reads took over 10 seconds, so a server reads with
a 20 second budget (the phone waits 30). The phone's own reader (phase 2) should be checked on the full sets on a
real device before it ships; the arm64 wrong code on hard2 is the one result that is worse in kind.

## 3. Codes without a Mac

### 3.1 Roles

- **Reads codes** (grant `codes`, unchanged): a server may ask the phone for codes (`codes.query`).
- **Detects codes** (new grant `codes_detect`, "Detect codes"): a device that has the model reads code messages
  the phone sends it and says which code it found. Macs detect implicitly (they get the notifications anyway).

The phone stays the place that grants, logs and brokers: one switch per device, one audit trail, one list of codes
(15 minutes, in memory, folded by service and code, newest first, Latest and Older), whoever found them.

### 3.2 Who detects

The phone decides per message:

| Order | Detector | When | What leaves the phone |
| --- | --- | --- | --- |
| 1 | The phone itself (phase 2) | It has the model | Nothing |
| 2 | A connected Mac reading codes for this phone (`sms_codes_draft1`, and this phone forwards it notifications) | Always, as today | The notification, as today |
| 3 | One connected server with Detect codes | Only when 1 and 2 are not available, and only while some server has Read codes on | One code text message, to one device |

Options considered:

| Rule | For | Against |
| --- | --- | --- |
| **Fixed order, one detector (chosen)** | A code text goes to as few devices as possible; deterministic; no duplicates | A Mac that is awake but has no model reads nothing (rare: Codes from messages on means the model is there, or Cloud) |
| First available | Simple | Arbitrary; the server may see texts while a Mac is awake |
| Several, with dedupe | Most robust | Every code text goes to every detector: more exposure for no gain |

Every connected Mac that reads codes and gets this phone's notifications counts, with or without the agents mirror:
it sees the text anyway, so no server needs to. A Mac without the mirror sends nothing back, so servers get no code
while it is the only reader; that trades a little availability for less exposure. A Mac whose Notifications switch is
off on the phone receives nothing and does not count.

Among servers the one Rahul gave Detect codes first wins (the grant's time on the phone, then the device ID). Device
IDs are random UUIDs each device chose for itself, so a "lowest ID wins" rule would let a paired server always pick
itself; the grant time is the phone's own record. At most 60 candidates an hour each (the slot is taken when the
server is picked, so two messages at once cannot both slip past), at most 20 waiting in all; a server that does not
answer within 30 seconds is not asked again for that message.

Detect codes is switched only on the phone: a Mac's `agents.grant_set` for it is refused (the phone answers with
`agents.state`, so the Mac's switch goes back) and the Mac shows the row read-only. It sends message text to a server,
so it needs a tap where the messages are. A Mac older than this branch skips the unknown grant and the
`codes.detect` activity rows (its decoder drops unknown grant keys and actions), so it neither shows nor changes them;
it keeps working for everything else.

### 3.3 One card, no duplicates

The broker already folds codes by service key and code, so a code found by a Mac and a server shows once, with
both ways in `via`. Each Mac keeps showing its own banner as today (its card logic folds the same code and service
within 10 minutes). Phase 3 sends codes found elsewhere to the Macs as `codes.found` the other way, so a Mac that
was away shows the same card without a second banner.

### 3.4 The phone as a reader (phase 2): measurements

The Rust reader built for Android arm64 (`cargo ndk`, static libc++, 6.1 MB binary), run on the bridgey-api36
emulator (arm64, 4 vCPUs on the personal Mac's M4, 2.5 GB RAM), with the same model:

| Measure | Emulator | OnePlus 11 estimate | Basis of the estimate |
| --- | --- | --- | --- |
| Load and first read | 1.03 s | 1.5 to 2.5 s | Flash read of 253 MB plus the first run; once per 15 idle minutes |
| Per message, median / p95 | 357 ms / 477 ms | 0.5 to 1.0 s | Snapdragon 8 Gen 2 cores at roughly half to two thirds of an M4 core per thread for llama.cpp |
| Memory while loaded | 309 MB resident (peak) | the same | The model is memory mapped; unloaded after 15 idle minutes |
| Battery per message | not measurable on an emulator | 1 to 3 J (about 0.003% of a 5,000 mAh battery) | 3 to 4 W for under a second |
| Battery per day | | under 0.2% for 30 code messages, plus about 1 J per model load | |
| Storage | 253 MB | 253 MB | One download, Wi-Fi only |

That is fast enough and cheap enough for a phone with 8 GB or more: the phone becomes self-sufficient, and no
message text leaves it. The open part is real-device numbers (thermal state, a cold flash read), which the first
build on Rahul's OnePlus 11 measures. Phones under 6 GB of RAM keep using a server or a Mac.

### 3.5 Privacy

- A server sees a code text only if Rahul switched Detect codes on for it on the phone (never in a preset, its own
  window like every grant), only while no Mac reads codes, only while some server has Read codes on, and only text
  messages from the default SMS app that pass the gate (no other message ever leaves). Phase 1 sends no mail.
- One audit entry per message on the phone ("Read a code message", the app's name, never the text) and one on the
  server (`codes.detect`, phone, app, outcome; never the text or the code).
- The server keeps the text in memory for the read only; the model runs on its own thread; nothing is logged.
- The phone does not trust the server's answer: it takes one answer per message, only from the server it asked,
  within 30 seconds; it runs its own guard on the code against the text it sent; it names the service itself.

## 4. Peer pairing

### 4.1 Kinds of device

| Kind | `platform` | Pairs on the local network | Invites | Joins invites |
| --- | --- | --- | --- | --- |
| Phone | `android` | yes | phase 2 | yes |
| Mac (and later Windows, Linux apps) | `macos` | yes | phase 2 | phase 2 |
| Server (`bridgey`) | `cli` | no (no discovery) | yes | yes (phase 2 out of debug builds) |

Every pairing is the same protocol 2 first pairing: commitment, reveal, a six-digit code compared at both ends,
Allow pairing (or an open invite) on the receiving side, envelope tags. The joiner is side 0 and commits.

**Invites for every kind (invite `v: 2`).** Today an invite is `v: 1` and only a server invites (`p: "cli"`); the
phone and the `bridgey` join path refuse any other `p` (vectors `platform macos`, `platform android`, `no platform`),
and the phone stores every invite-paired device as `cli` (`AGENT_PLATFORM`), never with the invite's own field. A link
must never decide how far a device is trusted. Invites for other kinds are a new version with these rules:

1. **Its own keys.** A `v: 2` invite derives its rendezvous ID with `bridgey-invite-rdv-v2` and seals signalling
   with `bridgey-invite-signal-v2`, so a `v: 2` secret can never be used on the `v: 1` path. There is no fallback: a
   device that issued `v: 2` accepts only `v: 2`.
2. **The whole invite is bound.** Both ends hash the exact bytes the inviter sent: the inviter the fragment text it
   put in its own link, the joiner the text after `#` exactly as received, before any parsing, decoding or
   re-encoding. Both append `base64(SHA-256(fragment))` to the signed transcript, so a link edited in transit (another
   `p`, `n`, `c` or `x`) cannot complete. The JSON is refused if a key appears twice, if a key is unknown, or if `p`
   is not on the fixed list `android`, `macos`, `cli`. Refusing duplicate keys needs our own strict parser on each
   platform: `org.json`, `serde_json` and `JSONSerialization` all keep one of the values silently.
3. **The kind comes from the signed confirm.** `pairing.confirm` gains `platform`, inside the signed transcript
   (`... \0 initiatorPlatform \0 responderPlatform`), from the same fixed list. Each end stores the kind the other
   signed; `p` in the invite only chooses the words on the screen before the code, and a signed kind that differs
   from `p` fails the pairing. On the `v: 1` path any platform in the confirm is ignored and the peer is `cli`.
4. **Paired by link is its own fact.** Each end stores `pairedBy: "invite"` next to the platform, never folded into
   it. Defaults and inbound handlers check that flag: a device paired by link starts with nothing granted, a Mac
   included, and handlers that today trust "a Mac" (notifications to it, Update all starts, settings relays, Mac
   actions) treat it as an agent until Rahul switches things on. Its page carries a permanent "Paired by link" label.
5. **The code screen says what it is.** "Pair with Work Mac, a Mac paired by link? It can do nothing until you
   switch things on."

`v: 2` invites are refused by every build before this change (they check `v == 1`), so an older device can never
join one and treat it as a server invite.

### 4.2 What each pair can do

Each device decides and enforces what it lets a paired device do with its own things (its clipboard, files folder,
notifications, ring, codes), and logs it. Grants are per pair. Nothing is transitive: a device never acts for a
third device, except the two relays below, which carry only data that is safe to relay.

| Pair | Features |
| --- | --- |
| Phone and Mac | Everything today |
| Mac and Mac | Clipboard (sent by hand; automatic only with Handoff off, as today), files and folders, settings sync, Update all, Handoff takeover sync, Connect anywhere routes, code cards (phase 3). Not: notifications, texts, calls, screen, camera, phone files |
| Mac and server | The agent grants, decided on the Mac: notify and ask (a Mac notification with buttons), files (to Downloads/Bridgey/<server>), set clipboard, Read codes and Detect codes with the Mac as broker |
| Phone and server | Today's agent grants, plus Detect codes |
| Server and server | Files and notify only; no codes (a server is not a code source) |

### 4.3 Devices and permissions on a Mac

One list, three groups: **Phones**, **Macs**, **Servers**. A server paired with this Mac opens a page with "What this
server can do here" (the grants this Mac gives, the same rows and wording as the phone) and its Activity. Servers
paired only with a phone stay under "Agents on <phone>" (today's mirror), marked "Paired with <phone>". A server
paired with both shows once, with two sections.

### 4.4 Settings sync without a hub

Today a phone relays a winning change to its other peers. In a mesh every device may, with these rules:

1. **An allowlist.** Only these keys cross a hop: `activity.previews`, `display.reduce_motion`,
   `files.folder_include_hidden`, `files.folder_include_system`. Every other key stays per edge (it syncs only
   between the two devices that share it and is never passed on), including `feature.*`, `clipboard.automatic`,
   `clipboard.files`, `codes.enabled`, `codes.email`, `focus.*`, `files.folder_destination`, `files.folder_conflict`,
   `updates.auto_all` and `connect.away`. A key added later is per edge unless it is added to the list.
2. **Stamps: a fixed rule at the device that made the change, none at relays.** Only the device where the person
   changed a setting stamps it: `changedAt` = the larger of its clock and the key's current `changedAt` plus one,
   `version` + 1, `changedBy` its own ID (the rule today). A relay never stamps, re-stamps or edits a record; it
   passes on exactly the record it stored. So a record has one stamp everywhere. A device whose clock runs ahead does
   not lock a setting: the next edit anywhere is stamped above it (current plus one) and wins. The only refusal is a
   fixed sanity ceiling, a `changedAt` more than one year ahead of the receiver's clock (a broken or hostile stamp);
   such a record is not stored or relayed by that receiver and is answered `settings.error` `invalid_message`. Nobody
   re-stamps in reply.
3. **Bounded memory.** Each device remembers, per key on the allowlist and per peer, only the stamp it last relayed.
4. **Relay only winners, only to full peers.** A device that applies a record because it wins (higher `changedAt`,
   then `version`, then `changedBy`) sends it on to its other peers, never back to the one it came from; a record
   that does not win is not sent on. Devices paired by link and agents neither send relayed records nor receive them.
   Each device therefore sends each (key, stamp) at most once per peer, the flood stops by itself, and duplicates are
   no-ops. Because every copy of a record is identical and the winner rule is a total order, every device that receives
   a record ends on the same winner. The bounded exception: a record stamped more than a year ahead of some device's
   clock is refused by that device and by the part of the mesh it alone connects; the rest converge on it. The rate
   limit (20 in 10 seconds per peer) stays.
5. **`changedBy` only breaks ties.** It is a device ID the sender wrote; "Changed on <device>" names the
   authenticated device the record arrived from, never `changedBy`.

### 4.5 Update all without a hub

Update all reaches one hop past the device the person used, and only through peers allowed to pass it on:

- **A per-edge grant.** Each device has, per peer, "May start updates for my other devices" (off by default, never on
  for a device paired by link or an agent). A start with `forward: true` is accepted for passing on only from a peer
  that holds it here; from any other peer the start updates this device (as today) and goes no further.
- **One hop.** The device the person tapped (or whose own automatic run started) sends `updates.start` with a new
  `runId` (UUID) and `forward: true`. A receiver that accepts the forward sends the same `runId` once to its own
  connected peers with `forward: false`; a `forward: false` start is never passed on.
- **Rate limits per peer** stay (one start in 30 seconds, five an hour), counted for forwarded starts too.
- **Seen runs** are kept for 1 hour, at most 64; a `runId` seen before is answered `accepted` and not passed on.
- **What the screen says.** "Started by B" names the authenticated device the start came from. "From your phone, via
  B" is shown only if this device also received the same `runId` directly from the phone; otherwise it says "via B"
  and nothing more. If the direct copy arrives after the forwarded one (a seen `runId`, answered `accepted` and not
  passed on), the label changes to "From your phone, via B"; it never goes the other way. There is no `origin` field.

The device the person used installs itself last, as today. Older devices ignore the fields and do not pass starts on.
A start still names no version, URL or file, and each device installs only its own signed build, so none of this can
downgrade.

### 4.6 Routes

Each pair already has its own pair secret, rendezvous IDs and tunnels, so any two devices can connect anywhere. A
node registers at most 64 rendezvous IDs (three days per pair), enough for 21 peers. No routing through a third
Bridgey device; relays stay the relays.

### 4.7 Compatibility

Existing phone and Mac pairs, Mac and Mac pairs from beta 19, and phone and server pairs keep working unchanged.
New pair kinds need both ends to advertise `mesh_draft1` (phase 2); an older device refuses invites from new kinds as
today ("Update both apps to pair"). Nothing re-pairs.

## 5. Protocol changes

Phase 1 (built; contract tables and vectors updated):

| Item | Change |
| --- | --- |
| `codes_detect_draft1` | New draft key, appended last on both apps (`knownDraftFeatureKeys`, `KNOWN_DRAFT_FEATURE_KEYS`) and in the CLI. An agent sets it while it has the model runner and a model; the phone sets it for an agent while Detect codes is on |
| `codes.candidate` | Phone to agent, 4 KiB: `version` 1, `candidateId`, `source` (`sms`), `app` (`messages`), `sender` (at most 64), `text` (1 to 600 UTF-16 units, joined and gated), `postedAt` |
| `codes.detected` | Agent to phone, 512 B: `version` 1, `candidateId`, `outcome` (`found`, `none`, `failed`), `code` (4 to 12 letters or digits, with `found` only), `reason` (with `failed`) |
| Grant `codes_detect` | "Detect codes" / "Находить коды", detail "Reads your code messages when no Mac is reading". Never in a preset |
| Audit action `codes.detect` | Phone: "Read a code message", detail the app's name. Server: outcome and app |
| `codes.result` `readers` | Now counts agents that can detect, as well as Macs |

Phase 2 and 3 (designed, not built): `mesh_draft1`; invites `v: 2` (section 4.1: own derivation labels, the
fragment hash and the signed `platform` in the transcript, `pairedBy`); `updates.start` `runId` and `forward`
(section 4.5, no `origin`); the one-year stamp ceiling (section 4.4, no new message); `codes.found` from the phone to Macs under
`codes_cards_draft1`; `agent.*` served by a Mac; `codes.candidate` with `source: email` behind its own switch.

## 6. Migration

- Nothing changes for existing pairs. New keys are false until both ends know them.
- Detect codes is off for every server until Rahul switches it on.
- A server needs a build with the model runner (`--features detect`) and `bridgey codes model download
  --accept-terms` (the same file the Mac downloads, SHA-256 checked, Gemma terms accepted with a date).
- Docs that said Macs never pair were corrected in phase 2.

## 7. Security analysis

| Threat | Before | After | Mitigation |
| --- | --- | --- | --- |
| More trust edges (mesh) | n phones times m Macs | up to n(n-1)/2 pairs | Each pair has its own keys, grants, audit and Forget; no transitive trust; a device acts only on its own things |
| A server is compromised | Agent grants only | Plus code texts while Detect codes is on | Explicit grant with a window; only when no Mac reads; one server per message; only gated SMS; text never stored or logged; audit on both sides; Forget revokes at once |
| A server injects codes | Not possible | Could claim a code for a message | One answer per candidate it was sent; the phone's guard must find the code in that text; the phone names the service; a refusal is logged on the server's activity |
| A server lies about a real token | | It could pick another code-like token in the text (an amount) | Limited to messages it was sent; Rahul sees which server read what; a second detector cross-check is possible later |
| Replay | | | `messageId` in the replay window; `candidateId` single use; 30 second expiry |
| Flooding | | | 60 candidates an hour per server, 20 waiting; the server reads at most 4 at once and answers `busy` beyond |
| Relays in the mesh (settings, Update all) | Phone relays settings | Every device relays | Settings: an allowlist of four preferences crosses a hop, everything else per edge; one stamp per record, set only where the change was made, relays never re-stamp, a one-year ceiling; no relays to or from link-paired devices or agents; bounded memory; only winners relayed; `changedBy` never shown. Update all: forwarding only from peers with the per-edge grant, one hop, per-peer rate limits, seen runs bounded, the authenticated sender shown; a start names nothing to install and cannot downgrade |
| A link decides trust (remote pairing for new kinds) | Server and phone only | Any pair | Today: only `p: cli` invites, stored as `cli`. `v: 2`: own derivation labels and no fallback, the received fragment hashed into the transcript, duplicate and unknown keys refused, the kind from the signed `pairing.confirm` (fixed list), `pairedBy: invite` kept apart and gating defaults and handlers, everything off, a permanent label; older builds refuse `v: 2` |
| A peer of a server claims to be a phone | | Another device sends `codes.candidate` | A release `bridgey` cannot join invites (debug builds only), so every peer of a release server is the device that joined its invite and passed the code check, which only the phone app does. A custom client that joins the invite is accepted as a phone; residual risk accepted until `v: 2` signs the kind |
| Device IDs gamed for priority | | A server picks a low ID to be asked first | Detectors are ordered by when Rahul granted them, not by ID |
| A Mac switches Detect codes on | | | Refused on the phone; read-only on the Mac |
| The model file | | | The Mac and `bridgey` use only a manifest pinned in the build (file, size, SHA-256, name, terms), so release write access alone cannot swap the model or the terms; `bridgey` fetches no manifest at all; the Mac offers an online manifest only if it is pinned; `curl -q` ignores `~/.curlrc`; a refused resume starts again; SHA-256 checked before use |
| A message steers the model | | Text with `<end_of_turn>` or `<start_of_turn>` | The reader tokenizes the message without parsing special tokens (the template's own parts only); on the 3,646 eval prompts the tokens are identical to before. The Mac's Swift runner still parses them until it calls the crate (phase 2) |
| A server floods or stalls the reader | | | Slots held by a guard (freed on every path); a job whose caller stopped waiting is dropped; a prompt too long for the context is read on a shorter window without unloading the model |
| Candidates from a non-phone | | Another server sends `codes.candidate` | A server reads candidates only from a peer paired as a phone that has not sent `agent.hello` in the current session (the record resets with each session) |

## 8. Phases

| Phase | Contents |
| --- | --- |
| **1 (built here)** | `rust/codes` as the single source of truth, its vectors, the accuracy guard; the server detects codes (`codes.candidate`, `codes.detected`, Detect codes, model download, audit); the phone forwards text messages to one server when no Mac reads; Android and Mac checked against the Rust vectors; phone feasibility measured |
| 2 | The phone reads codes itself (JNI to the crate, model download on Wi-Fi, a setting); the Mac calls the crate through `bridgey_codes_call` and drops its Swift copies; invites on every device (Mac shows and joins invites; `mesh_draft1`); a Mac grants servers |
| 3 | Mac and Mac features in full (settings flood, Update all `runId`, code cards across devices); Devices and permissions in three groups; Windows and Linux apps on the same core |

## 9. Open questions for Rahul

Answered 2026-11-04 (see [Phase 2](#phase-2-2026-11-04)): 1 the fixed order, now Mac, then a server, then the phone over
cloud; 2 no email for servers yet (deferred); 3 the phone reads over cloud instead of an on-device model; 4 Macs pair
over the tailnet now, invites later; 5 one-hop Update all deferred; 6 Until I turn it off by default.

1. **Who detects when several devices could?**
   (a) Fixed order, one device: phone, then an awake Mac, then one server. (b) The first that answers. (c) All of
   them, with duplicates folded. **Recommended: (a)**, built in phase 1: a code text goes to the fewest devices.
2. **Should servers read codes in email too?**
   (a) No, text messages only. (b) Yes, under the same Detect codes switch. (c) Yes, behind a second switch "Also
   mail", off by default. **Recommended: (c)**; phase 1 sends text messages only.
3. **Should the phone read codes itself (phase 2)?** It needs a 253 MB download and about 300 MB of memory while
   loaded, and costs well under 1% of battery a day.
   (a) Yes, offered in setup, on Wi-Fi, on by default for phones with 8 GB or more. (b) Yes, off until switched on.
   (c) No, keep servers and Macs. **Recommended: (a)**, after the OnePlus 11 measurements confirm the estimate.
4. **Remote pairing for Macs.** (a) Macs show and join invites (QR and link), like servers. (b) Macs pair with each
   other on the local network only; servers pair with Macs by invite. **Recommended: (a)**: Macs at home and at work
   then pair without being on the same network.
5. **Update all across the mesh.** (a) Every device reachable through connected devices (`runId`). (b) Only devices
   connected to the one you tap. **Recommended: (a)**.
6. **Detect codes window.** (a) Ask each time, like other grants. (b) Default to 7 days. (c) Only "for 1 hour" or
   "today". **Recommended: (a)** with "7 days" first in the list: it is a standing job, but it should expire.

## Phase 2 (2026-11-04)

Rahul's answers (2026-11-04): the phone reads codes **over cloud**, not with an on-device model; devices on the
tailnet **pair with each other directly**; Detect codes defaults to **Until I turn it off**. One-hop Update all, Mac
invites (`v: 2`) and email for servers stay deferred.

### Codes over cloud on the phone

When no Mac reads codes and no server with Detect codes is connected, the phone asks the existing Cloud engine itself:
Round Robin's relay `https://bridgey-otp-proxy.cs-share.workers.dev` (services/otp-proxy, Cloudflare Workers AI, Llama
3.2 3B), the same request the Mac's Cloud engine sends.

- **The order: a Mac, then a server, then the cloud.** A Mac with Codes from messages reads on its own model and sees
  the text anyway. A server with Detect codes is one of Rahul's own machines, chosen by him for this job. The cloud is a
  third party (Cloudflare), so it comes last: the phone uses it only when no server is connected at all, and only
  while some server has Read codes on (the codes are for servers; the phone shows the text message itself).
- **Its own opt-in.** Settings > Codes > "Use cloud when no Mac is reading", off until chosen, never synced. Turning it
  on shows the same consent as the Mac's Cloud engine: the message text, code included, goes through Round Robin's relay
  to Cloudflare Workers AI; nothing is stored there; email previews never go to the cloud.
- **Text messages only.** Only the text-message path (`AgentHub.smsCandidate`) calls the cloud; mail previews never do
  (Rahul's earlier rule; a test pins the single caller).
- **The guard.** The relay's answer counts only if the strict guard finds the code verbatim in the text the phone sent
  (links and copyright years blanked). The phone names the service itself.
- **Limits and failures.** At most 20 cloud reads an hour from the phone, a 3 second timeout, no redirects. A failure,
  a time-out, a rate limit or a refused answer means nothing happens: no other route, no retry.
- **Logged.** Each cloud read is one item in the phone's activity list ("Read a code message over cloud · Messages",
  with the outcome), never the text or the code.
- **The relay, unchanged.** Its limits as deployed: 10 calls a minute per install, 30 per IP, 30 in all (per Cloudflare
  location), 2,048-byte bodies, 600 characters of text, a 1.5 second model timeout, no request logs
  (`observability` off), no caching; the account is on Workers Free, so it stops answering at the daily allocation
  instead of billing. Cloudflare states it does not train on Workers AI customer content. The phone sends its own
  random install id (`X-Bridgey-Install`), used only as the rate-limit key. No Worker change was needed.

### Pairing over the tailnet

Devices on Rahul's tailnet find and pair with each other without sharing a local network: Mac and Mac, server and Mac,
server and server, and the phone with Tailscale on.

- **The pairing is the normal one.** The dialling side opens plain TCP to the other's tailnet address, port 42458, and
  makes a protocol 2 first pairing: committed offer, reveal, the six-digit code compared on both ends, the
  `bridgey-auth-v1` transcript, envelope tags. The receiving side answers only while it allows pairing (Allow pairing
  or its pairing screen on the apps; `bridgey pair --allow` on a server).
- **Finding devices.** The Mac reads `tailscale status --json` from the Tailscale app every minute (and on Look again),
  knocks on port 42458 at each online peer, and lists those that answer under Pair a new device as "On your tailnet";
  addresses already known for a trusted device are left out. `bridgey tailnet` lists the same. A tailnet name (MagicDNS)
  or address can be typed on all three (`bridgey pair --to NAME`). Discovery decides nothing: an entry has no device ID
  and no kind until the pairing authenticates.
- **Restricted until trusted.** A pairing made over a tailnet address with an identity key this device does not know
  yet (a first pairing, or a re-pairing under a device ID it already trusts, since the ID is the other device's own
  choice) starts restricted on the phone and the Mac, whatever the other device says it is: on the phone it is an agent with every grant off, on the Mac every feature reads
  off and only the session and `connect.*` are taken from it. Only the person lifts that, with **Trust as my device**
  (the device's page on the phone, Settings > Devices on the Mac); a device that advertises itself as a server is
  restricted again at its next features.update. Being on the tailnet grants nothing by itself, and a modified server
  that hides its kind gains nothing either. A pairing whose `bridgey pair` gave up (window over, cancelled) is never saved.
- **What a server gets: nothing.** The kind comes from the authenticated session, not from discovery or a link: a server
  advertises `agent_draft1`, `notify_draft1` and `ask_draft1` in its own map. The phone then stores it as an agent with
  every grant off, exactly like one paired by invite. A Mac keeps it in `agents.directDevices`: every feature reads off
  for it whatever the switches say, its features.update to it is empty apart from Connect anywhere, and anything it sends
  beyond the session and `connect.*` is dropped. Another server records it as `cli` and never takes code candidates from
  it (only from a phone paired by its own invite).
- **`bridgey pair --allow`** listens for at most 10 minutes (2 by default) on port 42458 (config `tcp_port`), bound only
  to this device's own tailnet addresses (loopback too in debug builds), takes connections only from Tailscale's ranges,
  at most three a minute from each source (checked as each is accepted; more than two waiting are closed), ends every
  attempt with the window, and pairs once. `tailscale status` is stopped after 5 seconds and never runs on the async
  threads. `bridgey pair --to`, the Mac's typed address (`[IPv6]:port` too) and the phone's typed name or IP refuse
  anything outside the tailnet (a name is looked up first and dialled only where it points into the tailnet), and a name two peers answer to
  dials neither. A phone paired with a server over the tailnet is restricted there too (`tailnet`, not `phone`), so it
  sends that server no code candidates: phones pair with servers by invite for Detect codes.
- **The cloud read** needs a server with Read codes that is connected now; its hourly limit is kept on disk (setting the
  clock back does not free it), the whole call has 3 seconds, at most 4 KiB of answer is read, and the install id is new
  every 30 days and after turning the opt-in off. Residual: a DNS lookup or socket call already blocking when the 3
  seconds end is not interrupted, so a read reported as failed may still reach the relay a moment later (the same text
  the person agreed to send).
- **After pairing** the two set a pair secret (`connect.setup`) and reconnect over Connect anywhere tunnels like any pair.

### Detect codes default

"How long?" for Detect codes lists "Until I turn it off" first; the other windows stay.

## As built (phase 1, 2026-11-04)

Phase 1 answers "what if all Macs are offline" with a server that detects codes. Built:

| Part | Where |
| --- | --- |
| The shared reader, its vectors and the accuracy eval | `rust/codes` (`bridgey-codes`), `protocol/test-vectors/codes-reader-v1.json`, `examples/vectors.rs`, `examples/codes_eval.rs` |
| Swift and Kotlin held to the Rust vectors | `CodeReaderVectorsTests.swift`, `CodeReaderVectorsTest.kt` |
| Detect codes on the phone | `agents/CodeDetections.kt` (the rule, answer checks), `AgentHub.smsCandidate` and `codesDetected`, the grant and its words, `codes.result` `readers` |
| Detect codes on a server | `rust/cli/src/detect.rs`, `daemon.rs` (`on_candidate`), `bridgey codes model status|download|remove`, a `bridgey doctor` line, feature `detect` |
| Contract | `messages.json`, contract tables, `agent-v1.json` (`codesCandidate`, `codesDetected`), `protocol-v1.json` (draft list), wording table, en and ru strings |

**Live test** (bridgey-api36 emulator with the signed release APK of this branch, installed over the agent-CLI build
with `adb install -r`; a separate `meshtest` profile of this branch's `bridgey` on contabo-europe, paired by invite and
given Read codes and Detect codes for today; the installed `bridgey` service and its pairing untouched):

1. **No Mac running.** `bridgey --profile meshtest codes --wait 2m --json` was waiting; `adb emu sms send 57575 "Your HDFC
   Bank OTP is 739204 ..."` posted at 00:30:28; the server read it at 00:30:30 (2 s, with the first model load) and the
   wait returned `739204`, `readers: 1`. A second code, `G-551093`, came back as `551093` in about a second. A text
   without a code never left the phone. The phone's Activity for the server shows "Read a code message · Messages" and
   "Read the code from 57575"; the server's `bridgey audit` shows `codes.detect found` for each.
2. **A Mac too.** A throwaway Mac instance of this branch (`make-test-instance.sh mesh 42611 --model`, own bundle ID,
   folder and port) paired with the emulator, Codes from messages on, the model warmed up. The next code (`640318`)
   was found by the Mac (`codes.found` sent once), the server received no candidate, and `bridgey codes` listed it once
   (`via ["sms"]`, `readers: 2`). No duplicate.

Found on the way: a Mac that has just been given its model outside the app reads the first code after the 2 second
budget (Metal compiles its shaders on the first run), so that code shows plain and, with that Mac counted as reading,
no server reads it either. The app warms the model up after its own download, so only test instances meet this.

**Not built in phase 1, and why:**

- The phone does not read codes itself yet: it was measured (section 3.4), not shipped, because the arm64 run gave one
  wrong code on hard2 and the phone UI for the download needs Rahul's answer to question 3.
- No new pairing kinds: Mac and Mac pairing on the local network already works; remote pairing for Macs, Mac grants
  for servers and the mesh relays are phase 2 and 3 (sections 4 and 8). Phase 1's question needs none of them.
- The Mac and the phone do not call the Rust reader yet; their copies are held to it by the shared vectors.
- Servers get text messages only, not mail previews (question 2).
- The release tarballs (`scripts/rr/cli/build-cli.sh`, musl with zig) do not carry the detector; a server builds it
  with `--features detect` (agent-cli-setup.md section 6).
