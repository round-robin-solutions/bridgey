# Local agent codes on Mac

In **Settings > Notifications > Local agent codes**, turn on **Let local agents read codes**. It starts off. **Codes from messages** must already be enabled and working; this setting never turns it on or changes its reader.

With Bridgey running, use its app executable:

```sh
'/Applications/Bridgey by Round Robin.app/Contents/MacOS/BridgeyMac' --local-codes
```

The result is a JSON array with `sender`, `code` and `expiresInSeconds`. It contains the newest unexpired code per sender. `[]` means none are available. Reading does not consume a code or extend its life. A stopped app or an endpoint that has never been enabled returns exit status 1. After switching off, an already-open endpoint returns `[]` until quit; the command never launches Bridgey or changes preferences. Treat the output as a secret: capture it into the requesting process, never a file, shell trace, session transcript or log.

Codes expire after 10 minutes by default, adjustable from 1 to 30 minutes. Older phone messages have their age deducted. Duplicate notifications never extend expiry; an older phone message cannot replace a newer one. Switching off or saving changed rules or duration clears all retained codes. Quitting loses them; reopening restores only the settings.

The blocked-sender list starts with bank and payment app names and common Indian bank SMS sender abbreviations. Each line matches part of the notification sender, app name or package name, ignoring punctuation and case. Edit the list and save, or choose **Use defaults** and save. The list cannot identify every financial sender; add unfamiliar names before requesting their codes.

The store is separate from notification history, live copy cards, phone-agent grants and settings sync. It only receives codes already accepted by the existing reader. History redaction and existing code-reader behavior stay as they were. This setting adds no phone or network messages, and it does not change existing grants.

Retained code bytes use anonymous memory with `mlock`, and are zeroed before release. Allocation or locking failure discards the code. Expiry uses a continuous clock that advances through sleep, plus a one-shot expiry task, pruning on wake and a check before every read. The store caps retention at 128 senders and 32 bytes per code. Socket response strings exist briefly in process memory; callers must handle their own copies securely.

The endpoint is `$TMPDIR/bridgey-local-codes-<uid>/codes.sock`: a Unix socket, with no network listener. The directory must belong to the current user and have mode `0700`; the socket must have mode `0600`. Symlinks and unsafe permissions are refused. Both ends verify the peer's macOS user ID with `getpeereid`. Any process running as that user can read while the setting is on.

The read-only request is `{"version":1,"command":"read"}` followed by a newline. Other requests are refused. Each read, including empty results and refused requests, logs the user ID, result and count through macOS logging. Codes, message text and sender names never enter that log.

No Bridgey installation, update or release is part of this change.
