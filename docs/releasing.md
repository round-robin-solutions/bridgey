# Releasing Bridgey

Bridgey publishes a signed Android APK and a macOS DMG from tags matching `v*`.
Without Apple secrets the Mac build uses an ad-hoc signature; when those
secrets are configured, the same workflow adds Developer ID signing and
notarization.

## Android signing

Create one long-lived release keystore and keep two offline backups. The same
key must sign every direct-download APK update.

Add these repository secrets under **Settings → Secrets and variables →
Actions**:

- `ANDROID_KEYSTORE_BASE64`: base64 text of the `.jks` file
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

Google Play is optional for GitHub releases. If Bridgey is later published on
Google Play, enroll in Play App Signing and keep a separate upload key.

## macOS signing and notarization

Enroll in the Apple Developer Program and create a **Developer ID Application**
certificate. Export the certificate and private key from Keychain Access as a
password-protected `.p12` file.

Create an App Store Connect API key with access suitable for notarization, then
add these repository secrets:

- `MACOS_CERTIFICATE_BASE64`: base64 text of the `.p12`
- `MACOS_CERTIFICATE_PASSWORD`
- `MACOS_SIGNING_IDENTITY`: full `Developer ID Application: … (TEAMID)` name
- `APPLE_API_KEY_BASE64`: base64 text of the `AuthKey_….p8` file
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`

The workflow imports the certificate into a temporary keychain, signs Bridgey
with Hardened Runtime and a secure timestamp, submits the DMG through
`notarytool`, staples the accepted ticket, and verifies it with Gatekeeper.

## Publish

1. Update Android `versionName`/`versionCode` and macOS bundle versions.
2. Commit and push `main`; wait for the Build workflow to pass.
3. Create and push an annotated tag such as `v0.1.0`.
4. The Release workflow creates the GitHub Release and attaches installers and
   checksums.

Release notes should retain the acknowledgement: “Built with the assistance of
OpenAI Codex.”

## Bridgey by Round Robin: Update all

The edition releases with `scripts/rr/release.sh` (see [rr-edition.md](rr-edition.md#releasing)).
Update all on a device starts each connected device's own updater, so a release reaches it only
once its channel feed is published. Build numbers (Android `versionCode`, macOS
`CFBundleVersion`) must grow with every release on every channel: a device compares the build it
was installing with the build it restarts on, and reports "Update didn't apply" when they match.

### After publishing: update every device

Devices with **Update all devices automatically** on find a new build on their own within 30 minutes
on Beta and Nightly (6 hours on Stable). To roll it out at once, the last release step is:

```sh
ssh <mac> '"/Applications/Bridgey by Round Robin.app/Contents/MacOS/BridgeyMac" --update-all'
```

Run it on one reachable Mac that is on the channel you published, after the channel feeds are live
(RR CI's release run has finished). It checks now, then runs Update all on that Mac as an automatic
run: its connected phones update first, the Mac restarts last after a 60-second countdown with Later.
The command hands the request to the running app (starting it if needed), prints the plan, then
`Result: started`, `Result: up to date (...)` or `Result: blocked because ...` (for example a call in
progress on a phone), and exits 0, 3 or 2 (1 for anything else). Blocked means nothing was touched:
run it again later, or leave it to the automatic checks. Other Macs update through a phone's
automatic run or their own checks, because Macs are not connected to each other. Add `--json` for
the raw answer lines.
