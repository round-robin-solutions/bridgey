# Set up the bridgey agent on a server

`bridgey` lets scripts and AI agents on a server reach your phone: notify you, ask you to approve
something, ring the phone, read its battery, read one-time codes, send files. Each server is its own
paired device, and the phone gives it nothing until you switch each permission on.

What you need: Bridgey by Round Robin on the phone with **Connect away from home** on (it is on by
default), and for codes, the Mac app with **Codes from messages** on, or a server that detects codes
(section 6) for when no Mac is awake.

## 1. Install

Linux (x86_64 or aarch64) and macOS:

```sh
curl -fsSL https://github.com/round-robin-solutions/bridgey/releases/download/cli-v0.2.0/install.sh | sh
```

It downloads the build for this machine, checks it against `SHA256SUMS`, and puts `bridgey` in
`~/.local/bin`. No root needed. The phone needs Bridgey by Round Robin 0.10.0-rr.1 beta 21 or newer.

Check it: `bridgey --version`.

## 2. Pair with the phone

```sh
bridgey pair
```

The name the phone shows is this server's pretty hostname (`hostnamectl --pretty`); pick another with
`bridgey pair --name "Contabo Europe agent"`.

1. The terminal shows a QR code and a `bridgey://pair#...` link. It works once, for 10 minutes.
2. On the phone: Bridgey, **Devices**, **Pair a device away from this network**, then scan the code or
   paste the link.
3. Both show a six-digit code. If they match, type `y` in the terminal and tap **Confirm** on the
   phone. There is no way to skip this.

The phone then opens the new device's **Devices and permissions** page with everything off.

## 3. Keep it running

```sh
bridgey service install
```

This writes and starts a systemd user service (`~/.config/systemd/user/bridgey.service`; on macOS a
launchd agent), which keeps the connection to the phone warm and restarts after a reboot. On a server,
also run `loginctl enable-linger $USER` once, or the service stops when you log out.

Without the service, the first command starts a background agent that stops after 10 minutes unused.
Commands work either way; with the service they answer faster.

## 4. Check

```sh
bridgey doctor
bridgey grants
```

`doctor` checks the binary, file permissions, the service, the Round Robin control service, the
relays, the clock and the route to each paired device. Every line should say `ok`.

`grants` lists what the phone allows this server, with times:

```
  Send you notifications   On until 15:40 UTC (for 1 hour)
  Read codes               Off
```

## 5. Turn permissions on (on the phone)

Bridgey, **Devices**, this server, **Permissions**. Each switch asks **How long?**: For 1 hour, Today,
7 days, or Until I turn it off.

| Permission | Lets the server |
| --- | --- |
| Send you files | send files to `Download/Bridgey/<server name>` |
| Set your clipboard | put text on the phone's clipboard |
| Ask for your clipboard | ask for it; you tap Send each time |
| Send you notifications | post in "Agent messages" |
| Ask you questions | post questions with answer buttons in "Agent questions" |
| Ring this phone | ring it (stops by itself after 60 seconds) |
| See battery | read the level and charging state |
| Read codes | read one-time codes your Mac found in messages and mail |

**Codes** come from your Mac: it finds them in the SMS and mail notifications the phone shows it, and
the phone hands them to servers with Read codes on. So the Mac must be awake and connected to the
phone, with Codes from messages on. Every code a server reads shows in the **Activity** tab, on the
phone and on the Mac. Codes are never written to disk or logs.

A server can ask for a permission: `bridgey grants request codes --note "for the deploy login"`. It
shows as **Waiting for you** on the phone.

Then, for example:

```sh
bridgey notify "Backup finished" "rr-web, 3.2 GB"
bridgey ask "Deploy rr-web?" -o approve=Approve -o deny=Deny --fail-unless approve && ./deploy.sh
bridgey codes --wait 2m --service "HDFC Bank" --json
bridgey battery
bridgey ring
```

Add `--json` to any command for one JSON object; exit codes are in [agent-cli.md](agent-cli.md#5-exit-codes).

## Pair with a Mac or another server over the tailnet

On a server that is on your Tailscale tailnet, `bridgey tailnet` lists the Bridgey devices there.

- **With a Mac:** on the Mac, open Settings > Devices > Pair a new device and tap Allow pairing (or open Bridgey's
  pairing screen); then `bridgey pair --to <mac's tailnet name>`. Or the other way round: `bridgey pair --allow` here,
  then on the Mac pick this server from "On your tailnet" (or type its tailnet name) and tap Pair.
- **With another server:** `bridgey pair --allow` on one, `bridgey pair --to <its tailnet name>` on the other.

Both ends show the same six-digit code; confirm it on both. The Mac gives this server nothing (every feature stays
off), and the phone's grants are not affected.

## 6. Detect codes (optional)

A server can read one-time codes for the phone when no Mac is reading, with the same model, prompt and
guard as the Mac ([mesh-and-codes.md](mesh-and-codes.md)). It needs about 300 MB of memory while a code
is being read (the model unloads after 15 idle minutes) and 253 MB on disk.

1. A build with the model runner. The release tarballs do not carry it yet; on the server:
   `cargo build --release -p bridgey-cli --features detect` in `rust/` (needs cmake, a C++ compiler and
   libclang; on hosts where bindgen cannot find `stdbool.h`, set
   `BINDGEN_EXTRA_CLANG_ARGS=-I/usr/lib/gcc/x86_64-linux-gnu/<version>/include`).
2. The model: `bridgey codes model download --accept-terms`. Without `--accept-terms` it prints the
   Gemma terms it asks you to accept. The file is checked against its SHA-256 before it is used.
   `bridgey codes model status` and `bridgey doctor` show where it stands; `bridgey codes model remove`
   stops it at once.
3. On the phone, open the server in Devices and switch **Detect codes** on, with a window. Within 30
   seconds the server says it can detect (the phone's map shows it), and from then on, while no Mac
   reads codes and some server has **Read codes** on, the phone sends this server each code text
   message, one at a time. Both sides log each one (`bridgey audit` shows `codes.detect`); the text is
   never stored or logged.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| `not granted` (exit 5) | Turn the permission on in the phone's Permissions tab; check with `bridgey grants`. A window may have ended. |
| `Could not reach` (exit 3) | Is the phone on, with Bridgey running and Connect away from home on? Run `bridgey doctor`. |
| `control service ... FAIL` in doctor | The server cannot reach `connect.roundrobin.in` on port 443; check the firewall or proxy. |
| `relay ... FAIL` in doctor | UDP to the relays is blocked. Allow outbound UDP 3478 and the relay port range. |
| `clock ... FAIL` | Turn on NTP (`timedatectl set-ntp true`). |
| `codes` warns "No Mac is reading codes" | Wake the Mac, check it is connected to the phone and that Codes from messages is on. |
| The service stops when you log out | `loginctl enable-linger $USER`. |
| The phone's pairing screen times out | Run `bridgey pair` again; an invite works once, for 10 minutes. |
| Logs | `journalctl --user -u bridgey` (macOS: `~/.config/bridgey/state/daemon.log`); `bridgey audit` lists what this server did. No message text, codes or clipboard content is ever logged. |

Files live in `~/.config/bridgey/` (keys and trust records are owner-only). `bridgey config list`
shows the settings.

## Uninstall

```sh
bridgey service uninstall
bridgey forget "<phone name>"      # then Forget this server on the phone too
rm -rf ~/.config/bridgey ~/.local/bin/bridgey
```

On the phone: Devices, this server, **Forget**. That deletes its trust, its pair secret and its grants.
