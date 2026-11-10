# Mac App Store eligibility

Audited 8 November 2026 against `rr/main` at
`70e933caf6a394d2528bccea399cfdb63657c7e2`. The open call-media work was also
inspected at `a9b405561f250ca2e5a41a84e33a8e04e1cb84f1`; it is not part of this
branch. Recheck both inventories when either revision changes.

**A Mac App Store build is blocked while preserving all current behavior.**
The main app is not sandboxed, now-playing support uses a private framework,
and Handoff takeover changes another process's preferences. We also need a
supported sandbox solution for remote input. This audit doesn't add a store
target, entitlement exception or feature gate, or change product behavior.

This is a source and policy audit, not App Review approval or runtime sandbox
proof. The Mac App Store request remains open. Developer ID distribution is
covered [separately](macos-developer-id-readiness.md).

## What blocks the current app

| ID | Source and current behavior | Constraint and next step |
| --- | --- | --- |
| MAS-1 | [Bridgey.entitlements](../macos/Resources/Bridgey.entitlements) contains only `com.apple.security.automation.apple-events`. | Guideline 2.4.5(i) requires App Sandbox. Sandboxing just the Share extension does not sandbox the main app. Do not add the entitlement and claim compatibility before the rows below are resolved. |
| MAS-2 | [MediaPlayers.swift](../macos/Sources/BridgeyMac/MediaPlayers.swift), `NowPlaying.readScript` and `commandScript`, load `/System/Library/PrivateFrameworks/MediaRemote.framework`, `MRNowPlayingRequest` and `MRMediaRemoteSendCommand` through JXA/osascript. | Guideline 2.5.1 requires public APIs. Running the private calls in an Apple binary doesn't make them public. We need a replacement covering the existing system-wide player discovery, metadata, artwork, selection and commands. Falling back to only Music/Spotify would change behavior. We haven't established a public replacement with that coverage. |
| MAS-3 | [HandoffTakeover.swift](../macos/Sources/BridgeyMac/HandoffTakeover.swift), `HandoffDefaults`, reads/writes/deletes the ByHost `ActivityAdvertisingAllowed` and `ActivityReceivingAllowed` keys in `com.apple.coreservices.useractivityd`, via `/usr/bin/defaults`. It remembers and restores each prior value. | Apple's current sandbox guide restricts access to other apps' preferences. An archived shared-preference exception exists, but Apple acceptance and ByHost behavior are unproved, and the keys aren't a documented public Handoff configuration API. NSPasteboard's documentation also says there is no macOS API for interacting with Universal Clipboard. An exception wouldn't resolve the public-API question. Replacing automatic takeover/restore with System Settings instructions needs Rahul's decision. |
| MAS-4 | [RemoteInputInjector.swift](../macos/Sources/BridgeyMac/RemoteInputInjector.swift), `CGEventInjector`, posts keyboard/mouse events at `.cghidEventTap`. [RemoteInputHost.swift](../macos/Sources/BridgeyMac/RemoteInputHost.swift), `AccessibilityAccess`, requires Accessibility trust. [MacSystemActions.swift](../macos/Sources/BridgeyMac/MacSystemActions.swift), `lockScreen`, posts Control-Command-Q. | Apple's guide restricts accessibility use and simulated input in Open/Save dialogs. This app exposes general remote input; Accessibility consent alone does not establish sandbox authority. No supported sandbox entitlement/backend retaining this behavior has been verified. Investigate with Apple and an isolated sandbox fixture before promising remote control or lock support. Do not add an undocumented accessibility entitlement or use an unsandboxed helper to escape the sandbox. |
| MAS-5 | [Package.swift](../macos/Package.swift) links Sparkle. [AppUpdater.swift](../macos/Sources/BridgeyMac/AppUpdater.swift) implements update checks/channels; [build-app.sh](../macos/build-app.sh) embeds its framework/helpers and feed. | Guideline 2.4.5(vii) requires store-distributed updates. A store edition would need to exclude the updater and adapt its settings, setup, update commands and help. Keep the direct edition intact. This is a distribution behavior decision, not an entitlement fix, and has not been approved. |

MAS-2 is an independent public-API blocker even if Apple accepts sandbox
exceptions for other features. These findings do not prove that every possible
implementation is ineligible; they show why the current implementation cannot
be labeled store-ready.

Handoff migration also needs a failure check: `HandoffDefaults.read` currently
treats a nonzero `defaults read` exit as an absent key. Under sandbox denial,
that could misidentify the prior state. We must distinguish denied access from
a missing preference before trusting takeover or restoration in a new edition.

## Features that need migration or proof

We can keep several features using public APIs, but still need sandbox proof.

| Feature | Source evidence | Work needed to retain behavior |
| --- | --- | --- |
| Phone screen on Mac | [PhoneScreen.swift](../macos/Sources/BridgeyMac/PhoneScreen.swift) receives an Android-consented stream. [PhoneScreenDecoder.swift](../macos/Sources/BridgeyMac/PhoneScreenDecoder.swift) uses VideoToolbox/CoreMedia; the window uses `AVSampleBufferDisplayLayer`. | This displays the phone's screen. We found no Mac ScreenCaptureKit/CGDisplay capture path. Preserve the receiver with network permissions and sandboxed decode/display proof. The generic whole-device mirror also needs an accurate review explanation: 4.2.7's additional rules apply when mirroring specific software/services rather than a generic host mirror. Don't infer an unconditional LAN-only restriction. |
| Text, images and links on the clipboard | [AutoClipboard.swift](../macos/Sources/BridgeyMac/AutoClipboard.swift) observes `NSPasteboard.general`; [ClipboardInbox.swift](../macos/Sources/BridgeyMac/ClipboardInbox.swift) supplies pasteboard data lazily. | NSPasteboard is a public API. Sandboxing does not justify removing clipboard support. Prove background observation, privacy/consent, lazy providers and echo prevention on supported systems. Handoff takeover remains the separate MAS-3 issue. |
| Clipboard files, Finder Share and Services | [ShareViewController.swift](../macos/ShareExtension/ShareViewController.swift) hands file URLs/data to the main app through a named pasteboard and custom URL. [ShareAndServices.swift](../macos/Sources/BridgeyMac/ShareAndServices.swift) consumes them; [ClipboardOutbox.swift](../macos/Sources/BridgeyMac/ClipboardOutbox.swift) reads files. | Prove transfer of file access from the provider/extension to the sandboxed main app, deferred reads, resource lifetime and relaunch. A path string is not an access grant. Apple's bookmark-transfer APIs are available; do not assume an App Group is required for the existing pasteboard mechanism. |
| Files, folders, Tray and resumed transfers | [BridgeySettings.swift](../macos/Sources/BridgeyMac/BridgeySettings.swift), `receiveDirectoryAccess`, already uses security-scoped bookmarks. [Tray.swift](../macos/Sources/BridgeyMac/Tray.swift), [FolderJournal.swift](../macos/Sources/BridgeyMac/FolderJournal.swift) and [FolderSender.swift](../macos/Sources/BridgeyMac/FolderSender.swift) persist ordinary bookmarks/paths. | Retain user-selected read/write access across relaunch using security-scoped bookmarks and balanced access lifetimes. Audit default Downloads, folder descendants, stale/moved bookmarks, restart/resume, permissions and external volumes. Ordinary stored bookmarks do not supply persistent sandbox authority. |
| Pairing identity, trust, settings and local history | [MacPairingStore.swift](../macos/Sources/BridgeyMac/MacPairingStore.swift) stores `trust-v3.json` under Application Support and has legacy Keychain migration. | Container adoption must preserve the existing key, paired devices and settings. Prepare and test a narrowly scoped migration manifest/import, including denied legacy access, retries and direct/store coexistence. Never generate a replacement identity just because the sandbox cannot see the old file. |
| Browser tab and selected-player control | [BrowserTab.swift](../macos/Sources/BridgeyMac/BrowserTab.swift) and [MediaController.swift](../macos/Sources/BridgeyMac/MediaController.swift) run fixed AppleScript using `osascript`. | Hardened Runtime automation permission is not an App Sandbox target grant. Audit actual target apps and supported scripting access groups; request narrowly scoped `scripting-targets` or a justified `temporary-exception.apple-events` where necessary. Subprocesses inherit restrictions. Arbitrary target support cannot be promised by adding the current Boolean entitlement. |
| Mac actions, Shortcuts and Tailscale discovery | [MacSystemActions.swift](../macos/Sources/BridgeyMac/MacSystemActions.swift) uses CoreAudio, IOKit power management, NSWorkspace and `/usr/bin/shortcuts`. [TailscaleSetup.swift](../macos/Sources/BridgeyMac/TailscaleSetup.swift) runs a separately installed Tailscale binary for read-only status. | Public API status alone does not prove sandbox access. Test volume/sleep/screensaver and Shortcuts inside the sandbox. External executable access and IPC need their own audit; helper inheritance cannot bypass restrictions. Retain discovery without turning an optional Tailscale installation into a required companion app. |
| LAN, Bluetooth and Connect anywhere | [Discovery.swift](../macos/Sources/BridgeyMac/Discovery.swift), [CompanionLinkAdvertiser.swift](../macos/Sources/BridgeyMac/CompanionLinkAdvertiser.swift), [ConnectCore.swift](../macos/Sources/BridgeyMac/ConnectCore.swift). The Rust dylib is bundled and signed by the packager. | Network client/server and Bluetooth sandbox entitlements are standard candidates. Local Network/Bluetooth consent remains separate. Prove Bonjour, inbound/outbound TCP/UDP, relay/fallback and the Rust library inside the sandbox. `dlopen` of bundled signed code is not inherently private API use. The external dylib environment override needs distribution review. No Network Extension/VPN entitlement is justified merely by using an existing Tailscale connection. |
| On-device code model | [CodeModel.swift](../macos/Sources/BridgeyMac/CodeModel.swift) pins the GGUF model/hash; [CodeModelStore.swift](../macos/Sources/BridgeyMac/CodeModelStore.swift) downloads it to Application Support. `llama.framework` is bundled. | Retain local inference and terms/consent. Establish whether the pinned model download is acceptable resource delivery under 2.4.5(iv)/2.5.2. Model data is not automatically executable code, and a hash alone does not establish review acceptance. Do not bundle/remove/switch the model or add JIT exceptions without evidence and approval. |
| Launch at login and app relaunch | [BridgeySettings.swift](../macos/Sources/BridgeyMac/BridgeySettings.swift) uses `SMAppService.mainApp`; [SetupCenter.swift](../macos/Sources/BridgeyMac/SetupCenter.swift) has a relaunch subprocess. | The public login mechanism is a suitable starting point; retain user consent. Prove helper/relaunch termination and inheritance against 2.4.5(iii). |

## Entitlement inventory

This inventory describes checked-in entitlement files and packaging source,
not a final signed artifact or Apple's provisioning decisions.

| Entitlement | Current source | Classification / implication |
| --- | --- | --- |
| `com.apple.security.automation.apple-events` | Main app: `true`. | Hardened Runtime permission to request Apple Events consent. Not a sandbox escape or a per-target scripting grant. |
| `com.apple.security.app-sandbox` | Share extension: `true`; main app: absent. | Standard capability; required for the store app. |
| `com.apple.security.files.user-selected.read-only` | Share extension: `true`. | Standard file-access capability. Does not prove that the receiving app retains the provider's grant. |
| `com.apple.security.device.audio-input` | Open #5 only: `true`. | Audio-input resource entitlement; not proof of system-audio consent or a successful sandboxed tap. |
| `com.apple.developer.usernotifications.time-sensitive` | Mentioned in a [CodeFloatWindow.swift](../macos/Sources/BridgeyMac/CodeFloatWindow.swift) comment; absent from entitlement files and signing arguments. | Not requested or enabled by current source. Do not add it based on the comment. |
| Network client/server, Bluetooth, Downloads, user-selected read/write, app-scoped bookmarks | Main app: absent. | Standard candidates for retained features, not an approved store entitlement set. Use only the scope each feature needs. |
| `com.apple.security.scripting-targets` | Absent. | Per-app scripting access groups; requires target dictionary audit. |
| `com.apple.security.temporary-exception.apple-events` | Absent. | Review-sensitive exception for identified apps without suitable scripting access groups. Requires justification; approval is not assumed. |
| `com.apple.security.temporary-exception.shared-preference.read-write` | Absent. | Potential narrow exception for MAS-3's domain, documented in Apple's archived reference. Not a supported Handoff setter or a confirmed approval route. Do not substitute a broad preference-file path exception. |
| Mach lookup/IOKit/file-path temporary exceptions | Absent. | Review-sensitive; do not add broad allowlists speculatively for event injection, power control or external helper IPC. |
| Application Groups / Keychain groups / other profile-bound capabilities | Absent from app/extension entitlement files. | Add only if a chosen design requires them and enrollment is complete. No profile, certificate or account access was performed. |

`build-app.sh` preserves Sparkle XPC helper entitlements from the downloaded
dependency while re-signing. A final binary audit must enumerate **all** nested
executables and their actual signatures/entitlements; the app's plist alone
cannot establish that inventory.

## Open #5: audio is public API, acceptance is still open

The inspected #5 candidate adds `CATapDescription`,
`AudioHardwareCreateProcessTap`, a private-visibility input-only aggregate and
`CATapMutedWhenTapped`, with an in-memory discard reader. Here "private" means
Core Audio object visibility, not a private framework. Apple's public Core
Audio tap sample documents process muting, macOS 14.2+, the
`NSAudioCaptureUsageDescription` key and the system-audio consent prompt.

#5 includes that usage description and the audio-input entitlement. This does
not establish Mac App Store eligibility or native correctness. Sandbox and
allow/deny/revoke tests, real suppression, route/process changes, cancellation,
cleanup and owner-death release remain acceptance gates. Use only the dedicated
isolated audio test host, RR CI-built immutable fixtures and the shared Mac
lock protocol. Do not run audio probes on daily-use Macs.

## Decisions and implementation gates

Rahul approved pursuing the Mac App Store; he has not approved reduced
features. The unresolved choices are concrete:

1. **Handoff:** investigate a documented Apple-supported takeover path or seek
   acceptance of a narrow exception. Manual System Settings guidance is a
   product change and requires approval.
2. **Media and remote input:** identify public, sandbox-compatible replacements
   with the same coverage. A smaller supported-app list or removal of remote
   control requires approval if that proves impossible.
3. **Updates:** approve store-managed updates for a separate edition and define
   what existing update controls/commands do there. Do not alter the direct
   edition's Sparkle path.
4. **Installation identity and migration:** decide direct/store replacement or
   coexistence before assigning another bundle ID. Preserve paired trust,
   permissions and local data in either design.

Once those decisions have a supported implementation, a store build needs:

- A self-contained Xcode distribution/archive/export path, minimal sandbox
  entitlements for the app and every helper, numeric store version/build
  values and category metadata. The current DMG/ZIP packager is not that path.
- Container/bookmark/extension migration and denial/revocation handling, tested
  with fresh and existing installations, reboot/relaunch and offline use.
- Signed nested-code and public-API inspection, licenses/resources and privacy
  manifest inclusion. Listing, age rating and privacy answers remain with the
  coordinator; coordinate code evidence rather than inventing answers.
- Owned RR CI checks and isolated native proof. No Apple enrollment, signing,
  provisioning, submission or public release until the applicable approval.

No reduced-feature build or unsandboxed companion is proposed as a completed
store release. Keep this PR unmerged while Rahul reviews the pack: the existing
`rr/main` after-verify path can publish a Nightly, even for a documentation merge.

## Apple references

Retrieved 8 November 2026 from public documentation only. These rules support
the findings; they do not replace App Review's decision.

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/):
  2.4.5(i)-(vii), 2.5.1, 2.5.2, consent under 2.5.14 and remote mirrors under 4.2.7.
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox):
  restricted activities, container access and child inheritance.
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox):
  user selection, bookmarks, transfers between processes and App Groups.
- [Migrating your app's files to its App Sandbox container](https://developer.apple.com/documentation/security/migrating-your-app-s-files-to-its-app-sandbox-container).
- [Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app).
- [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).
- [App Sandbox entitlement keys, archived](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).
- [Temporary exception entitlements, archived](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html):
  Apple Events, shared preferences, Mach, IOKit and filesystem exceptions.
- [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard).
- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

## Verification of this change

Documentation only. Checked the source paths, entitlement plists, packaging
commands and public Apple references at the revisions above. No build, suite,
sandboxed launch, audio interaction, keychain/certificate inspection or Apple
account operation was performed for this audit. Existing #5 work is unchanged.
