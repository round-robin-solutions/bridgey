# Connect anywhere: deploy runbook

Status: **not deployed.** Everything below needs Rahul's go-ahead first. It covers the control
service (`bridgey-rendezvous`) and the three relays (coturn). The design is in
[connect-anywhere.md](connect-anywhere.md); what phase 1 built is in its "Phase 1 as built" section.

Until this runs, the apps reach each other away from home only over learned LAN and private-network
(Tailscale) addresses. The relay and the control service were tested on rr-dev-1 only, bound to the
tailnet (`server/local/live-test.sh`).

## What needs Rahul's approval

| # | Change | Where | Why it needs approval |
| --- | --- | --- | --- |
| 1 | DNS-only A record `connect.roundrobin.in` to rr-web (80.225.252.87) | Round Robin Cloudflare zone | Public DNS |
| 2 | Dokploy project "Bridgey", app `bridgey-rendezvous` on rr-web, image built on rr-dev-1 | Round Robin Dokploy | A new production app |
| 3 | Host nginx vhost and certbot certificate for `connect.roundrobin.in` | rr-web | Production host change |
| 4 | Relay `bom` on oracle: compose stack in the personal Dokploy, UDP 3478 and 50000-59999 open in the OCI security list and host iptables | oracle | Opens public ports (oracle is unreachable right now) |
| 5 | Relay `sxb` on rr-dev-1: register rr-dev-1 as a Dokploy deploy server (it stays the build server), UDP 3478 and 60000-61999 open, relay capped at 300 Mbit/s and lowest traffic class | rr-dev-1 | Rahul's decision 4 says deploy server; firewall and `tc` changes |
| 6 | Relay `sin` on rb-vps: reinstall Dokploy's agent as a deploy server, UDP 3478 and 60000-61999 open | rb-vps | Same |
| 7 | DNS-only records `relay-in` (A), `relay-sg` and `relay-eu` (A and AAAA) `.roundrobin.in` | Round Robin Cloudflare zone | Public DNS |
| 8 | One TURN secret per relay in the vault (`Keychain/Bridgey Connect`) and in Dokploy | Vault, Dokploy | Secrets |
| 9 | `DEPLOYMENT.md`: the new app, the compose stacks, coturn under "Third-party pinned images"; rb-vps's retirement cancelled (Rahul, 2026-10-25) | PA | Record of the estate |

Not in phase 1: Cloudflare Realtime TURN (no key, no spend), TURN over TLS on 443, the ops dashboard
and alerts, the relay agent's allowance caps. The pool runs on the three own relays only.

## 1. Secrets

On rr-dev-1, never echoing the values:

```bash
umask 077
for r in bom sin sxb; do openssl rand -hex 32 > ~/.config/bridgey-connect/turn-$r; done
```

Copy each into `Keychain/Bridgey Connect` (Field `TURN_SECRET_BOM` and so on, values in backticks,
`*Added: YYYY-MM-DD*`), then into Dokploy: the control service gets all three (`TURN_SECRET_BOM`,
`TURN_SECRET_SIN`, `TURN_SECRET_SXB`), each relay stack only its own (`TURN_SECRET`). Secrets are hex
so the relay entrypoint can render them safely. Rotate yearly: switch the control service first, then
restart each relay (a few seconds; grants last 2 hours).

## 2. The control service on rr-web

- **Image:** `server/rendezvous/Dockerfile`, context the repository root. The Rust build runs natively
  on rr-dev-1 and cross-compiles a static musl binary for arm64 (`FROM --platform=$BUILDPLATFORM`,
  cargo-zigbuild), so the build needs BuildKit; check the Dokploy build log shows `TARGETARCH=arm64`.
  The runtime image is `scratch` with the binary and the settings file, about 6 MB, user 65534.
- **Dokploy app:** project "Bridgey", app `bridgey-rendezvous`, repository `round-robin-solutions/bridgey`
  branch `rr/main` (after the merge), build server `rr-dev-1-builder`, Dockerfile
  `server/rendezvous/Dockerfile`, registry GHCR (`registryId`, not a username: DEPLOYMENT.md rule 4).
  1 replica, 256 MiB, 0.5 CPU, port 8080, swarm health check
  `["CMD", "/bridgey-rendezvous", "--health"]`, start-first updates. Clients reconnect with jitter.
- **Environment:** the three `TURN_SECRET_*` only. Every other setting is in
  `server/rendezvous/bridgey-rendezvous.toml` (listen, limits, relays and their URLs and penalties).
- **No volume:** phase 1 keeps presence and rate limits in memory. Nothing to back up or migrate.
- **nginx on rr-web** (`/etc/nginx/sites-available/connect.roundrobin.in.conf`, then certbot webroot):

  ```nginx
  server {
      listen 443 ssl;
      server_name connect.roundrobin.in;
      # ssl_certificate lines from certbot
      client_max_body_size 64k;
      location /.well-known/acme-challenge/ { root /var/www/certbot; }
      location = /v1/ws {
          proxy_pass http://127.0.0.1:<published port>;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
          proxy_set_header X-Real-IP $remote_addr;
          proxy_read_timeout 900s;
          proxy_send_timeout 900s;
      }
      location ~ ^/(health|health/ready|v1/status)$ {
          proxy_pass http://127.0.0.1:<published port>;
          proxy_set_header X-Real-IP $remote_addr;
      }
      location / { return 404; }
  }
  ```

  DNS-only (grey cloud): Cloudflare's proxy closes idle WebSockets after about 100 s, which would
  force phones to send keep-alives every 45 s.
- **Check:** `curl -s https://connect.roundrobin.in/health/ready` says `ready`, and
  `curl -s https://connect.roundrobin.in/v1/status` lists the three relays with `"configured":true`.

## 3. The relays

One Dokploy compose app per host from `server/relay/compose.yml` (coturn 4.18.0 pinned by digest,
host network, 1 CPU and 512 MiB by default, the secret rendered into a tmpfs, never on disk or a
command line). Per host:

| Relay | Host | Dokploy | Environment | Ports to open (UDP) |
| --- | --- | --- | --- | --- |
| `bom` | oracle | personal Dokploy | `EXTERNAL_IP=92.4.95.94/<private address>`, `MIN_PORT=50000`, `MAX_PORT=59999`, `TOTAL_QUOTA=2000`, `BPS_CAPACITY=125000000`, `COTURN_CPUS=3.0` | 3478, 50000-59999 (OCI security list and host iptables) |
| `sin` | rb-vps | deploy server (agent reinstalled) | `EXTERNAL_IP=15.235.211.41`, `MIN_PORT=60000`, `MAX_PORT=61999`, `TOTAL_QUOTA=300`, `BPS_CAPACITY=25000000` | 3478, 60000-61999 |
| `sxb` | rr-dev-1 | deploy server (still the build server) | `EXTERNAL_IP=109.123.243.231`, `MIN_PORT=60000`, `MAX_PORT=61999`, `TOTAL_QUOTA=300`, `BPS_CAPACITY=37500000`, `COTURN_CPUS=1.5` | 3478, 60000-61999 |

The template denies relaying to private, carrier-NAT, tailnet, Docker and link-local ranges, has no
TCP relay and no admin CLI. On rr-dev-1 also put the relay ports in the lowest `tc` class so builds
and pushes always win (spec 9.10); that script is still to write.

Check each relay from another host: a STUN binding to `relay-xx.roundrobin.in:3478` answers, and a probe
pair (`rust/core/examples/probe.rs` with `--relay-only` and the production control URL) connects
through it.

## 4. Turning it on in the apps

`rr-edition.properties` already has `CONNECT_CONTROL_URL=wss://connect.roundrobin.in/v1/ws`, so the
next build after the deploy reaches it. Before that, a build with the setting on shows "Reaching the
Round Robin service" and keeps working over learned LAN and Tailscale addresses.

Test on real devices: Rahul's phone on mobile data and the personal Mac at home, both with "Connect
away from home" on; the device page shows "Relay (Mumbai)" or "Direct"; then back on the same Wi-Fi it
moves to LAN within a minute.

## Rollback

- Control service: stop the Dokploy app. Apps fall back to learned LAN and private-network addresses;
  relayed sessions end within 2 hours.
- A relay: stop its compose app (or set `enabled = false` for it in the settings file and redeploy the
  control service). New sessions use the other relays.
- DNS: delete the records. Nothing else depends on them.
