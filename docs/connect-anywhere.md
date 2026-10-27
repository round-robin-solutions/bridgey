# Connect anywhere

Status: architecture spec for Bridgey by Round Robin, 2026-10-25. **Phase 1 is built (2026-10-27,
branch `rr/connect-anywhere`) and not deployed**: see [Phase 1 as built](#phase-1-as-built-2026-10-27)
and the [deploy runbook](connect-anywhere-deploy.md). The protocol parts are edition-only until
upstream accepts them (draft section in [protocol.md](protocol.md#draft-connect-anywhere-connect_draft1)).
The agent command is specified separately in [agent-cli.md](agent-cli.md).

## Phase 1 as built (2026-10-27)

Rahul approved phase 1 on 2026-10-27: routes, the QUIC tunnel, the control service and the relay,
behind an opt-in switch. The transfer engine (section 8) is not part of it.

| Part | Built | Where |
| --- | --- | --- |
| Rust core `bridgey-connect` | One UDP socket shared by STUN, TURN and QUIC (RFC 9443); TURN client over UDP (Allocate, Refresh, ChannelBind, shared per relay); ICE agent with host, server-reflexive and relay candidates, nomination with a 300 ms window, keep-alive checks every 5 s, failover after 3 missed checks and upgrades after 3 good ones; QUIC (quinn 0.11, rustls ring, TLS 1.3, Ed25519 certificates both ways, pins, exporter); the route race (learned LAN and VPN addresses 2 at a time 150 ms apart, ICE through the control service in parallel); upgrades every minute, on network change and on foreground; the rendezvous client with keystore-signed node auth and adaptive keep-alive; a loopback bridge that hands each tunnel's stream 0 to the app with a one-time token | `rust/core` |
| Control service `bridgey-rendezvous` | Node auth (P-256, optional proof of work), presence, sealed signal forwarding, relay grants with TURN REST credentials (one relay per session for both sides), rate limits, health endpoints, one TOML settings file | `rust/rendezvous`, `server/rendezvous` |
| Relay | coturn 4.18.0 pinned by digest, the section 9.7 settings rendered from the environment into a tmpfs, compose stack | `server/relay` |
| Android and Mac | "Connect away from home" (off until chosen) in setup (question and bundle) and Settings; tunnel sessions run the unchanged session with `bridgey-auth-v2`; `connect.setup` and `connect.addresses`; pair secrets per device; route on the device page; a 3 s ping probe after network changes for quick failover | `android/.../connect`, `macos/.../Connect*.swift` |
| Protocol | Draft key `connect_draft1` (instead of the `capabilities` array, per the contract's draft rule), `connect.setup`, `connect.setup.ack`, `connect.addresses`; in-band ICE and `connect.route` listed as designed | `protocol/messages.json`, `docs/protocol.md` |
| Vectors | `connect-v1.json` from the Rust core (pair secret, pair check, rendezvous IDs, signal key, sealing, node auth, TURN credentials, transcript), checked by Rust, Python, Android and the Mac; `connectSetup` and `connectAddresses` in `protocol-v1.json` | `protocol/test-vectors` |

Live test (2026-10-27, rr-dev-1 and the personal Mac; nothing public): the control service (its
image) and coturn ran on rr-dev-1 bound to the tailnet only. The Android build on the emulator paired
over TCP with `server/local/test_peer.py` (a headless peer with the same core), set up the pair
secret, then reached it through the relay with LAN blocked:

| Measure | Result |
| --- | --- |
| Relay connect, core to core (5 runs) | 202 to 254 ms from the race start to the tunnel; the peer is raced 1.5 s after it drops or appears |
| Phone app to peer through the relay | tunnel 1.8 s after the race started, session authenticated (`bridgey-auth-v2`) 0.25 s later |
| Failover, direct or private network to relay (core, 3 runs) | 3.1 to 3.3 s from blocking the path to the relay tunnel (3 s probe plus about 0.1 s) |
| Failover in the phone app | 6.7 s from blocking the path to the relay session (3 s probe, 1.5 s grace, 1.8 s race, 0.25 s handshake) |
| What the relay saw | 4,077 relay packets captured; no device name, device ID, message kind or test marker in any of them |
| Core size | 3.5 MB arm64-v8a, 4.1 MB x86_64 (release, stripped); the control service image is 2.6 MB |

Calls made while building (for review):

- **No UniFFI yet.** The apps talk to the core through five C functions (Mac, `dlopen`) and four JNI
  functions (Android) carrying JSON commands and events. It keeps JNA and generated bindings out of
  both apps; UniFFI can replace it when v2 moves plugins into Rust.
- **Own STUN and TURN code instead of `rice-proto` and `turn-client-proto`.** About 700 lines, tested
  against the RFC 5769 vector and coturn. The spike that would have picked a crate was folded into
  phase 1.
- **The app session runs over a loopback TCP bridge** (127.0.0.1, a 32-byte one-time token per
  tunnel) so the existing session code needed no new transport.
- **QUIC sees one stable virtual address per ICE session**, so a move between ICE pairs keeps the
  connection without QUIC migration. A move between a learned-address tunnel and an ICE tunnel is a
  new tunnel that replaces the old session under the existing duplicate rule.
- **LAN sessions stay on today's TCP** when Bonjour finds the device; QUIC on the LAN is used for
  learned addresses only. **Decided by Rahul (2026-10-27): keep TCP on the LAN for now**, so moving
  LAN TCP sessions to QUIC (section 4.4) waits.
- **Tunnels carry paired devices only.** A device that is not already paired gets no prompt over a
  tunnel; remote pairing by invite (section 6.6) is a later phase.
- **The control service keeps no database in phase 1** (presence and limits in memory; SQLite comes
  with the ops view).
- **Path MTU discovery is off** (QUIC packets stay at 1,200 bytes) so relayed and tailnet paths never
  black-hole.
- **The Mac keeps the node key and pair secrets in a 0600 file** next to its pairing file, not the
  Keychain, because ad-hoc signed builds get a new Keychain partition on every update. Android wraps
  the pair secrets with a Keystore key and keeps the node key in the Keystore.

Not built in phase 1: in-band ICE and ICE restarts (the session is re-raced instead), TURN over TCP
and TLS on 443, Cloudflare TURN, the relay agent with allowance caps, the ops dashboard and alerts,
the network check, port mapping, network tags in `connect.addresses`, remote pairing, the anonymous
connection stats, and the mobile data question for large transfers (it belongs to the transfer
engine).

## 1. Summary

Connect anywhere lets two paired devices reach each other from any network, with no VPN on the
phone and no accounts. It is the Blip replacement, phase 1: send files and folders of any size
between your own paired devices, from anywhere, and resume after network drops and app restarts.
Sending to other people comes later.

- **Routes per device, first that answers wins.** Same Wi-Fi, then a private network address
  (Tailscale or another VPN, when on), then direct over the internet (IPv6 and hole punching), then
  a relay. Bridgey learns the other device's addresses while connected and moves back to a faster
  route on network change, on app foreground and every minute. This is T3 Connect's route model
  ([T3 remote access](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md)).
- **One new transport: QUIC.** Every new route carries QUIC (TLS 1.3) over one UDP socket that an
  ICE agent manages. The existing Bridgey session runs inside it unchanged: same pairing, same pinned
  identities, same AES-GCM payloads, same plugin messages. The identity signatures are bound to the
  QUIC connection, so relays and our servers see only ciphertext.
- **A tiny control service** lets devices find each other off the local network. It forwards
  sealed signalling between the two sides of a pair and hands out short-lived relay credentials.
  It knows devices only by a self-generated key and by rendezvous IDs derived from a secret that
  only the two paired devices hold.
- **Relay pool:** coturn on oracle (Mumbai), rb-vps (Singapore) and rr-dev-1 (France), with
  Cloudflare Realtime TURN as overflow and failover. The pool keeps each server under its traffic
  allowance with soft and hard caps per cycle and prefers the cheapest healthy relay near both
  devices.
- **Large transfers:** 1 MiB chunks with a SHA-256 each, a root hash per file, up to 8 parallel
  QUIC streams, and resume from the last durable chunk after reconnects and app restarts.
- **Agent CLI:** a headless Rust node, paired like any device, with nothing granted until Rahul
  switches it on.
- **One Rust core** (`bridgey-connect`, `bridgey-transfer`) is used by the Android app, the Mac app
  and the CLI. It is the start of the v2 shared core.
- **Ops dashboard and alerts** live in the control service, behind Cloudflare Access with Google
  sign-in for info@roundrobin.in (the RR CI pattern). Alert volume never grows with user count.
- **Cost:** USD 0 per month up to about 1,000 active device pairs under conservative assumptions.
  Cloudflare charges start only when the own pool (about 17 TB of relay traffic a month) is full
  (section 10).

### Scope

In scope: routes, learned addresses, direct internet, relay pool, control service, dashboard and
alerts, resumable transfer of files and folders, the network check in onboarding, remote pairing
(needed by the CLI), and the agent CLI.

Not in this phase:

- sending to other people;
- store-and-forward when the other device is offline (possible later paid feature, section 8.11);
- the gallery manager (moved to v2, section 8.11);
- iOS, Windows and Linux apps (v2).

### Plain words

| Term | Meaning |
| --- | --- |
| NAT | A router that shares one public address between many devices. Replies come in; unsolicited traffic does not. |
| CGNAT | The same, done by the mobile carrier for many customers at once (Jio and Airtel IPv4 on mobile data). |
| Easy and hard NAT | An easy NAT (endpoint-independent mapping) keeps the same public port whoever you talk to, so hole punching works. A hard NAT (endpoint-dependent, often called symmetric) picks a new port for every destination, so it usually fails ([Tailscale](https://tailscale.com/blog/how-nat-traversal-works)). |
| STUN | A tiny request to a public server: "what address do you see me as?" |
| Hole punching | Both devices send to each other's public address at the same time, so both NATs let the traffic in. |
| TURN, relay | A server that forwards packets between the devices when no direct path works. |
| ICE | The standard procedure that collects every possible address (candidates), tests pairs of them and picks one that works ([RFC 8445](https://www.rfc-editor.org/rfc/rfc8445)). |
| QUIC | An encrypted transport over UDP, the base of HTTP/3 ([RFC 9000](https://www.rfc-editor.org/rfc/rfc9000)). It uses TLS 1.3, carries many streams in one connection, controls congestion and survives address changes. |

## 2. Decisions this builds on

Rahul's decisions of 2026-10-25 are in `outputs/bridgey/plan.md`, under "Away from home without a
VPN on the phone" and "Blip replacement, agent CLI, relay pool, gallery". In short:

- **Phase 1:** your own devices, any size, resumable, files and folders.
- **Routes:**
  - Routes are per paired device, in the order above, and the first route that answers wins.
  - Addresses are learned while connected.
  - Bridgey upgrades on network change, on foreground and every minute.
- **Relay pool:**
  - Self-hosted relays on oracle, rr-dev-1 and rb-vps. Production `rr-web` is excluded.
  - Cloudflare Realtime TURN is the backup.
  - Each server has a soft and a hard cap; the pool prefers the cheapest healthy relay near both devices.
  - A dashboard shows usage against allowance.
- **CLI:**
  - A `bridgey` command, written in Rust.
  - Each install is its own paired device with explicit grants.
  - It never reads notifications unless granted.

Corrections from Rahul, 2026-10-25:

- The plans of the three servers are as listed in section 9.1.
- The plan to retire rb-vps is cancelled.
- Use one Cloudflare account only.
- Add a network check to onboarding.
- Store-and-forward and the gallery are out of this phase.
- Alerting must never scale with the number of users.

## 3. Architecture

```text
 Android app (Kotlin)      Mac app (Swift)         bridgey CLI (Rust)
   UI, plugins, LAN TCP      UI, plugins, LAN TCP     headless node
         \ UniFFI                / UniFFI                  |
          +------------- Rust core ------------------------+
          | route manager | ICE agent | QUIC (quinn) | TURN client |
          | rendezvous client | network check | resumable transfer |
          +-----------------+------------------------+------------+
                            | UDP 42458                | WSS 443
                            v                          v
      other device (direct)  or  relay pool         control service (rr-web)
                                 bom sin sxb cf     presence, sealed signalling,
                                 (coturn, CF TURN)  relay credentials, pool policy,
                                                    usage, ops dashboard, alerts
```

| Component | What it does | Where |
| --- | --- | --- |
| Rust core | Routes, ICE, QUIC tunnel, TURN client, rendezvous client, network check, resumable transfer | Linked into both apps through UniFFI; built into the CLI |
| Apps | UI, plugins, existing LAN TCP transport for upstream peers; call the core for every new route | Android, macOS |
| CLI node | A full Bridgey device without UI, for agents | rr-dev-1, oracle, the Macs |
| Control service (`bridgey-rendezvous`) | Presence mailbox, sealed signalling, node auth, relay credentials, pool selection, usage collection, ops view, alerts | Round Robin Dokploy on `rr-web` (section 6.7) |
| Relays | coturn plus a small relay agent that counts traffic and enforces caps | oracle (`bom`), rb-vps (`sin`), rr-dev-1 (`sxb`) |
| Cloudflare Realtime TURN | Overflow and failover relay (`cf`) | Cloudflare, one account |

What stays as it is:

- Pairing, the six-digit code, pinned P-256 identity keys and the session crypto.
- Plugin messages and their limits.
- Bonjour `_bridgey._tcp` and TCP port 42458.
- Today's newline-JSON over TCP for any peer without `connect.v1`, which includes upstream
  clients, so interoperability with upstream does not change.

The core handles routes and bulk bytes. The apps keep their plugins until v2 moves them into Rust.

## 4. Routes

### 4.1 Route kinds

| Order | Route | How it is found | Needs the control service | Transport | Cost |
| --- | --- | --- | --- | --- | --- |
| 1 | Same Wi-Fi (`lan`) | Bonjour (today) and learned LAN addresses | No | QUIC on UDP 42458 between edition devices; TCP 42458 with upstream peers | Free |
| 2 | Private network (`vpn`) | Learned addresses on Tailscale or other VPN interfaces | No | QUIC | Free |
| 3 | Direct over the internet (`direct`) | ICE: public IPv6 host candidates, STUN server-reflexive candidates, hole punching | Yes, for signalling | QUIC | Free |
| 4 | Relay (`relay`) | ICE relay candidates from the pool | Yes, for signalling and credentials | QUIC inside TURN | Relay allowance; Cloudflare after its free tier |

The UI shows "Same Wi-Fi", "Private network", "Direct" or "Relay (Mumbai)". Bridgey says
"Tailscale" only for addresses in `fd7a:115c:a1e0::/48` or on an interface named for Tailscale.
The IPv4 range `100.64.0.0/10` is shared with other VPNs and carrier NAT
([Tailscale KB](https://tailscale.com/kb/1015/100.x-addresses)), so those addresses are labelled
"Private network".

### 4.2 Candidates and priority

Priority follows [RFC 8445 section 5.1.2.1](https://www.rfc-editor.org/rfc/rfc8445#section-5.1.2.1):
`2^24 x type preference + 2^8 x local preference + (256 - 1)`. The type preferences encode the
route order:

| Candidate | Type preference | Route |
| --- | --- | --- |
| Host, private LAN address (RFC 1918, ULA other than Tailscale) | 126 | lan |
| Host, VPN interface (tun, utun, wg, tailscale; 100.64.0.0/10; fd7a:115c:a1e0::/48) | 118 | vpn |
| Host, global IPv6 | 110 | direct |
| Peer reflexive (learned from an incoming check) | 100 | direct |
| Port-mapped by the router (PCP, NAT-PMP or UPnP; phase 2 stretch) | 96 | direct |
| Server reflexive IPv4 (STUN) | 90 | direct |
| Relay, own pool | 2 | relay |
| Relay, Cloudflare | 1 | relay |

The local preference puts IPv6 before IPv4 and Wi-Fi before mobile data. Loopback, link-local,
Docker and bridge interfaces (`docker0`, `br-*`, `veth*`) are never offered. Each side offers at
most 24 candidates.

### 4.3 Connecting: the race

Bridgey tries the fast free routes at once, gives them a short head start over the relay, and takes
the best one that answered within a short window:

| Time | Action |
| --- | --- |
| 0 ms | Dial QUIC directly to the Bonjour address if the peer is on this network, and to up to 8 learned LAN and VPN addresses (newest first, 2 at a time, 150 ms apart, 2 Initial packets each, 300 ms timeout). |
| 0 ms | If presence says the peer is online: gather host candidates and server-reflexive candidates (STUN to the nearest own relay and to `stun.cloudflare.com`, 500 ms budget), send a sealed `offer`, trickle late candidates. |
| 0 ms | Ask the control service for relay credentials (`relay.request`). No allocation yet. |
| first check + 1,000 ms | If no non-relay pair has succeeded, allocate TURN (UDP, or TLS on 443 when UDP looks blocked) and add relay candidates. The cached network check skips this wait when UDP is blocked or both sides are behind hard NAT with no IPv6. |
| first success + 300 ms | Nominate the best pair that has succeeded so far. |
| then | QUIC handshake (1 round trip), then the inner Bridgey handshake (1.5 round trips). |
| 10 s | Give up on the route ("Can't reach the device right now"; CLI exit code 3). The inner handshake has its own 5 s deadline. |

Targets: connected within 2 s (median) and 5 s (95th percentile) off the local network, within
500 ms on it.

One authenticated session per pair, as today. The lower device ID is the controlling ICE agent and
the QUIC client; duplicate sessions are closed after authentication.

### 4.4 Every session gets an ICE agent

A session can start over a direct dial or today's LAN TCP connection. When it does, the two sides
immediately exchange `connect.offer` and `connect.answer` in-band, inside the encrypted session.
From then on the session has an ICE agent that knows every candidate pair.

- **Network changes** cause an ICE restart. The signalling goes in-band while the current path
  still works, and through the control service once it has failed.
- **QUIC moves to the new path** without dropping streams: the core gives QUIC one virtual
  address per ICE pair (section 7.4).
- **LAN TCP sessions** between edition devices move to QUIC as soon as it is up. The TCP
  connection is then closed.

### 4.5 Learned addresses

After authentication, and whenever its interfaces change, each side sends an encrypted
`connect.addresses` message. The receiver keeps at most 16 entries per peer:

| Field | Meaning |
| --- | --- |
| `a`, `p` | Address and UDP port (42458 unless that port was taken) |
| `kind` | `lan`, `vpn` or `public6` |
| `vpn` | `tailscale` or `other` |
| `net` | 8-byte network tag, computed as `HMAC-SHA256(pairSecret, "bridgey-net-v1" ‖ fingerprint)[0..8]`. Two devices on the same LAN compute the same tag, so "probably on my network" addresses go first. |
| timestamps | First seen, last seen, last success, failure count |

The network fingerprint is built from the default gateway, the DNS servers, the IPv6 /64 prefix
and the transport type, all from Android `LinkProperties` or macOS `NWPath`. It never uses the
Wi-Fi name: on Android the SSID needs location permission, which Bridgey does not request.

How entries change:

- When the peer reports new addresses, they replace the old ones, as in T3.
- An entry expires 30 days after it was last seen or last worked.
- An address that does not answer is skipped until the network changes. This follows T3: "A LAN
  address that doesn't answer when you're away from home is checked briefly and skipped".

### 4.6 Upgrades and failover

| Trigger | What runs |
| --- | --- |
| Network change (Android `registerDefaultNetworkCallback`, macOS `NWPathMonitor`) | New candidate gathering, then an ICE restart |
| App comes to the foreground | Same as a network change if the network fingerprint changed, otherwise the minute tick |
| Every 60 s while not on `lan` | Connectivity checks on the known higher-priority pairs only (a few hundred bytes of STUN) |
| The peer reports a network change (`connect.restart`) | ICE restart |

Rules:

- **Upgrade:** a higher pair must pass 3 checks in a row, 200 ms apart; then QUIC migrates to it.
  Bridgey never moves down while the current path works.
- **Failure:** 3 missed keep-alives (45 s) or a QUIC path failure. Bridgey moves to the next valid
  pair. If there is none, it restarts ICE; if that fails, it re-dials with the existing backoff
  (full jitter, 1 s base, 60 s cap).
- **Futile pairs:** a pair that failed 5 times on the same network is checked every 5 minutes
  instead of every minute.
- **Relay release:** after 120 s stable on a non-relay path, Bridgey releases the TURN allocation
  (Refresh with lifetime 0).

### 4.7 Keep-alives, idle and presence

| Item | Value | Why |
| --- | --- | --- |
| QUIC keep-alive, NATed UDP path | 15 s | Jio is reported to drop UDP mappings quickly ([forum report](https://community.infiniteflight.com/t/india-jio-network-atc-silence-on-expert-server-is-a-cgnat-udp-architecture-issue-not-a-device-bug/1275573), anecdotal). |
| QUIC keep-alive, LAN or VPN | 25 s | Today's LAN heartbeat is 10 s; QUIC needs less. |
| QUIC max idle timeout | 45 s | |
| Off-LAN session idle close | 5 min without application traffic | The session stays open while the app is in the foreground, a transfer runs or an agent request is pending. It reconnects on demand in about 1 to 2 s. |
| Presence connection to the control service | One WebSocket per device, keep-alive adaptive 60 to 270 s per network | Starts at 60 s, doubles after 3 clean intervals, halves after a drop. The server times out at 3 intervals. |
| Presence reconnect | Full jitter, 2 s base, 5 min cap | |

Presence runs only while the Bridgey service runs (the existing foreground service on Android) and
"Reach my devices away from home" is on. Target: presence costs at most 2% of a phone battery per
day on mobile data. This is a phase 2 exit check and has not been measured yet.

### 4.8 IPv6

IPv6 is the cheapest way past CGNAT in India:

- India is 69.88% native IPv6 ([Google, data as of 2026-10-23](https://www.google.com/intl/en/ipv6/statistics.html)).
- APNIC measures 93.2% of Reliance Jio users and 87.8% of Airtel mobile users preferring IPv6, and
  73.5% on Airtel broadband ([APNIC, read 2026-10-25](https://stats.labs.apnic.net/ipv6/IN)).

IPv6 is not open, though. Stateful firewalls still drop unsolicited inbound packets
([Tailscale](https://tailscale.com/blog/how-nat-traversal-works)), and JioFiber is reported to
block inbound IPv6 entirely
([forum](https://broadband.forum/threads/til-jiofiber-blocks-icmpv6-entirely.236569/), unverified).
So IPv6 host candidates are hole-punched like IPv4: both sides check at once.

For relays, `sin` and `sxb` have public IPv6. `bom` has none today: the check found only the
tailnet ULA on oracle. Cloudflare relays only IPv4
([FAQ](https://developers.cloudflare.com/realtime/turn/faq/)). An IPv6-only client therefore uses
`sin` or `sxb` when it needs an IPv6 relay.

### 4.9 Port mapping (phase 2 stretch)

On Wi-Fi the core can ask the router for a port mapping: PCP
([RFC 6887](https://www.rfc-editor.org/rfc/rfc6887)), then NAT-PMP, then UPnP IGD. A mapping
yields a port-mapped candidate that makes a hard home NAT reachable. This stays off until it has
been tested on Indian home routers.

## 5. Wire model and security

### 5.1 What travels in clear today

From [protocol.md](protocol.md) and the code (`PairingCoordinator.kt`):

| Exposed | Where |
| --- | --- |
| `kind`, `sessionId`, `messageId`, `transferId`, `sequence` | Every frame's routing header |
| `deviceId`, `deviceName`, ephemeral `publicKey`, long-term `identityKey`, `proof`, `signature` | `pairing.offer`, `pairing.answer`, `pairing.confirm` on every reconnect |
| Whole messages with no encrypted payload | `heartbeat.ping`/`pong`, `clipboard.ack`, `clipboard.rejected`, `files.accept`, `files.chunk.ack`, `files.complete.ack`, `files.cancel.ack`, `files.rejected`, `ping.ack`, `calls.rejected`, `pairing.cancel` |

On a home LAN this is today's accepted model. Through a relay or across the internet it would
reveal device names, a stable identity key that links a device across every network it uses, which
features are in use, and file sizes and timing.

### 5.2 Decision: encrypt everything on new routes with QUIC's TLS 1.3

Every frame on a new route travels inside QUIC, headers and acknowledgements included.

- **Not Noise.** Noise would be the minimal choice on top of a byte stream. But Bridgey needs
  QUIC anyway for reliable, congestion-controlled transfer over UDP and TURN, and QUIC requires
  TLS 1.3. A second handshake layer adds cost and no protection.
- **Not TLS over today's TCP.** There is no TCP path off the local network:
  - Cloudflare relays only UDP to the peer and does not implement TCP allocations
    ([RFC matrix](https://developers.cloudflare.com/realtime/turn/rfc-matrix/));
  - TCP hole punching through CGNAT is unreliable.
- **Minimal change.** The pairing crypto and stored identities do not change. One string in the
  signed transcript changes, and only on QUIC (section 5.3).

### 5.3 Tunnel handshake

1. **Certificate.** At process start each node makes an ephemeral Ed25519 TLS key and a
   self-signed certificate, renewed every 24 hours. `certSha256` is the SHA-256 of the DER
   certificate.
2. **Pin.** Signalling (sealed or in-band) carries each side's `certSha256`. A direct dial to a
   learned address has no pin and relies on step 5.
3. **QUIC handshake.** ALPN `bridgey/1`, TLS 1.3, certificates in both directions. If a pin is
   known, the presented certificate must match it; otherwise any well-formed certificate is
   accepted. The Web PKI is never used between devices.
4. **Session.** Stream 0, the first bidirectional stream, carries today's newline-JSON session
   with its 65,536-byte frame limit. The QUIC client sends `pairing.offer`.
5. **Channel binding.** Both identity keys sign this transcript instead of today's
   `bridgey-auth-v1` one (NUL-separated, as today):

   ```text
   "bridgey-auth-v2" \0 sessionId \0 initiatorDeviceId \0 responderDeviceId
     \0 initiatorEphemeralKey \0 responderEphemeralKey \0 base64(exporter) [\0 base64(inviteHash)]
   exporter = TLS-Exporter("EXPORTER-bridgey-tunnel-v1", "", 32)
   ```

   - The exporter is defined in [RFC 8446 section 7.5](https://www.rfc-editor.org/rfc/rfc8446#section-7.5);
     the binding works like [RFC 9266](https://www.rfc-editor.org/rfc/rfc9266). quinn exposes it
     as `Connection::export_keying_material`.
   - `inviteHash` appears only in remote pairing (section 6.6).
   - A man in the middle who terminates QUIC on both sides has two different exporters, so the
     signatures fail.
6. **Checks.** Verification is as today: pinned identity, HMAC confirmation proof, signature over
   the transcript. The session key, the verification code and AES-GCM payloads do not change.
7. **Bulk bytes.** Transfer data streams (section 8) rely on QUIC encryption alone, which steps 2
   to 5 authenticate end to end. Control messages keep their AES-GCM payloads, so plugin code
   paths stay untouched.

### 5.4 What each party sees

| Party | Sees | Never sees |
| --- | --- | --- |
| Relay (coturn or Cloudflare) | Both devices' public IP and port, timing and volume, a TURN username (`expiry:sid8.side`), QUIC packets (random connection IDs, encrypted packet numbers) | Names, device IDs, identity keys, plaintext, file names |
| Control service | Each node's public key and IP while connected; the rendezvous IDs a node registers, and so which node keys share a pair while online; size and timing of sealed signalling; relay grants; optionally a coarse NAT class | Device names, device IDs, identity keys, candidate lists, certificate pins, any content |
| Network observer on a relayed or direct path | Same as the relay | Same as the relay |
| Peer device | Everything it is granted, as today | |

### 5.5 Keys and secrets

| Item | Kind | Stored | Created | Used for |
| --- | --- | --- | --- | --- |
| Identity key (existing) | P-256 ECDSA | Android Keystore, macOS Keychain, CLI file `0600` | Install | Pairing, session authentication |
| Session key (existing) | Ephemeral P-256 ECDH, HKDF | Memory | Each session | AES-GCM payloads |
| TLS key | Ed25519 | Memory | Process start, 24 h | QUIC |
| Node key (new) | P-256 ECDSA | Keystore, Keychain, CLI file | First use of Connect anywhere | Control service authentication and rate limits. It is separate from the identity key so the service cannot link it to pairings. |
| Pair secret (new) | 32 bytes | Inside the trust record (Keystore-wrapped on Android, Keychain on macOS, CLI file) | `connect.setup` after pairing | Rendezvous IDs, signalling key, network tags |
| Invite secret (new) | 32 bytes | QR code or link only | Remote pairing | One-time rendezvous and transcript binding |
| TURN credentials | Username and password | Memory | Each relay grant, 2 h | Relay authentication |

Derivations (`‖` is concatenation, `\0` a zero byte):

```text
pairSecret = HKDF-SHA256(ikm = cLow ‖ cHigh, salt = "bridgey-pair-secret-v1",
                         info = idLow \0 idHigh, L = 32)
             cLow, cHigh: 32-byte contributions from the lower and higher device ID
             (lexicographic order, as in today's dialer rule)
sigKey     = HKDF-SHA256(ikm = pairSecret, salt = "", info = "bridgey-signal-v1", L = 32)
rdvId(d)   = base64url(HMAC-SHA256(pairSecret, "bridgey-rdv-v1" ‖ d)[0..16]), d = UTC date "YYYY-MM-DD"
side       = 0 for the lower device ID, 1 for the higher
```

Devices register today's and yesterday's rendezvous IDs, and from 23:00 UTC tomorrow's too.

### 5.6 Threats and mitigations

| Threat | Mitigation |
| --- | --- |
| A relay or the control service reads data | QUIC end to end, plus the inner AES-GCM; neither party ever holds keys |
| The operator links devices over time | Rendezvous IDs rotate daily and are derived per pair; node keys are unrelated to identity keys; no names. The service still sees IP addresses and which node keys share a pair while online (accepted and documented) |
| Man in the middle on a relayed path | Certificate pins from sealed signalling plus channel-bound identity signatures |
| Replayed signalling | Each sealed body carries `ts` (rejected if more than 5 min off) and a per-session `seq`; session IDs are random 128-bit values |
| A compromised or forgotten peer | "Forget device" deletes the pair secret, so its rendezvous IDs are no longer registered |
| Free relays abused by third parties (the app is open source) | Node keys, optional proof of work, per-node and per-session caps; pool hard caps mean cost cannot run away (section 9.6) |
| TURN used to reach internal networks | coturn `denied-peer-ip` for private, carrier-NAT, tailnet and Docker ranges; `no-tcp-relay`; `no-multicast-peers` |
| The UDP listener (42458) | Nothing reaches a plugin before the inner handshake; QUIC Retry (address validation) under load; per-source rate limits; fuzzing of STUN and QUIC input |
| Control service flooded | Per-IP and per-node limits, proof of work on demand, connection caps |
| Downgrade to unencrypted TCP | Edition peers never use TCP off the local network; TCP stays as today's LAN fallback |

### 5.7 Revocation and reset

"Forget device" also deletes:

- the pair secret;
- learned addresses;
- network check results tied to that peer;
- transfer state with that peer.

A new Settings action, "Reset away-from-home identity", creates a new node key and re-runs
`connect.setup` (with `rotate: true`) with every peer. Resetting the local identity still
invalidates all pairings, as today.

## 6. Rendezvous and signalling

### 6.1 The control service

`bridgey-rendezvous` is one small Rust service (axum, tokio, SQLite).

What it does:

- presence: which side of which pair is online;
- forwards sealed signalling;
- authenticates nodes;
- issues relay credentials and applies the pool policy;
- collects relay usage;
- serves the ops dashboard and sends alerts.

It never carries file or session data.

### 6.2 Node authentication

The connection is a WebSocket at `wss://connect.roundrobin.in/v1/ws`. Frames are JSON text, at
most 16 KiB each; `t` is the message type.

```text
C: {"t":"hello","v":1,"node":"<base64url P-256 SEC1 public key>","app":"bridgey-rr/0.7.0 android","keepalive":120}
S: {"t":"challenge","nonce":"<base64url 32 bytes>","pow":0}
C: {"t":"auth","sig":"<base64url DER ECDSA-P256-SHA256 over 'bridgey-rdv-auth-v1\0' ‖ nonce ‖ node>","pow":"<solution or omitted>"}
S: {"t":"welcome","nodeId":"<base64url SHA-256(node)[0..16]>","now":1761400000000,
    "limits":{"maxIds":64,"maxSignalBytes":6144,"signalsPerMinute":120}}
```

Proof of work is off (`pow: 0`) until abuse appears. When it is on, the client finds a
`solution` such that `SHA-256("bridgey-pow-v1" ‖ nonce ‖ node ‖ solution)` starts with `pow`
zero bits:

| Bits | Cost on a phone | When |
| --- | --- | --- |
| 16 | Under 50 ms | First sight of a node, once new nodes exceed 100 an hour |
| 20 | About 1 s | Under attack |

These phone timings are estimates.

### 6.3 Control messages

| Message | Direction | Fields | Limits |
| --- | --- | --- | --- |
| `register` | C to S | `ids` (rendezvous IDs, replaces the previous set) | 64 IDs per node; 3 sockets per node |
| `registered` | S to C | `online`: IDs whose other side is connected | |
| `presence` | S to C | `rdv`, `online` | Debounced 2 s |
| `signal` | C to S to C | `to`/`rdv`, `side`, `sid` (base64url 16 bytes), `body` (sealed) | Body 6 KiB; 120 a minute per node |
| `undeliverable` | S to C | `rdv`, `sid` | The other side is offline |
| `relay.request` | C to S | `rdv`, `sid`, `side`, `rtts` (ms per relay, for example `{"bom":31,"sin":72,"sxb":139,"cf":22}`), `need` (`udp` or `tls443`), optional `estBytes`, `exclude` | 30 grants an hour per node |
| `relay.claim` | C to S | `rdv`, `sid`, `side` | The other side picks up its grant; it must come from a socket registered for `rdv` |
| `relay.grant` | S to C | `sid`, `relay` (see below) | |
| `relay.denied` | S to C | `sid`, `code` (`pool_exhausted`, `node_capped`, `rate_limited`), `retryAfterMs` | |
| `relay.release` | C to S | `sid` | Optional; tidies accounting |
| `error` | S to C | `code` (`bad_request`, `unauthenticated`, `pow_required`, `rate_limited`, `too_many_ids`, `server_busy`), `retryAfterMs` | |

The service picks one relay per session for both sides, so a relay-to-relay path stays inside one
server (section 9.3). The requesting side gets its grant at once. The other side gets its own only
by `relay.claim` from its own authenticated socket.

```json
{"t":"relay.grant","sid":"q7Lw0d3xV2c9kP1sR8uT4w","relay":{
  "id":"bom","kind":"coturn",
  "urls":["turn:turn-in.roundrobin.in:3478?transport=udp",
          "turn:turn-in.roundrobin.in:3478?transport=tcp",
          "turns:turn-in.roundrobin.in:5349?transport=tcp"],
  "username":"1761407200:q7Lw0d3x.0","credential":"<base64 HMAC-SHA1>",
  "spki":"<base64 SHA-256 of the relay's TLS public key>",
  "expiresAt":1761407200000,"maxKbps":50000}}
```

A Cloudflare grant has `"kind":"cloudflare"`, the URLs, username and credential returned by
Cloudflare, `maxKbps` 40,000 and no `spki`: `turn.cloudflare.com` uses the Web PKI. Clients
re-request at 75% of the grant lifetime and move to the new allocation before the old one ends
(make before break).

### 6.4 Sealed peer signalling

```text
body = base64url( 0x01 ‖ nonce(12) ‖ AES-256-GCM(sigKey, nonce, plaintext, aad) )
aad  = "bridgey-signal-v1" \0 rdvId \0 side \0 sid
```

The plaintext is JSON of at most 4 KiB. Receivers drop bodies whose `ts` is more than 5 minutes
off, or whose `seq` is not above the last one seen for that `sid` and `side`.

| Type | Fields |
| --- | --- |
| `offer` | `sid`, `v` (1), `ufrag` (8 chars), `pwd` (24 chars), `cands`, `cert` (`certSha256`), `rtts`, `net` (`nat`, `v6`), `ts`, `seq` |
| `answer` | Same as `offer` |
| `cand` | `sid`, `cands`, `done` (end of candidates), `ts`, `seq` |
| `restart` | `sid`, `ufrag`, `pwd`, `reason` (`network_change`, `path_failed`, `relay_switch`), `ts`, `seq` |
| `bye` | `sid`, `reason`, `ts`, `seq` |

Each candidate is `{"k":"host|prflx|srflx|mapped|relay","a":"<ip>","p":<port>,"net":"lan|vpn|public6|cell|wifi","pri":<u32>,"relay":"bom"}`.
The same messages travel in-band, inside the encrypted session, as `connect.offer`,
`connect.answer`, `connect.candidates`, `connect.restart` and `connect.bye`.

### 6.5 The ICE-like algorithm

1. **Gather.**
   - Host candidates from every up interface except the excluded ones.
   - Server-reflexive candidates from the same UDP socket, by STUN binding to two servers. The
     same mapped port from both means an easy NAT; different ports mean a hard one. That result
     feeds the network check (section 12.2).
   - Relay candidates only as in section 4.3.
2. **Exchange.** `offer`/`answer` with fresh `ufrag` and `pwd` and the certificate pin, sealed
   through the control service or in-band. Late candidates trickle
   ([RFC 8838](https://www.rfc-editor.org/rfc/rfc8838)).
3. **Pair.** Every local candidate with every remote one of the same IP family. Duplicates are
   pruned, and each pair gets a priority (section 4.2).
4. **Check.** STUN binding checks with short-term credentials, one every 25 ms in priority order.
   An incoming check triggers one back. Each check is retried up to 6 times, starting at 250 ms
   and doubling. The controlling side is the lower device ID (RFC 8445 tie-breaker otherwise).
5. **Nominate.** "First that answers wins", with a 300 ms preference window. Relay pairs compete
   only after the 1,000 ms relay grace.
6. **Connect.** The QUIC handshake runs over the nominated pair, then the inner Bridgey handshake
   on stream 0.
7. **Keep improving.** Checks on higher pairs continue for 10 s after nomination. A success
   migrates QUIC immediately, without waiting for the minute tick.
8. **Keep alive.** QUIC PING keeps the path warm (section 4.7). Liveness is QUIC
   acknowledgements; Bridgey does not use WebRTC consent checks every 5 s.
9. **Restart.** Network change, path failure or relay switch: new `ufrag`/`pwd`, re-gather, check,
   then migrate QUIC.

Tailscale-style "birthday" probing of hard NATs is not planned. It costs battery and needs about
256 to 1,024 probes for a 64% to 98% chance with one hard side
([Tailscale](https://tailscale.com/blog/how-nat-traversal-works)). The relay covers that case.

### 6.6 Remote pairing (QR code or link)

Pairing today needs Bonjour on the same network. A server CLI is never on Rahul's Wi-Fi, so
remote pairing is required for phase 1.

1. **Invite.** The inviter (`bridgey pair` or the app) makes
   `{v:1, rdv: random 16 bytes, secret: random 32 bytes, svc: "<control URL>", name, exp: now + 10 min}`.
   It shows the invite as a QR code and as `bridgey://pair#<base64url>`. The invite sits in the
   URL fragment, so a link never reaches a web server.
2. **Rendezvous.** Both sides register `HMAC-SHA256(secret, "bridgey-invite-rdv-v1")[0..16]`. They
   seal signalling with `HKDF-SHA256(secret, "", "bridgey-invite-signal-v1")`.
3. **Tunnel.** They bring up the QUIC tunnel over any route, the relay included.
4. **Pair.** The existing pairing runs inside the tunnel:
   - the transcript carries `inviteHash = SHA-256(secret)`;
   - both screens show the six-digit code;
   - both people confirm. The CLI asks in the terminal, and there is no non-interactive mode,
     because the UI "must not offer a one-sided or automatic confirmation path" (`SECURITY.md`).
5. **After pairing.** `connect.setup` creates the pair secret. The invite is single use and dies
   after 10 minutes. The phone opens the new device's permissions with everything off.

### 6.7 Where it runs, how it deploys, what it stores

| Item | Plan |
| --- | --- |
| Production | Round Robin Dokploy on `rr-web`, project "Bridgey", app `bridgey-rendezvous`, image `ghcr.io/round-robin-solutions/bridgey-rendezvous` built on rr-dev-1 (the one path). The build stage runs natively and cross-compiles: `FROM --platform=$BUILDPLATFORM`, target `aarch64-unknown-linux-musl`. Emulating a Rust build would be very slow, like the Bliss case. 1 replica, 256 MiB, 0.5 CPU, swarm health check `/health/ready`, start-first updates (clients reconnect with jitter). |
| Why `rr-web` | It is a different failure domain from the relays, it is the standard production path (the same shape as the Forms relay), and signalling traffic is tiny. Alternative: oracle's personal Dokploy, if Bridgey should stay off production (open question). |
| Hostname | `connect.roundrobin.in`, a DNS-only A record (unproxied). Third-party reports say Cloudflare's proxy closes idle WebSockets after about 100 s on free plans ([example](https://websocket.org/guides/infrastructure/cloudflare/)), which would force 45 s phone keep-alives. Host nginx vhost with WebSocket upgrade, `proxy_read_timeout 900s` and 64 KiB bodies; certbot webroot certificate. |
| Ops hostname | `bridgey-ops.roundrobin.in`, proxied, behind Cloudflare Access (section 11). |
| Storage | SQLite in volume `bridgey-rendezvous-data`. Schema changes are additive, with `MIGRATE_ON_START=1`, the same deliberate rule-5 exception as the Forms relay and Social. |
| Kept in memory only | Presence (which socket holds which rendezvous ID), client IP addresses, pending sessions, rate-limit counters |
| Kept in SQLite | Nodes (key hash, first and last seen, flags `trusted`/`banned`, counters); relays (config snapshot, health, usage per cycle); usage samples; session rows (sid hash, start, end, relay, bytes, node hashes, outcome); alert state and history. Never device names, rendezvous IDs, IP addresses (except temporary prefix bans with an expiry) or sealed bodies. |
| Retention | 5-minute samples for 35 days, hourly for 13 months, daily kept. Session rows 30 days, then folded into daily totals. Alert history 90 days. Nodes unseen for 180 days are deleted. Logs 14 days, with no IP addresses at info level. |
| Backups | A nightly `VACUUM INTO` snapshot in the app plus a Dokploy volume backup to `rr-dokploy-backups`, keep 14 (the Forms relay pattern). Everything can be rebuilt; relay agents keep their own cycle counters too. |
| Health | `/health` (static), `/health/ready` (SQLite writable, config loaded), `/v1/status` (relay health, for the dashboard) |
| Settings | One file, `bridgey-rendezvous.toml`: relays, caps, cycles, penalties, limits, alert thresholds. Only secrets come from the environment: TURN secrets per relay, relay agent tokens, Cloudflare TURN key ID and API token, Telegram token and chat, the Access audience tag. Vault note `Keychain/Bridgey Connect`. |
| Staging | oracle personal Dokploy at `connect.rbansal.xyz`, with a staging coturn on oracle (ports 3480/udp and tcp, relay range 59000 to 59499) capped at 10 GB a month. Nightly builds may point at staging. |

### 6.8 When the control service is down

LAN and private-network routes keep working, because direct dials need no control service.
Relayed sessions continue until their grant expires (at most 2 hours). New sessions away from the
local network fail with "Can't reach the device away from home right now". Devices retry presence
with backoff. An external check alerts within 3 minutes (section 11.4).

## 7. Stack choice

### 7.1 Requirements

1. Standard TURN for coturn and Cloudflare: UDP relaying to the peer, TCP or TLS on 443 from the
   client, IPv4-only relays at Cloudflare.
2. Hole punching, IPv6 included.
3. A reliable, encrypted, multi-stream transport with congestion and flow control for
   multi-gigabyte files.
4. Path changes without dropping the session.
5. One implementation for Android, macOS and Linux servers, later Windows.
6. Rust, so it becomes the v2 core.
7. A small binary.

### 7.2 Options

| Option | NAT traversal and TURN | Data transport | Platforms and size | Verdict |
| --- | --- | --- | --- | --- |
| WebRTC data channels, native libwebrtc | Mature, TURN over TLS included | SCTP over DTLS. RFC 8831 says senders "SHOULD limit the maximum message size to 16 KB"; dcSCTP defaults are a 256 KiB message and 1,191-byte packets ([dcSCTP options](https://webrtc.googlesource.com/src/+/refs/heads/main/net/dcsctp/public/dcsctp_options.h)) | Google stopped prebuilt Android and iOS libraries in 2020 ([announcement](https://groups.google.com/g/discuss-webrtc/c/Ozvbd0p7Q1Y/m/M4WN2cRKCwAJ)); community AARs are 11.5 to 12.3 MB per arm64 ABI; the CLI would need another stack | Two stacks, heavy, and SCTP is not built for multi-gigabyte files |
| webrtc-rs `webrtc`/`rtc` 0.21 (Rust) | Sans-IO `rtc-ice` and `rtc-turn`. The async wrapper skips `turns:` and TCP TURN URLs ([source](https://github.com/webrtc-rs/webrtc/blob/v0.21.1/src/peer_connection/transport/turn_relayer.rs)) | SCTP. A 13 Mbit/s throughput issue ([#101](https://github.com/webrtc-rs/webrtc/issues/101)) was closed in 2026 after fixes | Rust everywhere | Pre-1.0 API churn, and no TURN over TLS in the wrapper today, which hotel Wi-Fi needs |
| str0m 0.24 (Rust, sans-IO) | Its ICE agent is standalone as [`is`](https://docs.rs/is) 0.11. It has no TURN client: the application supplies relay candidates | SCTP data channels, 128 KiB default send buffer | Rust | Good ICE, but the data channel layer is built for media servers |
| libdatachannel and libjuice (C, C++) | libjuice relays only over UDP; TCP and TLS TURN need libnice ([DOC.md](https://github.com/paullouisageneau/libdatachannel/blob/master/DOC.md)) | usrsctp | C and C++ build per platform; Rust bindings lag (datachannel-sys 0.23 vs libdatachannel 0.24.6) | Native build pain, not a Rust core |
| iroh 1.4 (Rust, QUIC via noq) | Own hole punching; its relay is a DERP-derived HTTPS relay, self-hostable, not TURN ([iroh-relay](https://github.com/n0-computer/iroh/blob/main/iroh-relay/src/lib.rs)) | QUIC multipath | Rust; Kotlin through uniffi, built from source | The most complete package, but it cannot use coturn or Cloudflare TURN (Rahul's pool), and its identities are Ed25519 while Android Keystore keys are P-256 |
| Keep the custom protocol over a byte stream through our own TCP or WebSocket relay | None: TCP hole punching is unreliable | TCP | Any | Every byte off the local network is relayed, and Cloudflare TURN is unusable (UDP only to peers, no RFC 6062) |
| **Recommended:** sans-IO ICE ([`rice-proto`](https://github.com/ystreet/librice) 0.4 with [`turn-client-proto`](https://docs.rs/turn-client-proto) 0.7) plus QUIC ([`quinn`](https://github.com/quinn-rs/quinn) 0.11) carrying the existing Bridgey frames | Standard TURN over UDP, TCP and TLS (rustls) | QUIC streams, Cubic congestion control, flow control, migration | One Rust core: UniFFI on Android and macOS, native in the CLI | Recommended |

Go's pion is the most mature stack outside browsers for ICE, TURN, DTLS and SCTP, but it would
split the v2 core across two languages.

### 7.3 Recommendation and why

**Recommendation: one Rust core with a sans-IO ICE agent plus TURN client (`rice-proto` and
`turn-client-proto`), QUIC from `quinn` 0.11, rustls with the ring provider, and the existing
Bridgey session on QUIC stream 0.**

- **The relays Rahul chose.** It is the only option that uses coturn and Cloudflare TURN as
  decided, with TURN over TLS on 443 for hotel Wi-Fi.
- **Built for big files.** QUIC gives congestion control, per-stream flow control (backpressure),
  parallel streams without head-of-line blocking across files, encryption of every header, and
  connection migration for upgrades. That fits multi-gigabyte transfers, which data channels do not.
- **Minimal change.** The Bridgey protocol is untouched: frames and plugins stay; only the
  transcript string and the transport change.
- **One code base.** Android, macOS, the CLI and later Windows and Linux share it. It is the seed
  of the v2 core.
- **Easy to swap.** Sans-IO parts (no sockets or clocks inside) are easy to test with virtual
  networks and to replace. The fallback, if `rice-proto` fails the spike, is str0m's `is` agent
  plus `turn-client-proto`; the I/O layer stays the same.

Pins and spike exit criteria (phase 0):

- **Versions:** `quinn` 0.11.x. 0.12 changes the `AsyncUdpSocket` API, so the core wraps it.
  Also `rice-proto` 0.4.x, `turn-client-proto` 0.7.x, rustls 0.23.x with ring.
- **Connectivity:** QUIC over ICE over coturn and Cloudflare TURN (UDP and TLS on 443) between an
  arm64 Android phone and a Linux server.
- **Behaviour:** an ICE restart migrates QUIC without losing streams, and a 15-minute soak at
  50 Mbit/s holds.
- **Size:** the `.so` stays under 6 MB per ABI. The size is unmeasured; this is the budget.

### 7.4 How the pieces fit

- **One UDP socket per node.** Port 42458 on the apps (any free port if taken); the CLI uses an
  ephemeral port unless configured. STUN, TURN and QUIC share it, demultiplexed by the first byte
  ([RFC 9443](https://www.rfc-editor.org/rfc/rfc9443)):
  - 0 to 3 is STUN;
  - 64 to 79 is TURN ChannelData when it comes from the TURN server;
  - anything else is QUIC.

  This needs quinn's `grease_quic_bit` off: RFC 9443 says such endpoints "MUST NOT send the
  grease_quic_bit transport parameter", and quinn 0.11 turns it on by default.
- **Virtual addresses.** The core shows quinn one virtual address per ICE pair, through
  `new_with_abstract_socket` and `rebind_abstract`, so a switch of pair is a normal QUIC client
  migration with path validation and fresh congestion and MTU state. quinn servers accept client
  migration by default; the controlling side is the QUIC client, so it starts every migration.
- **Relay MTU.** Relay paths carry UDP payloads of at most 1,280 bytes (TURN ChannelData adds 4
  bytes). Direct paths use path MTU discovery from 1,200 up to 1,452. Black-hole detection is
  checked in the spike.

| quinn setting | Value |
| --- | --- |
| ALPN | `bridgey/1` |
| `keep_alive_interval` | 15 s on NATed paths, 25 s on LAN and VPN |
| `max_idle_timeout` | 45 s |
| `stream_receive_window` | 4 MiB |
| `receive_window`, `send_window` | 16 MiB each (covers 400 Mbit/s at 300 ms) |
| `max_concurrent_uni_streams` | 16 |
| Congestion controller | Cubic (the default; quinn's BBR is marked experimental) |
| `initial_mtu` | 1,200 |
| Migration | Server side on (default); client initiates |

### 7.5 Platform integration

| Platform | How |
| --- | --- |
| Android | `libbridgey_core.so` built with cargo-ndk for arm64-v8a (x86_64 only in debug builds, for the emulator). UniFFI Kotlin bindings; async functions become `suspend`. Callbacks: a Keystore signer (identity and node keys never leave the Keystore) and a storage adapter for MediaStore and Storage Access Framework. Runs inside the existing connection service process. |
| macOS | Static library in an xcframework (arm64 and x86_64), UniFFI Swift bindings, Keychain signer, `NWPathMonitor` feeding network changes. |
| CLI | The same crates, statically linked (musl on Linux). |
| Crypto | ring for P-256 ECDH and ECDSA (DER signatures, matching Android `SHA256withECDSA` and CryptoKit), HKDF, HMAC, AES-256-GCM and SHA-256; rustls on the ring provider. The Rust tests reuse `protocol/test-vectors/crypto-v1.properties`, so all three implementations agree byte for byte. |
| CI | The RR CI `bridgey` project gains a `rust` task (`cargo test`, `cargo clippy -D warnings`) on the GitHub-hosted Linux lane. The `android` task adds the Rust toolchain and cargo-ndk; the `macos` task builds the xcframework. |

## 8. Large-file transfer (`transfer.v1`)

Version 1 of files (`files.v1`) stays for upstream peers. It is sequential, base64 inside JSON,
24 KiB chunks, no resume, 10 GiB maximum. `transfer.v1` is used when both peers advertise it.

### 8.1 Targets

| Path | Target |
| --- | --- |
| Same Wi-Fi (5 GHz), phone and Mac | At least 30 MB/s sustained; aim 60 MB/s |
| Direct over the internet | At least 90% of the slower of sender upload and receiver download, at up to 300 ms round trip and 1% loss |
| Own relay | Per-session cap 50 Mbit/s by default (6.25 MB/s), delivering at least 90% of the cap when the links allow |
| Cloudflare relay | At most 40 Mbit/s per session. Cloudflare documents drops above "50-100 Mbps" per allocation ([TURN overview](https://developers.cloudflare.com/realtime/turn/)) |
| Resume | Restarts within 3 s of reconnecting; re-sends at most 1 chunk per stream |
| Memory | At most 32 MiB of buffers per transfer on the phone |
| Size | Files up to 1 TiB; up to 100,000 entries per transfer |

### 8.2 Model

- **Chunks.** Files split into 1 MiB chunks (2^20 bytes); the last one is shorter.
  `H_i = SHA-256(chunk_i)`. ARMv8 has SHA-256 instructions, so hashing is not the bottleneck.
- **File root.**
  `root = SHA-256("bridgey-transfer-v1\0" ‖ u64be(size) ‖ u32be(chunkSize) ‖ H_0 ‖ ... ‖ H_{n-1})`.
  The receiver checks each chunk as it lands and keeps its hash. At the end it computes the root
  from stored hashes, with no second pass over the file.
- **Content addressing.** Chunks are addressed by their hashes. That is what a future
  store-and-forward needs: chunks become objects keyed by `H_i` (section 8.11).
- **Sender state.** For each outgoing transfer the sender keeps the source identity (URI or path,
  size, modification time) and the chunk hashes it has sent, so it never re-hashes on resume.

### 8.3 Control messages

These are encrypted session messages: `kind`, `sessionId`, `messageId` and AES-GCM `nonce` and
`ciphertext`, as today. The payload fields are:

| Message | Direction | Payload |
| --- | --- | --- |
| `xfer.offer` | Sender to receiver | `version` 1, `transferId` (UUIDv7), `kind` (`files` or `folder`), `rootName` (folder), `itemCount`, `totalBytes`, `chunkSize` 1048576, `pages`, first manifest page |
| `xfer.manifest` | Sender to receiver | `transferId`, `page`, `items` (up to 1,000): `i`, `path`, `size`, `mtime`, `mime`, `dir` |
| `xfer.accept` | Receiver to sender | `transferId`, `streams` (1 to 8), `destination` and `conflict` (defined by the folders spec, section 8.8) |
| `xfer.reject` | Receiver to sender | `transferId`, `reason` (`disabled`, `not_granted`, `too_large`, `no_space`, `declined`) |
| `xfer.have` | Receiver to sender | `transferId`, `files`: `[{i, ranges: [[from, to], ...]}]`, durable chunks only. Sent every 64 chunks or 1 s, and on resume. |
| `xfer.file.done` | Sender to receiver | `transferId`, `i`, `root` |
| `xfer.file.ok` | Receiver to sender | `transferId`, `i`, after verification and the atomic rename |
| `xfer.file.bad` | Receiver to sender | `transferId`, `i`, `chunks` to send again |
| `xfer.resume` | Sender to receiver | `transferId`, after any reconnect. The receiver answers `xfer.have`, or `xfer.unknown` if its partials are gone. |
| `xfer.changed` | Sender to receiver | `transferId`, `i`, `size`, `mtime`: the source changed, so that file starts again from zero |
| `xfer.pause`, `xfer.cancel` | Either way | `transferId`; both idempotent |
| `xfer.done`, `xfer.done.ack` | Sender, then receiver | `transferId` |

Paths in `xfer.manifest`:

- relative only, `/` separated, NFC-normalised;
- no empty, `.` or `..` components;
- no control characters, no backslashes;
- at most 255 bytes per component, 4,096 per path and 32 levels deep.

The receiver applies its own name rules on top: never overwrite, collision-safe names, as today.

### 8.4 Data streams

Data goes over QUIC unidirectional streams from sender to receiver, encrypted by QUIC (section 5.3).

```text
stream header (24 bytes): "BXT1" | transferId (16, UUID bytes) | streamNo (u16 BE) | flags (u16 BE, 0)
record (45-byte header):  type (u8, 1 = chunk) | fileIndex (u32 BE) | chunkIndex (u32 BE)
                          | length (u32 BE, at most chunkSize) | sha256 (32) | payload (length bytes)
```

If a record's hash does not match its payload, the receiver stops that stream (`STOP_SENDING`, code
`0x10 bad_chunk`) and lists the chunk in `xfer.file.bad`. Small files share one stream back to
back, so a folder of 10,000 photos does not open 10,000 streams.

### 8.5 Parallel streams and backpressure

- **Streams.** 4 by default, 8 on LAN; the receiver picks the number in `xfer.accept`. Chunks are
  handed out from one shared queue, so a fast stream takes more.
- **Why parallel.** Disk reads, hashing and writes overlap across cores. All streams share one
  QUIC congestion controller, so this never takes an unfair share of the network.
- **Backpressure** works end to end with no extra messages:
  - the sender reads at most 2 chunks ahead per stream;
  - the receiver queues at most 4 chunks per stream for writing, and reads from QUIC only while
    there is room in that queue;
  - QUIC flow control (4 MiB per stream, 16 MiB per connection) then slows the sender.
- **Memory.** At most 4 streams × (2 + 4) chunks × 1 MiB = 24 MiB per transfer on the phone,
  under the 32 MiB target.

### 8.6 Resume

The receiver writes chunks in place at their offsets. The rule is "data first, state second":

1. Every 64 chunks or 1 s, the receiver flushes the data file (`fsync`).
2. Then it writes a state file: a bitmap of verified chunks and their hashes. For a 50 GB file
   that is 51,200 × 32 bytes, about 1.6 MB.
3. Only then does it send `xfer.have`.

After a crash, the bitmap never claims more than is on disk.

- **Reconnect.** The sender sends `xfer.resume`; the receiver answers `xfer.have`; the sender
  skips what is acknowledged. The sender spot-checks: it re-hashes the last acknowledged chunk and
  compares it with its stored hash.
- **App restart.** Transfers are persistent on both sides and resume automatically on the next
  session with that peer, on any route.
- **Source changed.** If size or modification time differ from the offer, the sender sends
  `xfer.changed` and starts that file again from zero. The root check catches everything else.
- **Partials** are kept for 7 days, or until the transfer is cancelled. They may use at most 20%
  of free space; above that, the oldest are dropped first.

### 8.7 Storage per platform

| Platform | Partial file | Final step |
| --- | --- | --- |
| Android, `Download/Bridgey` | MediaStore entry with `IS_PENDING=1`, opened `"rw"`, random-access writes | Clear `IS_PENDING` after the root check |
| Android, granted folder (folders spec) | Storage Access Framework document named `<name>.bridgey-part`, opened `"rw"` | Rename. If the provider cannot do random access in `"rw"`, fall back to one in-order stream. |
| macOS | `<name>.bridgey-part` beside the target (as today) | Atomic rename |
| CLI | `<name>.bridgey-part` in the inbox | Atomic rename |

State files live in app-private, no-backup storage.

### 8.8 Folders

The folders spec (`docs/folders-and-settings-sync.md`, branch `rr/folders-spec`) had not been
written when this spec was. This section follows the decisions recorded in `plan.md`:

- **Where it lands.** Three destination modes. The default is "choose on the Mac while sending"
  among the phone's granted folders; the others are "phone asks each time" and "fixed default
  folder".
- **Existing folder.** Bridgey asks each time: Merge keeping both, Replace files, or Save as new
  folder.
- **No broad storage permission.** Only folders granted once through Android's folder picker.

`transfer.v1` carries the folder structure (`path` and `dir` entries, empty folders included) and
the bytes. The folders spec owns `destination` and `conflict` in `xfer.accept` and any messages
for browsing granted folders. If it defines its own manifest, this spec adopts it; the fields in
section 8.3 are the minimum needed.

### 8.9 Android background

- **Foreground service.** Transfers run inside the existing connection service. It is a
  foreground service of type `connectedDevice` (`AndroidManifest.xml`), and
  `CHANGE_WIFI_MULTICAST_STATE` already meets that type's runtime prerequisite
  ([service types](https://developer.android.com/develop/background-work/services/fgs/service-types)).
  `connectedDevice` has no daily time limit.
- **No `dataSync`.** On Android 15 and later it is limited to "a total of 6 hours in a 24-hour
  period" ([timeout](https://developer.android.com/develop/background-work/services/fgs/timeout)),
  which a 50 GB transfer on mobile data could exceed.
- **When the service is off** (the user chose "Turn off Bridgey" and then shares a file):
  - Android 14 and later: a user-initiated data transfer job, `setUserInitiated(true)`,
    `RUN_USER_INITIATED_JOBS`, `setEstimatedNetworkBytes`, and a progress notification through
    `setNotification`
    ([UIDT](https://developer.android.com/develop/background-work/background-tasks/uidt)). It must
    be scheduled while the app is visible, which a share action is. Google recommends it over
    `dataSync` for user-requested transfers.
  - Android 8 to 13: start the connection service for the transfer.
- **Doze.** It suspends network access for normal apps
  ([Doze](https://developer.android.com/training/monitoring-device-state/doze-standby)). Processes
  in the foreground-service state keep network access in Doze
  (`NetworkPolicyManager.isProcStateAllowedWhileIdleOrPowerSaveMode` in AOSP; not stated in the
  developer docs). Low Power Standby, on some Android 14+ devices, allows only top apps, so
  screen-off transfers can stall there. This must be tested.
- **Locks.** A partial wake lock is held only while bytes flow and released after 30 s idle. On
  LAN a `WifiLock` in low-latency mode keeps throughput up. Both need `WAKE_LOCK`, a new manifest
  permission.
- **Network changes** come from `registerDefaultNetworkCallback` (section 4.6). Transfers stay on
  the default network; there is no binding to mobile data while on Wi-Fi.
- **OEM battery managers** (OnePlus OxygenOS among them) may still kill the service. A killed
  transfer resumes on restart (section 8.6). It is tested on the OnePlus 11.

### 8.10 macOS background

The Mac app holds `ProcessInfo.beginActivity(options: .userInitiated)` during transfers, so App
Nap does not throttle them. Sleep ends the session and wake resumes it: the network change starts
an ICE restart, and the transfer resumes.

### 8.11 Later: store-and-forward and the gallery

**Store-and-forward** ("deliver later when the device comes online") is out of scope. It is a
possible future paid feature (Rahul: "if we ever decide to charge users"). R2 would cost USD 0.015
per GB-month after 10 GB, with free egress and Class A writes at USD 4.50 per million
([R2 pricing](https://developers.cloudflare.com/r2/pricing/)). The design stays compatible:

- chunks are content-addressed;
- the root hash authenticates a whole file;
- `connect.setup` can later add a static key agreement key so a sender can encrypt to an offline
  device.

**The gallery manager** moved to v2 and needs its own performance research. What it will need
from this layer:

- a content-addressed thumbnail cache (thumbnails keyed by source hash and size);
- prefetch of the next screen;
- small request and response messages on their own QUIC streams, so a thumbnail never queues
  behind a bulk chunk;
- a preference for the lowest-latency route.

## 9. Relay pool

### 9.1 Members

| Relay | Host | Provider and plan | Location | Provider allowance | Measured baseline (read-only, 2026-10-25) | Bridgey caps per cycle | Rate caps | IPv6 relay |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `bom` | oracle | OCI Always Free, A1 Flex 4 OCPU / 24 GB; personal tenancy, Always Free only since 2026-10-25 | Mumbai, `ap-mumbai-1` ([OCI ranges](https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json)) | 10 TB/month outbound ([Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)), shared with everything in the tenancy; inbound free ([price list](https://www.oracle.com/cloud/price-list/)) | 141 GB out since 2026-10-06 (`enp0s6`), about 0.23 TB a month | Host egress: soft 6 TB, hard 8 TB | 1 Gbit/s in total; 50 Mbit/s per session | No (no public IPv6 on the VCN today) |
| `sin` | rb-vps | OVH VPS-2 (4 vCores, 8 GB, 75 GB) | Singapore ([ARIN: VPS-SGP2](https://rdap.arin.net/registry/ip/15.235.211.41)) | 1 TB/month quota in Asia-Pacific, "Beyond this, the bandwidth is capped at 10 Mbps" ([OVHcloud Asia VPS](https://www.ovhcloud.com/asia/vps/)) | 566 GB in and 502 GB out since 2026-07-08 (`ens3`), about 0.3 TB a month both ways | Host total (in plus out, the conservative reading): soft 700 GB, hard 900 GB | 200 Mbit/s in total; 50 Mbit/s per session | Yes |
| `sxb` | rr-dev-1 | Contabo Cloud VPS 12 (12 vCPU, 48 GB, 400 GB), 800 Mbit/s port | Lauterbourg, France (AS51167) | "Unlimited*": "No default bandwidth cap; a fair usage policy applies" and Contabo "reserves the right to throttle affected servers" ([Contabo docs](https://docs.contabo.com/docs/servers-hosting/vps/), [help](https://help.contabo.com/en/support/solutions/articles/103000271195-are-there-any-bandwidth-or-traffic-limits-at-contabo-)) | 140 GB out since 2026-10-18 (`eth0`), about 0.6 TB a month (builds, pushes, Syncthing) | Host egress: soft 8 TB, hard 10 TB; also a 24-hour average of at most 100 Mbit/s. All tunable. | 300 Mbit/s in total; 50 Mbit/s per session; lowest traffic priority | Yes |
| `cf` | Cloudflare Realtime TURN | One TURN key in the Round Robin Solutions account | Anycast, the nearest Cloudflare location | 1,000 GB/month free, shared with the SFU; then USD 0.05/GB; only "data sent from the Cloudflare edge to the TURN client" is billed ([FAQ](https://developers.cloudflare.com/realtime/turn/faq/), [pricing](https://developers.cloudflare.com/realtime/sfu/platform/pricing/)) | 0 | Free tier: soft 800 GB, hard 950 GB. Paid: a monthly spend cap (proposed USD 5, about 100 GB; Rahul decides) | 40 Mbit/s per session (client paced) | No (relays are IPv4 only) |

Notes on the members:

- **Contabo history.** Older Contabo pages and forum reports mention a 32 TB package and
  throttling after sustained high use. The current terms show only fair use, so the `sxb` caps are
  Bridgey's own conservative budget.
- **Latency.** rr-dev-1 is about 130 ms from India. From rr-dev-1 over the tailnet, oracle answered
  in 151 ms and rb-vps in 171 ms. `sxb` is therefore Europe's relay and India's last own fallback.
- **rb-vps** stays a long-term pool member: the earlier plan to retire it is cancelled (Rahul,
  2026-10-25).

How Rahul can confirm the points that are still open:

| Relay | Open point | How to confirm |
| --- | --- | --- |
| `bom` | Whether the 10 TB is tenancy-wide and which month it uses, and what happens above it on an Always Free-only tenancy | OCI Console, Billing and Cost Management, Cost Analysis, filtered on outbound data transfer. Oracle does not document the overage case ("will only charge you for resource usage above the Always Free limits" applies after an upgrade), so the hard cap must hold. |
| `sin` | The plan bought, whether the quota counts both directions, and the reset date | OVH Control Panel, Bare Metal Cloud, Virtual private servers, rb-vps, Home: the model and the datacentre. API `GET /vps/{serviceName}` returns `model` and `offerType`. OVH removed the VPS traffic endpoints ([ovhcloud-cli #204](https://github.com/ovh/ovhcloud-cli/issues/204)), so usage is measured on the host and the direction and reset date are a support question. |
| `sxb` | Fair-use thresholds | Contabo Customer Control Panel, Your services (product "Cloud VPS 12", port speed). The API `GET /v1/compute/instances/{id}` shows the product. Ask support by email for written fair-use thresholds. |
| `cf` | Billing month and usage | Cloudflare dashboard, Realtime, TURN, usage; GraphQL `callsTurnUsageAdaptiveGroups` (section 11.2). |

### 9.2 Allowance accounting

Each relay host runs `bridgey-relay-agent`, a small Rust binary in the coturn compose stack with
host networking and `NET_ADMIN`.

**What it reads:**

- **nftables counters** on the relay ports, in its own table. This is the real-time count of relay
  bytes. coturn's own traffic counters only update when a session ends.

  ```text
  table inet bridgey_relay {
    counter relay_in {}
    counter relay_out {}
    chain in  { type filter hook input  priority -10; udp dport { 3478, <relay range> } counter name relay_in
                tcp dport { 3478, 5349 } counter name relay_in }
    chain out { type filter hook output priority -10; udp sport { 3478, <relay range> } counter name relay_out
                tcp sport { 3478, 5349 } counter name relay_out }
  }
  ```

- **`/proc/net/dev`** on the public interface (`enp0s6`, `ens3`, `eth0`): the host total that the
  provider counts.
- **coturn Prometheus** on `127.0.0.1:9641`: `turn_total_allocations`, `turn_total_traffic_*`,
  `turn_auth_credential_failures`, `turn_packet_dropped`. Per-user labels stay off, because coturn
  warns they leak memory with ephemeral usernames
  ([turnserver.conf](https://github.com/coturn/coturn/blob/4.18.0/examples/etc/turnserver.conf)).
- **Per-session bytes** from coturn's session log lines, for per-node caps. The exact log format is
  to be checked in phase 3.

**Persistence and reporting:**

- It keeps cycle counters on disk (`/var/lib/bridgey-relay/cycle.json`), because nftables counters
  reset on reboot.
- Every 60 s it sends them to the control service: `POST /v1/relay/usage`, signed with HMAC-SHA256
  under a per-relay agent token (header `X-Bridgey-Relay-Sig` over timestamp and body).

**Fail-closed.** At the hard cap the agent itself inserts an nftables `drop` for the TURN ports.
It does this even if the control service is unreachable, so the provider limit holds. Clients then
fail over to another relay.

Cycle reset dates are set per relay in the config. Until confirmed, all four use the 1st of the
month, 00:00 UTC; `sin` keeps a 10% margin because its reset date is unknown.

### 9.3 Selection policy

When a `relay.request` arrives, the control service picks one relay for both sides of the session.

1. **Eligible relays:**
   - healthy: last health check under 60 s old, and the agent reported within the last 3 minutes;
   - not draining;
   - under the hard cap;
   - under the rate cap and, for `sxb`, the 24-hour average cap;
   - allocations under the quota;
   - not in `exclude`.
2. **Path round trip:** `rtt = rttA(r) + rttB(r) + penalty(r)`.
   - Clients measure RTT with three STUN binding requests to each own relay's 3478/udp and to
     `stun.cloudflare.com` while gathering, and cache it per network for 1 hour.
   - Penalties are config: `bom` 0, `sin` 10 ms, `sxb` 40 ms (it is the build server), `cf` 0.
3. **Near enough:** keep relays with `rtt` at most 400 ms; if none qualify, keep them all.
4. **Cost tier:**
   - 0: an own relay under its soft cap;
   - 1: an own relay between soft and hard cap, only if its projection stays under the hard cap
     until the cycle ends;
   - 2: Cloudflare under the free-tier hard cap;
   - 3: Cloudflare paid, under the spend cap.
5. **Choice:** sort by (tier, rtt) and take the first.

There is no country table and no GeoIP. The relay with the lowest round trip is naturally the
regional one:

| Devices in | Usual order |
| --- | --- |
| India (and the Gulf) | `bom`, then `sin`, then `sxb`, then `cf` |
| South-East Asia | `sin`, then `bom` |
| Europe | `sxb` |
| Elsewhere | Lowest round trip, with `cf` as overflow and failover |

**Stickiness and failover:**

- A session keeps its relay until the relay fails or crosses its hard cap.
- On failure the client sends `relay.request` with `exclude: ["bom"]`, makes the new allocation,
  restarts ICE, and QUIC migrates.
- New sessions rebalance by themselves.
- While a Dokploy or RR CI build holds rr-dev-1's build slot (`iieon-slot`), `sxb` reports
  `draining`, if `drain_when_building = true`. No new sessions start there; existing ones continue.

### 9.4 Cloudflare Realtime TURN

**What it offers** ([TURN overview](https://developers.cloudflare.com/realtime/turn/)):

| Protocol | Address |
| --- | --- |
| STUN over UDP | `stun.cloudflare.com:3478` |
| TURN over UDP | 3478, or 443 |
| TURN over TCP | 3478, or 80 |
| TURN over TLS | 5349, or 443 |

Relaying to the peer is UDP only, IPv4 only.

**Credentials.** The control service calls
`POST https://rtc.live.cloudflare.com/v1/turn/keys/{keyId}/credentials/generate-ice-servers` with
`{"ttl":7200}` ([credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/)).
The maximum lifetime is 48 hours. A grant ends early through `.../credentials/{username}/revoke`.

**Billing direction.** Cloudflare bills "data sent from the Cloudflare edge to the TURN client";
traffic from the relay to a peer that is not a TURN client is "not part of billing"
([FAQ](https://developers.cloudflare.com/realtime/turn/faq/)). If only the sending device holds the
Cloudflare allocation, the bulk direction goes from Cloudflare to the peer, and only the reverse
acknowledgements are billed. The cost projection does not count on this: billing rules can change.

**Limits:**

- Cloudflare drops packets above about "50-100 Mbps" or "5-10 kpps" per allocation, so sessions
  are paced at 40 Mbit/s.
- It "denies CreatePermission or ChannelBind requests if private IP ranges ... are used".

**Terms caution.** The Cloudflare Realtime service terms say it may be used "to enable video call
functionality for your Internet Properties", and forbid using it "to operate or enable any
telecommunications service"
([service-specific terms, 2026-09-28](https://www.cloudflare.com/service-specific-terms-developer-platform/)).
On the other side, the docs say "You can use TURN directly in your application too"
([what is TURN](https://developers.cloudflare.com/realtime/turn/what-is-turn/)). Relaying file
transfers is therefore a grey area. The pool works without Cloudflare: it is a backup, kept behind
a provider interface so it can be switched off or replaced (open question 1).

**One account.** Splitting relay traffic over several Cloudflare accounts to multiply the free tier
would breach the Self-Serve Subscription Agreement:

- section 2.2.1(c) forbids use "intended to circumvent Service-specific usage limits, quotas";
- section 2.2.1(e) forbids scripted account creation
  ([terms, last updated 2025-09-12](https://www.cloudflare.com/terms/)).

The design uses a single Cloudflare account. Paid overage is cheap (USD 5 per 100 GB) and appears in
the cost projection. Legitimately separate accounts, such as a future customer with their own
Cloudflare TURN key, fit as "bring your own TURN credentials": a pool entry of kind `cloudflare` or
`coturn` with its own key, caps and policy, used only by that customer's devices.

### 9.5 Relay credentials

coturn uses the TURN REST style ([draft-uberti-behave-turn-rest-00](https://datatracker.ietf.org/doc/html/draft-uberti-behave-turn-rest-00);
coturn `use-auth-secret`):

```text
username   = "<expiry unix seconds>:<first 8 chars of sid>.<side>"    e.g. "1761407200:q7Lw0d3x.0"
credential = base64(HMAC-SHA1(static-auth-secret of that relay, username))
```

- **Secrets.** Each relay has its own `static-auth-secret`, known only to the control service and
  that relay (vault `Keychain/Bridgey Connect`). It is rotated yearly; grants are short, so a
  rotation is a coturn restart of a few seconds after the control service switches.
- **Lifetime.** Grants last 2 hours for both coturn and Cloudflare, and clients renew at 90
  minutes. One grant can move at most 45 GB (2 h at 50 Mbit/s), which bounds abuse per grant. If
  the control service is down, relayed sessions end within 2 hours.
- **Identity.** The username carries no device identity. Logs and dashboards see a session prefix
  and a side.

### 9.6 Abuse limits

| Limit | Default (config) |
| --- | --- |
| Concurrent relay sessions per node | 4 |
| Relayed bytes per node | 50 GB a day, 300 GB per rolling 30 days; then `relay.denied` `node_capped` |
| Relay grants per node | 30 an hour |
| Per-session bandwidth | 50 Mbit/s each direction on own relays (`max-bps=6250000`); 40 Mbit/s on Cloudflare |
| Relay totals (`bps-capacity`) | `bom` 1 Gbit/s, `sin` 200 Mbit/s, `sxb` 300 Mbit/s |
| Allocations (`total-quota`) | `bom` 2,000, `sin` 300, `sxb` 300; `user-quota` 2 per username |
| Proof of work | Off; 16 bits when new nodes exceed 100 an hour; 20 bits under attack |
| Bans | By node key hash, or temporarily by IPv4 /24 or IPv6 /48 with an expiry, from the ops view |
| Trusted nodes | `trusted_nodes` in config (Rahul's own devices, if he wants) lifts the per-node caps, never the relay caps |

### 9.7 coturn configuration

coturn 4.18.0 (2026-09-08), image `coturn/coturn:4.18.0` pinned by digest. Host networking, as
coturn recommends for large port ranges
([docker README](https://github.com/coturn/coturn/blob/4.18.0/docker/coturn/README.md)). Example for
`bom`:

```text
listening-port=3478
tls-listening-port=5349
listening-ip=<private address>
relay-ip=<private address>
external-ip=92.4.95.94/<private address>
min-port=50000
max-port=59999
realm=bridgey
use-auth-secret
static-auth-secret=<rendered from the environment into a tmpfs at start>
fingerprint
no-multicast-peers
no-tcp-relay
no-tlsv1_2
cert=/var/lib/bridgey-relay/tls/relay.pem
pkey=/var/lib/bridgey-relay/tls/relay.key
user-quota=2
total-quota=2000
max-bps=6250000
bps-capacity=125000000
max-allocate-lifetime=3600
stale-nonce=600
prometheus
prometheus-port=9641
log-file=stdout
simple-log
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.0.0.0-192.0.0.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=::1
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
```

What these settings mean:

- `no-tlsv1_2` makes TLS 1.3 the minimum. In 4.18.0 the TLS 1.2 default is turned off this way;
  `no-tlsv1` and `no-cli` no longer exist ([release notes](https://github.com/coturn/coturn/releases/tag/4.18.0)).
- The admin CLI is off by default.
- Prometheus listens on localhost only (`--prometheus-address=127.0.0.1`).
- The TLS key is self-signed: the relay agent creates it on first start and reports its SPKI hash,
  which grants carry as `spki`. No certificate authority or renewal is needed, because clients pin it.
- `denied-peer-ip` blocks private, carrier-NAT, tailnet (100.64.0.0/10) and Docker
  (172.16.0.0/12) ranges, so nobody can use the relay to reach internal networks.

For `sin` and `sxb`, the relay range is 60000 to 61999, with the `total-quota` and `bps-capacity`
values from section 9.6.

Compose sketch (`server/relay/compose.yml` in this repo, unbranded):

```yaml
services:
  coturn:
    image: coturn/coturn:4.18.0@sha256:<pinned digest>
    network_mode: host
    restart: unless-stopped
    entrypoint: ["/usr/local/bin/bridgey-relay-agent", "exec-coturn"]   # renders the config into tmpfs
    volumes: [relay-state:/var/lib/bridgey-relay, ./bridgey-relay-agent:/usr/local/bin/bridgey-relay-agent:ro]
    tmpfs: [/run/coturn]
    environment: [TURN_SECRET]
    cpus: "${COTURN_CPUS}"        # bom 3.0, sin 1.0, sxb 1.5
    mem_limit: 512m
  relay-agent:
    image: ghcr.io/round-robin-solutions/bridgey-relay-agent:<version>
    network_mode: host
    cap_add: [NET_ADMIN]
    restart: unless-stopped
    environment: [RELAY_ID, CONTROL_URL, AGENT_TOKEN, HOST_IFACE]
    volumes: [relay-state:/var/lib/bridgey-relay]
volumes:
  relay-state: {}
```

### 9.8 Ports and firewalls

| Host | Open to the internet | Where | Notes |
| --- | --- | --- | --- |
| oracle (`bom`) | 3478/udp, 3478/tcp, 5349/tcp, 50000-59999/udp | OCI VCN security list or a network security group, plus host iptables | Check the host rules before opening: Oracle's Ubuntu images ship restrictive iptables rules, and this host already opens ports for RustDesk and Traefik. 9641 stays on localhost. Optional later: TURN over TLS on 443 through a Traefik TCP router with `HostSNI(`turn-in.roundrobin.in`)` passthrough. |
| rb-vps (`sin`) | 3478/udp, 3478/tcp, 5349/tcp, 60000-61999/udp | Host firewall | 443 belongs to host nginx, so TURN over TLS on 443 comes from Cloudflare |
| rr-dev-1 (`sxb`) | 3478/udp, 3478/tcp, 5349/tcp, 60000-61999/udp | Host firewall (Contabo's panel firewall is optional) | Plus traffic shaping (section 9.10) |
| rr-web | Nothing new: `connect.roundrobin.in` and `bridgey-ops.roundrobin.in` go through host nginx on 443 | | |
| Servers running a CLI node | 42458/udp, optional | Provider and host firewall | Lets phones behind hard NAT reach the server directly; otherwise sessions use a relay ([agent-cli.md](agent-cli.md#network)) |

DNS: `turn-in`, `turn-sg` and `turn-eu.roundrobin.in` as DNS-only A records (AAAA for `sg` and
`eu`) in the Round Robin Cloudflare zone. TURN cannot pass Cloudflare's proxy.

### 9.9 Deployment, approvals and AGENTS.md exceptions

Everything below is a server change or spending decision. Nothing happens before Rahul approves,
and every exception goes into `AGENTS.md` "Approved exceptions" and `context/DEPLOYMENT.md` when
deployed.

| Host | Deployment | Approval or exception needed |
| --- | --- | --- |
| rr-web | `bridgey-rendezvous` as a normal production app through Round Robin Dokploy (the one path: build on rr-dev-1, GHCR, deploy, `/health/ready` gate); host nginx vhosts and certbot for `connect.roundrobin.in`; Dokploy domain plus Cloudflare Access for `bridgey-ops.roundrobin.in` | No exception for the app. `MIGRATE_ON_START=1` is listed as a deliberate rule-5 exception (single SQLite writer), like the Forms relay. DNS records in the Round Robin zone. |
| oracle (`bom`) | Compose stack "Bridgey relay (bom)" in the personal Dokploy | Opening the relay ports in the OCI security list and host firewall. Adding coturn to `DEPLOYMENT.md` "Third-party pinned images" and the stack to "Compose stacks". The optional Traefik TCP router for 443 is its own change. |
| rr-dev-1 (`sxb`) | It is the Dokploy build server (`rr-dev-1-builder`), not a deploy server, and DEPLOYMENT.md says it has "No production apps" | Exception, for example: "2026-1x-xx: Bridgey relay (coturn + relay agent) on rr-dev-1 as a compose stack, host network, CPU 1.5, 512 MiB, relay traffic capped at 300 Mbit/s and in the lowest traffic class, drains while the build slot is busy. Rahul: <quote>." Choose between registering rr-dev-1 as a deploy-type server in the personal Dokploy, or a plain compose stack like the reels-worker exception. Plus the firewall and `tc` changes. |
| rb-vps (`sin`) | Dokploy was removed on 2026-10-08, and rb-vps runs "never production apps" | Exception for a public relay: attach rb-vps to the personal Dokploy as a deploy server, or run a plain compose stack. Record in DEPLOYMENT.md and plan.md that its retirement is cancelled (Rahul, 2026-10-25). Plus firewall changes. |
| Cloudflare | One Realtime TURN key in the Round Robin Solutions account (`POST /accounts/{id}/calls/turn_keys`); a Zero Trust organisation for Access | Spending: the free tier, then paid overage under a cap Rahul sets. Access is free for under 50 users ([Access plans](https://www.cloudflare.com/sase/products/access/)). |
| Vault | `Keychain/Bridgey Connect`: TURN secrets per relay, relay agent tokens, Cloudflare TURN key ID and API token, Access audience tag, Telegram (reuse `@rahul_deploy_bot`) | Rule 1 of AGENTS.md |

### 9.10 Protecting rr-dev-1 builds

1. **CPU and memory.** coturn is limited to 1.5 CPUs and 512 MiB with a low CPU share; the relay
   agent to 0.25 CPU.
2. **Total rate.** Relay traffic is capped at 300 Mbit/s (`bps-capacity=37500000`) of the
   800 Mbit/s port.
3. **Traffic class.** `tc` HTB on `eth0` puts relay source ports in the lowest-priority class, so
   build pushes to GHCR, pulls and Syncthing always win.
4. **Sustained rate.** When the 24-hour average passes 80 Mbit/s, the control service stops
   assigning new sessions to `sxb`; the limit is 100 Mbit/s.
5. **Penalty.** `sxb` carries a 40 ms selection penalty, so only Europe, or overflow, lands there.
6. **Draining.** `drain_when_building` makes `sxb` drain while a build runs.

## 10. Cost projection

Conservative assumptions (memory note "frugal by default"):

| Assumption | Value | Basis |
| --- | --- | --- |
| Traffic away from home per active pair (phone plus Mac or CLI) | 20 GB a month; Rahul himself 200 GB | Blip-like use: photos, videos, folders. High on purpose. |
| Share of that traffic needing a relay | 40% base, 60% in the sensitivity rows | Tailscale estimates direct "over 90% of the time" on typical networks ([blog](https://tailscale.com/blog/how-nat-traversal-works)). In India, Tailscale reports Jio and Airtel residential CGNAT as commonly symmetric ([Peer Relays post](https://tailscale.com/blog/peer-relays-international-networks)); IPv6 on Jio and Airtel mobile (88% to 93%) works the other way. |
| Overhead | +5% (QUIC, TURN headers, acknowledgements) | |
| Counting | Once at the relay's egress (both sides on the same relay). `sin` counts in and out. | Section 9.3 |
| Regional mix | India 70%, South-East Asia 15%, Europe and the rest 15% | Rahul's users are mostly in India |
| Cloudflare | Every relayed byte billed (the "server-to-peer not billed" saving ignored) | Section 9.4 |

Own pool capacity per month at the hard caps, minus the measured baseline:

| Relay | Capacity |
| --- | --- |
| `bom` | 8 - 0.25 = 7.75 TB |
| `sin` | (900 - about 300 GB) / 2 = 0.3 TB, because in and out both count |
| `sxb` | 10 - 0.6 = 9.4 TB |
| **Total own** | **17.45 TB**, plus Cloudflare's 1 TB free |

| Scenario | Active pairs | Away-from-home traffic | Relayed (40%, +5%) | Own pool takes | Cloudflare | Cloudflare USD a month |
| --- | --- | --- | --- | --- | --- | --- |
| A. Rahul only | 1, plus CLIs | 0.2 TB | 0.08 TB | All, on `bom` | 0 | 0 |
| B. Early users | 100 | 2 TB | 0.84 TB | All | 0 | 0 |
| C. Growing | 1,000 | 20 TB | 8.4 TB | All: India 5.9 TB on `bom` (under its 6 TB soft cap); South-East Asia 1.3 TB, of which `sin` takes 0.3 TB, `bom` about 0.1 TB up to its soft cap, and `sxb` the rest; Europe and the rest 1.3 TB on `sxb` | 0 | 0 |
| D. Larger | 2,500 | 50 TB | 21 TB | 17.45 TB | 3,550 GB: 1,000 free, 2,550 paid | 127.50 |
| E. Much larger | 5,000 | 100 TB | 42 TB | 17.45 TB | 24,550 GB: 23,550 paid | 1,177.50 |
| C at 60% relay | 1,000 | 20 TB | 12.6 TB | All (India 8.8 TB: `bom` 7.75, the rest on `sxb`) | 0 | 0 |
| D at 60% relay | 2,500 | 50 TB | 31.5 TB | 17.45 TB | 14,050 GB: 13,050 paid | 652.50 |

For comparison, Cloudflare only, with no own relays, at the same 40%:

| Scenario | Cloudflare USD a month |
| --- | --- |
| B | 0 (inside the free tier) |
| C | 7,400 GB paid, 370 |
| D | 20,000 GB paid, 1,000 |

The own pool removes about USD 370 a month at scenario C.

**Fixed monthly costs: USD 0 extra.**

- oracle is Always Free; Contabo and OVH are already paid.
- The control service uses about 256 MiB on rr-web.
- Cloudflare Access is free for fewer than 50 users; Telegram is free; the domains exist.

What the numbers mean:

- **Up to about 1,000 active pairs, relaying is free.** With a USD 5 spend cap, Cloudflare stops
  at 1,100 GB a month. In scenario D that would leave about 2.45 TB without a relay, so before D
  arrives, either raise the cap or add capacity.
- **Cheapest next capacity.** Upgrading the personal Oracle tenancy to Pay As You Go keeps the
  10 TB free and bills Asia-Pacific egress at USD 0.025/GB above it
  ([Oracle price API, part B93455](https://apexapps.oracle.com/pls/apex/cetools/api/v1/products/?currencyCode=USD&partNumber=B93455)),
  half Cloudflare's price. DEPLOYMENT.md records this as Rahul's decision. If South-East Asia
  grows, a cheap Singapore relay would keep it off `sxb`.
- **Trigger to grow:** the projected relayed bytes pass 80% of the own pool's hard caps two months
  running.

## 11. Dashboard and alerts

### 11.1 Recommendation: an ops view inside the control service

**Recommendation: a small ops view served by the control service at
`https://bridgey-ops.roundrobin.in`, behind Cloudflare Access with Google sign-in for
info@roundrobin.in only.** It copies the RR CI *pattern* (Access, JWT check, Telegram path), not
RR CI's code. Reasons:

- **The data is already there.** The control service holds usage, health, grants and Cloudflare
  usage, so there is nothing new to deploy, back up or keep in sync.
- **Separate concerns.** Bridgey's relays are product infrastructure for Round Robin users. RR CI
  is a private build tool on the personal domain, and its deploys should not touch Bridgey
  monitoring, nor the other way round.
- **Separate failure domains.** RR CI runs on oracle, the same host as `bom`. The control service
  on rr-web stays up when oracle is down, which is exactly when the dashboard matters.

The fallback when Access is unavailable is a tailnet listener with a bearer token, as RR CI has.

### 11.2 Metrics and sources

| Metric | Source | Granularity |
| --- | --- | --- |
| Relay bytes in and out per relay; host totals; percentage of soft and hard cap this cycle; projected end of cycle (trend of the last 7 days) | Relay agent (nftables, `/proc/net/dev`) | 60 s, stored as 5-minute samples |
| Current Mbit/s, active allocations, sessions, CPU, dropped packets, authentication failures | Relay agent, coturn Prometheus | 60 s |
| Health: STUN round trip to 3478/udp; synthetic TURN allocate every 5 minutes; agent freshness | Control service probes | 60 s / 5 min |
| Cloudflare egress and ingress this month, free-tier percentage, projected spend, concurrent connections | GraphQL `callsTurnUsageAdaptiveGroups` (`egressBytes`, `ingressBytes`, `concurrentConnections`, by `keyId` and `customIdentifier`) ([analytics](https://developers.cloudflare.com/realtime/turn/analytics/)) | Hourly. The data is sampled, so budgets add a 10% margin. |
| Nodes online, presence sockets, sessions signalled per hour, relay grants per hour, relay rate (grants per session), relay by region | Control service | 5 min |
| Route mix, connect success, time to connect (median, 95th percentile), NAT classes | Optional anonymous reports, only if Rahul enables them (open question 7) | Hourly |
| Credential issuance, rate-limit hits, proof of work level, bans | Control service | 5 min |

Retention is as in section 6.7: 5-minute samples for 35 days, hourly for 13 months, daily kept.

Views:

- **Overview:** one card per relay, with an allowance bar marked at soft and hard cap and the
  projection, plus health, Mbit/s and sessions. A Cloudflare card shows free tier, paid GB and
  spend.
- **Connections:** aggregates only.
- **Abuse:** top node hashes by bytes, proof of work, bans.
- **Alerts:** current and history.
- **Config:** read-only.

There are no per-user pages: devices appear only as key hashes in the abuse view.

### 11.3 Access control

1. **Cloudflare Access.** An application on `bridgey-ops.roundrobin.in` with the Google identity
   provider and the policy email equals `info@roundrobin.in`.
2. **JWT check.** On every ops request the service verifies the `Cf-Access-Jwt-Assertion` header:
   RS256, `kid` matched against `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`,
   `aud` equal to the application's AUD tag, `iss` equal to the team domain
   ([validating JWTs](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/)).
3. **Separate listener.** Ops routes are served only on the ops hostname's listener, never on
   `connect.roundrobin.in`.
4. **Admin actions.** Drain a relay, ban a node, change a cap: these need the same JWT plus a CSRF
   token, and every one is written to the alert history.

### 11.4 Alerts that never scale with users

Alerts fire only on infrastructure symptoms and on aggregates with minimum sample sizes. Never per
user, device or transfer.

| Key | Severity | Fires when | Re-notify while firing |
| --- | --- | --- | --- |
| `control.down` | Page | `/health` fails 3 checks in 3 minutes. Checked from outside by the `bom` relay agent, which sends to Telegram directly, so a down control service still alerts. | 6 h |
| `region.down:<relay>` | Page | The only own relay near most of its traffic is down for 5 minutes and Cloudflare is not available | 6 h |
| `relay.down:<relay>` | Warn | Health fails for 5 minutes | 24 h |
| `relay.allowance:<relay>` | Warn at 80% and 95%; page at 100% if no other relay has headroom | Cycle usage against the hard cap | On a new threshold only |
| `relay.projection:<relay>` | Warn | Projected to pass the hard cap before the cycle ends | Once per cycle |
| `cloudflare.free` | Warn | 80% of the free tier | On a new threshold only |
| `cloudflare.spend` | Warn at 50%; page at 100% (Cloudflare grants stop) | Spend against the monthly cap | On a new threshold only |
| `control.errors` | Warn | 5xx responses above 1% over 10 minutes, with at least 200 requests | 24 h |
| `connect.relay_rate` | Warn | Relay grants above 60% of sessions over 1 hour, with at least 50 sessions | Daily at most |
| `connect.failures` | Warn | More than 50 failed connects per 1,000 sessions over 1 hour, with at least 100 sessions (only if anonymous reports are on) | Daily at most |
| `abuse.*`, `secret.age`, new nodes per day | Info | Proof of work turned on, bans, TURN secret older than 365 days | Daily digest only |

How alerts are delivered:

- **One state machine per key:** inactive, pending (the "for" period), firing, resolved. Bridgey
  sends one message on firing and one on resolved, and re-notifies only on the interval above or
  when severity rises.
- **Grouping.** Alerts that fire within 60 s of each other, with the same group (relay or region),
  go in one message.
- **Global limit.** At most 6 messages an hour and 30 a day. Beyond that, one message an hour says
  "N more alerts suppressed, see the dashboard".
- **Daily digest** at 09:00 IST (03:30 UTC): info items, each relay's cycle percentage, Cloudflare
  GB and spend, aggregate connection health.
- **Severity.** Pages only for outages users feel. Warn messages go out normally. Info goes only
  into the digest.
- **Implementation:** a small in-house equivalent of Alertmanager's `group_by`, `group_wait`,
  `repeat_interval` and inhibition, inside the control service. It sends through the same Telegram
  path as RR CI (`rrci/outbound.py`: Bot API `sendMessage` to `@rahul_deploy_bot`'s chat, text
  capped at 3,500 characters). A full Prometheus and Alertmanager pair would cost two more
  containers for no gain at this size. If one is added later, these rules map one to one.

## 12. Onboarding and UX

### 12.1 Turning it on

- **Onboarding** gains a step: "Reach your devices away from home?" It explains, in plain words:
  devices connect directly when they can, or through a Round Robin relay that sees only encrypted
  data; no account; it can be turned off at any time. Then it runs the network check.
- **Settings.** "Away from home" sits in the "Devices and permissions" section. It holds the
  switch, "Check this network", "Large transfers on mobile data" (Ask above 500 MB, Allow, or
  Wi-Fi only) and "Reset away-from-home identity".
- **Device page.**
  - A route chip shows the route in use: "Same Wi-Fi", "Private network", "Direct", or
    "Relay (Mumbai)".
  - Tapping it shows the round trip, the current speed and when Bridgey last tried to upgrade.
- **Transfers** say "Paused, will resume" when the connection drops.
- **First relayed transfer.** A one-time notice: "This transfer goes through a Round Robin relay.
  The relay only sees encrypted data and may be slower than a direct connection."

### 12.2 Check this network

Run during onboarding and from Settings; it takes up to 5 s.

| Test | How |
| --- | --- |
| UDP works | STUN binding to the nearest own relay and to `stun.cloudflare.com:3478` |
| NAT mapping | Same mapped port from both servers means an easy NAT; different ports mean a hard one |
| IPv6 | A global IPv6 address, plus a STUN binding over IPv6 to `sin` or `sxb` |
| Relay over TLS | TCP and TLS reachability of 443 (Cloudflare) and 5349 (own) |
| Path to a paired device | If one is online, a full connect, then the route that won |
| VPN present | A Tailscale or other VPN interface |

Results in plain words:

| Result | Shown when |
| --- | --- |
| "Direct connections work on this network." | Easy NAT, or IPv6 works, or a paired device connected directly |
| "Direct connections may work. Bridgey will try, and use a relay if needed." | Hard NAT on this side, other side unknown |
| "This network blocks direct connections; transfers will use a relay and may be slower." | UDP blocked, or hard NAT with no IPv6 |

Simple fixes, shown only when they apply:

- "Turn on IPv6 on your router": Wi-Fi has no IPv6 but mobile data does.
- "Turn on UPnP or NAT-PMP on your router": a hard home NAT.
- "Tailscale is on. Bridgey will use it when your other device has it too."

The result is cached per network for 7 days, keyed by the network fingerprint of section 4.5
hashed with a local key. It decides route order without probing every time (section 4.3).

The control service gets at most the NAT class as one word (`open`, `easy`, `hard`, `udp_blocked`),
and only if anonymous reports are on. Nothing else about the network leaves the device.

## 13. Upstream angle

Upstream's roadmap lists "Optional end-to-end encrypted relay without making accounts or cloud
service mandatory", "End-to-end encrypted off-LAN relay with direct connections preferred",
"Resume verified transfers after network interruption or application restart", "Resumable
content-addressed transfers with end-to-end integrity verification", "QR-assisted pairing", "One-time
remote permissions, including grants limited to a single session or time window" and "A private
per-device audit log" ([README](../README.md#roadmap)). The architecture document already says
"QUIC can be introduced later without changing plugin message contracts". This design keeps to that.

How it stays upstream-friendly:

- **Unbranded names everywhere:** ALPN `bridgey/1`; capabilities `connect.v1`, `transfer.v1` and
  `agent.v1`; labels `bridgey-*-v1`; no "rr" in any wire string.
- **Edition values in one file.** `rr-edition.properties` gains
  `CONNECT_CONTROL_URL=wss://connect.roundrobin.in/v1/ws`. An upstream build ships with no control
  service. LAN and private-network routes still work, and direct and relay routes start working
  once a user enters a self-hosted URL.
- **Self-hostable.** `server/` holds the rendezvous service, the relay agent and one compose file
  (rendezvous plus coturn), all MIT. Cloudflare is just one optional provider entry.
- **Optional** and off by default upstream; nothing in a LAN-only setup changes.

What to offer upstream, in this order:

1. The protocol draft as a discussion issue.
2. The QUIC tunnel with the channel-binding transcript, as an optional transport.
3. `transfer.v1`.
4. The rendezvous and relay compose files for self-hosters.
5. Time-window grants and the audit log.

Risk: upstream may not want a Rust library inside its Kotlin and Swift apps. The protocol can be
implemented natively (Network.framework has QUIC on macOS 12 and later); the Rust core is offered,
not required.

## 14. Phased build plan

Sizes are relative: S is about 1 unit, M about 2 to 3, L about 4 to 6. One unit is roughly one
focused week.

| Phase | What | Size | Needs | Done when |
| --- | --- | --- | --- | --- |
| P0. Spike | QUIC over ICE over TURN in Rust; pick `rice-proto` or `is`; Android build; size and throughput measured | S | | Section 7.3 exit criteria met |
| P1. Routes and learned addresses | Rust core skeleton and UniFFI in both apps; QUIC tunnel with channel binding; QUIC on LAN between edition devices; direct dial to learned LAN and VPN addresses; route manager with upgrades; `connect.setup`, `connect.addresses`; route chip in the UI | L | P0 | Phone and Mac reach each other over Tailscale with no control service; LAN QUIC at least as fast as today's TCP; coming home moves the session to LAN within 60 s |
| P2. Direct over the internet | Control service (presence, sealed signalling, node auth) on staging and production; STUN, IPv6, hole punching; in-band ICE restarts; network check and onboarding step; remote pairing by QR code | L | P1 | Phone on Jio or Airtel data and Mac on home broadband connect directly where the NATs allow; presence costs at most 2% battery a day |
| P3. Relay pool, credentials, dashboard | coturn on `bom` first, then `sin` and `sxb` after approval; relay agent; selection; caps; Cloudflare provider; abuse limits; ops view; alerts | L | P2 | Any pair of networks connects, UDP-blocked included (TLS on 443); caps proven on staging with tiny limits; alert grouping and limits proven with a fault drill |
| P4. Resumable transfer | `transfer.v1` in the core; storage adapters (MediaStore, Storage Access Framework, macOS, CLI); parallel streams; resume after reconnect and restart; folders per the folders spec; Android service and UIDT path; `files.v1` fallback | L | P1 (LAN); P3 for every network | A 20 GB phone-to-Mac transfer over a relay survives 3 forced drops and an app kill, re-sending at most 4 MiB per drop; LAN at least 30 MB/s |
| P5. CLI phase 1 | Headless node; pair by QR; `send`, `clip`, `notify`, `ask` and `wait`, `ring`, `battery`, `status`; JSON and exit codes; grants, rate limits and audit log on Android; tarball and Homebrew | M | P2; P4 for large resumable sends; P3 for phones on UDP-blocked networks | An agent on rr-dev-1 asks "Approve / Deny" and gets Rahul's answer; a fresh CLI device has nothing granted |
| P6. CLI phase 2 | Daemon (systemd, launchd); inbox for files from the phone; clipboard watch; `watch` event stream; MCP server mode; notification reading behind its own grant; time-window grants; `.deb`; self-update from the channel feeds | M | P5 | |

The total is roughly 25 to 35 units for P0 to P4 and 4 to 6 for P5 and P6.

This matches Rahul's build order: Connect anywhere is step 3 (P0 to P4), the CLI step 4 (P5 and
P6). P5 can start right after P2 for agents on servers with public addresses (rr-dev-1, oracle):
a phone behind CGNAT can reach a public server directly, so these need no relay.

## 15. Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Indian CGNAT mostly hard, so more relaying than assumed | Bandwidth use and cost | IPv6 first; port mapping on home routers (phase 2 stretch); 60% sensitivity row in the cost table; caps |
| Jio's aggressive UDP timeouts | Drops, battery | 15 s keep-alives only while a session is active; 5-minute idle close |
| Battery cost of presence and keep-alives | Users switch it off | Adaptive keep-alive; measured exit criterion; FCM or UnifiedPush wake-ups considered later (open question 8) |
| Cloudflare terms scope Realtime to "video call functionality" | Cloudflare backup could be refused | Own pool first; Cloudflare behind a provider interface; ask Cloudflare or accept the risk (open question 1) |
| Oracle overage behaviour undocumented for Always Free-only tenancies | Unexpected bill or block | Hard cap at 8 of 10 TB, enforced locally fail-closed; cost analysis check |
| rb-vps quota: 1 TB with a 0.3 TB baseline, direction and reset date unknown | 10 Mbit/s throttle also hurts rb-vps's other jobs | Host-total cap at 900 GB, counting both directions; ask OVH |
| Relay starves rr-dev-1 builds | Slow releases | Section 9.10 |
| Rust core inside both apps (UniFFI, async, JNI, size, CI time) | Delays P1 | P0 spike measures; transport-only core first; existing LAN TCP stays as fallback |
| Library maturity (`rice-proto` 0.4 with "initial TURN support"; quinn 0.12 API change) | Rework | Sans-IO lets us swap ICE crates; wrap quinn's socket trait; pin versions |
| UDP blocked (hotels, offices) | No direct route | TURN over TLS on 443 through Cloudflare; optional 443 on `bom` via SNI passthrough |
| Abuse of an open-source app's free relays | Allowance used up | Node keys, proof of work, per-node caps, bans, hard caps |
| Control service is a single point for off-LAN reachability | No new remote sessions while it is down | LAN and VPN routes keep working; relayed sessions survive up to 2 h; external alert |
| New attack surface (UDP listener, signalling, QUIC parsing) | Security | Limits before parsing, QUIC Retry, fuzzing, security review before release |
| macOS firewall prompt for an ad-hoc-signed app listening on UDP | Confusing first run | Test on both Macs; the existing local network permission flow |
| Upstream declines | The edition diverges | Keep it optional and unbranded; edition-only until accepted |

## 16. Testing on real devices and networks

Unit and simulation tests come first: sans-IO ICE with virtual NAT types (easy, hard, UDP blocked,
IPv6 firewall), QUIC migration, resume with killed processes, and protocol fuzzing. Then the
real-world matrix, which needs Rahul's OnePlus 11, the personal Mac, the work Mac, a second SIM or
hotspot and a few public networks:

| Case | Expected |
| --- | --- |
| Phone on Jio 5G, Mac on home broadband (JioFiber or Airtel) | Direct over IPv6 where possible; otherwise relay `bom` |
| Phone on Airtel 4G, Mac on a hotspot from another phone (CGNAT on both sides) | Relay, with one allocation where possible |
| Hotel, airport or cafe Wi-Fi with a captive portal and UDP blocked | TURN over TLS on 443 (Cloudflare) |
| Office Wi-Fi (work Mac) | Direct or relay; record the NAT class |
| Tailscale on both, phone VPN on | Private network route with no control service |
| Walk out of home mid-transfer (Wi-Fi to mobile), then come back | Resumes on direct or relay, then upgrades to LAN within 60 s |
| Airplane mode for 2 minutes; app killed; phone rebooted; Mac sleep and wake | Each resumes the transfer with at most 1 chunk per stream re-sent |
| Screen off for 1 hour with presence on; 24 hours of normal use | Battery Historian under 2% a day for presence; transfers continue under Doze |
| CLI on rr-dev-1 (France) and oracle (Mumbai), phone on Jio | `ask` round trip; direct path to the public server |
| Stop coturn on `bom` mid-transfer | Moves to `sin` or `cf` within 10 s; transfer continues |
| Staging relay with a 1 GB hard cap | Soft-cap shift, hard-cap fail-closed, alerts once each, grouped |
| 20 GB file and a folder of 10,000 small files, both directions | Throughput targets of section 8.1 |
| An upstream Bridgey client | Today's LAN TCP, unchanged |

## 17. Open questions for Rahul

1. **Cloudflare terms.** Realtime is scoped "to enable video call functionality". Should the
   Cloudflare backup go ahead as is, wait until we have asked Cloudflare, or stay off?
2. **Cloudflare monthly spend cap** after the free 1,000 GB: USD 0 (free tier only), USD 5
   (about 100 GB), or more?
3. **Where the control service runs:** rr-web (proposed: production path, separate from the
   relays) or oracle (keeps Bridgey off production)?
4. **Hostnames:** `connect.roundrobin.in`, `bridgey-ops.roundrobin.in` and
   `turn-in`/`turn-sg`/`turn-eu.roundrobin.in`, or a Bridgey domain?
5. **Ops dashboard sign-in:** a new free Zero Trust organisation on the Round Robin Cloudflare
   account, or the existing personal team that protects ci.rbansal.xyz?
6. **Relays on rr-dev-1 and rb-vps:** approve the exceptions. For each, should it be registered as
   a Dokploy deploy server, or run as a plain compose stack?
7. **Anonymous connection reports** (route type, success, NAT class, nothing else) for the
   dashboard's failure metrics: on by default in the edition, opt-in, or never? Upstream promises
   no telemetry.
8. **Reachable while idle:** should the phone keep its presence connection whenever "Away from
   home" is on (needed for agents to reach it), and should push wake-ups (FCM or UnifiedPush) be
   considered later?
9. **Per-device relay caps for everyone:** 50 GB a day and 300 GB per 30 days? Should your own
   devices be marked trusted (uncapped)?
10. **Large transfers on mobile data:** default "Ask above 500 MB"?
11. **Oracle budget:** is a hard cap of 8 of 10 TB right, given everything else on oracle shares
    the 10 TB?

Calls made in this spec without asking (please review):

- QUIC is used on LAN between edition devices too, not only off the local network.
- 1 MiB chunks; 4 streams (8 on LAN).
- 2-hour relay grants.
- The control service on a DNS-only hostname.
- The ops view inside the control service rather than in RR CI.
- "Away from home" placed under "Devices and permissions".
- RTT-based relay choice with penalties instead of a country table.
- `sin` counted in both directions.
- A 40 ms penalty and build-time draining for `sxb`.

## 18. Sources

**Read locally:**

- `README.md`, `docs/protocol.md`, `docs/architecture.md`, `SECURITY.md`, `docs/rr-edition.md`,
  `android/app/src/main/AndroidManifest.xml`, `PairingCoordinator.kt`, `ProtocolCrypto.swift`.
- `outputs/bridgey/plan.md`, `context/DEPLOYMENT.md`, `AGENTS.md`, and rr-ci `rrci/outbound.py`.
- Interface counters on oracle, rb-vps and rr-dev-1, and tailnet latency from rr-dev-1, read-only
  on 2026-10-25.

External sources, read 2026-10-25 unless dated:

| Topic | Sources |
| --- | --- |
| T3 Connect | [remote access](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md) |
| Cloudflare Realtime TURN | [overview](https://developers.cloudflare.com/realtime/turn/), [FAQ](https://developers.cloudflare.com/realtime/turn/faq/), [credentials](https://developers.cloudflare.com/realtime/turn/generate-credentials/), [analytics](https://developers.cloudflare.com/realtime/turn/analytics/), [RFC matrix](https://developers.cloudflare.com/realtime/turn/rfc-matrix/), [what is TURN](https://developers.cloudflare.com/realtime/turn/what-is-turn/), [pricing](https://developers.cloudflare.com/realtime/sfu/platform/pricing/) |
| Cloudflare terms | [service-specific terms](https://www.cloudflare.com/service-specific-terms-developer-platform/), [Self-Serve Subscription Agreement](https://www.cloudflare.com/terms/) |
| Other Cloudflare | [R2 pricing](https://developers.cloudflare.com/r2/pricing/), [Access JWT validation](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/), [Access plans](https://www.cloudflare.com/sase/products/access/) |
| Oracle | [Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm), [price list](https://www.oracle.com/cloud/price-list/), [public IP ranges](https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json) |
| Contabo | [VPS docs](https://docs.contabo.com/docs/servers-hosting/vps/), [traffic limits](https://help.contabo.com/en/support/solutions/articles/103000271195-are-there-any-bandwidth-or-traffic-limits-at-contabo-), [API](https://api.contabo.com) |
| OVHcloud | [Asia VPS](https://www.ovhcloud.com/asia/vps/), [Singapore VPS](https://www.ovhcloud.com/en-sg/vps/), [API schema](https://eu.api.ovh.com/1.0/vps.json), [ovhcloud-cli #204](https://github.com/ovh/ovhcloud-cli/issues/204), [ARIN RDAP 15.235.211.41](https://rdap.arin.net/registry/ip/15.235.211.41) |
| coturn | [repository](https://github.com/coturn/coturn), [4.18.0 release](https://github.com/coturn/coturn/releases/tag/4.18.0), [turnserver.conf](https://github.com/coturn/coturn/blob/4.18.0/examples/etc/turnserver.conf), [docker](https://github.com/coturn/coturn/blob/4.18.0/docker/coturn/README.md) |
| Standards | [RFC 8445](https://www.rfc-editor.org/rfc/rfc8445), [RFC 8489](https://www.rfc-editor.org/rfc/rfc8489), [RFC 8656](https://www.rfc-editor.org/rfc/rfc8656), [RFC 6062](https://www.rfc-editor.org/rfc/rfc6062), [RFC 9000](https://www.rfc-editor.org/rfc/rfc9000), [RFC 9001](https://www.rfc-editor.org/rfc/rfc9001), [RFC 9443](https://www.rfc-editor.org/rfc/rfc9443), [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446), [RFC 9266](https://www.rfc-editor.org/rfc/rfc9266), [RFC 8838](https://www.rfc-editor.org/rfc/rfc8838), [RFC 6887](https://www.rfc-editor.org/rfc/rfc6887), [RFC 8831](https://www.rfc-editor.org/rfc/rfc8831), [TURN REST draft](https://datatracker.ietf.org/doc/html/draft-uberti-behave-turn-rest-00) |
| Libraries | [quinn](https://github.com/quinn-rs/quinn), [librice and rice-proto](https://github.com/ystreet/librice), [turn-client-proto](https://docs.rs/turn-client-proto), [str0m](https://github.com/algesten/str0m), [is](https://docs.rs/is), [webrtc-rs](https://github.com/webrtc-rs/webrtc), [libjuice](https://github.com/paullouisageneau/libjuice), [libdatachannel](https://github.com/paullouisageneau/libdatachannel), [iroh 1.0](https://www.iroh.computer/blog/v1), [iroh hole punching](https://docs.iroh.computer/concepts/holepunching), [noq](https://github.com/n0-computer/noq) |
| WebRTC | [prebuilt libraries discontinued](https://groups.google.com/g/discuss-webrtc/c/Ozvbd0p7Q1Y/m/M4WN2cRKCwAJ), [dcSCTP options](https://webrtc.googlesource.com/src/+/refs/heads/main/net/dcsctp/public/dcsctp_options.h), [MDN data channels](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API/Using_data_channels), [Apple NWProtocolQUIC](https://developer.apple.com/documentation/network/nwprotocolquic) |
| Android | [FGS timeout](https://developer.android.com/develop/background-work/services/fgs/timeout), [FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types), [UIDT](https://developer.android.com/develop/background-work/background-tasks/uidt), [Doze](https://developer.android.com/training/monitoring-device-state/doze-standby), [background start limits](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start), [ConnectivityManager](https://developer.android.com/reference/android/net/ConnectivityManager) |
| Networks | [Google IPv6](https://www.google.com/intl/en/ipv6/statistics.html), [APNIC India](https://stats.labs.apnic.net/ipv6/IN), [Tailscale NAT traversal](https://tailscale.com/blog/how-nat-traversal-works), [Tailscale Peer Relays (India CGNAT)](https://tailscale.com/blog/peer-relays-international-networks), [Tailscale 100.x](https://tailscale.com/kb/1015/100.x-addresses), [Tailscale IPv6](https://tailscale.com/kb/1033/ip-and-dns-addresses) |

## Decisions confirmed by Rahul (2026-10-25)

1. **Cloudflare TURN is allowed** for relaying Bridgey traffic (Rahul's decision on the terms question). Use it as backup and overflow behind our own pool, through the provider interface, on one Round Robin Cloudflare account. No splitting across accounts.
2. **Control service:** on `rr-web` through Dokploy, like other Round Robin product services. LAN and private-network routes keep working if it is down.
3. **Hostnames:** under `roundrobin.in`: `connect.roundrobin.in` for the control service, `relay-in.roundrobin.in` (oracle, Mumbai), `relay-sg.roundrobin.in` (rb-vps, Singapore), `relay-eu.roundrobin.in` (rr-dev-1, France), and a private ops dashboard.
4. **Relays on rr-dev-1 and rb-vps run as Dokploy deploy targets:** add rr-dev-1 as a Dokploy deploy server (it stays the build server, so the relay is rate-limited and lowest priority), and reinstall Dokploy's agent on rb-vps as a deploy server. All three relays deploy through Dokploy, so no AGENTS.md exception is needed for them.
5. **Cloudflare paid spend cap: USD 0.** Only the free 1,000 GB a month is used; when it runs out, Cloudflare is skipped until the next month and the own pool carries everything (or the transfer waits with a clear status if the pool is also at its caps).
6. **Reachability:** while "Away from home" is on, the phone keeps one light connection to the control service so paired devices and agents can reach it. Push wake-ups to save battery come later.
7. **Mobile data:** a user setting "Ask before using mobile data above", default 100 MB, adjustable (including "Always ask" and "Never ask").
8. **Anonymous connection stats: on by default, opt-out** in Settings > Privacy. Route used, success or failure and timing class only; never names, files, addresses or device identifiers. The README and onboarding state this plainly, since it changes the upstream "no telemetry" position for the edition.
