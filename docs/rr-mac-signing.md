# macOS pairing storage and signing

Round Robin edition only. Findings from 2026-10-26, tested on macOS 27.0.1 with Sparkle 2.10.0.

## Where the Mac keeps its pairing state

`~/Library/Application Support/in.roundrobin.bridgey/trust-v3.json` holds this Mac's long-term
P-256 signing key (raw 32 bytes, base64) and the phones it trusts (id, name, public identity
key). `MacPairingStore` (`macos/Sources/BridgeyMac/MacPairingStore.swift`):

- creates the folder 0700 and the file 0600, and on every load tightens a looser mode (logged
  as `PAIRING_STORE ... repairing`). It refuses a symlinked file or folder, a file owned by
  another user, and anything over 1 MiB;
- writes atomically: a 0600 temp file opened with `O_EXCL | O_NOFOLLOW`, `F_FULLFSYNC` (or
  `fsync`), `rename` over the target, then `fsync` of the folder. A crash leaves at most a
  `.trust-v3.json.tmp-*` file, which is never read and is removed on the next load;
- excludes the file from Time Machine and other backups (`isExcludedFromBackupKey`);
- validates on load (version 3, a P-256 key that parses, well-formed device entries). A
  damaged file is never overwritten: pairing waits and the panel says so;
- skips writes when nothing changed.

The app makes no other Keychain calls. The only `SecItem` use left is the one-time migration
below. Sparkle keeps its own state in the app's defaults; the EdDSA signing key lives on
rr-dev-1, not on any Mac.

## Why not the Keychain

The login keychain is a legacy file keychain (the data protection keychain needs an
entitlement that only a provisioning profile can grant). Each item there has two gates:

1. **ACL application list.** It stores the creating app's designated requirement. Our
   requirement matches every build, so this gate passes after updates.
2. **Partition list** (checked by securityd for keychains under `~/Library/Keychains`). It stores
   the creating app's partition ID. securityd (`securityd/src/clientid.cpp`,
   `partitionIdForProcess`) gives `apple:` to Apple code, `teamid:<team>` to App Store,
   TestFlight, Apple Development and Developer ID code, and `cdhash:<hash of this build>` to
   everything else, including ad-hoc **and self-signed** code. Each build has a new cdhash, so
   the first read of each item after an update asked for the login password. There were two
   items (identity and trust), hence two questions per update.

Tested with two probe builds (A creates an item, B reads it), signed the way `build-app.sh`
signs the app:

| Keychain | ad-hoc A to B | self-signed certificate A to B |
| --- | --- | --- |
| `/tmp/test.keychain-db` (old format, no partitions) | read OK | read OK |
| `~/Library/Keychains/test.keychain-db` (partitioned, like login) | denied (prompt) | denied (prompt) |

Only an Apple-issued certificate gives a stable `teamid:` partition. Without one, a private
file is the only storage that never asks.

## Moving off the Keychain (first launch of the new version)

1. If `trust-v3.json` exists, the Keychain is never touched.
2. Otherwise read the old items: `in.roundrobin.bridgey.trust` / `state-v2` (branch builds only),
   then `in.roundrobin.bridgey.trust` / `trusted-devices-v1` and
   `in.roundrobin.bridgey.identity` / `p256-signing-v1`. macOS asks once per existing item.
3. If any read fails (Deny, Cancel), stop. Nothing is written, retired or regenerated; the
   panel shows a card with Retry, and the next launch tries again. Pairing and reconnects wait
   meanwhile, because a pairing made with a stand-in key would break later.
4. Write the file, read it back and compare, then retire each old item without prompts: it is
   overwritten with a short marker (`moved-to-trust-v3.json`), then deleted. macOS refuses the
   delete for items another build created (`errSecInvalidOwnerEdit`, tested), so the empty
   markers can remain in Keychain Access. They hold no secret and can be deleted by hand.
5. Only a new install (no file, no old items) creates a new identity key.

Tested against a real partitioned keychain with two different builds: denied read leaves both
items and writes nothing; after Always Allow the file is written (0600, folder 0700, backup
exclusion set), the identity matches, both items hold only the marker; the next launch makes
no Keychain reads.

## Threat model of the file

Same model as `~/.ssh/id_*`, Syncthing's `key.pem` and KDE Connect's private key:

- Readable by any process running as the user (and by root). Malware running as the user
  could copy the key and impersonate this Mac to paired phones; it could also read the
  clipboard and files directly. The Keychain would not have stopped such malware from
  overwriting items (tested: any build can replace an item it cannot read).
- Protected at rest by FileVault. Not in Time Machine or other backups, so a backup disk does
  not carry the key.
- Other user accounts on the Mac cannot read it (0600, folder 0700).
- Revocation is unchanged: Forget on the phone removes this Mac's key there.

## Self-signed signing (optional, `release.sh --mac-sign`)

Kept because the designated requirement then pins our certificate
(`identifier "in.roundrobin.bridgey" and certificate leaf = H"3c2c1398bba96941d730cd99e95541aa49f3b5cc"`),
so another ad-hoc app claiming our bundle ID no longer satisfies privacy grants made to
Bridgey. Nothing depends on it.

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
ad-hoc later also passes on EdDSA alone. Never rotate the EdDSA key and the signer at once.
