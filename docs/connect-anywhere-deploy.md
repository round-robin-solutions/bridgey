# Connect anywhere: deploy runbook

Status: **live since 2026-10-27** (Rahul: "Deploy all"), except the Mumbai relay on oracle, which is
down (steps below). Design: [connect-anywhere.md](connect-anywhere.md).

## What is live

| Part | Where | Dokploy (Round Robin, project "Bridgey" `hTDw6XwfUgGf-Nmo9Pm5T`) | Check |
| --- | --- | --- | --- |
| Control service | https://connect.roundrobin.in (WebSocket `/v1/ws`), rr-web | app `bridgey-rendezvous` (`AWhUiERgwLozVUZrH6aAz`, appName `bridgey-rendezvous-bls5vl`), Dockerfile `server/rendezvous/Dockerfile`, built on `rr-dev-1-builder`, GHCR, port 8080 published on the host as 18450 | `curl https://connect.roundrobin.in/health/ready` says `ready`; `/v1/status` lists the relays |
| Relay `sin` | relay-sg.roundrobin.in (15.235.211.41), rb-vps | compose `bridgey-relay-sg` (`sPkcw4V_FcPmlFYpGF8Bw`) on deploy server `client-update-portal-vps` (`FJI1IAi5SEF9_fDNfSV8J`, user ubuntu, port 2222) | `rust/core/examples/turn_check.rs` from another host |
| Relay `sxb` | relay-eu.roundrobin.in (109.123.243.231), rr-dev-1 | compose `bridgey-relay-eu` (`AUcFGMLUaVr3qgXixmTvn`) on deploy server `rr-dev-1-deploy` (`OJQHZTE0Gl8BYvaS7CcF9`, user `dokploy-deploy`) | same |
| Relay `bom` | relay-in.roundrobin.in, oracle | not deployed (oracle is down); no DNS record yet; no secret in the control service, so nobody is sent there | see "oracle" below |

All three Dokploy entries follow branch `rr/connect-anywhere` with auto-deploy on push (control
service: `rust/**`, `server/rendezvous/**`; relays: `server/relay/**`). **When the branch merges,
switch all three to `rr/main`.**

Secrets: vault `Keychain/Bridgey Connect` (one per relay). The control service has
`TURN_SECRET_SIN` and `TURN_SECRET_SXB`; each relay has its own as `TURN_SECRET`. Dokploy writes each
relay's environment to a `.env` next to the compose file on that host (folder mode 750, owned by
the deploy user).

How it was set up, so it can be repeated:

- **DNS:** DNS-only A records `connect`, `relay-sg`, `relay-eu` in the Round Robin zone (made with
  the personal Cloudflare global key, which is a member of the Round Robin account). No AAAA:
  phase 1 relays IPv4 only (`LISTENING_IP`).
- **rr-web:** nginx `sites-available/connect.roundrobin.in.conf` (enabled), certbot webroot cert
  `connect.roundrobin.in`, `access_log off`. nginx talks to the container on 127.0.0.1:18450, not
  through Traefik: Traefik's default read timeout would end idle WebSockets. The app reads
  `X-Real-IP` (`trust_proxy = true`).
- **rr-dev-1:** user `dokploy-deploy` (docker group, only the Dokploy key, sshd drop-in
  `61-dokploy-deploy.conf`) so the relay runs natively; the build user `dokploy-build` forces
  arm64. `/etc/dokploy/compose` (750) belongs to it, with ACLs on `/etc/dokploy` and `logs`.
- **rb-vps:** `/etc/dokploy/{compose,logs}` belong to root there, so the app folders were made by
  hand for user ubuntu (`/etc/dokploy/compose/bridgey-relay-sg-z2hi0b`,
  `/etc/dokploy/logs/bridgey-relay-sg-z2hi0b`, 750). A new compose app on rb-vps needs the same.
- **Firewalls (ufw, both relay hosts):** UDP 3478 and 61000-62999, commented "Bridgey relay". The
  relay range stays above Linux's ephemeral ports (32768-60999).

## oracle (relay-in, Mumbai) when it is back

1. Make sure the VM has its public IP and the personal Dokploy (or register it in the Round Robin
   Dokploy, which already lists it as `personal-oracle-staging`, `Q91K4rsiyqgzY0Fvxb_ax`). Create
   the app folders for the deploy user as on rb-vps if `/etc/dokploy/{compose,logs}` belong to root.
2. Open UDP 3478 and 61000-62999 in the OCI security list of its subnet and in the host iptables
   (before the final REJECT rule: `sudo iptables -I INPUT -p udp --dport 3478 -j ACCEPT` and the same
   for `61000:62999`, then `sudo netfilter-persistent save`).
3. Compose app `bridgey-relay-in` in project "Bridgey" from `server/relay/compose.yml`, environment:
   `TURN_SECRET` = `TURN_SECRET_BOM` from the vault note, `EXTERNAL_IP=92.4.95.94/<private address>`,
   `LISTENING_IP=<private address>`, `MIN_PORT=61000`, `MAX_PORT=62999`, `TOTAL_QUOTA=2000`,
   `BPS_CAPACITY=125000000`, `COTURN_CPUS=3.0`. Deploy.
4. DNS-only A record `relay-in.roundrobin.in` to 92.4.95.94.
5. From rr-dev-1: `TURN_SECRET=<bom secret> rust/target/release/examples/turn_check relay-in.roundrobin.in:3478`.
6. Only then add `TURN_SECRET_BOM` to the control service's environment and redeploy it. Until this
   step the control service skips `bom`, so clients are never sent to a dead relay.

## What needed Rahul's approval (approved 2026-10-27)

| # | Change | Where | Why it needs approval |
| --- | --- | --- | --- |
| 1 | DNS-only A record `connect.roundrobin.in` to rr-web (80.225.252.87) | Round Robin Cloudflare zone | Public DNS |
| 2 | Dokploy project "Bridgey", app `bridgey-rendezvous` on rr-web, image built on rr-dev-1 | Round Robin Dokploy | A new production app |
| 3 | Host nginx vhost and certbot certificate for `connect.roundrobin.in` | rr-web | Production host change |
| 4 | Relay `bom` on oracle: compose stack in the personal Dokploy, UDP 3478 and 61000-62999 open in the OCI security list and host iptables | oracle | Opens public ports (oracle is unreachable right now) |
| 5 | Relay `sxb` on rr-dev-1: register rr-dev-1 as a Dokploy deploy server (it stays the build server), UDP 3478 and 61000-62999 open, relay capped at 300 Mbit/s (coturn `bps-capacity`); the `tc` lowest traffic class is not set up yet | rr-dev-1 | Rahul's decision 4 says deploy server; firewall and `tc` changes |
| 6 | Relay `sin` on rb-vps: reinstall Dokploy's agent as a deploy server, UDP 3478 and 61000-62999 open | rb-vps | Same |
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
  `["CMD", "/bridgey-rendezvous", "--health"]`, **stop-first updates** (`updateConfigSwarm`). The
  port is published in host mode, so a start-first update can never place the new task ("host-mode
  port already in use") and the old container keeps running while Dokploy reports the deploy as
  done; that hid every redeploy from 2026-10-27 to 2026-10-30. Stop-first costs a few seconds of
  downtime; clients reconnect with jitter. After a deploy, `/v1/status` counters start from zero.
- **Environment:** the three `TURN_SECRET_*` only. Every other setting is in
  `server/rendezvous/bridgey-rendezvous.toml` (listen, limits, relays and their URLs and penalties, and
  `public_host`, which single-flight sign-ins sign: it must be the name clients connect to, because nginx
  forwards another Host). `/v1/status` counts `fastHellos`, `warmGrants` and `reclaimed` (docs/connect-anywhere-latency.md).
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
host network, 1 CPU and 512 MiB by default, the secret rendered into a tmpfs and never on a command
line). Per host:

| Relay | Host | Dokploy | Environment | Ports to open (UDP) |
| --- | --- | --- | --- | --- |
| `bom` | oracle | personal Dokploy | as in the oracle steps above | 3478, 61000-62999 (OCI security list and host iptables) |
| `sin` | rb-vps | deploy server | `EXTERNAL_IP` and `LISTENING_IP` `15.235.211.41`, `MIN_PORT=61000`, `MAX_PORT=62999`, `TOTAL_QUOTA=300`, `BPS_CAPACITY=25000000` | 3478, 61000-62999 |
| `sxb` | rr-dev-1 | deploy server (still the build server) | `EXTERNAL_IP` and `LISTENING_IP` `109.123.243.231`, `MIN_PORT=61000`, `MAX_PORT=62999`, `TOTAL_QUOTA=300`, `BPS_CAPACITY=37500000`, `COTURN_CPUS=1.5` | 3478, 61000-62999 |

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
