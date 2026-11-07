# Connect Bridgey through Tailscale

Use Tailscale when your devices already share a private network, or when you want
to manage that network yourself. Bridgey uses the official Tailscale app installed
on each device; it does not include another VPN engine or ask for your Tailscale
password.

Bridgey's **Connect away from home** service remains a separate option. It can
connect paired devices directly or through an encrypted Round Robin relay, with
no Tailscale account or phone VPN required. You can keep both methods available.
Being on the same Tailscale network does not pair devices or grant Bridgey
permissions.

## Set up Tailscale once

1. Open Bridgey's **Connect away from home** settings or **Pair a new device**.
2. Choose **Get Tailscale** if it is missing, or **Open Tailscale** if installed.
   Use the official [Mac](https://tailscale.com/download/mac) or
   [Android](https://tailscale.com/download/android) app. If you already use
   Tailscale, keep that installation and account.
3. In Tailscale, sign in and connect each device to the same Tailscale network.
   Complete any device approval required by your network administrator. Android
   asks for VPN permission in its own system dialog.
4. Return to Bridgey and check again. Open Bridgey's pairing screen on the other
   device, or choose **Allow pairing** there.

Bridgey opens Tailscale only when you choose the action. It does not sign you in,
switch accounts, change VPN settings or disconnect another VPN for you.

## Pair your devices

On the Mac, **Pair a new device** lists reachable Bridgey devices on your
Tailscale network alongside nearby devices. Tailscale entries are labelled
**On your tailnet**. Choose the device and compare the code on both screens.

On Android, the official Tailscale app does not expose a peer list or signed-in
status to Bridgey. The setup row therefore reports whether the app can be opened,
without treating installation or a generic VPN as proof of a Tailscale connection.
You can start pairing from the Mac, or enter the other device's Tailscale name
(MagicDNS) or address in Bridgey's existing address field. Find that name or
address in Tailscale. A reachable Bridgey session is checked separately.

New devices paired over a Tailscale address start restricted. After verifying
the device, choose **Trust as my device** in its Bridgey settings, then choose
what to share. A Tailscale sign-in never bypasses Bridgey's code comparison or
per-device permissions. Servers retain their separate grant controls.

## If the device does not appear

- Check Tailscale is connected on both devices and both belong to the same
  Tailscale network. An installed app can still be signed out, stopped or waiting
  for device approval.
- Open Bridgey on both devices and allow pairing on the receiving device. On the
  Mac, use **Look again** to refresh discovery.
- Try the other device's Tailscale address. MagicDNS names require working DNS;
  using the address avoids that dependency. Network access rules must permit
  Bridgey's pairing port, TCP `42458`.
- Android normally permits one active VPN. If another VPN is active, make the
  choice in Android or Tailscale; Bridgey does not change it automatically.
- If the Mac has a command-line-only Tailscale installation, finish sign-in and
  connection there using the [official CLI guide](https://tailscale.com/kb/1080/cli).
  Bridgey can read its status, but there is no Tailscale app window to open.

The Bridgey service switch controls Bridgey's own away-from-home service.
Independent Tailscale connections and same-Wi-Fi pairing remain available. To
disconnect Tailscale itself, use Tailscale.

Technical details: [tailnet pairing and trust](mesh-and-codes.md#pairing-over-the-tailnet),
[Connect anywhere](connect-anywhere.md),
[supported Mac variants](https://tailscale.com/kb/1065/macos-variants).
