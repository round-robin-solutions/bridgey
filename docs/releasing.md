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

## Bridgey by Round Robin

Versions: 1.0.0, 1.0.0-beta.2, 1.0.0-nightly.YYYYMMDD ([rr-edition.md](rr-edition.md#versions)). Every beta
and stable release is in [CHANGELOG.md](../CHANGELOG.md).

```sh
python3 scripts/rr/cut-release.py beta --notes-file notes.md --push   # next beta of EDITION_NEXT_VERSION
python3 scripts/rr/cut-release.py promote --push                      # Stable, only when Rahul says so
```

Leave out `--push` to see the tag, the notes and the changelog entry first. Pushing the tag starts the RR CI
release, which builds, publishes and updates the feeds ([rr-edition.md](rr-edition.md#releasing)).

### Update all

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

### Windows

Every release and nightly can carry the Windows app: `Bridgey-RR-<version>-windows-x64.zip` and `...-arm64.zip`, in
SHA256SUMS, with a CycloneDX SBOM (`...-Windows.sbom.cdx.json`: the Rust crates `bridgey_core.dll` links for the
Windows target, from `cargo tree`, and the app's NuGet packages) and in the provenance file.

- **Where they're built:** a Windows runner, never rr-dev-1. Nightlies: the `windows` job of
  `.github/workflows/rr-ci-nightly.yml`, with the time the other jobs use. Betas and Stable: the RR CI
  `release-windows` (and `nightly-windows`) task runs `scripts/rr/ci-release-windows.ps1` and hands its folder to the
  publishing job like the Mac job's; `scripts/rr/ci-release.sh` checks the revision and the version name. Without a
  Windows build, a release goes out as before and the feed keeps its previous Windows entry.
- **The feed:** each channel feed gains a `windows` entry next to `android` and `macos` (which keep their fields and
  the legacy names 0.x apps read): `version`, `build` (the Windows job's own build time), `minimumOsBuild`, and per
  architecture `url`, `sha256`, `size` and `edSignature`, an Ed25519 signature made with the Sparkle key that signs the
  Mac's updates.
- **The app:** checks its channel's feed when it opens (at most every six hours, Settings > Updates can turn that off)
  and from Settings. It trusts only downloads under `UPDATE_ASSET_URL_PREFIX`, checks the size, SHA-256 and signature
  (`rust/client/src/update.rs`) before installing, and asks first. Installing hands over to the unpacked update, which
  replaces the app's files once Bridgey has closed and opens it again. Builds aren't Authenticode-signed yet, so the
  release key's signature is the check that a download is ours.

A dry run with Windows: put the two zips, `release.env`, `windows.build-info` and `windows-rust-dependencies.txt` in a
folder (the Windows job's artifacts), then

```sh
scripts/rr/release.sh nightly --skip-android --skip-macos --windows-artifacts <folder>
```

leaves the release in `dist/<tag>` without publishing.
