# Developer ID distribution readiness

This is the direct-download path. It does not satisfy the
[Mac App Store request](macos-app-store-audit.md). Apple enrollment is pending;
we haven't accessed an identity, certificate, provisioning profile or account.
Signing, notarization submission and release need their own approval.

## Existing tooling

| Tool | What the source already does |
| --- | --- |
| [macos/build-app.sh](../macos/build-app.sh) | With `MACOS_SIGNING_IDENTITY`, signs nested Sparkle helpers/frameworks, llama, the Rust dylib, the Share extension and the app in order, using Hardened Runtime and a secure timestamp. It verifies the resulting bundle with `codesign --verify --deep --strict`. This path does not sandbox the main app. |
| [macos/package-release.sh](../macos/package-release.sh) | Builds the app, creates a DMG, optionally submits that DMG with `notarytool --wait` when all three Apple API variables are populated, staples/validates the DMG, then creates the Sparkle ZIP and checksums. It does not staple the app inside the ZIP. |
| [scripts/rr/build-macos.sh](../scripts/rr/build-macos.sh) | The existing Round Robin signing path imports a self-signed identity into a disposable keychain. Self-signed success is not Developer ID or Gatekeeper proof. |
| [scripts/rr/build-macos-remote.sh](../scripts/rr/build-macos-remote.sh) | Takes the shared `/tmp/app-build-mac.lock` and restores it on exit. Its explicit credential forwarding is for Round Robin self-signing, not the Apple signing/notarization variables. Do not assume a local export reaches the remote worker. |

We inspected the scripts without executing them. They don't need a duplicate
or another CI service. Don't run `package-release.sh` casually with Apple
variables present: the existing script then contacts Apple's service automatically.

## Preparation after enrollment and review

Use the existing owned RR CI dispatcher and shared Mac lock. The following are
implementation/validation gates. Don't run the account-dependent steps now.

1. Provide the correct Developer ID Application signing identity through the
   approved RR CI secret mechanism, scoped to that build. Reject incomplete
   notarization configuration and prevent unsigned/self-signed output from
   being labeled notarized. Do not reuse the Round Robin self-signed import as
   proof, enumerate personal keychains or add a hosted CI workflow.
2. Verify all nested signatures, expected bundle identifiers, team, runtime
   flags, timestamps and entitlements. The app and Share extension must have
   matching numeric build versions; third-party helper versions are their own.
   Verify that the Connect core, local model runtime, assets and notices are
   actually present. Validate the exact revision and record artifact hashes.
3. Require an explicit notarization step. Preserve the request ID and accepted
   result; fetch Apple's diagnostic log for failure. Merely completing a
   submission is not acceptance. Configure bounded failure/cancellation and
   cleanup before making this an owned CI task.
4. Prepare the ZIP path correctly: submit an archive containing the final app,
   verify acceptance, staple and validate the app, and then generate the final
   distributable ZIP. Create/notarize/staple the final DMG as needed. Stapling
   the current DMG alone does not staple the app copied into the ZIP. Freeze
   final bytes before checksums and Sparkle EdDSA signatures/feed generation.
5. Prove fresh online and offline Gatekeeper installation and upgrades in an
   isolated user environment. Include trust/settings migration, Automation,
   network, clipboard/files, phone screen and the #5 audio acceptance gates.
   A valid signature or accepted notarization is not feature proof.
6. Give Rahul the review pack with source SHA, artifact SHA-256 values,
   signature/notarization evidence and native results. Publish only after his
   explicit review-pack approval. Do not route App Store packages through the
   Sparkle feed or call a Developer ID DMG a store build.

The unrelated legacy [GitHub release workflow](../.github/workflows/release.yml)
is not an approved route for new builds/tests. Keep owned RR CI as the
dispatcher; this audit makes no CI or deployment changes.

See Apple's [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
for Developer ID, Hardened Runtime, timestamp and submission requirements. Apple
states that Mac App Store submission already includes equivalent security
checks; notarizing a direct-download app does not provide store eligibility.

For existing pairing/key storage and Round Robin signature behavior, see
[macOS pairing storage and signing](rr-mac-signing.md).
