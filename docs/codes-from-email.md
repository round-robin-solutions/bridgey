# Codes from email: plan

Status: **Phase 1 built** (branch `rr/codes-email`); Phase 2 not built. Bridgey by Round Robin edition. Written 2026-10-31 after Rahul
asked: "I also want to plan support for adding OTP detection through email."

**Rahul's decisions (2026-10-31)**, which win over the recommendations below:

1. Inboxes: Gmail, Outlook, Proton Mail and Spark (Rahul reads all his mail in Spark), all from the
   phone's mirrored notifications (`com.google.android.gm`, `com.microsoft.office.outlook`,
   `ch.protonmail.android`, `com.readdle.spark`; checked on Google Play: the rewritten Proton Mail
   app kept its package, and no other Proton Mail or Spark package is published).
2. Gmail's Updates tab: handled outside the app, by a Gmail filter that puts code emails in Primary.
3. Phase 2: decided after Phase 1; not built.
4. Engine: always the model on this Mac, even when Cloud reads text messages. With no model
   downloaded, email codes wait: a one-time prompt to download it, never the cloud.
5. Same code by SMS and email within 10 minutes: one banner, the card says "also by email". Also
   across mail apps (Gmail and Spark syncing one account): one card, "by email, Gmail and Spark".
   Key: the code plus the service, so two different codes from one service are two cards.
6. "Also read codes in email" is on whenever Codes from messages is on.
7. Codes (SMS too) are listed newest first by the phone's post time, with "now", "40 s ago",
   "2 min ago". A newer code from the same service is marked "Latest, use this one" and the older
   ones "Older, replaced", dimmed; the floating Copy panel shows the newest code and, when an older
   one from that service is still up, "Replaces the code from 1 min ago".

Today "Codes from messages" (draft `sms_codes_draft1`, [protocol.md](protocol.md#codes-from-messages-sms_codes_draft1))
shows "Code 482913 from HDFC Bank" with Copy code on the Mac, but only for text messages. This plan
adds one-time codes that arrive by email, reusing the same engines (the fine-tuned Gemma 3 270M on
the Mac, or the opt-in Cloudflare relay), the same verbatim guard (`CodeGuard`) and the same Copy
code card, including the floating 60 s copy panel being built on `rr/code-copy-float`.

## 1. Summary

- **Email codes are not caught today.** The Mac only reads notifications from the phone's SMS app
  (`isCodeCandidate` in `macos/Sources/BridgeyMac/CodeReader.swift` returns false unless
  `smsDefaultApp` is true or the package is a known SMS app). A Gmail or Outlook notification with a
  code shows as a plain mirrored notification. The phone also forwards only `EXTRA_TEXT`, which for
  a mail app is usually the subject alone (assumption, to check on the phone in Phase 0).
- **The cheapest private source is the notification the phone already mirrors.** It needs no new
  permission, no account, no server and no Google review. Its limits are what the preview holds and
  which emails notify at all: Gmail notifies only for Primary by default, and most code emails land in
  Updates (see 2.1).
- **Direct mailbox access works but costs more.** The Gmail API needs a restricted scope
  (`gmail.readonly`, and even `gmail.metadata` is restricted). For Rahul's own accounts an unverified
  "personal use" client is allowed (under 100 users, with a warning screen). Shipping it to everyone
  means restricted-scope verification plus a yearly CASA security assessment (about $540 to
  $4,500 a year from the cheapest lab, several weeks).
- **Mail.app on the Mac is the weakest fit for Rahul.** macOS already fills codes from Mail into
  Safari (and, since macOS 26, other browsers) and can delete them after use, so Bridgey adds little
  for a Mail.app user. On 2026-10-31 the personal Mac had no Mail data at all and the work Mac had a
  Mail folder but Mail was not running.

**Recommendation:** Phase 0 measures (one week of count-only numbers on the phone plus a synthetic
email eval of the model). Phase 1 reads codes from mirrored email notifications, with no new
permissions. Phase 2 (only if Phase 1 misses codes Rahul cares about) reads Gmail directly from the
Mac through the Gmail API with a personal-use client, for Rahul's own accounts. Mail.app, IMAP,
browser extensions and forwarding stay out.

## 2. What was checked

### 2.1 Rahul's own code emails (count only)

On 2026-10-31 a read-only, count-only script ran over the last 365 days of two of Rahul's mailboxes
(`info@roundrobin.in` and the job-mail Gmail, through `gog --readonly`). It searched subjects with
code words, looked for a code-like token with a code word nearby, and printed totals only. No code,
subject or body was printed or kept; the fetched data was deleted afterwards. The personal Gmail had
only one matching message, so it is left out.

| | Count |
| --- | --- |
| Messages with code words in the subject | 104 |
| ... in Gmail's Updates category / Primary / Promotions | 79 / 22 / 2 |
| Messages where a code was found | 35 |
| Code in the subject | 9 of 35 (26%) |
| Code in the subject or the first 100 characters of the body | 14 of 35 (40%) |
| Code in the subject or the first 200 characters of the body | 29 of 35 (83%) |
| Code further than 600 characters into the body | 2 of 35 |
| Body length (URLs removed), median | about 600 to 700 characters |

Caveats: a regex heuristic, not the model; a small sample from two accounts; Gmail's text body,
not the actual notification preview. What it says: a preview of about 200 characters would hold most
codes, the subject alone holds about a quarter, whole bodies are longer than the relay's 600
character limit, and **three in four code emails are in Updates, which Gmail does not notify for by
default** ("By default, notifications are turned on for any messages in your Primary label",
[Gmail Help](https://support.google.com/mail/answer/1075549?hl=en&co=GENIE.Platform%3DAndroid)).

### 2.2 Android 15+ hiding of codes in email notifications

- Android hides the text of notifications in which "an OTP has been detected" from untrusted
  listeners; companion device associations are exempt
  ([Android 15 behavior changes](https://developer.android.com/about/versions/15/behavior-changes-all)).
- In the open-source notification assistant (ExtServices), the detector's own filter includes
  `CATEGORY_EMAIL` and the BigText and Inbox styles that Gmail uses
  (`NotificationOtpDetectionHelper.java`, `SENSITIVE_NOTIFICATION_CATEGORIES`, `SENSITIVE_STYLES`), but
  the assistant runs it only when the package equals the default SMS app (`Assistant.java`,
  `Objects.equals(sbn.getPackageName(), mSmsHelper.getDefaultSmsPackage())`)
  ([ExtServices source](https://android.googlesource.com/platform/packages/modules/ExtServices/+/refs/heads/main/java/src/android/ext/services/notification/)).
  So on phones using the AOSP assistant, email notifications are not hidden. Pixels use Google's
  closed Android System Intelligence, and OnePlus may use either, so this is checked on the phone.
- Either way, a phone with Bridgey's companion link (already offered for SMS codes) is exempt, so the
  fix is the same. Bridgey only needs to recognise the placeholder on email notifications too.
- Gmail added its own "Copy code" pill in the inbox list and inside the email in September 2026, but
  not in the notification
  ([Android Police](https://www.androidpolice.com/gmail-for-android-finds-verification-codes-so-you-dont-have-to/)).

### 2.3 Apple's own features

macOS 14 and later fill verification codes from Mail (and Messages) into Safari and can delete them
after use ("Clean Up Automatically", now "Delete After Use"); the feature is Apple Mail only and does
not help Gmail users ([MacStories](https://www.macstories.net/stories/macos-sonoma-the-macstories-review/11/),
[iDownloadBlog](https://www.idownloadblog.com/2023/06/29/how-to-auto-delete-sms-and-email-codes-on-iphone-mac/)).
macOS 26 extended code autofill to third-party browsers but not to third-party apps
([MacRumors](https://www.macrumors.com/2025/06/12/ios-26-macos-tahoe-expand-one-time-code-autofill/)).
For someone who reads mail in Mail.app, macOS already does most of this job.

## 3. Options

### 3.1 Email notifications already mirrored from the phone

The phone's notification listener already receives Gmail, Outlook and other mail notifications and
forwards them encrypted to the paired Macs. To read codes from them:

- the phone marks mail-app notifications (`CATEGORY_EMAIL`, or a known mail package) and, only for a
  Mac that turned email codes on, adds the expanded preview (`EXTRA_BIG_TEXT`, which for Gmail is
  likely the subject plus the first lines of the body; assumption to check) capped at 600 characters;
- the Mac runs the same reader and guard on it, with a stricter pre-check for mail (section 6).

No new Android or macOS permission. Covers every mail app on the phone. Misses what the phone does not
notify for (Gmail's Updates by default), codes beyond the preview, and mail apps that put only "New
message" in the notification.

### 3.2 Mail.app on the Mac

| Way in | What macOS allows | Setup for Rahul | Reliability |
| --- | --- | --- | --- |
| Read Mail's files: `~/Library/Mail/V10/MailData/Envelope Index` (SQLite) and `.emlx` bodies | Needs Full Disk Access for Bridgey ([amail](https://github.com/KorigamiK/amail), [Apple Mail on-disk format](https://github.com/ErnestoCobos/cobos-apple-mail-mcp/wiki/Apple-Mail-on-disk-format)). Full Disk Access also opens Messages, Safari history and every other protected folder | Add Bridgey to Full Disk Access; Mail set to download whole messages | Undocumented schema that changes between macOS releases; only after Mail syncs; Mail must run |
| Mail rule with "Run AppleScript" | Scripts live in `~/Library/Application Scripts/com.apple.mail`; adding the rule by script needs Automation consent for Mail | Create a rule, or allow Bridgey to control Mail | Rules run only while Mail runs and only on mail Mail itself receives; handing the text to Bridgey needs a local channel |
| Mail extension (MailKit, macOS 12+) | `MEMessageActionHandler.decideAction(for:)` is called "as MailKit downloads messages"; it can ask again with the body, and `MEMessage.rawData` holds the full RFC 2822 message ([MEMessageActionHandler](https://developer.apple.com/documentation/mailkit/memessageactionhandler), [rawData](https://developer.apple.com/documentation/mailkit/memessage/rawdata)). `MEMessageDecoder` is for encrypted mail, not this | Turn the extension on in Mail > Settings > Extensions | Clean API, no Full Disk Access. Mail must run. Unknown: whether Mail loads an extension from our self-signed build, and how a sandboxed extension hands a code to the app (the Share extension uses a named pasteboard and a URL, which is wrong for codes) |

All three need Mail.app set up and running, which Rahul does not do today, and duplicate Apple's own
autofill from Mail.

### 3.3 Direct mailbox access

**Gmail API (OAuth).**

- Scopes: `gmail.readonly` is restricted; `gmail.metadata` is also restricted and excludes the body
  ([Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)). Since the code is
  in the subject only a quarter of the time (2.1), metadata gives no review advantage and loses most
  codes, so `gmail.readonly` it would be.
- Review: personal-use apps (fewer than 100 users, known to the developer) can skip verification and
  click through the "unverified app" screen; the cap is for the project's lifetime. Apps in "Testing"
  need no verification but their refresh tokens expire after 7 days. Internal apps in a Workspace
  organisation have no cap and no warning
  ([When is verification not needed](https://support.google.com/cloud/answer/13464323?hl=en),
  [OAuth 2.0 Policies](https://developers.google.com/identity/protocols/oauth2/policies)).
- For everyone: restricted-scope verification, and "If you store or transmit restricted scope data on
  servers, then you need to complete a security assessment"
  ([Restricted scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)).
  Older guidance exempted local-only clients, but recent developer reports say Google asked
  local-only apps for CASA anyway
  ([Google Developer forums](https://discuss.google.dev/t/is-casa-required-for-all-access-restricted-scopes/340650)).
  CASA Tier 2 through TAC Security is about $540 a year (premium up to $1,800, Tier 3 about $4,500),
  and verification takes weeks
  ([Switch Labs](https://www.switchlabs.dev/post/casa-tier-2-tier-3-security-review-providers-pricing-and-the-cheapest-option),
  [Google Groups](https://groups.google.com/g/google-apps-script-community/c/XgsHT2Fr7u8)).
- New mail: push needs a Cloud Pub/Sub topic, renewing `watch` at least every 7 days, and carries only
  a `historyId` ([Gmail push](https://developers.google.com/workspace/gmail/api/guides/push)). A Mac app
  can instead poll `history.list` every 10 s while awake, which needs no server.

**Microsoft Graph (Outlook.com, Microsoft 365).** Delegated `Mail.Read` works for personal Microsoft
accounts, with delta queries per folder
([message: delta](https://learn.microsoft.com/en-us/graph/api/message-delta?view=graph-rest-1.0)).
Change notifications need a public HTTPS endpoint and subscription renewal
([Outlook change notifications](https://learn.microsoft.com/en-us/graph/outlook-change-notifications-overview)),
so a Mac would poll delta instead. No CASA equivalent for personal accounts; Microsoft 365 tenants may
block consent to apps from unverified publishers.

**IMAP IDLE with an app password.** Near-instant on new mail, no Google review. But the app password
is a full-mailbox credential: Google says app passwords "aren't recommended", need 2-Step Verification,
can be blocked by work accounts and are revoked when the Google password changes
([Google Account Help](https://support.google.com/accounts/answer/185833?hl=en)). Outlook.com no
longer accepts basic authentication for IMAP
([Microsoft known issue](https://support.microsoft.com/en-us/support/known-issues/outlook-and-other-apps-are-unable-to-connect-to-outlook-com-when-using-basic-authentication)),
so it would need OAuth there anyway. A held IDLE connection is fine on a Mac and costly on a phone.

**Where it would run.**

- **The Mac (recommended for Phase 2):** the reader and model already live there, it is mains-powered,
  and mail never leaves it. The catch: this edition has no usable Keychain (self-signed builds, see
  [rr-mac-signing.md](rr-mac-signing.md)), so the refresh token would sit in a 0600 file like
  `trust-v3.json`, readable by any process running as Rahul.
- **The phone:** it already has the Gmail app's notifications (3.1); a second background sync of the
  mailbox costs battery and adds Android background limits for little gain.
- **A server: never.** It would put every email through Round Robin's infrastructure, break the
  promise in SECURITY.md that Round Robin servers see only ciphertext (the opt-in cloud engine being
  the one, capped, exception), and trigger CASA for certain.

### 3.4 Browser extensions and forwarding

- **Chrome or Safari extension reading a Gmail tab.** Works only while a Gmail tab is open and loaded,
  depends on Gmail's page structure, needs "read and change your data on mail.google.com", and needs a
  native-messaging bridge to the app. Our Safari extension would be unsigned, and "Allow unsigned
  extensions" resets every time Safari quits
  ([Running your Safari web extension](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)).
  Rejected: fragile and narrow.
- **Forwarding rules to a Bridgey-owned address.** Rejected for privacy: every forwarded email (and its
  code) would pass through and be readable on a Round Robin mail server, which contradicts the no-server
  design; Bridgey has no accounts to route a code to the right Mac; and Gmail forwarding needs a
  confirmed address and filters per account.

## 4. Options matrix

Latency is from the email reaching the mailbox to the code on the Mac. "Seconds" for Gmail's push to
the phone is an assumption measured in Phase 0. Effort is rough engineering days including tests.

| Option | Privacy (where mail goes, what is kept) | Permissions and setup | Latency | Reliability | Review cost | Effort | Reuses engines and CodeGuard |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **A. Mirrored mail notifications** | Preview (max 600 chars) inside the existing encrypted session; nothing stored; codes never logged | None new. Optional: Gmail filter or Updates notifications | Gmail push (seconds) + under 1 s | Limited by what notifies and what the preview holds (about 40 to 80% of code emails, 2.1) | None | 4 to 5 | Fully; needs an email eval of the model |
| B1. Mail.app files | Whole mailbox readable by Bridgey | Full Disk Access (opens every protected folder) | Mail's sync + poll | Low: undocumented, Mail must run | None | 4 | Yes, after MIME parsing |
| B2. Mail rule + AppleScript | Mail text through a local script | Rule in Mail, Automation consent | Mail's sync | Low to medium | None | 3 | Yes |
| B3. MailKit extension | Message bodies seen by Bridgey's extension | Enable in Mail settings | Mail's sync | Medium; signing and IPC unknown | None | 5 to 7, plus a spike | Yes, after MIME parsing |
| **C1. Gmail API on the Mac** | Mailbox read on the Mac only; refresh token in a 0600 file | Google sign-in, unverified-app warning | Up to 10 s polling + 1 s | High for Gmail | Free for Rahul's accounts; verification + CASA (about $540 to $4,500 a year) for everyone | 5 to 7 | Yes, after MIME parsing |
| C2. Graph on the Mac | As C1 | Microsoft sign-in | Polling interval | High for Outlook | None for personal accounts | 4 to 5 | Yes |
| C3. IMAP IDLE, app password | App password = full mailbox, on disk | Create app password | Seconds | Medium (revoked on password change, blocked on some accounts) | None | 4 to 5 | Yes |
| D1. Browser extension | Gmail page content | Unpacked or unsigned extension, native host | Seconds while the tab is open | Low | Store review if published | 5 | Yes |
| D2. Forwarding to Bridgey | Every forwarded email on a Round Robin server | Forwarding filter per account | Seconds | Medium | Server privacy policy | 3 + server | Yes |

## 5. Recommended plan

### Phase 0: measure (about 2 days of work, 1 week of counting)

1. **Phone, lab builds only:** extend the hidden Code reader test with an "Email notifications" tally.
   For each mail-app notification over a week it counts, never logging text: notifications seen,
   group summaries, `EXTRA_TEXT` vs `EXTRA_BIG_TEXT` length, whether a code-like token with a code
   word is in the title, text or big text, and whether Android's placeholder replaced the text.
   Run on Rahul's OnePlus 11 (Android 16) and on the API 36 emulator with a test Google account.
2. **Model eval:** add synthetic email-preview sets to `outputs/bridgey/research/otp-tiny-model`
   (subject plus about 200 characters of body; global services, Indian banks and government, GitHub,
   Microsoft, Apple, Slack-style codes, plus look-alikes: order and invoice numbers, tracking, promo
   codes, newsletters, "your code expired", sign-in links without a code), and a blind set written by
   a separate agent. Run v3 on the personal Mac and the cloud relay.
   Gate: at least 97% exact on code messages, no wrong code on any code message, at most 1% codes
   shown on no-code messages. If v3 misses the gate, a round-5 fine-tune mixes email templates in,
   and must not regress the SMS sets (the v4 lesson in the model README).

### Phase 1: codes from mail notifications (about 5 days)

- **Android:** classify mail-app notifications (`CATEGORY_EMAIL`, or a short list of mail packages:
  Gmail, Outlook, Samsung Email, Proton Mail, Yahoo Mail, Spark, K-9/Thunderbird, Zoho Mail). For a
  peer with `email_codes_draft1` true, add `emailApp` and `preview` (section 7). Skip group summaries.
  Apply the redaction check to mail apps too and let a hidden email count towards `codes.status`.
- **Mac:** a separate switch "Also read codes in email" under Codes from messages. `isCodeCandidate`
  gains a mail branch: switch on, not redacted, `preview` (or `text`) at most 600 characters, and the
  stricter mail pre-check. Same reader, same 2 s budget, same guard, same `postCodeNotification`,
  so the banner, the Copy code button, the panel card, auto-copy and the floating 60 s copy panel all
  work unchanged. The card says where the code came from ("by email").
- **Engine:** see question 4. The plan assumes email follows the chosen engine only if Rahul says so;
  otherwise email codes are read on this Mac only.
- **Dedup and filtering** as in section 6.
- **Help for Gmail:** the setup copy explains Gmail's Primary-only default and offers the filter
  (section 8).

### Phase 2: Gmail directly on the Mac (only if Phase 1 misses codes Rahul needs; about 6 days)

- A Round Robin Google Cloud project, External, "In production", unverified, `gmail.readonly` only,
  used only by Rahul's own accounts (stays under the 100-user personal-use cap; never "Testing", whose
  tokens die after 7 days). Workspace accounts on roundrobin.in can use an Internal client instead.
- The Mac signs in with the system browser (PKCE, loopback redirect), stores the refresh token in a
  0600 file under Application Support (same handling as `trust-v3.json`, excluded from backups),
  polls `users.history.list` every 10 s while the Mac is awake and Bridgey runs, fetches only new
  INBOX messages from the last 15 minutes, and reads subject plus the first 600 characters of the
  plain-text body through the same reader and guard. Nothing is stored except the last `historyId`.
- Disconnect revokes the token at Google and deletes the file. Codes found here dedup against the
  phone's (section 6).
- If it ever ships to other users: restricted-scope verification and yearly CASA, a product and
  spend decision for Rahul.

### Not planned

Mail.app (any of the three ways), IMAP with app passwords, Microsoft Graph (until Rahul names an
Outlook account), browser extensions, forwarding.

## 6. Matching, dedup and filtering

**Same Copy code UX.** An email code becomes a `LiveCodeCard` exactly like an SMS code, so it gets the
banner "Code 482913 from GitHub" (sender = the notification title, else the app name), the Copy code
button, the panel card for 10 minutes, auto-copy under the same rules (unlocked, used in the last two
minutes, setting on) and the floating 60 s copy panel. The card gains one field, the source
(`sms` or `email`, later `gmail`), shown as "by text" or "by email". The clipboard handling
(concealed, this Mac only, cleared after 60 s) does not change. History keeps "Sent a one-time code".

**Dedup.** Banks and some services send the same code by SMS and email.

- Key: the accepted code, uppercased, across all sources and all paired phones (and Phase 2).
- Window: the life of the card (10 minutes).
- The second arrival shows no new banner, no sound, no auto-copy and no second floating panel; the
  existing card adds "also by email". Its notification goes to history only.
- A different code from the same sender is a new card (the newer code usually replaces an older one).

**Filtering marketing and look-alikes.**

1. Gmail's default notification setting already skips Promotions (2 of 104 in 2.1).
2. A stricter pre-check for mail than for SMS: the text must pass `looksLikeOtpTraffic` and contain a
   code word near the token (code, OTP, one-time, verification, verify, passcode, PIN, sign in, login,
   2FA, security code, and the Hindi words the pattern baseline uses). Order, invoice and promo mails
   rarely say these words next to their numbers.
3. The model decides; it was trained on promo and transaction look-alikes, and Phase 0 adds email ones.
4. `CodeGuard` refuses anything not literally in the preview or not shaped like a code (4 to 8
   characters, every part with a digit). Known gap: codes with a letters-only group, such as
   "ABC-123", are refused; the Phase 0 eval says how common they are.
5. Later, if needed: "Not a code" on the card, remembered per sender on this Mac.

## 7. Protocol changes (draft)

New draft key **`email_codes_draft1`** in `features.update`. Each side sets it when notifications are
on for that peer and, on the Mac, when "Also read codes in email" is on. Missing means `false`. It
needs `sms_codes_draft1` too (it reuses `codes.status` and the companion link). Upstream peers never
see any of this.

**New fields on `notifications.post`** (phone to Mac, inside the encrypted payload), sent only to a
peer whose latest `features.update` showed `email_codes_draft1: true`:

| Field | Type | Meaning |
| --- | --- | --- |
| `emailApp` | boolean, on mail-app notifications | the notification came from a mail app (category email or a known mail package) |
| `preview` | string, at most 600 UTF-16 units, optional | the expanded text (`EXTRA_BIG_TEXT`, else `EXTRA_TEXT`), only when it passes `looksLikeOtpTraffic` on the phone and is not a group summary; never cut, so a longer text is left out |
| `redacted` | boolean, now also with `emailApp: true` | Android's placeholder replaced the text |

No new messages. `codes.status` keeps its meaning; a hidden mail notification counts like a hidden
SMS. Settings sync gains one key, `codes.email` (boolean), next to `codes.enabled`. Update
`docs/protocol.md`, `docs/protocol-contract.md` and `ProtocolContractTest.kt` together. Phase 2 is
local to the Mac and changes no protocol. `preview` and codes are never logged, as for SMS.

## 8. Settings and setup copy

**Mac, Settings > Notifications > Codes from messages** (new rows under the existing switch):

- Switch: **Also read codes in email**
  Subtitle: "Gmail, Outlook and other mail apps on your phone. Bridgey reads the preview your phone
  already shows, on this Mac. Off by default."
- When on and the engine is Cloud: "Email previews are read on this Mac, not in the cloud." (or, if
  Rahul chooses so in question 4, the cloud confirmation says "text messages and email previews").
- Help row: **Not seeing codes from Gmail?**
  "Gmail on your phone only notifies for Primary unless you change it, and most code emails land in
  Updates. Either add a Gmail filter that puts code emails in Primary, or turn on notifications for
  Updates in Gmail (this notifies for every update)."
  Button: **Show me how** opens a one-page guide:
  1. On a computer, open Gmail, search `subject:(code OR OTP OR verification OR "sign in")`.
  2. Click the filter icon, then Create filter.
  3. Tick "Categorize as: Primary" and "Also apply filter to matching conversations". Create filter.
- Code card source line: "by text" / "by email"; duplicate line: "Also arrived by email".

**Phone, Settings > Notifications:** "Email codes: uses your mail app's notifications" under Code access.

**Setup question** (same step as Codes from messages): "Show codes from email too?" with "Uses the
email notifications your phone already sends. Nothing else is read."

**Phase 2, Mac, Codes from messages > Gmail on this Mac:**

- Button: **Connect Gmail**
- Before sign-in: "Bridgey on this Mac checks this Gmail account for new mail every 10 seconds and reads
  only new messages that look like they hold a code. Mail is read on this Mac and never sent anywhere.
  Google will say the app is not verified: it is Round Robin's own app for your accounts. Disconnect
  any time here or at myaccount.google.com/permissions."
- Connected: "Connected: name@gmail.com. Last checked 4 s ago." Button: **Disconnect**.

## 9. Test plan

Builds and suites run on the RR CI runners. Tests never use Rahul's real mailboxes or phone number for
sending; device tests use a dedicated test Google account.

**Unit (Android):** mail-app classification (category, package list, not calls, not Bridgey);
preview from BigText, Inbox and Messaging styles; group summaries skipped; 600-character limit with no
cutting; pre-check gating; redaction detection on mail apps; `preview` absent for a peer without the
key; nothing logged (log capture assertion).

**Unit (Mac):** `isCodeCandidate` mail branch (switch off, redacted, too long, no code word); dedup
(SMS then email, email then SMS, two phones, different codes, outside 10 minutes); one banner, one
auto-copy, one floating panel per code; card source text; history text; `codes.email` settings sync;
the email engine choice from question 4.

**Contract:** `email_codes_draft1` and the three fields in `protocol-contract.md` and
`ProtocolContractTest.kt`; an old Mac ignores the fields; an old phone never sends them.

**Model:** the Phase 0 email sets and gate on the shipped model and on the relay; the SMS sets
re-run unchanged if the model changes.

**Device:**

- API 36 emulator with the test Google account in Gmail: real code emails (GitHub, Microsoft and
  Google sign-in codes to the test account) and look-alikes; check the preview fields, the Mac banner,
  Copy code and the floating panel.
- Rahul's OnePlus 11, Android 16, with the test account added to Gmail: the same, plus with and
  without the companion link, to see whether OxygenOS hides email codes.
- Latency, 20 emails: the message's `Date` header to the Mac banner. Target: Bridgey's part under
  1 s; report Gmail's part as measured.
- Privacy: logs at the most verbose level contain no preview or code; diagnostics hold outcome words
  only.

**Phase 2:** sign-in and refresh with the test account; token file is 0600 and excluded from backups;
revoked token shows "Reconnect"; `historyId` too old falls back to the last 15 minutes; sleep and wake;
offline; quota stays far below limits at a 10 s interval.

## 10. Questions for Rahul

1. **Which inboxes matter?**
   (a) Gmail on the phone (personal, job and Round Robin accounts); (b) also an Outlook account;
   (c) also Mail.app on a Mac.
   Recommendation: (a). Mail.app is not running on either Mac, and macOS already fills codes from it.

2. **Gmail only notifies for Primary, and 79 of 104 code-like emails were in Updates. How should
   they reach the phone's notifications?**
   (a) A Gmail filter per account that puts code emails in Primary (I can add it to your accounts);
   (b) turn on Updates notifications in Gmail (noisy); (c) leave it, and rely on Phase 2.
   Recommendation: (a).

3. **Build Phase 2 (read Gmail directly on the Mac)?**
   (a) Not now: ship Phase 1, look at two weeks of misses, then decide; (b) yes, for your own accounts
   only, with Google's "unverified app" warning; (c) yes, for every user, which needs Google
   verification and a yearly security assessment (about $540 to $4,500 a year, several weeks).
   Recommendation: (a).

4. **Which engine reads email codes?**
   (a) Always on this Mac, even when Cloud is chosen for text messages; (b) whatever engine is chosen
   for text messages, with the cloud consent text mentioning email.
   Recommendation: (a). Email previews carry more personal detail than an SMS, and the on-Mac model
   is the default anyway.

5. **The same code by SMS and email?**
   (a) One banner; the card says "also by email"; (b) show both.
   Recommendation: (a).

6. **Default for "Also read codes in email"?**
   (a) Off until chosen, offered in setup and Settings; (b) on whenever Codes from messages is on.
   Recommendation: (a), matching the edition's "off until chosen".

## Sources

- [Android 15 behavior changes: OTP redaction](https://developer.android.com/about/versions/15/behavior-changes-all)
- [AOSP ExtServices notification assistant (Assistant.java, NotificationOtpDetectionHelper.java)](https://android.googlesource.com/platform/packages/modules/ExtServices/+/refs/heads/main/java/src/android/ext/services/notification/)
- [Gmail Help: notification settings on Android](https://support.google.com/mail/answer/1075549?hl=en&co=GENIE.Platform%3DAndroid)
- [Android Police: Gmail finds verification codes (2026-09-21)](https://www.androidpolice.com/gmail-for-android-finds-verification-codes-so-you-dont-have-to/)
- [MacStories: macOS Sonoma review, codes from Mail](https://www.macstories.net/stories/macos-sonoma-the-macstories-review/11/)
- [iDownloadBlog: auto-delete SMS and email codes](https://www.idownloadblog.com/2023/06/29/how-to-auto-delete-sms-and-email-codes-on-iphone-mac/)
- [MacRumors: one-time code autofill in macOS Tahoe](https://www.macrumors.com/2025/06/12/ios-26-macos-tahoe-expand-one-time-code-autofill/)
- [amail: Apple Mail's local index](https://github.com/KorigamiK/amail)
- [Apple Mail on-disk format](https://github.com/ErnestoCobos/cobos-apple-mail-mcp/wiki/Apple-Mail-on-disk-format)
- [MailKit: MEMessageActionHandler](https://developer.apple.com/documentation/mailkit/memessageactionhandler)
- [MailKit: MEMessage.rawData](https://developer.apple.com/documentation/mailkit/memessage/rawdata)
- [Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- [Google: when verification is not needed](https://support.google.com/cloud/answer/13464323?hl=en)
- [Google OAuth 2.0 Policies](https://developers.google.com/identity/protocols/oauth2/policies)
- [Google: restricted scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)
- [Google Developer forums: is CASA required for all restricted scopes](https://discuss.google.dev/t/is-casa-required-for-all-access-restricted-scopes/340650)
- [Switch Labs: CASA Tier 2 and 3 providers and pricing](https://www.switchlabs.dev/post/casa-tier-2-tier-3-security-review-providers-pricing-and-the-cheapest-option)
- [Google Groups: CASA verification pricing thread](https://groups.google.com/g/google-apps-script-community/c/XgsHT2Fr7u8)
- [Gmail API push notifications](https://developers.google.com/workspace/gmail/api/guides/push)
- [Google Account Help: app passwords](https://support.google.com/accounts/answer/185833?hl=en)
- [Microsoft: Outlook.com basic authentication](https://support.microsoft.com/en-us/support/known-issues/outlook-and-other-apps-are-unable-to-connect-to-outlook-com-when-using-basic-authentication)
- [Microsoft Graph: message delta](https://learn.microsoft.com/en-us/graph/api/message-delta?view=graph-rest-1.0)
- [Microsoft Graph: Outlook change notifications](https://learn.microsoft.com/en-us/graph/outlook-change-notifications-overview)
- [Apple: running your Safari web extension](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)
