# Reconnect reliability: what each mechanism costs and buys

Bridgey used to reconnect only through Bonjour/NSD (local network discovery) and only from the
side with the lower device id. On 26 October the phone's link to the work Mac reset at 02:56 and
nothing redialled until Bridgey on the Mac was restarted at 09:33. These mechanisms fix that.
Every value below is a named constant: `ReconnectPolicy` in
`macos/Sources/BridgeyMac/Reconnect.swift` and `android/app/src/main/java/dev/bridgey/android/Reconnect.kt`.

Phone costs are estimates, not measurements: no phone was attached while this was written. The
overnight test at the end of this page is how to measure them. The reasoning uses round numbers:
a Wi-Fi packet that wakes a sleeping phone keeps it awake for about 0.1 to 0.2 s at about 150 mA,
so roughly 0.005 to 0.01 mAh per wake-up. The OnePlus 11 battery is 5,000 mAh, so 1 mAh is 0.02%.

## 1. Retrying known addresses, with backoff

Each side remembers where every trusted device was last reachable (from discovery, from its own
dials and from the far end of connections the other device made) and keeps dialling those
addresses while the device is away, whichever side dialled before.

| | |
|---|---|
| Benefit | Recovery no longer needs discovery to work. After a drop: tries at 2 s, 5 s, 15 s, 30 s, then every 60 s for an hour, then every 10 minutes. The 02:56 case would have reconnected as soon as the phone could take a connection, within a minute at worst. |
| Phone battery | Timers hold no wake lock, so they do not wake a sleeping phone; attempts ride on wake-ups that happen anyway. One attempt is one TCP SYN plus, if the Mac is gone, up to three ARP broadcasts: about 1 ms of CPU. The real cost is the Mac dialling a phone whose Bridgey cannot answer (frozen by the phone's battery manager): each SYN can wake it. First hour: about 64 wake-ups, 0.3 to 0.6 mAh. After that 6 an hour: about 1 to 1.5 mAh a day (0.03%). |
| Data | About 100 bytes per attempt. Under 50 KB a day per device, local network only. |
| Network chatter | While the peer is away: 60 SYNs an hour in the first hour, then 6 an hour, per device and per side. |
| Risks | A stale address may now belong to another device. The handshake fails safely because identities are pinned; a reconnect also names the device it wants (`targetDeviceId`), so another Bridgey declines quietly instead of showing a pairing code, and a dial answered by the wrong device closes at once. Both sides dial at once: the session registry keeps the socket dialled by the lower id on both ends, in any order, and closing the loser never reports a disconnect (unit tested). Off the home network the old address is not dialled at all: only addresses on a network the device is on now (no mobile data wake-ups). |
| Default | On, as above. Knobs: `fastDelays`, `fastPhase` (1 h), `slowDelay` (10 min). |

## 2. Periodic discovery restarts while a device is away

Every 5 minutes, for the first hour of a disconnection, each side stops and restarts discovery
and announces itself again. A long-running mDNS browse slows its queries to about one an hour
(RFC 6762), so a device that comes back quietly can stay invisible; a restart asks again at once.

| | |
|---|---|
| Benefit | Finds a device whose address changed, or whose announcement was missed, within 5 minutes during the first hour. Discovery finding a trusted device triggers a dial at once. |
| Phone battery | One restart is about 8 to 12 multicast packets and a few ms of CPU in the system's mDNS service. 12 restarts in the first hour, then none: well under 0.1 mAh. |
| Data | About 1 KB per restart. |
| Network chatter | 8 to 12 multicast packets per restart per device. Multicast reaches every device on the Wi-Fi, so it stops after an hour. |
| Risks | mDNS storms on big networks: bounded to one restart per device per 5 minutes, for an hour. Android NSD allows each app a small number of active requests (about 10) and fails extra ones: Bridgey keeps at most a registration, a browse and one resolve, and stops before it starts again. A quick re-register could clash with its own old name: there is a 1 s gap. |
| Default | Every 5 minutes for 1 hour. Knobs: `discoveryRestartInterval`, `discoveryRestartWindow`. |

## 3. Restarts on wake, network change, screen on and Doze exit

These are the moments a dropped device is likely reachable again. The backoff resets to "try
now" and discovery restarts. Events within 2 s collapse into one recovery (at most 10 s late).

| | |
|---|---|
| Benefit | Reconnects in about 2 to 4 s after the Mac wakes, Wi-Fi returns, or the phone screen turns on, instead of waiting up to 10 minutes. |
| Phone battery | Screen on happens dozens of times a day, so on the phone screen on and Doze exit act only while a trusted device is disconnected. Network changes always re-announce the phone. Event-driven restarts are at least 30 s apart. Each is the cost of one restart (above) plus one dial per disconnected device. |
| Data | About 1 KB per event. |
| Network chatter | One restart and one SYN per disconnected device per event. |
| Risks | A flapping Wi-Fi: covered by the 2 s debounce and the 30 s spacing. |
| Default | On. Knobs: `eventQuietPeriod`, `eventMaxWait`, `eventRestartSpacing`. |

## 4. Heartbeat (unchanged: ping every 10 s, link dead after 30 s silent)

| | |
|---|---|
| Benefit | A link that died silently is noticed within 30 to 40 s, and the reconnect starts. Checked on both sides with several devices: each session has its own timer and its own silence clock. |
| Phone battery | This is the largest steady cost and it predates this change: while connected, the Mac's ping arrives every 10 s and wakes a sleeping phone, about 360 wake-ups an hour, roughly 2 to 4 mAh an hour (up to about 1.5% a day). |
| Data | About 150 bytes per ping and pong, about 50 KB an hour. |
| Network chatter | 4 small packets every 10 s per connected pair. |
| Risks | Lengthening it means slower detection, and upstream clients expect a ping within 30 s. |
| Default | Unchanged. Worth a later "screen off" heartbeat of about 25 s from the Mac, if the overnight battery numbers show it matters. |

## 5. Wi-Fi lock (setting, off by default, Android 13 and older only)

| | |
|---|---|
| Benefit | Keeps Wi-Fi out of power save, so packets arrive with less delay. It does not keep a TCP link alive: the access point holds packets for a phone in power save. |
| Phone battery | High: Wi-Fi stays fully awake, roughly 20 to 50 mA extra, 150 to 400 mAh a night (3 to 8%). |
| Data | None. |
| Network chatter | None. |
| Risks | From Android 14 a high-performance lock is turned into a low-latency lock, which works only with the screen on and Bridgey in front, so on the OnePlus 11 (Android 16) it would do nothing at night. The setting is hidden there. |
| Default | Off; shown only on Android 13 and older, under This phone. |

## 6. Battery optimisation exemption (asked once, and in Settings)

| | |
|---|---|
| Benefit | Probably the fix for the drop itself. Stock Android already lets a foreground service use the network in Doze, so the 02:56 reset (a TCP RST, sent while the phone's Wi-Fi was up) points at the phone's own battery manager freezing Bridgey or cutting its sockets about 33 minutes after the screen went off, which is when deep Doze starts. On OnePlus the exemption is the "allow background activity" switch. |
| Phone battery | Little: Bridgey holds no wake locks, so the exemption mostly stops the system from freezing it. |
| Data | None. |
| Network chatter | None. |
| Risks | Google Play limits this request to apps whose core function needs it; Bridgey is distributed outside Play, and a companion link to a paired device is an accepted use. |
| Default | Asked once after the first connection; a row under Settings, This phone, shows the state with Allow, and opens App info for OnePlus's own switch. |

## Logs and diagnostics

- Mac: `/usr/bin/log show --last 12h --predicate 'subsystem == "in.roundrobin.bridgey"'`. States,
  reasons, counts and 8-character device ids are public; names, files and addresses are not.
- Android: `adb logcat -s Bridgey`.
- Both apps keep connection events on disk (last 1,000) and export them with diagnostics:
  drop reason, each dial (attempt, address source, last octet only), discovery restarts, wake,
  network, screen and Doze events, and on Android the power state at each drop (Doze, screen,
  battery saver, standby bucket, exemption).
