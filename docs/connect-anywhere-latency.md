# Connect anywhere: connecting in under a second

Status: built on branch `rr/connect-fast` (2026-10-30). Rahul's goal: a phone and a Mac reach a working,
authenticated session through the relay in under 1 s from the moment it is needed, instead of about 4 s.
Design: [connect-anywhere.md](connect-anywhere.md). Measured results: [Results](#results).

## The three measures

| | What starts the clock | What stops it |
| --- | --- | --- |
| **A. Cold start** | The phone app's process starts (LAN unavailable) | The phone's session on the relay is authenticated |
| **B. Failover** | The LAN goes away (the Mac test instance drops its LAN sessions and turns relay only) | The session on the relay is authenticated on both devices |
| **C. Warm reconnect** | The app comes to the foreground after its session died in the background | The session is authenticated again |

Each is measured 20 times on the bridgey-api36 emulator and a throwaway Mac test instance, both on the personal
Mac in India, through the public control service (`connect.roundrobin.in`) and relay (`relay-sg`, Singapore).

## The floor

From India, measured from the personal Mac:

| Hop | Round trip |
| --- | --- |
| Control service (rr-web) | about 38 ms (TCP connect 36 to 46 ms) |
| relay-sg | 75 ms |
| relay-eu | 170 ms |
| Phone to Mac through relay-sg (R) | about 150 ms (two device-to-relay legs) |

A session needs at least: the control service connection (TCP, TLS, then one flight), one signal each way, one
connectivity check through the relay, the QUIC handshake, and the Bridgey handshake (the initiator authenticates
one round trip after its offer, the responder half a round trip later). With R = 150 ms and the control service at
38 ms, that is about 3 x 38 + 2 x 20 + 150 + 150 + 150 to 225 ms, roughly 0.6 to 0.7 s plus the app's own start.
None of those steps can be removed without weakening security: the QUIC handshake proves the peer's certificate,
and the Bridgey handshake is an interactive ECDH exchange that must not become replayable (protocol 2).

## How others connect quickly

| System | What makes it fast | What we took |
| --- | --- | --- |
| Tailscale (DERP, magicsock) | Each device keeps a connection to a home relay chosen by latency ([DERP servers](https://tailscale.com/kb/1232/derp-servers)). "All connections start out with DERP preselected": the connection works at once through the relay "while path discovery runs in parallel", then "transparently upgrades" to a direct path, usually within seconds ([How NAT traversal works](https://tailscale.com/blog/how-nat-traversal-works)). | Relay ready before it is needed (the warm relay), direct and relayed paths raced side by side, upgrades a moment later without dropping the connection. |
| iroh | QUIC between endpoints; "when two endpoints first connect, they exchange network information through the relay", the relay carries traffic when no direct path works, and "once a direct path is established, the relay steps back" ([iroh relays](https://docs.iroh.computer/concepts/relays)). | Same shape as our ICE agent with QUIC on a virtual address: the path moves under QUIC. |
| WebRTC ICE | Trickle ICE sends candidates as they are found ([RFC 8838](https://www.rfc-editor.org/rfc/rfc8838)); browsers gather ahead of time (`iceCandidatePoolSize`) so TURN allocations exist before the offer; aggressive nomination selects the first pair that works ([RFC 5245 section 8.1.1.2](https://www.rfc-editor.org/rfc/rfc5245#section-8.1.1.2)); RFC 8445 keeps regular nomination but allows choosing early. | Candidates in the first offer (pre-gathered), trickle for the rest, aggressive nomination before the first selection, regular nomination for later moves. |
| TURN ([RFC 8656](https://www.rfc-editor.org/rfc/rfc8656)) | Allocate costs two round trips (the first is refused with 401 to learn the realm and nonce); permissions (CreatePermission) let data through at once as Send indications, channels only shrink the framing; an allocation lives until refreshed or released. | Realm and nonce cached per relay (one round trip), permissions before channels, one allocation per device kept warm and permitted for every relay in the pool. |
| TLS 1.3 / QUIC 0-RTT | Resumption saves CPU, not round trips; 0-RTT early data saves one round trip but is replayable ([RFC 8446 section 8](https://www.rfc-editor.org/rfc/rfc8446#section-8), [RFC 9001 section 9.2](https://www.rfc-editor.org/rfc/rfc9001#section-9.2)). | Not used: a persistent control connection makes the control service's handshake rare, and the tunnel's handshake is followed by the Bridgey handshake, which needs its own round trip anyway (see below). |

### Why no 0-RTT

- **Control service.** The connection is kept open, so its handshake happens once per app start or network
  change. The single-flight sign-in already puts hello, sign-in and registration into the upgrade request; 0-RTT
  would save one more round trip (about 38 ms) at the cost of replayable early data through nginx.
- **Tunnel.** QUIC 0-RTT needs a session ticket from an earlier connection to the same certificate; each node
  makes a new certificate per process, so a cold start (A) never has one. The data that could ride in it is
  `pairing.offer`, and the Bridgey handshake still needs the responder's ephemeral key before anyone can send an
  action, so 0-RTT would save half a round trip for one side at most, while replayable early data would reach the
  session layer. Protocol 2's envelope tags and replay window stay as they are.

## What was slow (before)

From the code and the waterfall of beta 13 (numbers in [Results](#results)):

| Step | Before | After |
| --- | --- | --- |
| Control service sign-in | DNS, TCP, TLS, upgrade, then hello, challenge, a keystore signature, auth, welcome, then register and registered: six round trips plus the signature in series | DNS, TCP, TLS, then one flight (the signature is made while TCP and TLS run): three round trips |
| Control service frames | Nagle on the service's sockets: a frame sent while the previous was unacknowledged waited for the delayed ack (about 40 ms per hop) | `TCP_NODELAY` on every connection |
| Race start | A new peer, and a peer that just dropped, waited 1.5 s ("connect 1.5 s after start", commit bfa6916, and the grace after a drop); the first race was scheduled 1.6 s after the peer list | At once; 300 ms only when the peer's LAN address is on this network, so the app's LAN TCP can win at home |
| Waiting for the control service | Polled every 100 ms | Woken by the event |
| Relay | Requested per session, then STUN to the relay, then a fixed 1 s wait for a direct pair, then Allocate (two round trips), then the candidate trickled, then channels bound, pairs frozen until bound (polled every 100 ms) | The device's own relay is allocated and permitted for every relay in the pool before any session; its candidate and the server-reflexive one go in the first offer; the answerer opens its relay to the offerer as it answers; Send indications until a channel is bound |
| After a force-kill | The relay refused the allocation left on the same socket (437) for up to 10 minutes, so the phone used the next relay (Strasbourg, about 330 ms) | The service gives the node back the credential of its own earlier allocation (proof: the node's signed sign-in); the node ends it and allocates again |
| Checks | One pair every 25 ms in priority order, so relay pairs (lowest priority) went last; first retransmit after 250 ms | A direct lane and a relayed lane each start a check every 25 ms; relayed pairs get a 50 ms head start (none when no direct pair is pending); first retransmit after 100 ms |
| Nomination | First success, then a 300 ms window for a better pair, then a nomination check (one more round trip) before QUIC | Aggressive nomination: the first pair that answers is the path; better pairs are tried 1, 2, 4 and 8 s later and QUIC moves without noticing |
| Network change | A 3 s ping probe before a session was given up | 1.5 s |
| Foreground after sleep | The control connection was trusted however long it had been quiet, so signals could sit behind TCP retransmits; a lost one reconnected on back-off | Replaced at once when it has been quiet for 25 s or was lost (cutting back-off short, and abandoning an attempt stuck on the old network); the app ends a session as soon as the core says its tunnel closed |
| First STUN request of a new node | Could be refused by the socket (tokio WouldBlock before the reactor saw it writable) and wait for its retransmit | Waits for writability |

## The design

### Single-flight sign-in

The client signs `"bridgey-rdv-auth-v2\0" ‖ host ‖ "\0" ‖ ts ‖ cnonce ‖ node` (ts: 8-byte big-endian Unix ms,
cnonce: 16 random bytes) while DNS, TCP and TLS run, and sends hello, signature, rendezvous IDs and the warm relay
request as base64url JSON in the `x-bridgey-hello` header of the WebSocket upgrade. The service checks the node
key, the signature over its own configured host (`public_host`), that `ts` is within two minutes, and that it has
not seen this (node, cnonce) before, then answers the upgrade with `x-bridgey-welcome: 1`, sends `welcome`, and
handles the registration and the warm request as if they had arrived as frames. Anything wrong means no
`x-bridgey-welcome`, and the client runs the challenge flow on the same socket. Older services ignore the header;
older clients never send it.

### The warm relay

- `welcome` lists the pool (`relays`: ID and STUN address). The node probes every relay with one STUN binding at
  once: round trips for the relay choice, and its server-reflexive address from the nearest.
- `relay.warm` (or the warm request in the sign-in) gives the node credentials of its own, valid 12 hours and
  renewed in their last hour. The username is `"<expiry>:w.<tag>"`, tag = base64url(HMAC-SHA256(secret,
  "bridgey-warm-v1" \0 nodeId \0 expiry)[0..9]), so the relay sees an opaque name and only the service can tie
  it to the node.
- Off mobile data (Android tells the core whether the network is metered; a Mac always), the node keeps an
  allocation with these credentials and permits every relay in the pool, so a peer's relay candidate on any
  relay reaches it with no setup. A STUN binding to the relay every 25 s keeps the NAT mapping open and the
  server-reflexive address fresh; the allocation, its permissions and channels are refreshed every 4 minutes.
  On mobile data the node keeps the credentials only and allocates when a session starts (one round trip with
  the cached realm and nonce).
- Sessions put the server-reflexive and warm relay candidates in their first description. The answerer permits
  the offerer's addresses on its relay as it answers. With one warm side, the other side's server-reflexive
  address reaches it straight away, which is the path a restarting phone uses before its own allocation exists.
- **After a crash.** The app keeps the core's state (pool, round trips, the warm allocation's relay, server,
  username, realm and nonce; never a credential) in a file outside backups. On the next start, if the state is
  younger than 11 minutes and the socket is the same, the sign-in carries `reclaim` with the old username. The
  service returns its credential only when the tag matches the signed-in node, the node ends the old allocation
  (Refresh with lifetime 0), and allocates again once the relay has freed it (on its next second).

### Racing

ICE runs direct and relayed checks side by side, gives direct pairs 50 ms, and selects the first pair that
answers. QUIC rides a virtual address, so a better pair found a second later takes over without a new
connection. The race starts as soon as a peer is not connected; only when one of the peer's LAN addresses is on
this device's own subnet does the app's LAN TCP connection get 300 ms first, because LAN sessions stay on TCP
(Rahul, 2026-10-27).

## Tunnel throughput

Measured with the fast-transfers probe (`--binary-mb 64`: 64 MiB in 256 KiB binary frames each way at once, the
other side echoing every byte, SHA-256 checked), two headless nodes on rr-dev-1 through the local control service
and coturn, 3 runs each, the first transfer of each run:

| Path | Before | After |
| --- | --- | --- |
| Direct tunnel | 4.7, 5.6, 8.8 MB/s each way | 24.2, 25.5, 24.8 MB/s |
| Through the relay | 4.8, 5.1, 5.5 MB/s | 3.4, 4.0, 4.7 MB/s (within noise) |

What changed: the UDP socket asks for 4 MiB send and receive buffers (the defaults, about 200 KB, dropped the
bursts a QUIC window sends); the queue between the socket reader and QUIC holds a full window (16,384 datagrams)
instead of dropping past 2,048; QUIC takes every waiting datagram in one call instead of one per wake-up; the
loopback bridge copies through 256 KiB buffers instead of tokio's 8 KiB. QUIC's flow-control windows (4 MiB per
stream, 16 MiB per connection) were already larger than the bandwidth-delay product of these paths, and files
belong on a stream, not QUIC datagrams (they need ordering and retransmission). BBR was tried in place of Cubic
and was worse on both paths (3 to 9 MB/s direct, 2.5 to 3.3 relayed), so Cubic stays.

The relay path is held by the relay itself: coturn's `max-bps=6250000` (50 Mbit/s per allocation, section 9.7 of
the spec) drops what goes over, and QUIC then backs off. Raising it is a cost decision (relay bandwidth
allowances), not a code change. Packets stay at 1,200 bytes because path MTU discovery is off (a tunnel can move
onto a relayed path at any moment, and larger packets would black-hole there).

## Bugs found on the way

| Bug | Effect | Fix |
| --- | --- | --- |
| A session that selected a path but never got its QUIC dial (beta 13 too) | Lived forever; every later race for that peer waited on it, and the lower device ID turned every offer away as glare. In the before C runs neither side reconnected within 40 s | Sessions end 10 s after selection without a tunnel, or 25 s after they began |
| Glare after a lost offer | The lower device ID held out for an offer it had sent into the other side's dead control connection (about 8 s in the first after C runs) | The lower side sends its unanswered offer again once it is a second old; the higher side always yields |
| A stale control connection after sleep (beta 13 too) | Signals waited behind TCP retransmits; the reconnect came on back-off, 25 s later in one before C run | Foreground replaces a connection quiet for 25 s or lost (a close no longer counts as hearing from the service), abandons an attempt still under way, and never interrupts a process's first attempt |
| The ICE agent's 15 s counted from the session's start | An offer kept through glare and answered late died just as its answer arrived | Counted from when checks can start |
| The app noticed a dead tunnel only through its loopback socket | After sleep, up to the foreground | The core's tunnel-closed event ends the session (the Mac exposed it but did not use it) |
| Trimmed relay channels were forgotten | The relay kept using them, so that peer's data was dropped | Kept known (not refreshed) for 11 minutes |
| Nagle on the control service | About 40 ms on a frame sent right after another | `TCP_NODELAY` |
| The first STUN request of a new node | Sometimes refused by the socket and resent 250 ms later | Waits for writability |
| The probe example never reported a working session (since the beta fit) | Its failover test backed off instead of redialling | Reports it like the apps |

## Security review

Two rounds by separate Claude reviewers, each given the code and the invariants. Round one (no high findings)
led to: a replay-proof controlled side (it selects only pairs its own check proved), trimmed relay permissions,
warm credentials asked once, reclaims only to the grant's relay, a bounded sweep of the sign-in replay memory, a
per-address slot given back on a failed upgrade, and the pin set before the answer. Round two found that two of
those fixes broke connection setup in a narrow window (checks or a QUIC dial arriving before the answer) and that
the glare rule misbehaved with slow signalling; all fixed with tests (a replayed nomination is never selected;
checks before the answer still select). Kept deliberately: foreground replaces a quiet control connection without
pinging first, because the ping would cost a second exactly when the connection is dead (the trade: one sign-in
per foreground after 25 s of quiet, and a moment where the peer sees this device offline).

## Security

| Property | How it holds |
| --- | --- |
| Protocol 2 envelope tags and replay checks | Untouched. The tunnel and the Bridgey handshake are the same; nothing rides in 0-RTT. |
| Only paired devices tunnel | Unchanged: signalling is still sealed with the pair secret, tunnels still need `bridgey-auth-v2` signatures bound to the QUIC exporter, and an offer from an untrusted device still closes the tunnel. |
| The single-flight sign-in cannot be replayed | Signed over the service's host and a timestamp, taken once per (node, cnonce) within two minutes (the service remembers each for the window). A replayed or out-of-window hello is refused and falls back to the challenge. Pre-existing limits (sockets per node, per IP) apply. |
| Reclaiming needs the device key | The credential of a warm username is returned only on a socket that signed in with the node key the tag was made for. The saved state holds no credential. |
| The relay learns nothing new | It sees an opaque username per node per 12 hours instead of per session (it already saw the device's IP); payloads stay QUIC-encrypted. |

## Battery

| Device | What runs while idle | Cost |
| --- | --- | --- |
| Mac | STUN binding to the relay every 25 s (about 100 bytes each way), allocation refresh every 4 minutes | Negligible |
| Android on Wi-Fi | The same | Estimated 0.03% to 0.15% of a 15 Wh battery a day (below) |
| Android on mobile data | Nothing new: credentials only, allocation on demand | No new radio wake-ups; a session there costs one extra relay round trip |

The control service keep-alive (60 to 270 s, adaptive) and the tunnel keep-alives are unchanged.

**The Wi-Fi estimate.** A STUN binding every 25 s is 3,456 small exchanges a day (about 100 bytes each way). On
Wi-Fi in power-save mode a small exchange costs roughly 5 to 20 mJ (the radio wakes, sends, waits for the reply
and dozes again; published Wi-Fi power-save measurements put a short wake in this range). That is 17 to 70 J a
day, 5 to 19 mWh, or 0.03% to 0.15% of a 15 Wh phone battery. This is an estimate: the emulator has no real
radio, and it was not measured on a phone. While Android holds the phone in Doze the app's network is paused and
the keep-alive does nothing; the first connection after Doze then allocates again (one relay round trip), which
measure C covers.

**What was traded.** Mobile data gets no warm allocation, so a session that starts there needs one more relay
round trip (about 75 ms to relay-sg) than on Wi-Fi, in exchange for no new radio wake-ups. The keep-alive is
25 s rather than 60 to 120 s because home routers commonly expire UDP mappings after 30 to 60 s, and a lapsed
mapping turns the warm allocation into a cold one.

## Results

Emulator bridgey-api36 and the Mac test instance, both on the personal Mac in India; public control service and
relay-sg; 20 runs each unless noted. "Before" is beta 13 (rr/main 0aed845) plus the timing marks only; "after" is
this branch. The personal Mac was busy throughout (load average 8 to 11, another app using about 5 cores).

| Measure | Before: median | Before: p95 | After: median | After: p95 |
| --- | --- | --- | --- | --- |
| **A. Cold start** (process start to the phone's session on the relay) | 2.35 s | 3.29 s | **1.01 s** | 1.65 s |
| **B. Failover** (LAN dropped to the session on the relay on both devices) | 1.49 s | 1.53 s | **0.61 s** | 0.66 s |
| **C. Warm reconnect** (foreground to the session back) | no session within 40 s in 5 of 5 runs | | see below | |

How the harness differs from the 2026-10-30 beta measurements (3.4 s for B, about 4 s for A): the LAN drop is
seen at once (the Mac test instance closes the LAN session, so the phone gets the close immediately), and turning
relay only on no longer restarts the Mac's control service connection (a test artifact; only the UDP paths
change). The before numbers above use the same harness as the after numbers.

### A. Cold start: median waterfall (ms since the phone's process started)

| Step | Before | After |
| --- | --- | --- |
| Core started (Application.onCreate) | 111 | 92 |
| Control service: DNS, TCP, TLS | 137, 281, 818 | 121, 186, 288 |
| Signed in and registered | 1,054 (upgrade, challenge, signature, auth, welcome, register) | 331 (one flight after TLS) |
| Offer sent / answer received | 1,109 / 1,201 | 342 / 422 |
| First pair answers | 1,412 | 596 |
| Pair selected | 1,888 (300 ms window, then a nomination round trip) | 596 (aggressive nomination) |
| QUIC up (the phone is the QUIC server here) | 2,194 | 761 |
| Session authenticated | **2,354** | **1,014** |
| The left-behind allocation | 437 on relay-sg; the next session's relay moved to relay-eu | ended 79 ms after sign-in; the warm allocation back on relay-sg about a second later |

The emulator's TCP and TLS to the control service at a cold start take 65 to 500 ms (TLS was 500 ms in most
before runs and in the slow after runs); the same core on the Mac does TCP in 35 ms and TLS in 39 ms. The three
after runs above 1.5 s are that, plus one run whose QUIC handshake lost a packet and waited for QUIC's probe timer
(the first one fires after about a second, since QUIC assumes a 333 ms round trip until it measures one).

### B. Failover: median waterfall (ms since the Mac dropped the LAN)

| Step | Before | After |
| --- | --- | --- |
| Both sides see the drop | -9 (phone), 2 (Mac) | -9, 2 |
| Race and offer | 33 (phone), 36 (Mac): after the re-registration answered, which ended the 1.5 s grace | -3 (phone), 2 (Mac): at once |
| Relay ready | grant 72 to 100, allocation 223 (Mac), the phone's after the 1 s grace (1,221 when used) | already allocated (warm) |
| First pair answers | 641 (Mac), 668 (phone) | 184 (phone), 232 (Mac) |
| Pair selected | 1,028 / 1,114 | 184 / 232 |
| QUIC up | 1,269 (Mac) / 1,335 (phone) | 392 / 456 |
| Session authenticated | 1,430 (Mac) / **1,492** (phone) | 550 / **612** |

The final B set (20 of 20 between 0.59 and 0.76 s) ran on the last build. Two earlier sets on intermediate builds
had clusters of three or four runs at 2.4 to 13 s while the personal Mac's load average was 16 to 24: the pair
was selected in about 0.3 s as usual, then QUIC and the session waited out retransmit timers, which points at lost
packets on the way (the emulator's user-mode network under load is the likely place, but that was not proven);
a third set on the same code at load 8.8 had none, as did the final one.

After the drop: one signal each way (about 40 ms each through the control service), one relay round trip for the
check, one for QUIC and one and a half for the Bridgey handshake (the relay round trip between the two devices is
about 150 ms). That is the floor from section "The floor".
