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
| Foreground after sleep | The control connection was trusted however long it had been quiet, so signals could sit behind TCP retransmits | Replaced at once when it has been quiet for 25 s and a peer is waiting |
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
| Android on Wi-Fi | The same | One small packet each way every 25 s while the Wi-Fi radio is associated: estimated well under 0.5% of a day's battery (see Results for the estimate) |
| Android on mobile data | Nothing new: credentials only, allocation on demand | No new radio wake-ups; a session there costs one extra relay round trip |

The control service keep-alive (60 to 270 s, adaptive) and the tunnel keep-alives are unchanged.

## Results

To be filled with the 20-run medians and 95th percentiles for A, B and C before and after, and the waterfalls.
