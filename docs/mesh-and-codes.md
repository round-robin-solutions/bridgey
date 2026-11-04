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
| Mac and Mac | **Works on the local network already.** A Mac lists every Bridgey it discovers, other Macs included, and since beta 19 two Macs that tap each other pair (the crossed pairing fix). The MacBook Pro trusts both other Macs today. Several pages still say "Macs never pair" (protocol.md Update all, user-guide.md, folders-and-settings-sync.md 8) | rr/devices-fix notes, plan.md 2026-11-01 |
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
| synth (2,000) | 1,127/1,130, 0, 0 | 1,127/1,130, 0, 0 | 1,120/1,130, 0, 0 (7 time-outs on a loaded host, see below) | not run |
| hard2 (200) | 106/110, 0, 1 | 106/110, 0, 1 | 106/110, 0, 1 | see As built |
| hard3 (240) | 118/120, 0, 5 | 118/120, 0, 5 | 118/120, 0, 7 | 118/120, 0, 7 |
| hard4 (240) | 103/120, 5, 17 | 103/120, 5, 17 | 103/120, 5, 18 | not run |
| mail blind (240) | 116/120, 0, 0 | 116/120, 0, 0 | 117/120, 0, 0 | not run |
| mail blind2 (240) | 118/120, 0, 0 (116 with the rule frozen before it) | 118/120, 0, 0 | 118/120, 0, 0 | see As built |
| Median per message | 106 ms | 77 to 117 ms | 442 to 805 ms (shared host) | 357 to 360 ms |

"wrong" is a wrong code on a code message, "false" a code shown for a no-code message. **On the same backend the Rust
reader gives exactly the Mac's numbers on every set.** CPU builds of llama.cpp (x86 and arm64 alike) differ from
Metal by a hair: two more expired codes in Indian languages shown on hard3, one more code found on mail blind. The
research's own CPU run gave 8 false on hard3, so this is the backend, not the port.

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
| 2 | A connected Mac reading codes for this phone (`sms_codes_draft1` and the mirror) | Always, as today | The notification, as today |
| 3 | One connected server with Detect codes | Only when 1 and 2 are not available, and only while some server has Read codes on | One code text message, to one device |

Options considered:

| Rule | For | Against |
| --- | --- | --- |
| **Fixed order, one detector (chosen)** | A code text goes to as few devices as possible; deterministic; no duplicates | A Mac that is awake but has no model reads nothing (rare: Codes from messages on means the model is there, or Cloud) |
| First available | Simple | Arbitrary; the server may see texts while a Mac is awake |
| Several, with dedupe | Most robust | Every code text goes to every detector: more exposure for no gain |

Among servers the lowest device ID wins, at most 60 candidates an hour each, at most 20 waiting in all; a server
that does not answer within 30 seconds is not asked again for that message.

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
| Memory while loaded | 300 MB resident (peak) | the same | The model is memory mapped; unloaded after 15 idle minutes |
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
Allow pairing (or an open invite) on the receiving side, envelope tags. An invite gets `p` for any platform; the
joiner is side 0 and commits; the invite secret is bound into the signed transcript (unchanged).

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

Today a phone relays a winning change to its other peers. In a mesh every device does: a device that applies a record
because it wins (higher `changedAt`, then `version`, then `changedBy`) sends it on to its other peers, never back to
the one it came from. A record that does not win is not sent on. Each device therefore sends each (key, stamp) at most
once per peer, the flood stops by itself, every device ends on the same winner, and duplicates are no-ops. No new
message; the rate limit (20 in 10 seconds per peer) stays.

### 4.5 Update all without a hub

`updates.start` gains optional `runId` (UUID) and `origin` (`deviceId`, `name`). A device that accepts a start
with a `runId` it has not seen sends the same `runId` on to its connected peers that allow remote starts, and updates
itself. A `runId` seen before is answered `accepted` and not sent on. The origin installs itself last, as today;
devices reached through another device are shown as "via <device>". The automatic run's rule (lowest device ID among
those with `auto`) is unchanged and harmless with duplicates. Older devices ignore the fields and do not pass starts on.

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

Phase 2 and 3 (designed, not built): `mesh_draft1`; invites with any `p`; `updates.start` `runId` and `origin`;
`codes.found` from the phone to Macs under `codes_cards_draft1`; `agent.*` served by a Mac; `codes.candidate` with
`source: email` behind its own switch.

## 6. Migration

- Nothing changes for existing pairs. New keys are false until both ends know them.
- Detect codes is off for every server until Rahul switches it on.
- A server needs a build with the model runner (`--features detect`) and `bridgey codes model download
  --accept-terms` (the same file the Mac downloads, SHA-256 checked, Gemma terms accepted with a date).
- Docs that say Macs never pair are corrected when phase 2 ships Mac invites.

## 7. Security analysis

| Threat | Before | After | Mitigation |
| --- | --- | --- | --- |
| More trust edges (mesh) | n phones times m Macs | up to n(n-1)/2 pairs | Each pair has its own keys, grants, audit and Forget; no transitive trust; a device acts only on its own things |
| A server is compromised | Agent grants only | Plus code texts while Detect codes is on | Explicit grant with a window; only when no Mac reads; one server per message; only gated SMS; text never stored or logged; audit on both sides; Forget revokes at once |
| A server injects codes | Not possible | Could claim a code for a message | One answer per candidate it was sent; the phone's guard must find the code in that text; the phone names the service; a refusal is logged on the server's activity |
| A server lies about a real token | | It could pick another code-like token in the text (an amount) | Limited to messages it was sent; Rahul sees which server read what; a second detector cross-check is possible later |
| Replay | | | `messageId` in the replay window; `candidateId` single use; 30 second expiry |
| Flooding | | | 60 candidates an hour per server, 20 waiting; the server reads at most 4 at once and answers `busy` beyond |
| Relays in the mesh (settings, Update all) | Phone relays settings | Every device relays | Only records that win are relayed (no loops); a start never names a version or file and installs only signed builds, so it cannot downgrade |
| Remote pairing for new kinds | Server and phone | Any pair | Same commit and reveal, code at both ends, invite bound into the transcript, single use, 10 minutes |
| The model file | | | Pinned manifest prefix, size bound, SHA-256 checked before use, terms accepted |

## 8. Phases

| Phase | Contents |
| --- | --- |
| **1 (built here)** | `rust/codes` as the single source of truth, its vectors, the accuracy guard; the server detects codes (`codes.candidate`, `codes.detected`, Detect codes, model download, audit); the phone forwards text messages to one server when no Mac reads; Android and Mac checked against the Rust vectors; phone feasibility measured |
| 2 | The phone reads codes itself (JNI to the crate, model download on Wi-Fi, a setting); the Mac calls the crate through `bridgey_codes_call` and drops its Swift copies; invites on every device (Mac shows and joins invites; `mesh_draft1`); a Mac grants servers |
| 3 | Mac and Mac features in full (settings flood, Update all `runId`, code cards across devices); Devices and permissions in three groups; Windows and Linux apps on the same core |

## 9. Open questions for Rahul

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

## As built (phase 1, 2026-11-04)

Filled in at the end of the branch; see the commit log of `rr/mesh-codes`.
