# Agent CLI (`bridgey`)

Status: draft spec for Bridgey by Round Robin, 2026-10-25. Spec only; nothing is built yet.
Transport, relays and remote pairing come from [connect-anywhere.md](connect-anywhere.md). The
wire messages are in the draft section of [protocol.md](protocol.md#draft-connect-anywhere-edition-only).

## 1. What it is

`bridgey` is a command that lets AI agents on rr-dev-1, oracle or the Macs reach Rahul's phone:

- send files and folders;
- set and request the clipboard;
- post a notification, or ask a question with answer buttons and wait for the reply ("Approve /
  Deny");
- ring the phone;
- read its battery.

Each install is its own paired device, and the phone grants it nothing until Rahul switches each
permission on.

It is written in Rust on the same crates as the apps' new transport. It is the first piece of the
v2 shared core (section 12).

### Decision: a headless node, not control of the Mac app

| | Headless node (recommended) | Local control of the Mac app |
| --- | --- | --- |
| Where it works | Linux servers (rr-dev-1, oracle), Macs, later Windows | Macs only, and only while the app runs |
| How it reaches the phone | Its own session over any route, relay included | The Mac app's session |
| Identity and grants | Its own device, own grants, own audit trail on the phone | Borrows the Mac's identity; the phone cannot tell an agent from Rahul at the Mac |
| v2 value | It is the core: protocol, crypto, routes, transfer, plugins in Rust | None; it adds an IPC surface to the Swift app |
| Cost | Needs remote pairing and the control service (P2) | Smaller, but a dead end |

**Recommendation: the headless node.** Most agents run on servers, and a separate identity is what
makes per-agent grants and auditing meaningful. Local control of the Mac app can come later as a
convenience, as an `--via-app` mode, if it is ever wanted.

## 2. Install and pair

```sh
brew install round-robin-solutions/tap/bridgey      # macOS and Linuxbrew
# or: curl -fsSL https://github.com/round-robin-solutions/bridgey/releases/download/cli-v0.1.0/install.sh | sh
bridgey pair --name "rr-dev-1 agent"
```

`bridgey pair` prints a QR code in the terminal, Unicode half blocks that are readable over SSH,
and a `bridgey://pair#...` link. Then:

1. On the phone: Devices, "Pair a device away from this network", then scan.
2. Both show a six-digit code. The CLI asks `Does the phone show 407 747? [y/N]`. There is no flag
   that skips this; pairing needs a person at both ends.
3. The phone opens the new device's permissions, all off, with presets to choose from (section 6).

The invite lasts 10 minutes and works once. `bridgey pair --link-only` prints just the link, for
pasting into a chat with yourself.

## 3. Commands

Each command picks the device with `-d, --device <name|id>` or the `BRIDGEY_DEVICE` variable. If
there is only one paired phone, that one is the default. Durations look like `30s`, `10m` or `2h`.

| Command | What it does | Main options |
| --- | --- | --- |
| `bridgey pair` | Remote pairing by QR code or link | `--name`, `--link-only` |
| `bridgey devices` | Paired devices, online state, route, granted features | |
| `bridgey status [DEVICE]` | Route in use, round trip, relay, battery if granted | |
| `bridgey grants [DEVICE]` | What the phone has granted this device, with expiries (read-only) | |
| `bridgey send PATH...` | Send files and folders (folders keep their structure) | `--to <folder token>` (granted folder, folders spec), `--no-wait`, `--resume <id>` |
| `bridgey transfers` | Current and recent transfers | |
| `bridgey transfer resume\|cancel ID` | Resume or cancel a transfer | |
| `bridgey clip set [TEXT\|-]` | Put text on the phone's clipboard (`-` reads stdin) | `--html <file>`, `--sensitive` |
| `bridgey clip get` | Ask the phone for its clipboard; Rahul taps Send on the phone | `--timeout` (default 2m) |
| `bridgey notify TITLE [BODY]` | Post a notification | `--priority normal\|high`, `--tag`, `--from` |
| `bridgey ask TITLE [BODY]` | Ask with answer buttons and wait | `-o, --option ID=LABEL` (1 to 3), `--text`, `--text-hint`, `--timeout` (default 30m, max 24h), `--require-unlock`, `--fail-unless ID`, `--no-wait`, `--keep-on-timeout`, `--from` |
| `bridgey wait ASK_ID` | Wait for, or fetch, the answer to an earlier ask | `--timeout` |
| `bridgey ring` | Ring the phone (Find Device) | `--duration` (default 30s, max 60s), `--stop` |
| `bridgey battery` | Level and charging state | |
| `bridgey ping` | One short sound on the phone; reports delivery | |
| `bridgey audit` | This install's local audit log | `--since`, `--json` |
| `bridgey doctor` | Network check from this host (connect-anywhere section 12.2) plus config and key checks | |
| `bridgey forget DEVICE` | Remove the pairing on this side | |
| `bridgey config get\|set KEY [VALUE]` | Read or change `config.toml` | |

Phase 2 adds `bridgey daemon`, `bridgey inbox`, `bridgey watch` and `bridgey mcp` (section 13).

Examples:

```sh
# Ask for approval before a deploy; continue only on "approve"
bridgey ask "Deploy rr-web?" "hopwire 1.4.2, 3 migrations" \
  -o approve=Approve -o deny=Deny --require-unlock --timeout 20m --fail-unless approve --json \
  && ./deploy.sh

# Send a build and a folder of screenshots
bridgey send dist/app-release.apk ./screens --json

# Tell Rahul something, quietly
bridgey notify "Nightly passed" "bridgey 0.6.0-rr.2-nightly.20261026" --from "RR CI"

# Free-text answer
bridgey ask "Release notes headline?" --text --text-hint "One line" --timeout 1h --json

# Fire and forget, then collect the answer later
id=$(bridgey ask "Merge PR 42?" -o yes=Merge -o no=Hold --no-wait --json | jq -r .askId)
bridgey wait "$id" --timeout 4h --json
```

## 4. Output

The default output is short text for people. `--json` (or `BRIDGEY_OUTPUT=json`) prints exactly
one JSON object on stdout. `--jsonl` streams one event per line and ends with the result. Errors
go to stderr in text mode; in JSON mode they are the JSON object.

```json
{"ok":true,"command":"ask","device":{"id":"c1f0...","name":"OnePlus 11"},
 "askId":"01934f3e-8a7c-7b1e-9d1a-2f6c0b8e4d21",
 "answer":{"option":"approve","label":"Approve","text":null,"answeredAt":"2026-10-25T12:04:31Z"},
 "route":"direct"}
```

```json
{"ok":false,"command":"ask","error":{"code":"not_granted","message":"OnePlus 11 has not allowed questions from this device","feature":"ask","exit":5}}
```

```jsonl
{"event":"connecting","device":"OnePlus 11"}
{"event":"connected","route":"relay","relay":"bom","rttMs":64}
{"event":"progress","transferId":"0193...","bytes":52428800,"total":734003200,"rate":6100000}
{"event":"interrupted","transferId":"0193...","resumable":true}
{"event":"progress","transferId":"0193...","bytes":104857600,"total":734003200,"rate":5900000}
{"event":"result","ok":true,"command":"send","transferId":"0193...","files":2,"bytes":734003200}
```

The JSON key names are stable within a major version. New keys may appear at any time; agents
must ignore keys they do not know.

## 5. Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done. For `ask`, an answer arrived, whichever option it was, unless `--fail-unless` applies. |
| 1 | Other failure |
| 2 | Usage error (bad option or argument) |
| 3 | Device unreachable: no route within the connect deadline (10 s, `--connect-timeout`) |
| 4 | Timed out waiting for an answer or acknowledgement |
| 5 | Not granted by the phone |
| 6 | Rate limited; `error.retryAfterMs` says when |
| 7 | Declined or rejected: the user declined, the ask was dismissed, or `--fail-unless` saw another answer |
| 8 | Not paired or unknown device |
| 9 | Transfer failed (integrity, storage, cancelled on the phone) |
| 10 | Incompatible: the phone lacks the capability (for example an old app version) |
| 11 | Transfer interrupted but resumable; the JSON has `transferId` for `bridgey transfer resume` |
| 130 | Interrupted (Ctrl-C) |

## 6. Grants

Grants are decided and enforced on the phone. The CLI only learns what is granted, so it can give
clear errors. A new CLI device starts with everything off, whatever the global switches say.

| Grant (wire feature key) | Lets the agent | Notes |
| --- | --- | --- |
| Send you files and folders (`files`) | Deliver files to `Download/Bridgey/<device name>` or a granted folder | Optional limits: per transfer (default 2 GB), per day (default 5 GB) |
| Set your clipboard (`clipboard`) | Write text or HTML to the phone clipboard | Existing feature key |
| Ask for your clipboard (`clipboard_request`) | Request it; every request needs Rahul's tap | Android blocks background clipboard reads, so there is no silent read |
| Send notifications (`notify`) | Post notifications in the "Agent messages" channel | |
| Ask questions (`ask`) | Post questions with buttons in the "Agent questions" channel and receive answers | |
| Ring this phone (`find_device`) | Start and stop Find Device | The phone stops agent rings after 60 s by itself |
| See battery (`battery`) | Receive `battery.update` | Existing feature key |
| See your notifications (`notifications`) | Receive forwarded phone notifications | Never in a preset; its own screen with a warning; can be limited by app with the existing filters |

- **Presets** on the pairing screen: "Messages and questions" (notify plus ask), "Files" and "Find
  my phone" (ring plus battery). Rahul can still change each switch.
- **Time windows.** Each grant can expire: "for 1 hour", "today", "7 days" or "until I turn it
  off". This is upstream's "grants limited to a single session or time window". When a grant
  expires the phone sends `features.update`, and the CLI reports `not_granted`.
- **The device page** shows the permissions and an Activity tab with the audit log (section 9).

On the wire this reuses `features.update`, with new optional keys `notify`, `ask` and
`clipboard_request`. Older clients ignore unknown keys. The CLI advertises `platform: "cli"` in
its pairing messages, so the phone applies agent defaults.

## 7. Asking and waiting for an answer

1. **Request.** The CLI sends `ask.request`:
   - `askId` (UUIDv7, chosen by the CLI, so a retry after a reconnect never duplicates the question);
   - `title` (at most 120 characters) and `body` (at most 1,000);
   - `options`: 1 to 3 of `{id, label}`, the id matching `[a-z0-9_-]{1,32}` and the label at most
     20 characters;
   - `allowText`;
   - `requireUnlock`;
   - `expiresAt` (at most 24 h ahead);
   - `from` (at most 64 characters, shown as "says it is from", since the agent sets it itself).
2. **Posted.** The phone checks the grant and rate limits and posts a high-importance notification
   with one action per option.
   - With `allowText`, a Reply action with inline text takes one of the three action slots, so at
     most 2 options are allowed then.
   - With `requireUnlock`, actions use `Notification.Action.Builder.setAuthenticationRequired(true)`
     (Android 12, API 31, and later;
     [reference](https://developer.android.com/reference/android/app/Notification.Action.Builder#setAuthenticationRequired(boolean))).
     On older Android the tap opens Bridgey, which needs the unlock.
   - The phone replies `ask.posted`, or `ask.rejected` with a code.
3. **Answered.** Rahul taps. The phone sends `ask.answer` with `askId`, `option` or `text` (at most
   1,000 characters) and `answeredAt`. If the CLI is not connected, the phone keeps the answer for
   24 hours and delivers it on the next session, or when asked with `ask.status`.
4. **Other endings:**
   - `ask.dismissed`: swiped away; exit code 7.
   - `ask.expired`: the expiry passed.
   - `ask.cancel`: sent by the CLI on timeout, unless `--keep-on-timeout`. The notification
     disappears and the phone confirms with `ask.cancelled`.
5. **Waiting.**
   - The blocking command keeps the session up, with keep-alives, and re-dials with backoff if the
     route drops.
   - The background agent process (section 10) holds the pending ask, so a killed command loses
     nothing: `bridgey wait <askId>` picks it up.
   - At most 3 pending asks per agent device, and 10 on the phone in total.

An agent that runs inside an MCP client with short tool timeouts uses `--no-wait` and then
`bridgey wait`. The phase 2 MCP server does the same internally.

## 8. Rate limits

The phone enforces these limits per agent device. Each can be changed on the device page.

| Action | Default limit |
| --- | --- |
| `notify` | 30 an hour, burst 5; `high` priority 10 an hour |
| `ask` | 20 an hour, 3 pending |
| `ring` | 3 per 10 minutes |
| `clip set` | 60 an hour |
| `clip get` | 10 an hour, 1 pending |
| `send` | 20 transfers an hour; size limits as granted |
| New sessions from one agent device | 120 an hour |

When a limit is hit, the phone answers `rate_limited` with `retryAfterMs`, and the CLI exits with
code 6. The CLI never retries on its own after a rate limit.

## 9. Audit log

**On the phone,** per device. This is upstream's "private per-device audit log".

- **Each entry:** time; action (`pair`, `grant.change`, `notify`, `ask`, `answer`, `ring`,
  `battery`, `clipboard.set`, `clipboard.request`, `files.receive`, `forget`); outcome
  (`delivered`, `answered:<option>`, `declined`, `rate_limited`, `not_granted`, `expired`).
- **Detail:** the title for notify and ask (at most 120 characters); file names and the total size
  for files. Never clipboard content and never notification text.
- **Limits:** at most 2,000 entries or 90 days per device. Owner-only file, no backup, never in
  diagnostics.
- **In the app:** shown in the device page's Activity tab; can be exported as JSON and cleared.

**In the CLI,** `~/.local/state/bridgey/audit.jsonl` (`0600`), rotated at 10 MB, keeps 5 files.

- **Each entry:** time; command; device; outcome; a hash of the arguments. Never message text,
  clipboard content or file contents.
- **The caller,** as far as it can be known: parent process name, Unix user, and `BRIDGEY_CALLER`
  if the agent sets it (for example `claude:hopwire`).

## 10. Config, files and keys

One settings file, `~/.config/bridgey/config.toml`:

```toml
device_name = "rr-dev-1 agent"
default_device = "OnePlus 11"
control_url = "wss://connect.roundrobin.in/v1/ws"   # edition default; empty in upstream builds
udp_port = 0                                        # 0 = any free port; set 42458 to accept direct paths
output = "text"                                     # or "json"

[timeouts]
connect = "10s"
ask = "30m"

[inbox]                                             # phase 2
dir = "~/bridgey-inbox"
```

Files:

| Item | Linux | macOS |
| --- | --- | --- |
| Identity key (P-256), node key | `~/.local/share/bridgey/keys/` (`0600`) | Keychain (`in.roundrobin.bridgey.cli`), falling back to the same files |
| Trust records (peer identity keys, pair secrets, learned addresses) | `~/.local/share/bridgey/trust.json` (`0600`) | `~/Library/Application Support/in.roundrobin.bridgey.cli/` |
| Transfer state | `~/.local/share/bridgey/transfers/` | same folder as above |
| Agent socket | `$XDG_RUNTIME_DIR/bridgey/<profile>.sock` (`0600`, peer UID checked) | `$TMPDIR/bridgey-<profile>.sock` |

Environment: `BRIDGEY_DEVICE`, `BRIDGEY_OUTPUT`, `BRIDGEY_CONFIG`, `BRIDGEY_PROFILE` and
`BRIDGEY_CALLER`.

**Profiles.** `--profile <name>` keeps a separate state folder, and so a separate paired device.
Use it to give two agents on one host different grants.

**Background agent process.** Existing Bridgey clients close duplicate sessions from one device,
so two commands running at once must share one session.

- The first command starts `bridgey agent` in the background, like ssh's ControlMaster.
- It holds the session, pending asks and transfers.
- Later commands talk to it over the agent socket.
- It exits after 10 minutes idle. In phase 2, `bridgey daemon` runs the same process permanently.

## Network

The CLI dials out. A phone behind CGNAT reaches a server with a public address directly, provided
the server accepts the phone's packets.

- **Direct paths to the server:** set `udp_port = 42458` and allow 42458/udp inbound in the
  provider firewall (OCI security list on oracle) and in the host firewall. Without that, the phone
  is often behind a hard NAT, its packets arrive from an unexpected port, and the session falls
  back to a relay.
- **On Macs at home** the CLI usually goes direct or over the LAN.
- **Opening ports is a server change,** so it waits for Rahul's approval like the relay ports.

## 11. Packaging

| Target | Build | Delivered as |
| --- | --- | --- |
| Linux x86_64 and aarch64 | `cargo zigbuild --release --target {x86_64,aarch64}-unknown-linux-musl`; static, rustls with ring, no OpenSSL | `bridgey-<version>-<target>.tar.gz` on GitHub Releases, plus `SHA256SUMS` |
| macOS arm64 and x86_64 | `cargo build --release` for both, then `lipo` and an ad-hoc codesign | `bridgey-<version>-macos-universal.tar.gz` |
| Homebrew | Formula `bridgey` in `round-robin-solutions/homebrew-tap` (the tap planned for the Mac app) | `brew install round-robin-solutions/tap/bridgey` |
| apt (phase 2) | `cargo deb` | `.deb` attached to the release. A signed apt repository only if needed (R2 behind Cloudflare, a dedicated signing key). |
| Install script | Downloads the right tarball and checks it against `SHA256SUMS` before installing | `install.sh` asset |
| Windows (v2) | `x86_64-pc-windows-msvc` | Later |

- **Tags:** `cli-v0.1.0`, separate from the app tags, so CLI and app releases do not block each other.
- **Builds:** on RR CI's GitHub-hosted lane (the repository is public), Linux on `ubuntu-latest`
  and macOS on `macos-15`. The CLI needs no signing secrets beyond checksums.
- **Self-update (phase 2):** the existing channel feeds (`stable.json`, `beta.json`,
  `nightly.json`) gain a `cli` entry per target with URL, SHA-256 and size. `bridgey update`
  follows the same "never downgrade" rule as the apps.

## 12. How it maps to the v2 Rust core

| Crate | Contents | First used by | v2 role |
| --- | --- | --- | --- |
| `bridgey-proto` | Message types (serde), envelope, limits, validation, test vectors | CLI | All clients |
| `bridgey-crypto` | Pairing (P-256 ECDH, HKDF, code, HMAC proof), transcripts v1 and v2, AES-GCM payloads, a signer trait (Keystore, Keychain, file) | CLI | All clients |
| `bridgey-connect` | Routes, ICE, TURN, QUIC tunnel, rendezvous client, network check | Apps (P1 to P3), CLI | All clients |
| `bridgey-transfer` | `transfer.v1`, manifest, resume state, a storage trait | Apps (P4), CLI | All clients |
| `bridgey-node` | Session manager, plugin dispatch (battery, clipboard, notify and ask, find, files), grants, rate limits, audit log | CLI | The whole app core for Windows and Linux; Android and macOS move plugins into it over time |
| `bridgey-ffi` | UniFFI bindings for Kotlin and Swift | Apps | All native UIs |
| `bridgey-cli` | The command | CLI | |
| `bridgey-rendezvous`, `bridgey-relay-agent` | Servers | Control service, relays | |

The CLI is the first client to use the whole stack, which makes it the test bed for the v2 core.
The Windows (WinUI 3) and Linux (GTK4 and libadwaita) apps are native UIs on `bridgey-node`
through `bridgey-ffi`.

## 13. Phases

| Phase | Contents | Needs |
| --- | --- | --- |
| Phase 1 (P5) | `pair`, `devices`, `status`, `grants`, `send` (resumable), `transfers`, `clip set` and `clip get`, `notify`, `ask` and `wait`, `ring`, `battery`, `ping`, `audit`, `doctor`, `forget`, `config`; JSON and exit codes; background agent process; on Android: agent defaults, grants with time windows, rate limits, "Agent messages" and "Agent questions" channels, audit log; tarballs, install script, Homebrew | Connect anywhere P2 (P3 for UDP-blocked phones, P4 for large sends) |
| Phase 2 (P6) | `bridgey daemon` (systemd user unit, launchd agent); `bridgey inbox` (files the phone sends to the agent's device); `bridgey watch` (JSONL events: clipboard from the phone, answers, battery changes, granted notifications); `bridgey mcp` (an MCP server exposing `send_file`, `notify`, `ask`, `get_answer`, `ring`, `battery`); notification reading behind its explicit grant; `.deb`; `bridgey update` | Phase 1 |

## 14. Security notes

- **Pairing.** Every pairing needs the code confirmed at both ends. No unattended pairing, and no
  pairing tokens in config files.
- **Agents are ordinary devices,** subject to the same per-device revocation: "Forget" on the
  phone deletes the trust, the pair secret and the grants.
- **Nothing executes on the CLI side** because of a phone message. The CLI never runs commands it
  receives and has no remote shell. Phase 2 inbox files are written as plain files with
  collision-safe names, never made executable.
- **Text the agent supplies** (titles, bodies, labels, `from`) is shown as plain text on the
  phone, never as HTML or links.
- **Logs** on both sides hold no message text, clipboard content or file contents.

## 15. Open questions for Rahul

1. **Binary name:** `bridgey` (may clash with a future upstream CLI) or `bridgey-rr`?
2. **Phase 1 scope:** is `clip get`, which needs a tap on the phone every time, worth keeping in
   phase 1?
3. **Files from agents:** should they land in a subfolder per device
   (`Download/Bridgey/<device name>`) by default?
4. **Questions on the Mac:** should agents also be able to ask on the Macs (a Mac notification with
   buttons), or the phone only for now?
5. **Default limits:** are the defaults in section 8 right? For example, 20 asks an hour.
