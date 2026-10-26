# macOS signing and the Keychain question after updates

Round Robin edition only. Findings from 2026-10-26, tested on macOS 27.0.1 with Sparkle 2.10.0.

## Why macOS asks for the login password after an update

Bridgey keeps its signing key and the trusted phones in the login keychain (legacy file
keychain; the data protection keychain needs an entitlement that only a provisioning profile
can grant). Each item there has two gates:

1. **ACL application list.** It stores the creating app's designated requirement. Our ad-hoc
   requirement `identifier "in.roundrobin.bridgey"` already matches every build, so this gate
   passes after updates.
2. **Partition list** (checked by securityd for keychains under `~/Library/Keychains`). It stores
   the creating app's partition ID. securityd (`securityd/src/clientid.cpp`,
   `partitionIdForProcess`) gives `apple:` to Apple code, `teamid:<team>` to App Store,
   TestFlight, Apple Development and Developer ID code, and `cdhash:<hash of this build>` to
   everything else, including ad-hoc **and self-signed** code. Every build has a new cdhash, so
   the first read after an update fails this gate and macOS asks for the login password. "Always
   Allow" adds the new build's cdhash; writes never ask (securityd only prompts on reads).

Tested with two different probe builds (A creates an item, B reads it), signed exactly as
`build-app.sh` signs the app:

| Keychain | ad-hoc A to B | self-signed certificate A to B |
| --- | --- | --- |
| `/tmp/test.keychain-db` (old format, no partitions) | read OK | read OK |
| `~/Library/Keychains/test.keychain-db` (partitioned, like login) | denied (prompt) | denied (prompt) |

So a stable self-signed certificate does **not** stop the question. Only an Apple-issued
certificate (Developer ID, Apple Developer Program) gives a stable `teamid:` partition.

## Why it was two questions

There were two items, `in.roundrobin.bridgey.identity` (read in `MacIdentity`) and
`in.roundrobin.bridgey.trust` (read in `MacTrustRegistry`), each read once at launch, each with
its own partition list. Since this change both live in one item (`in.roundrobin.bridgey.trust`,
account `state-v2`), read once per launch through `MacKeychainState.shared`.

- First launch of the new build: it reads the two old items (two questions, as before), writes
  the combined item and deletes the old ones.
- Every later update: one question, for the combined item.
- If the user chooses Deny, nothing is written or deleted, and the stored key is kept for the
  next launch (this launch runs with a temporary key). The old code tried to delete and
  replace the identity item in that case.
- Re-saving an unchanged trust list is skipped.

## Self-signed signing (optional, `release.sh --mac-sign`)

What it still gives: the designated requirement pins our certificate
(`identifier "in.roundrobin.bridgey" and certificate leaf = H"3c2c…f3b5cc"`), so another
ad-hoc app that claims our bundle ID no longer satisfies the Keychain ACL or privacy grants.
It does not remove the post-update question.

How it runs: `build-macos-remote.sh` pipes the p12 and its password to a 0700 folder on the
Mac; `build-macos.sh` creates a throwaway keychain with a random password, imports the p12
with `-T /usr/bin/codesign`, sets the key partition list (`apple-tool:,apple:,codesign:`) so
codesign works over ssh without a prompt, puts the keychain on the search list for the build,
deletes the p12 files right after import, and on exit restores the search list and deletes the
keychain. The login keychain is not touched. `security import -P` shows the p12 password in
the Mac's process list for a moment.

`build-app.sh` modes: `MACOS_SIGNING_IDENTITY` (Apple identity, timestamped), `RR_SIGNING_IDENTITY`
(SHA-1 of the self-signed identity, hardened runtime, `--timestamp=none`), or neither (ad-hoc).
Sparkle's helpers are signed with the same identity; the app keeps its entitlements.

## Sparkle and a change of signer

`SUUpdateValidator.m` (`validateUpdateForHost`) accepts an update when the EdDSA signature
matches the **installed** app's `SUPublicEDKey`, or when the new app's code signature matches
the installed app's designated requirement. It rejects only an update that is unsigned or
whose code signature is invalid. Going from ad-hoc to the self-signed certificate passes both
checks: EdDSA (same key) and code signing (the certificate-signed build satisfies
`identifier "in.roundrobin.bridgey"`, checked with `codesign --verify -R=...`). Going back to
ad-hoc later also passes on EdDSA alone. Losing the EdDSA key while switching signers would
strand users; never rotate both at once.

## Ways to reach zero questions (decision needed)

1. **Apple Developer Program** (paid, yearly). Sign with Developer ID: stable `teamid:`
   partition, no question after updates, notarisation, no Gatekeeper warning on first open.
   `build-app.sh` already supports `MACOS_SIGNING_IDENTITY`; the `--mac-sign` pipeline can
   import a Developer ID p12 the same way.
2. **Hand-off on update.** Tested: a new build may overwrite an item it cannot read, without a
   prompt, and then owns it. The old build could leave the combined item's contents in a 0600
   file just before Sparkle relaunches; the new build writes them back and deletes the file.
   No question, but the signing key sits on disk for a few seconds.
3. **Keep as is:** one question per update.
