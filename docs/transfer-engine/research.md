# Transfer engine: research

Status: research for Bridgey by Round Robin, 2026-10-25. Research only; nothing is built. The
design that follows from it is [design.md](design.md); the robustness plan is
[test-plan.md](test-plan.md); open decisions are in [questions-for-rahul.md](questions-for-rahul.md).

Method: five research tracks (prior art in peer-to-peer and sync tools; resumable HTTP and cloud
protocols plus testing tools; durability and atomicity per platform; integrity and throughput
numbers; background execution per platform), read from primary sources where they exist
(specifications, man pages, AOSP and xnu source, official docs, papers). Quotes are verbatim.
"(inference)" marks reasoning that is ours, "unverified" marks claims we could not confirm, and
third-party benchmarks are labelled as such. The claims the design leans on hardest were checked a
second time by hand; they are listed in the [verification log](#verification-log).

## Summary

1. **Nobody we looked at gives users a ledger.** Syncthing, rsync, BitTorrent, iroh, croc and
   Resilio resume well, but none shows a per-file record of what arrived, what was verified and
   why something did not. Blip's site promises "Blip resumes after network interruption, drives
   being unplugged, full disks... you name it" and says nothing about verification
   ([blip.net](https://blip.net/)). A visible ledger with checksums is open ground.
2. **The receiver must own the truth about what is durable.** Every resumable protocol that works
   makes the receiving side authoritative: tus ("MUST always include the Upload-Offset header"),
   Google Drive ("Don't assume that the server received all bytes sent"), Dropbox
   (`incorrect_offset.correct_offset`), Syncthing (the puller writes only blocks whose hash
   matches). A transport acknowledgement is not durability: the IETF resumable upload draft warns
   that data "might have been delivered and acknowledged at the transport layer without yet being
   reflected in the offset".
3. **Change detection by metadata alone is not enough.** On ext4 a file can change content while
   keeping inode number, size, mtime and ctime (our own test on rr-dev-1). Git solves the same
   problem by re-reading "racy" files. Syncthing re-hashes every block it serves and treats a
   mismatch as "the file changed". croc's sampled hash once let a changed file through.
4. **BLAKE3 is the best single hash for us**, though not because it is faster on phones: hardware
   SHA-256 is about as fast as the `blake3` crate on one Arm core. BLAKE3 wins because one pass
   gives per-block verification, a whole-file checksum that equals `b3sum`, parallel hashing on
   Macs and x86, and verified ranges. With 1 MiB groups the tree costs 32 to 64 bytes per MiB.
5. **Durable state needs platform-specific care.** Linux needs `fdatasync` plus a directory
   `fsync` after rename; macOS `fsync` stops at the drive cache (F_FULLFSYNC or F_BARRIERFSYNC);
   an `fsync` error can be "forgotten" (fsyncgate), so the batch must be treated as lost; some
   Android devices mount f2fs with `nobarrier`; MediaStore pending items expire after 7 days on
   Android 11+ and never on Android 10; SAF has no atomic replace.
6. **On Android the existing `connectedDevice` foreground service is the right home** for long
   transfers: no time limit, network kept in Doze, and allowed from `BOOT_COMPLETED` on
   Android 15. `dataSync` has a 6-hour limit. Wi-Fi locks do nothing with the screen off on
   Android 14+. OnePlus is the worst-rated OEM on dontkillmyapp, so resume after a kill is
   mandatory, not a nice-to-have.
7. **The link sets throughput, not the CPU.** Hashing plus encryption of 50 GB costs about 45 s of
   one big phone core. Realistic targets: 250 to 350 Mbit/s phone to Mac with both on Wi-Fi 6,
   at least 900 Mbit/s on Gigabit Ethernet, about 10 Mbit/s on Indian mobile uplink (the median),
   45 to 48 Mbit/s through a 50 Mbit/s relay.
8. **Small files are a storage problem.** Storage Access Framework calls cost tens of
   milliseconds each on real phones (third-party measurements), so 100,000 files through SAF is
   hours of create calls alone. Batching on the wire is easy; batching on the destination needs
   design.
9. **Deterministic simulation of the engine is feasible in Rust.** quinn-proto is sans-IO and
   seedable, turmoil and madsim simulate networks, LazyFS and dm-log-writes simulate power loss.
   The engine core should be sans-IO so most robustness tests run as seeded simulations.

## 1. Prior art

### 1.1 At a glance

| System | Unit and hash | Partial state and resume | Source change detection | Partial naming and cleanup |
| --- | --- | --- | --- | --- |
| Syncthing BEP v1 (v2.1.7, 2026-10) | Power-of-two blocks 128 KiB to 16 MiB, SHA-256 each | The temp file is the state; re-hashed on restart, matching blocks kept | Sender re-hashes each requested block; mismatch forces a rescan | `.syncthing.<name>.tmp`; deleted after 24 h |
| rsync 3.5.x | Block of about sqrt(size), 700 B to 128 KiB; rolling sum plus xxh128 or MD5 | `--partial` file becomes the delta basis; whole-file check, one redo | Size plus mtime quick check | `.<name>.XXXXXX`; partials deleted unless `--partial` |
| zsync 0.8 | 2 or 4 KiB blocks; rolling plus strong hash; SHA-1 or SHA-256 file hash | `.part` file re-scanned | Block mismatch stops using that server | `<name>.part` |
| BitTorrent v2, libtorrent 2.x | 16 KiB leaves in a per-file SHA-256 merkle tree | Resume data: have bits, verified leaves, block bitmasks | None locally | `.<infohash>.parts` |
| iroh-blobs 0.103 | BLAKE3, 1 KiB chunks in 16 KiB groups | data, outboard, sizes and a crash-safe bitfield | Content addressed; imports assumed unchanged | Untagged partials garbage-collected |
| Resilio Sync | 32 KB to 2 MB pieces; hash unpublished | Local blocks re-checked | mtime and size scan, then full rehash | `.!sync` |
| Magic Wormhole | One stream; final hash ack | No file resume; Dilation replays messages across reconnects | None | None |
| croc 11.5 | 32 KiB chunks; xxHash of the file | All-zero regions treated as missing | Hash compared before transfer only | Writes the final name |
| LocalSend 2.2 | Whole file per POST; optional SHA-256 | None | None | Not documented |
| KDE Connect | One TLS socket per payload | None; incomplete file deleted | None | Final name |
| tus 1.0.0 | Byte offsets; optional per-PATCH checksum | Server offset via HEAD | Not covered | `Upload-Expires` |
| Dropbox upload sessions | 4 MiB blocks; `content_hash` | Server offset, `correct_offset` on mismatch | Not covered | Sessions valid 7 days |
| Google Drive resumable | 256 KiB multiples | Server range via 308 | Not covered | Session URI one week |
| Amazon S3 multipart | Parts 5 MiB to 5 GiB, up to 10,000 | Client keeps its own part list | Not covered | Lifecycle rule needed |

### 1.2 System by system

**Syncthing (Block Exchange Protocol v1).**
- Blocks: "The block size is dependent on the file size and varies from 128 KiB up to 16 MiB"; the
  size is "the smallest block size that results in fewer than 2000 blocks"
  ([BEP](https://docs.syncthing.net/specs/bep-v1.html), [syncing](https://docs.syncthing.net/users/syncing.html)).
- The rolling weak hash was removed in v2.0.0 (August 2025): "Rolling hash detection of shifted
  data is no longer supported as this effectively never helped"
  ([v2.0.0](https://github.com/syncthing/syncthing/releases/tag/v2.0.0)); it saved "about 0.8% of
  transferred blocks" ([PR 10005](https://github.com/syncthing/syncthing/pull/10005)).
- Requests carry `offset, size, hash`, and the sender "SHOULD ensure that the transmitted block
  matches the requested hash". On a mismatch the sender invalidates the file and rescans
  ([model.go](https://github.com/syncthing/syncthing/blob/main/lib/model/model.go)).
- "Syncthing never writes directly to a destination file"; temp files are
  `.syncthing.original-filename.ext.tmp`, kept "for up to a day" after an error.
- Resume after restart has no progress database: the puller re-hashes the old temp file and
  keeps matching blocks ([folder_sendrecv.go](https://github.com/syncthing/syncthing/blob/main/lib/model/folder_sendrecv.go)).
- `.stfolder` is "a safety check to ensure that your folder is properly readable and present on
  disk" ([FAQ](https://docs.syncthing.net/users/faq.html)); syncing stops when it disappears.
- In-flight limits: `pullerMaxPendingKiB` and `maxRequestKiB` default to 32 MiB
  ([config](https://docs.syncthing.net/users/config.html)).
- Right for us: hash list before data, receiver-driven requests carrying the expected hash, the
  sender re-verifying what it reads, temp file then rename, a folder health marker, a cap on
  bytes in flight. Wrong for us: continuous multi-device sync machinery; re-hashing the whole
  temp file on every resume (a full read of a 100 GB partial on a phone) (inference); no report.

**rsync.**
- "rsync normally verifies that each transferred file was correctly reconstructed on the receiving
  side by checking a whole-file checksum that is generated as the file is transferred"
  ([man page](https://github.com/RsyncProject/rsync/blob/master/rsync.1.md)).
- On a failed check the receiver logs "failed verification -- update discarded (will try again)"
  and redoes the file once with full-length checksums; a second failure is an error
  ([receiver.c](https://github.com/RsyncProject/rsync/blob/master/receiver.c),
  [generator.c](https://github.com/RsyncProject/rsync/blob/master/generator.c)).
- `--append` updates "without verifying any of the existing content"; `--inplace` can leave a file
  "in an inconsistent state"; `--delay-updates` is "a little closer to atomic".
- Right for us: cheap quick check plus mandatory end verification; one automatic retry at full
  strength, then a hard error. Wrong for us: one sender-driven stream per file; resume re-reads
  both sides; no persisted ledger.

**zsync.** Receiver-driven: "Since it knows which data it needs, it can simply use HTTP Range
requests to pull the data", and "No state is needed on the server"
([paper](http://zsync.moria.org.uk/paper/ch02.html)). A block mismatch "will usually indicate that
the file on the server is updated" ([paper](http://zsync.moria.org.uk/paper/ch04s03.html)). 0.8.0
stopped shortening checksums because they "could expose the client to collision attacks"
([NEWS](https://github.com/cph6/zsync/blob/master/NEWS)). Right for us: the receiver computes what
it lacks; a mismatch means "source changed". Wrong for us: rolling scans of local files are wasted
work for fresh transfers.

**BitTorrent v2 (BEP 52) and libtorrent.**
- `pieces root` is the root of a tree "constructed from 16KiB blocks of the file", SHA2-256; each
  non-empty file is aligned to a piece boundary, so "identical files always result in the same root
  hash" ([BEP 52](https://www.bittorrent.org/beps/bep_0052.html)).
- Hash requests fetch proofs on demand, at most 512 hashes per request. The tree "allows
  validating payload received from a peer immediately, down to 16 kiB blocks"
  ([libtorrent features](https://github.com/arvidn/libtorrent/blob/RC_2_0/docs/features.rst)).
- libtorrent fast resume trusts saved state unless it is "corrupt or doesn't fit the storage", and
  since 1.2 "resume data no longer has timestamps of files"
  ([manual](https://github.com/arvidn/libtorrent/blob/RC_2_0/docs/manual.rst),
  [ChangeLog](https://github.com/arvidn/libtorrent/blob/RC_2_0/ChangeLog)).
- Right for us: per-file root as identity; separate "have" and "verified" states. Wrong for us:
  swarm machinery; trusting resume data without checking local edits (inference).

**iroh-blobs (n0-computer, 0.103, 2026).**
- Verification unit: "2^4*1024 = 16KiB"; "The requester will notice if data is incorrect after at
  most 16 KiB of data" ([DESIGN.md](https://github.com/n0-computer/iroh-blobs/blob/main/DESIGN.md)).
- Requests are a hash plus chunk ranges; missing ranges are computed by the receiver
  ([protocol.rs](https://github.com/n0-computer/iroh-blobs/blob/main/src/protocol.rs)).
- Crash safety: on persist it syncs data, outboard and sizes, and only then writes the bitfield
  ("only write the bitfield if the syncs were successful"); after a dirty shutdown it is
  "reconstructing bitfield from outboard"
  ([bao_file.rs](https://github.com/n0-computer/iroh-blobs/blob/main/src/store/fs/bao_file.rs)).
- On sync cost: "If you sync after each chunk, and a sync takes 5ms, your write speed is now
  limited to 200 kilobytes per second" (DESIGN.md).
- "A chunk of a blob can only go from not present ... to present ..., not the other way" (DESIGN.md).
- The README says this version "is not yet considered production quality".
- Right for us: nearly the whole block layer (tree-verified units, receiver-computed gaps, a
  bitfield that is a cache rebuilt from the tree). Wrong for us: storage keyed by hash instead of
  user paths, a full hash before the first byte of a large import, pre-1.0 APIs, `noq` instead of
  quinn.

**Resilio Sync.** Pieces "from 32KB (kilobytes) up to 2MB"; `.!sync` files are renamed when
complete; "If syncing doesn't resume after Sync restart, delete .!sync files"; an option
"Forces peer to recalculate file hash again after writing to disk"; files being edited are delayed
"10 seconds" by default ([Resilio help](https://help.resilio.com/hc/en-us/articles/206217095),
[207371636](https://help.resilio.com/hc/en-us/articles/207371636),
[207491426](https://help.resilio.com/hc/en-us/articles/207491426)). Right for us: optional
read-after-write check; a settle delay for files being edited. Wrong for us: closed protocol;
stuck partials need manual cleanup.

**Magic Wormhole.** Classic transfers have no resume; a 2016 issue asking for it was still open in
2025 ([#88](https://github.com/magic-wormhole/magic-wormhole/issues/88)). The Dilation protocol
keeps each message queued "until an ACK is received" and re-sends the queue over a new connection
([dilation-protocol.md](https://github.com/magic-wormhole/magic-wormhole-protocols/blob/main/dilation-protocol.md)).
Right for us: acknowledged control messages replayed across connection generations. Wrong for us:
in-memory only, so it does not survive an app restart (inference).

**croc.** Claims "Allows resuming transfers that are interrupted"
([README](https://github.com/schollz/croc)). The receiver scans the existing file and requests
every all-zero run; "there are no "progress" files needed"
([HN](https://news.ycombinator.com/item?id=24520340), [utils.go](https://github.com/schollz/croc/blob/main/src/utils/utils.go)).
A sampled hash once missed a changed file; the maintainer: "Using a constant time hash is a
tradeoff ... that sacrifices accuracy for speed" ([#368](https://github.com/schollz/croc/issues/368)).
The anti-pattern for us: zeros, file length or metadata as evidence of receipt.

**LocalSend.** Protocol v2.2 has sessions, per-file accept and an optional SHA-256 with 422 on a
mismatch, but no resume: "Never gets more than halfway before disconnecting, then I have start over
at 0" ([#1191](https://github.com/localsend/localsend/issues/1191),
[protocol](https://github.com/localsend/protocol/blob/main/README.md)).

**KDE Connect.** Payloads go over a separate TLS socket; a short file is logged as "Received
incomplete file" and deleted; the source has "TODO: MD5-check the file"
([filetransferjob.cpp](https://invent.kde.org/network/kdeconnect-kde/-/blob/master/core/filetransferjob.cpp)).

**AirDrop and Quick Share.** AirDrop: "If you leave Bluetooth or Wi-Fi range after an AirDrop
transfer is initiated, the transfer continues over the internet"
([Apple](https://support.apple.com/guide/iphone/use-airdrop-to-send-items-to-nearby-devices-iphcd8b9f0af/ios));
resuming a failed AirDrop is not documented (unverified). Quick Share (Play services 25.04,
February 2025) can "continue ... over Wi-Fi or mobile data even if the sender or receiver loses
direct connection" ([Android Authority](https://www.androidauthority.com/google-quick-share-resume-internet-connection-3522823/));
whether it picks up mid-file is unverified. Lesson: users now expect a transfer to survive a
network change, and neither product shows partial state or verification.

**Blip.** Public claims: "Keep your progress, whatever happens. Blip resumes after network
interruption, drives being unplugged, full disks... you name it" ([blip.net](https://blip.net/),
checked by hand), and "Blip auto-resumes your transfers in case of interruptions" (App Store
1.2.3). A co-founder on transport: "We evaluated QUIC (and many other approaches)" and it is
"something closer to Tailscale DERP" ([HN](https://news.ycombinator.com/item?id=44651516)). Nothing
public on checksums, verification, a ledger or source changes (unverified). Our Reddit research
adds the staff line "Blip assumes the disk name and file structure remained the same" and the
user request "keep ledger on interrupted and successful transfer session, so a user can resume,
retry resume or resend" ([thread](https://www.reddit.com/r/blippers/comments/1t07qz3/blip_vs_syncthing_for_long_session_transfer_on/oja2fzi/);
the full study is `outputs/bridgey/research/blip-reddit-pain-points.md` in the PA workspace).

**tus 1.0.0 and the IETF resumable upload draft.**
- tus: HEAD returns `Upload-Offset`; PATCH at a wrong offset gets "409 Conflict"; the checksum
  extension rejects a chunk with "460 Checksum Mismatch" and the chunk "MUST be discarded";
  `Upload-Expires` bounds partial state; concatenation allows "parallel uploads"
  ([tus 1.0.0](https://tus.io/protocols/resumable-upload)).
- IETF draft-ietf-httpbis-resumable-upload-14 (tagged 2026-10-18): the server is "responsible for
  persisting the state of the upload resource", its offset "MUST NOT decrease", a 409 "MUST
  include the correct offset", clients must handle "backtracking of a reasonable length", and
  parallel transfers to one resource are forbidden; integrity digests were removed in -12
  ([draft source](https://github.com/httpwg/http-extensions/blob/draft-ietf-httpbis-resumable-upload-14/draft-ietf-httpbis-resumable-upload.md)).
- Right for us: the authoritative, monotonic offset; a mismatch reply that carries the right
  value; killing stale streams. Wrong for us: no integrity in the IETF draft; SHA-1 in tus.

**HTTP ranges (RFC 9110).** If-Range means "if the representation is unchanged, send me the
part(s) that I am requesting in Range; otherwise, send me the entire representation"; a strong
validator "is unique across all versions of all representations"; Last-Modified "is implicitly
weak unless it is possible to deduce that it is strong" ([RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html)).
`wget -c` "has no way of verifying that the local file is really a valid prefix"
([wget manual](https://www.gnu.org/software/wget/manual/wget.html)); Chromium re-hashes the
on-disk prefix on resume and clears it on mismatch
([base_file.cc](https://github.com/chromium/chromium/blob/main/components/download/internal/common/base_file.cc)).
Lesson: bind a resume to a strong validator and re-check the bytes already on disk.

**Dropbox, Google Drive, S3, B2, Azure.**
- Dropbox: `incorrect_offset.correct_offset` "may occur when a previous request was received and
  processed successfully but the client did not receive the response"; "Upload sessions are valid
  for 7 days"; maximum file "2,199,019,061,248 bytes"; concurrent sessions accept 4 MiB-aligned
  pieces "in any order" ([files.stone](https://github.com/dropbox/dropbox-api-spec/blob/main/files.stone)).
  The `content_hash` is SHA-256 of the concatenated SHA-256 of 4 MiB blocks
  ([content hash](https://www.dropbox.com/developers/reference/content-hash)).
- Google Drive: the session URI "expires after one week"; status by an empty PUT with
  `Content-Range: bytes */<total>`; "Don't assume that the server received all bytes sent in the
  previous request" ([Drive uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads)).
- S3: parts "5 MiB to 5 GiB", up to 10,000; maximum object now "48.8 TiB" (raised 2025-12-02);
  CRC checksums combine into full-object checksums; "maintain your own list of the part numbers";
  incomplete uploads cost money until a lifecycle rule aborts them
  ([quotas](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html),
  [integrity](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity-upload.html),
  [MPU overview](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)).
- B2 requires a SHA-1 per part and a `partSha1Array` at finish as "a double-check that the right
  parts were uploaded in the right order" ([b2_finish_large_file](https://www.backblaze.com/apidocs/b2-finish-large-file));
  Azure garbage-collects idle uncommitted blocks "within a week"
  ([Put Block](https://learn.microsoft.com/en-us/rest/api/storageservices/put-block)).
- Right for us: per-part checksums, a final list check, completion that is safe to repeat (the
  final reply is the one most often lost), explicit expiry. Wrong for us: silent one-week cleanup,
  restarting on any 4xx (Drive).

### 1.3 Lessons carried into the design

| Lesson | From |
| --- | --- |
| The receiver says what is durable; every resume starts by asking it | tus, Drive, Dropbox, IETF draft |
| A transport ACK is not durability; report only synced, recorded blocks | IETF draft, iroh-blobs |
| Manifest and hashes first; the receiver pulls missing ranges, each request names the expected hash | Syncthing, zsync, iroh-blobs |
| The sender re-hashes every block it serves; a mismatch means "source changed" | Syncthing, zsync |
| Never infer receipt from zeros, length or metadata | croc, rsync `--append`, libtorrent fast resume |
| The progress bitmap is a cache: data first, then the bitmap; rebuild it from the hash tree after a crash | iroh-blobs |
| A final whole-file check gates the rename and goes into the report | rsync, zsync, Wormhole draft |
| One automatic retry at full strength, then a visible failure | rsync |
| Hidden partial beside or near the target, atomic rename | Syncthing, Resilio, rsync |
| A folder marker or volume identity turns "drive unplugged" into a pause, not a failure | Syncthing `.stfolder`, Blip's claim |
| Skip rolling-hash delta sync; it rarely helps | Syncthing v2.0.0 |
| Expire partial state explicitly on both ends and say so | tus, Dropbox, Azure |
| Make completion idempotent and queryable afterwards | Dropbox, B2, S3 |

## 2. Integrity

### 2.1 What the wire already protects, and what it does not

QUIC authenticates every packet with an AEAD tag ([RFC 9001](https://www.rfc-editor.org/rfc/rfc9001.html)),
so on-path tampering, relay tampering and wire corruption are covered. The classic case for
end-to-end checks ("1 in 30,000 packets fails the TCP checksum", Stone and Partridge, SIGCOMM
2000) does not apply to QUIC payloads. File hashes are still needed for what happens outside the
encrypted pipe:
- storage, firmware or memory errors before encryption or after decryption (Meta found hundreds of
  CPUs with silent data corruption in its fleet: [arXiv 2102.11245](https://arxiv.org/abs/2102.11245));
- engine bugs: a wrong offset, stale bytes spliced in on resume, a truncated write;
- the source file changing while it is read;
- torn writes after a crash;
- a buggy peer. A compromised original sender defeats any hash (inference).

A non-cryptographic checksum (xxHash, CRC32C) would cover accidental corruption only. xxHash's own
README: "xxHash is not a cryptographic hash function"
([xxHash](https://github.com/Cyan4973/xxHash)). We also want the file checksum to be an identity
(adopt an orphaned partial by content, recognise a re-shared file), so a cryptographic hash is
needed (inference).

### 2.2 BLAKE3 versus SHA-256 on our hardware

| Core | SHA-256 | BLAKE3 (`blake3` crate, 1 thread) | Source |
| --- | --- | --- | --- |
| Neoverse V2 (Graviton4, derived from Cortex-X3), 1 MiB | 1.54 GB/s | 1.45 GB/s | [commonware PR 4982](https://github.com/commonwarexyz/monorepo/pull/4982) (third-party) |
| Same core, BLAKE3 on 4 and 16 threads | | 5.7 and 22.3 GB/s | same |
| Zen 5 with AVX-512 and SHA-NI | 2.22 GB/s | 10.9 GB/s | same |
| Apple M1, `openssl speed` / `b3sum` | 2.45 GB/s | 1.50 GB/s | [HN](https://news.ycombinator.com/item?id=38249473), [BLAKE3 PR 319](https://github.com/BLAKE3-team/BLAKE3/pull/319) (third-party) |
| Cortex-A76 (Raspberry Pi 5), cycles per byte | 2.03 | 3.04 | [eBASH](https://bench.cr.yp.to/results-hash/aarch64-pi5.html) |
| Cortex-A72 without crypto extensions, cycles per byte | 11.34 | 5.92 | [eBASH](https://bench.cr.yp.to/results-hash/aarch64-pi4b.html) |

- Snapdragon 8 Gen 2 (OnePlus 11) has one Cortex-X3 core plus A715, A710 and A510 cores
  ([XDA](https://www.xda-developers.com/qualcomm-snapdragon-8-gen-2/)). Scaling the V2 numbers
  by clock gives about 1.76 GB/s SHA-256 and 1.65 GB/s BLAKE3 on the X3 (inference). No direct
  X3 measurement was found (unverified).
- The crate's NEON path is 4 lanes and chosen at compile time ("The NEON implementation does not
  participate in dynamic feature detection, which is currently x86-only"); it needs a C compiler,
  so Android builds use the NDK clang ([BLAKE3 repo](https://github.com/BLAKE3-team/BLAKE3)).
- The Arm crypto extension is optional in the core licence ("The optional Cryptographic Extension
  is not included in the base product"), and older Intel machines lack SHA-NI, so SHA-256 falls
  back to software there ([Arm TRM](https://documentation-service.arm.com/static/60a54fe9982fc7708ac1c8a3)).

Conclusion (inference): on the phone the two are a wash for one pass. The draft scheme in
`connect-anywhere.md` (SHA-256 per chunk plus a whole-file hash) costs two passes and produces a
root nobody can check with a standard tool. BLAKE3 needs one pass for both per-block checks and the
whole-file checksum, scales across cores, and is about five times faster on x86 Linux and Windows.

### 2.3 Trees, bao and outboard size

- BLAKE3 splits input into 1,024-byte chunks in a binary tree where "Left subtrees are full"
  ([BLAKE3 paper](https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf)). A 1 MiB
  block that starts at a multiple of 1 MiB is a complete subtree, so its chaining value can be
  computed independently.
- `blake3` 1.8.0 added the `hazmat` module ("intended for advanced use cases like Bao and Iroh"):
  `HasherExt::set_input_offset`, `finalize_non_root`, `merge_subtrees_non_root` and
  `merge_subtrees_root`. The offset "must also be a multiple of CHUNK_LEN", and mistakes "will
  give you garbage output", so results must be compared with `blake3::hash`
  ([hazmat](https://docs.rs/blake3/latest/blake3/hazmat/index.html), checked by hand; latest
  release 1.8.7, 2026-08-20).
- bao: the outboard encoding is the tree without the chunks; at 1 KiB granularity it is 6.25% of
  the file; "Bao is beta cryptography software. It has not been formally audited yet"
  ([bao](https://github.com/oconnor663/bao)). bao-tree 0.17.0 (2026-10-22) adds configurable
  chunk groups (outboard = (groups - 1) x 64 bytes) and fixed a bug: "Stop decoding after the
  first error, instead of verifying further items against unauthenticated hashes"
  ([bao-tree](https://github.com/n0-computer/bao-tree)).

| Group size | Outboard for a 500 GB file | Share |
| --- | --- | --- |
| 1 KiB (plain bao) | 31.25 GB | 6.25% |
| 16 KiB (iroh) | 1.95 GB | 0.39% |
| 1 MiB, parent nodes | 30.5 MB | 0.006% |
| 1 MiB, leaf chaining values only (parents recomputed) | 15.3 MB | 0.003% |

(Arithmetic is ours.)

### 2.4 Encryption cost

AES-256-GCM on a Snapdragon 8 Gen 2 tablet: 4.35 GB/s at 16 KiB blocks; ChaCha20-Poly1305
1.46 GB/s ([openssl bench](https://acbalingit.com/post/openssl-bench/), third-party). rustls with
ring orders AES-256-GCM first ([rustls 0.23.46](https://docs.rs/crate/rustls/0.23.46/source/src/crypto/ring/mod.rs)).
QUIC header protection is one AES block per packet; at 800 Mbit/s that is about 2.5% of one X3
core (inference). The AES-GCM confidentiality limit is 2^23 packets per key
([RFC 9001](https://www.rfc-editor.org/rfc/rfc9001.html)); quinn-proto starts a key update before
it, roughly every 11.7 GB (inference from
[quinn-proto 0.11.19](https://docs.rs/crate/quinn-proto/0.11.19/source/src/config/transport.rs)),
so a 500 GB transfer crosses about 43 key updates and must be tested for that.

## 3. Durable state, crash safety and atomic finalise

### 3.1 Sync and ordering per platform

| Platform | Fact | Source |
| --- | --- | --- |
| Linux | fdatasync skips timestamps but "a change to the file size ... would require a metadata flush" | [fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html) |
| Linux | After create or rename, "an explicit fsync() on a file descriptor for the directory is also needed" | same |
| Linux | rename "will be atomically replaced"; `RENAME_NOREPLACE` returns an error if the target exists (ext4 3.15, btrfs 3.17, XFS 4.0, vfat 4.9) | [rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html) |
| Linux | After a writeback error "you still only get the error once (so retrying fsync() is not OK)"; ext4, XFS and btrfs "mark pages clean after fsync fails" | [PostgreSQL fsync errors](https://wiki.postgresql.org/wiki/Fsync_Errors), [Rebello et al., ATC 2020](https://www.usenix.org/system/files/atc20-rebello.pdf) |
| macOS | fsync: "the drive itself may not physically write the data ... and it may be written in an out-of-order sequence" | [xnu fsync.2](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/fsync.2) |
| macOS | F_FULLFSYNC: data "fsync'd on the same device before is guaranteed to be persisted"; F_BARRIERFSYNC is "useful to guarantee valid state on disk when ordering is a concern but durability is not" | [xnu fcntl.2](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/fcntl.2), [Apple: reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes) |
| macOS | F_FULLFSYNC measured at "58 IOPS ... On internal NVMe" on an M1 (2022) | [HN, marcan](https://news.ycombinator.com/item?id=30372823) (third-party) |
| macOS | rename "guarantees that an instance of new will always exist"; `renamex_np` with RENAME_EXCL or RENAME_SWAP since 10.12 | [xnu rename.2](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/rename.2) |
| macOS | Rust's `File::sync_all` calls F_FULLFSYNC on Apple targets with no fallback; Go falls back on ENOTSUP for SMB mounts | [Rust std unix.rs](https://github.com/rust-lang/rust/blob/master/library/std/src/sys/fs/unix.rs), [Go fd_fsync_darwin.go](https://github.com/golang/go/blob/master/src/internal/poll/fd_fsync_darwin.go) |
| Windows | ReplaceFile is Microsoft's suggested pattern, but REPLACEFILE_WRITE_THROUGH "is not supported"; FILE_RENAME_POSIX_SEMANTICS from Windows 10 1709 | [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew), [FILE_RENAME_INFORMATION](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information) |
| Windows | Go's toolchain retries renames for 2,000 ms on ACCESS_DENIED and SHARING_VIOLATION "to work around filesystem flakiness" | [robustio](https://github.com/golang/go/blob/master/src/cmd/internal/robustio/robustio_flaky.go) |
| Android | MediaProvider usually hands the owner a lower-filesystem fd; fsync on a FUSE fd runs fsync on the lower file | [MediaProvider FuseDaemon](https://android.googlesource.com/platform/packages/providers/MediaProvider/+/refs/heads/main) |
| Android | FUSE passthrough since Android 12, not for devices upgraded from 11 | [AOSP FUSE passthrough](https://source.android.com/docs/core/storage/fuse-passthrough) |
| Android | Pixel 3 mounted f2fs with `fsync_mode=nobarrier`: after a power cut "user can see old or zero data" | [AOSP crosshatch commit](https://android.googlesource.com/device/google/crosshatch/+/e02e4813256e51bacdecb93ffd8340f6efbe68e0) |

### 3.2 Android shared storage

- **MediaStore pending items.** "While this flag is set, only the owner of the item can open the
  underlying file" ([MediaColumns](https://developer.android.com/reference/android/provider/MediaStore.MediaColumns)).
  AOSP: `DEFAULT_DURATION_PENDING = 7 * DateUtils.DAY_IN_MILLIS`, and every update that sets
  `IS_PENDING=1` recomputes the expiry to now plus 7 days; apps cannot write `DATE_EXPIRES`
  ("External apps have no ability to change this field")
  ([FileUtils.java](https://android.googlesource.com/platform/packages/providers/MediaProvider/+/refs/heads/main/src/com/android/providers/media/util/FileUtils.java),
  checked by hand). Expired items are deleted by the idle job. On Android 10 the column has no
  default, so abandoned pending items never expire (android10-release source).
- Pending files live on disk as `.pending-<expires>-<name>` and are renamed on publish; MediaProvider
  does not fsync that rename (inference from source), so publish must be reconciled after a crash.
- Collisions become "name (1)" up to 31; a leading dot is rewritten to "_"; an extension that does
  not match the MIME type is appended.
- **Storage Access Framework.** `renameDocument` needs `FLAG_SUPPORTS_RENAME`, may return a new
  document, and the provider "may alter this name ... such as avoiding conflicting names"
  ([DocumentsContract](https://developer.android.com/reference/android/provider/DocumentsContract)).
  ExternalStorageProvider builds unique names with " (n)" and its document IDs are `rootId:path`, so a
  rename changes the URI; there is no atomic replace (inference from
  [ExternalStorageProvider.java](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/ExternalStorageProvider/src/com/android/externalstorage/ExternalStorageProvider.java)).
- "rw" implies "a normal file on disk that supports seeking"; "r" or "w" may be a pipe. Since
  Android 10, "w" no longer truncates; use "wt" ([ContentResolver](https://developer.android.com/reference/android/content/ContentResolver),
  [issue 180526528](https://issuetracker.google.com/issues/180526528)).
- Persisted grants are capped at 128 (Android 10) and 512 (Android 11+), oldest pruned silently
  ([UriGrantsManagerService](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android11-release/services/core/java/com/android/server/uri/UriGrantsManagerService.java)).
- SAF per-call cost: "There are two rounds of IPC for every SAF API call"
  ([CommonsWare](https://commonsware.com/blog/2019/06/05/storage-access-framework-counterpoints.html));
  measured create times of 19 to 96 ms on several phones, against 1 to 6 ms for direct file
  creation ([Magic Dosbox forum](https://magicbox.imejl.sk/forums/topic/storage-access-framework-performance/),
  third-party).

### 3.3 Ledgers and crash consistency

- SQLite: "A transaction committed in WAL mode with synchronous=NORMAL might roll back following a
  power loss or system crash. Transactions are durable across application crashes regardless"; with
  FULL "an additional sync operation of the WAL file happens after each transaction commit"
  ([pragma](https://www.sqlite.org/pragma.html)). Android's own default is WAL with NORMAL.
- Pillai et al. (OSDI 2014) found "a total of 60 vulnerabilities" in eleven applications, 27 from
  calls "persisted out of order", and noted that applications "overlook the presence of garbage
  content in the log" ([paper](https://www.usenix.org/system/files/conference/osdi14/osdi14-paper-pillai.pdf)).
  Their follow-up: "use a library, such as SQLite, that implements crash consistency below your
  application" ([ACM Queue](https://research.cs.wisc.edu/adsl/Publications/alc-queue15.pdf)).
- Dan Luu: "The most common class of error was incorrectly assuming ordering between syscalls"
  ([Files are hard](https://danluu.com/file-consistency/)).

### 3.4 Pre-allocation and FAT

- ext4, XFS, btrfs and f2fs support `fallocate` (later writes "are guaranteed not to fail because of
  lack of disk space") and holes; APFS supports F_PREALLOCATE and sparse files
  ([fallocate(2)](https://man7.org/linux/man-pages/man2/fallocate.2.html), [APFS reference](https://developer.apple.com/support/downloads/Apple-File-System-Reference.pdf)).
- FAT32 and exFAT have no holes: Linux zero-fills the gap when writing past the end of a FAT file,
  and exFAT reads beyond ValidDataLength return zeros, so writing out of order on SD cards and USB
  sticks writes the gap twice ([Linux fs/fat, fs/exfat](https://github.com/torvalds/linux/tree/master/fs),
  [exFAT spec](https://learn.microsoft.com/en-us/windows/win32/fileio/exfat-specification)).
- FAT32 cannot store a file of 4 GiB or more (file size is a 32-bit field; well known, not
  re-verified here).

## 4. Change detection

| Platform | Identity | Change signal | Caveats |
| --- | --- | --- | --- |
| Linux | `st_dev` + `st_ino` ("unique only within a filesystem") | size, `st_mtim` and `st_ctim` in ns; ctime is "not settable from userland" | Inode numbers are reused; within one jiffy changes share a timestamp; multigrain timestamps (6.13) only on ext4, XFS, btrfs, tmpfs ([inode(7)](https://man7.org/linux/man-pages/man7/inode.7.html), [multigrain](https://docs.kernel.org/filesystems/multigrain-ts.html)) |
| macOS | `documentIdentifierKey` "persists across system restarts" and "survives 'safe save' operations" | `generationIdentifierKey` changes "when the data in the file's data fork is changed"; APFS stores ns timestamps | Not supported on all volumes ([URLResourceKey](https://developer.apple.com/documentation/foundation/urlresourcekey)) |
| Windows | FILE_ID_INFO plus volume serial; NTFS IDs last "until it is deleted"; "a FAT file ID can change over time" | LastWriteTime (FAT 2 s, exFAT 10 ms) and the USN journal | LastWriteTime "is not fully updated until all handles ... are closed" ([FILE_ID_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info), [file times](https://learn.microsoft.com/en-us/windows/win32/sysinfo/file-times)) |
| Android URIs | OpenableColumns guarantees only DISPLAY_NAME and SIZE ("Null if unknown") | MediaStore DATE_MODIFIED (seconds), GENERATION_MODIFIED (API 30, "more robust than using DATE_MODIFIED"); SAF COLUMN_LAST_MODIFIED may be null | Picker URIs expose neither ([OpenableColumns](https://developer.android.com/reference/android/provider/OpenableColumns), [MediaStore](https://developer.android.com/reference/android/provider/MediaStore)) |

- Our test on rr-dev-1 (Linux 6.8, ext4, 2026-10-25): five create and delete cycles all got the
  same inode number; rewriting "AAAA" as "BBBB" left size, mtime and ctime identical.
- Git's racy-git problem: a modification can happen "so fast that the file's st_mtime timestamp does
  not change", so Git compares contents whenever mtime is not older than the index
  ([racy-git](https://git-scm.com/docs/racy-git)).

**Grant lifetimes decide whether an Android sender can resume after a restart.**

| How the file reached Bridgey | Read access lasts | Can be persisted |
| --- | --- | --- |
| `ACTION_OPEN_DOCUMENT` | "until the user's device restarts" | Yes ([docs](https://developer.android.com/training/data-storage/shared/documents-files)) |
| Photo picker | "until the device is restarted or until your app stops" | Yes, `takePersistableUriPermission`; "up to 5,000 media grants" ([photo picker](https://developer.android.com/training/data-storage/shared/photopicker), checked by hand) |
| `ACTION_SEND` (share sheet) | While the receiving activity's stack is alive | No: only grants with FLAG_GRANT_PERSISTABLE_URI_PERMISSION persist ([Intent](https://developer.android.com/reference/android/content/Intent)) |

Force stop and clearing app data remove grants
([AOSP ActivityManagerService](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/am/ActivityManagerService.java)).

## 5. Failure modes seen in the wild

Inputs to the failure catalogue in [design.md](design.md#12-failure-catalogue):
- Blip: "Waiting for connection" with no reason, destination folder changes breaking transfers
  ("Previously received data is missing"), screen-off pauses, "file not exists on disk" forcing a
  cancel and resend (Reddit research, PA workspace).
- Syncthing: unmounted folders (hence `.stfolder`), FAT timestamp granularity
  (`modTimeWindowS` "Default is 2 on Android when the folder is located on a FAT partition").
- rsync: corrupted reconstruction caught by the whole-file check and redone.
- croc: a changed file accepted because of sampled hashing.
- LocalSend and KDE Connect: any drop means start again from zero.
- fsyncgate: silent data loss after an fsync error, followed by a successful fsync.
- Android: pending items expiring, grants lost on restart, SAF renames returning new URIs, "w" not
  truncating.

## 6. Recovery UX: what users asked for

- Blip users: "keep ledger on interrupted and successful transfer session, so a user can resume,
  retry resume or resend" and "would love a record with some minor stats of past transfers just for
  verification" (Reddit research).
- Nothing in the prior art shows a per-file verification report to users. Developers' tools come
  closest: `b3sum --check`, `sha256sum -c`, rsync's itemised output (inference).
- Android 16 adds `Notification.ProgressStyle` "to help users seamlessly track user-initiated,
  start-to-end journeys" ([progress-centric notifications](https://developer.android.com/develop/ui/views/notifications/progress-centric)).

## 7. Throughput and fairness

### 7.1 Links

| Path | Evidence | Planning number |
| --- | --- | --- |
| Phone on Wi-Fi 6 (2x2, 80 MHz) | Galaxy S10 900/600 Mbit/s down/up, Mi 10 920/540 ([Aggarwal et al., INFOCOM 2021](https://ece.northeastern.edu/fac-ece/dkoutsonikolas/publications/infocom21.pdf)) | Phone sends at 540 to 600 Mbit/s at best |
| Phone and Mac both on Wi-Fi via one access point | Each byte crosses the air twice (inference) | 250 to 350 Mbit/s |
| OnePlus 11 | "2×2 MIMO, Support 2.4G/5G, Wi-Fi 7"; "128GB UFS 3.1/256GB UFS 4.0"; 5,000 mAh ([specs](https://www.oneplus.in/11/specs), checked by hand) | No 6 GHz band; 160 MHz support unverified |
| Gigabit Ethernet | TCP maximum "941.482448 Mbit/sec" ([NST wiki](https://wiki.networksecuritytoolkit.org/nstwiki/index.php/LAN_Ethernet_Maximum_Rates,_Generation,_Capturing_%26_Monitoring)) | At least 900 Mbit/s |
| India mobile data | Ookla median 126.92 Mbit/s down, 9.82 Mbit/s up (September 2026) ([Ookla](https://www.speedtest.net/global-index/india)); Opensignal 5G upload averages Airtel 19.3, Jio 13.0 Mbit/s (February 2026, read through search excerpts) | Uplink 8 to 18 Mbit/s: 50 GB takes 6 to 14 hours |
| Own relay | Per-session cap 50 Mbit/s (connect-anywhere section 9.6) | 45 to 48 Mbit/s |

### 7.2 QUIC on phones

- Zhang et al. (WWW 2024): "the UDP+QUIC+HTTP/3 stack suffers a data rate reduction of up to 45.2%
  compared to the TCP+TLS+HTTP/2 counterpart", caused by "high receiver-side processing overhead"
  and "QUIC's user-space ACKs" ([arXiv 2310.09423](https://arxiv.org/abs/2310.09423), checked by
  hand). The clients they measured did not use GRO.
- quinn reached "up to 8.22 Gbit/s" on a Xeon with 10 GbE, "limited by single-core performance"
  ([König et al., KIT 2023](https://publikationen.bibliothek.kit.edu/1000161904/152028985)).
- quinn-udp 0.6.3 uses GSO, GRO and `recvmmsg` on Linux and Android; on macOS it sends one datagram
  per system call unless the non-default `fast-apple-datapath` feature uses private APIs that "may
  crash on unsupported OS versions"
  ([quinn-udp](https://docs.rs/crate/quinn-udp/0.6.3/source/src/unix.rs),
  [PR 1993](https://github.com/quinn-rs/quinn/pull/1993)).
- On phones with TCP, "the CPU of modern smartphones is not a bottleneck", but "With GSO/GRO
  disabled, the max. throughput drops to only 300-400 Mbps" (Aggarwal et al.).
- quinn defaults: per-stream receive window about 1.25 MB, which caps one stream at about
  125 Mbit/s at 80 ms round trip (inference from
  [quinn-proto config](https://docs.rs/crate/quinn-proto/0.11.19/source/src/config/transport.rs)).

### 7.3 Storage and small files

- UFS 4.0: "a sequential write speed of 2,800 MB/s"; eUFS 3.1 writes "over 1,200MB/s"
  ([Samsung](https://news.samsungsemiconductor.com/global/samsung-develops-first-ufs-4-0-storage-solution-compliant-with-new-industry-standard/)).
  After the WriteBooster cache fills, writes go to TLC "and in turn performance will be reduced"
  ([KIOXIA](https://americas.kioxia.com/content/dam/kioxia/en-us/business/memory/mlc-nand/asset/KIOXIA_WriteBooster_Feature_Tech_Brief.pdf));
  post-cache speed on the OnePlus 11 is unverified.
- 100,000 files of 64 bytes between two servers: rsync 21 s, scp 3 min 56 s, tar over ssh 8.5 s
  ([Bash-Prompt](https://bash-prompt.net/guides/bash-rsync-speedup/), third-party). Per-file
  round trips, not bytes, dominate.

### 7.4 Battery

| Radio | Extra power per Mbit/s, downlink | Uplink | Source |
| --- | --- | --- | --- |
| 4G | 14.55 mW | 80.21 mW | [Narayanan et al., SIGCOMM 2021](https://feng-qian.github.io/paper/5g_sigcomm21.pdf) (Galaxy S20 Ultra) |
| Low-band 5G | 13.52 mW | 29.15 mW | same |
| Wi-Fi 6 | 1.22 to 1.98 nJ/bit while transferring | | Aggarwal et al. (Mi 10) |

One mW per Mbit/s is one nJ per bit, so a 50 GB upload over 4G costs about 32 kJ, roughly half of
a 5,000 mAh battery, while hashing and encryption of the same 50 GB cost about 90 to 180 J
(inference). Battery policy matters for mobile-data uploads, not for hashing.

## 8. Platform background execution

### 8.1 Android

| Rule | API | Source |
| --- | --- | --- |
| `dataSync` may run "a total of 6 hours in a 24-hour period", then `onTimeout`; the timer resets when the user brings the app to the foreground | 35+ | [Android 15 changes](https://developer.android.com/about/versions/15/behavior-changes-15) (checked by hand) |
| Only `dataSync` and `mediaProcessing` have time limits; a service that declares `connectedDevice|dataSync` and calls `startForeground` without a type inherits the limit | 35+ | [FGS timeout](https://developer.android.com/develop/background-work/services/fgs/timeout), [ActiveServices.java](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/am/ActiveServices.java) |
| `BOOT_COMPLETED` receivers may not start `dataSync`, `camera`, `mediaPlayback`, `phoneCall`, `mediaProjection`, `microphone`; `connectedDevice` is allowed | 35+ | Android 15 changes (checked by hand) |
| `connectedDevice` covers "Interactions with external devices that require a Bluetooth, NFC, IR, USB, or network connection"; Bridgey's `CHANGE_WIFI_MULTICAST_STATE` meets its prerequisite | 34+ | [FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types) |
| Network in Doze: a process running a foreground service has "No restrictions" | all | [Power details](https://developer.android.com/topic/performance/power/power-details) |
| UIDT jobs: `RUN_USER_INITIATED_JOBS`, scheduled while visible "or in one of the allowed conditions"; a network constraint is mandatory in AOSP; notification within 10 s; AOSP defaults allow 6 to 12 h per run and 24 h cumulative | 34+ | [UIDT](https://developer.android.com/develop/background-work/background-tasks/uidt) (checked by hand), [JobInfo.java](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/apex/jobscheduler/framework/java/android/app/job/JobInfo.java), [JobSchedulerService.java](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/apex/jobscheduler/service/java/com/android/server/job/JobSchedulerService.java) |
| Task Manager Stop "Terminates your app's process immediately", skips `onStopJob()` and "Prevents user-visible jobs from being rescheduled" | 33+ | UIDT (checked by hand) |
| The system may offer to restrict an app for "1 partial wake lock held for an hour when screen is off"; restricted apps "Can't launch foreground services" and existing ones "are removed from the foreground" | 28+ | [Background optimisation](https://developer.android.com/topic/performance/background-optimization) (checked by hand) |
| `WIFI_MODE_FULL_HIGH_PERF` is deprecated and replaced by low-latency mode, which "is only active when the screen is on" and the app is in the foreground | 34+ | [WifiManager.java](https://android.googlesource.com/platform/packages/modules/Wifi/+/refs/heads/main/framework/java/android/net/wifi/WifiManager.java) |
| Low Power Standby blocks network and wake locks even for foreground services, but ships off in AOSP (`config_lowPowerStandbySupported` false) | 33+ | [PowerManager.java](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/os/PowerManager.java) |
| Battery optimisation exemption: lets an app "use the network and hold partial wake locks during Doze and App Standby" and start FGS from the background | 23+ | [Doze](https://developer.android.com/training/monitoring-device-state/doze-standby), [FGS background start](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start) |
| Force stop: pending intents cancelled (15+), jobs and alarms cancelled, no restarts until the user opens the app; `ApplicationExitInfo` reports `REASON_USER_REQUESTED` | 30+ | [Android 15 all apps](https://developer.android.com/about/versions/15/behavior-changes-all) |
| Android 16: jobs that run alongside a foreground service now count against the job runtime quota | 36 | [Android 16 changes](https://developer.android.com/about/versions/16/behavior-changes-all) |
| Android 17 (released 2026-06-16): local network access needs `ACCESS_LOCAL_NETWORK` at target 37; apps at target 36 or lower keep "an implicit permission grant" | 37 | [Local network permission](https://developer.android.com/privacy-and-security/local-network-permission) (checked by hand) |

OnePlus: dontkillmyapp rates OnePlus 5 of 5 (worst): "Deep optimization or Adaptive Battery ... is
the main app killer", "Sleep standby optimization ... will then disable the phone's network
connections", and OnePlus phones "started reverting this setting randomly"
([dontkillmyapp](https://dontkillmyapp.com/oneplus)). OxygenOS shares ColorOS's code base. The
OnePlus 11 runs OxygenOS 16 (Android 16). Whether current OxygenOS kills foreground services is
unverified; it must be measured.

### 8.2 macOS, Windows, Linux

- `beginActivity(options: .userInitiated)` "prevents the system from deferring the operations or
  putting your app in App Nap" and includes `.idleSystemSleepDisabled`;
  `.userInitiatedAllowingIdleSystemSleep` allows idle sleep
  ([energy guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html)).
  "It is not possible to prevent forced sleep, only delay it" ([QA1340](https://developer.apple.com/library/archive/qa/qa1340/_index.html));
  lid close sleeps unless in closed-display mode with power and an external display.
  `willSleepNotification` observers "can delay sleep for up to 30 seconds".
- Windows: power requests "block the NoCS phase indefinitely on AC power, and for up to 5 minutes on
  DC power", after which desktop apps stop in Modern Standby
  ([modern standby](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/prepare-software-for-modern-standby));
  `PowerRequestExecutionRequired` keeps a process from being suspended
  ([PowerSetRequest](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-powersetrequest)).
- Linux: lingering lets "users who are not logged in to run long-running services"
  ([loginctl](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html)); logind delay
  inhibitors default to 5 s ([inhibitor locks](https://systemd.io/INHIBITOR_LOCKS/)).
- Metered networks: Android `NET_CAPABILITY_NOT_METERED` and `TEMPORARILY_NOT_METERED` (a network
  "can't have both"), macOS `NWPath.isExpensive` and `isConstrained` (Low Data Mode), Windows
  `ConnectionCost`, NetworkManager `Metered`.

## 9. Testing prior art

| Tool | What it gives us | Source |
| --- | --- | --- |
| FoundationDB simulation and BUGGIFY | "a deterministic simulation of an entire FoundationDB cluster within a single-threaded process"; fault points that "make rare states and events more common" | [FDB testing](https://apple.github.io/foundationdb/testing.html), [FDB paper](https://www.foundationdb.org/files/fdb-paper.pdf) |
| TigerBeetle VOPR | "all non-deterministic parts of the system are stubbed out"; replay by seed | [VOPR](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md) |
| quinn-proto | "a fully deterministic implementation of QUIC protocol logic"; `rng_seed`; an in-memory `Pair` harness | [quinn-proto](https://github.com/quinn-rs/quinn/blob/main/quinn-proto/src/lib.rs) |
| turmoil 0.7 | Multiple hosts in one thread with simulated TCP and UDP; `unstable-fs` loses unsynced writes on `Sim::crash` | [turmoil](https://docs.rs/turmoil/0.7.2/turmoil/) |
| madsim 0.2 | Deterministic tokio replacement; real `tokio::fs` (not simulated) | [madsim](https://github.com/madsim-rs/madsim) |
| proptest-state-machine | Reference model versus implementation, failures shrink "to a minimal sequence of transitions" | [proptest book](https://proptest-rs.github.io/proptest/proptest/state-machine.html) |
| tc netem | Loss, delay, jitter, reorder, duplicate, corrupt, rate, with `seed` for reproducibility; works on UDP | [tc-netem(8)](https://man7.org/linux/man-pages/man8/tc-netem.8.html) |
| toxiproxy | "A TCP proxy": not usable for QUIC | [toxiproxy](https://github.com/Shopify/toxiproxy) |
| quic-network-simulator | ns-3 scenarios including `rebind` and `blackhole` | [simulator](https://github.com/quic-interop/quic-network-simulator) |
| LazyFS | FUSE file system that "only flushes data if explicitly requested", `clear-cache` and torn-write faults | [LazyFS](https://github.com/dsrhaslab/lazyfs) |
| dm-log-writes, dm-flakey | Replay a disk to every flush point; drop or fail writes | [log-writes](https://docs.kernel.org/admin-guide/device-mapper/log-writes.html), [dm-flakey](https://docs.kernel.org/admin-guide/device-mapper/dm-flakey.html) |
| SQLite test harness | A VFS that simulates I/O errors and a crash VFS that "randomly reorders and corrupts the unsynchronized write operations" | [SQLite testing](https://www.sqlite.org/testing.html) |
| cargo-fuzz, `arbitrary`, ClusterFuzzLite | Structure-aware fuzzing in CI; quinn already has fuzz targets | [rust-fuzz book](https://rust-fuzz.github.io/book/cargo-fuzz/setup.html), [ClusterFuzzLite](https://google.github.io/clusterfuzzlite/) |
| cargo-mutants | Finds code no test would catch breaking | [mutants.rs](https://mutants.rs/) |
| Android adb | `dumpsys deviceidle force-idle`, `am set-standby-bucket`, `cmd appops set ... RUN_ANY_IN_BACKGROUND ignore`, `am kill` versus `am force-stop`, `cmd connectivity airplane-mode`, `cmd netpolicy set restrict-background true` | [Doze testing](https://developer.android.com/training/monitoring-device-state/doze-standby), [power testing](https://developer.android.com/topic/performance/power/test-power) |
| macOS | `pmset sleepnow`, `pmset relative wake`, `pmset -g assertions`, `caffeinate`, dummynet through `dnctl` and `pfctl` | [pmset(1)](https://keith.github.io/xcode-man-pages/pmset.1.html), [dnctl(8)](https://keith.github.io/xcode-man-pages/dnctl.8.html) |

## 10. Architecture inputs

- The connect-anywhere spec already chose one Rust core with quinn 0.11, rustls on ring, UniFFI for
  Kotlin and Swift, and crates `bridgey-connect` and `bridgey-transfer`
  ([connect-anywhere.md](../connect-anywhere.md#7-stack-choice), [agent-cli.md](../agent-cli.md#12-how-it-maps-to-the-v2-rust-core)).
- quinn exposes stream priorities, custom runtimes and abstract sockets
  (`Endpoint::new_with_abstract_socket`), which is what both ICE and a simulation harness need.
- `blake3` 1.8 `hazmat` gives subtree hashing without depending on bao; bao-tree 0.17 is an option
  if we ever need standard verified range proofs (inference).
- SQLite (through `rusqlite` with the bundled build) is the documented safe choice for a
  crash-consistent ledger (Pillai et al.).

## Corrections to earlier drafts

`connect-anywhere.md` section 8 was written before this research. These points change:

| Draft text | Correction |
| --- | --- |
| SHA-256 per 1 MiB chunk plus a root over the chunk hashes | BLAKE3 with 1 MiB subtree chaining values; the root equals `b3sum` |
| "ARMv8 has SHA-256 instructions, so hashing is not the bottleneck" | True for one pass; the draft needed two passes. Hashing is not the bottleneck either way |
| UIDT needs `setEstimatedNetworkBytes` and must be scheduled while visible | A network constraint is mandatory; the estimate is only recommended; scheduling is allowed in more states |
| Low Power Standby "on some Android 14+ devices" | API 33+, off by default in AOSP; check OxygenOS with `dumpsys power` |
| "On LAN a WifiLock in low-latency mode keeps throughput up" | Only with the screen on and the app in the foreground; useless for screen-off transfers |
| "Partials ... may use at most 20% of free space; above that, the oldest are dropped first" | Dropping partials silently contradicts "never lose progress"; proposed instead: never auto-delete before expiry, pause new transfers (question for Rahul) |
| Sender pushes chunks and the receiver reports `xfer.have` | Receiver-driven requests, as in Syncthing, zsync and iroh (design section 7) |

## Verification log

Checked by hand on 2026-10-25, beyond the research tracks:

| Claim | Result |
| --- | --- |
| Android 15 `dataSync` 6-hour limit and the `BOOT_COMPLETED` list | Confirmed on the Android 15 behaviour page; `connectedDevice` is not in the list |
| MediaStore pending expiry of 7 days, recomputed when `IS_PENDING=1` is set | Confirmed in AOSP `FileUtils.java` (`DEFAULT_DURATION_PENDING`, `computeDateExpires`) |
| Photo picker grants can be persisted, cap 5,000 | Confirmed on the photo picker page |
| UIDT requirements and Task Manager stop behaviour | Confirmed on the UIDT page |
| Android 17 `ACCESS_LOCAL_NETWORK` at target 37 | Confirmed on the local network permission page |
| `blake3::hazmat` functions and rules; added in 1.8.0; latest 1.8.7 | Confirmed on docs.rs and the BLAKE3 releases page |
| Excessive wake lock prompt and what "restricted" does to foreground services | Confirmed on the background optimisation page |
| OnePlus 11 Wi-Fi, storage and battery | Confirmed on oneplus.in |
| QUIC data rate reduction of up to 45.2% | Confirmed in the arXiv abstract |
| Blip's resume claim, and no mention of verification | Confirmed on blip.net |

## Sources

All links are inline above. Grouped for reference:
- **Prior art:** Syncthing ([BEP](https://docs.syncthing.net/specs/bep-v1.html), [config](https://docs.syncthing.net/users/config.html), [source](https://github.com/syncthing/syncthing)); rsync ([man page](https://github.com/RsyncProject/rsync/blob/master/rsync.1.md)); zsync ([paper](http://zsync.moria.org.uk/paper/ch02.html)); [BEP 52](https://www.bittorrent.org/beps/bep_0052.html); [libtorrent](https://github.com/arvidn/libtorrent); [iroh-blobs](https://github.com/n0-computer/iroh-blobs); [Resilio help](https://help.resilio.com/); [Magic Wormhole protocols](https://github.com/magic-wormhole/magic-wormhole-protocols); [croc](https://github.com/schollz/croc); [LocalSend protocol](https://github.com/localsend/protocol); [KDE Connect](https://invent.kde.org/network/kdeconnect-kde); [blip.net](https://blip.net/).
- **Resumable protocols:** [tus](https://tus.io/protocols/resumable-upload), [IETF draft -14](https://github.com/httpwg/http-extensions/blob/draft-ietf-httpbis-resumable-upload-14/draft-ietf-httpbis-resumable-upload.md), [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html), [Dropbox spec](https://github.com/dropbox/dropbox-api-spec/blob/main/files.stone), [Drive uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads), [S3 MPU](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html), [B2](https://www.backblaze.com/docs/cloud-storage-large-files), [Azure Put Block](https://learn.microsoft.com/en-us/rest/api/storageservices/put-block).
- **Integrity and performance:** [BLAKE3 spec](https://github.com/BLAKE3-team/BLAKE3-specs/blob/master/blake3.pdf), [BLAKE3 repo](https://github.com/BLAKE3-team/BLAKE3), [blake3 hazmat](https://docs.rs/blake3/latest/blake3/hazmat/index.html), [bao](https://github.com/oconnor663/bao), [bao-tree](https://github.com/n0-computer/bao-tree), [eBASH](https://bench.cr.yp.to/), [RFC 9001](https://www.rfc-editor.org/rfc/rfc9001.html), [Zhang et al.](https://arxiv.org/abs/2310.09423), [quinn](https://github.com/quinn-rs/quinn), [Aggarwal et al.](https://ece.northeastern.edu/fac-ece/dkoutsonikolas/publications/infocom21.pdf), [Narayanan et al.](https://feng-qian.github.io/paper/5g_sigcomm21.pdf), [Ookla India](https://www.speedtest.net/global-index/india).
- **Durability:** [fsync(2)](https://man7.org/linux/man-pages/man2/fsync.2.html), [rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html), [xnu man pages](https://github.com/apple-oss-distributions/xnu/tree/main/bsd/man/man2), [PostgreSQL fsync errors](https://wiki.postgresql.org/wiki/Fsync_Errors), [SQLite pragma](https://www.sqlite.org/pragma.html), [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html), [MediaProvider](https://android.googlesource.com/platform/packages/providers/MediaProvider/+/refs/heads/main), [DocumentsContract](https://developer.android.com/reference/android/provider/DocumentsContract), [Pillai et al.](https://www.usenix.org/system/files/conference/osdi14/osdi14-paper-pillai.pdf), [racy-git](https://git-scm.com/docs/racy-git).
- **Background execution:** [FGS types](https://developer.android.com/develop/background-work/services/fgs/service-types), [FGS timeout](https://developer.android.com/develop/background-work/services/fgs/timeout), [UIDT](https://developer.android.com/develop/background-work/background-tasks/uidt), [Android 15](https://developer.android.com/about/versions/15/behavior-changes-15), [Android 16](https://developer.android.com/about/versions/16/behavior-changes-all), [Android 17 local network](https://developer.android.com/privacy-and-security/local-network-permission), [dontkillmyapp OnePlus](https://dontkillmyapp.com/oneplus), [Apple energy guide](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html), [Microsoft modern standby](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/prepare-software-for-modern-standby), [systemd inhibitor locks](https://systemd.io/INHIBITOR_LOCKS/).
- **Testing:** [FoundationDB](https://apple.github.io/foundationdb/testing.html), [TigerBeetle VOPR](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/internals/vopr.md), [turmoil](https://docs.rs/turmoil/0.7.2/turmoil/), [madsim](https://github.com/madsim-rs/madsim), [proptest](https://proptest-rs.github.io/proptest/), [tc-netem](https://man7.org/linux/man-pages/man8/tc-netem.8.html), [LazyFS](https://github.com/dsrhaslab/lazyfs), [SQLite testing](https://www.sqlite.org/testing.html), [cargo-fuzz](https://rust-fuzz.github.io/book/cargo-fuzz/setup.html), [cargo-mutants](https://mutants.rs/).
