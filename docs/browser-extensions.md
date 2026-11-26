# Browser extensions

Bridgey's extension sends the page you are on, or a link, from Chrome, Edge, Firefox, Brave or Arc to a phone
or computer paired with Bridgey. It uses the link handoff the apps already have (`quick.request` with
`feature: "links"`, opened at once where the receiving device allows it, see
[protocol.md](protocol.md#open-links-right-away-links_open_draft1)). The roadmap item is "Package browser
extensions for link handoff" (v0.9).

- **Toolbar button:** a popup with the page, your devices and their state, **Send**, and your last five sends.
- **Right-click** a page or a link: **Send this page to Pixel 8**, **Send link to Work Mac**.
- **Alt+Shift+S** sends the page to the device you used last (or the only one that can take it). **Alt+Shift+B**
  opens the popup. Both can be changed in the browser's extension shortcuts.
- A `tel:` link goes to the chosen phone as a call request on the Mac, under Settings > Calls > When another
  app asks to call (it asks first by default). An email address from a `mailto:` link goes to the device's
  clipboard.

| Part | Where |
| --- | --- |
| The extension (Manifest V3, one source for Chrome, Edge and Firefox) | [extensions/browser/src](../extensions/browser/src) |
| Packaging per browser | [extensions/browser/build.py](../extensions/browser/build.py) |
| The native messaging helper (Rust) | [rust/browser-host](../rust/browser-host) |
| Extension IDs and host name, one file for the helper and both apps | [extensions/browser/native-host.json](../extensions/browser/native-host.json) |
| Mac: manifests, socket, Settings row | [BrowserSupport.swift](../macos/Sources/BridgeyMac/BrowserSupport.swift) |
| Windows: requests, manifests, registry, pipe, Settings row | [BrowserBridge.cs](../windows/src/Bridgey.Core/BrowserBridge.cs), [BrowserHost.cs](../windows/src/Bridgey.App/Platform/BrowserHost.cs) |
| Store listing drafts | [extensions/browser/store](../extensions/browser/store/README.md) |

## Install by hand

Every beta and Stable release carries `Bridgey-RR-<version>-Chrome.zip`, `-Edge.zip` and `-Firefox.zip`, listed
in `SHA256SUMS`. Until the extension is in the stores:

1. **Turn on browser support in Bridgey.** Mac: Settings > Media and actions > **Browser extensions** >
   **Install**. Windows: Settings > Media and actions > **Browser extensions** (switch on). This registers the
   helper with the browsers on this computer, for your user only.
2. **Chrome, Brave, Arc, Vivaldi:** unzip the Chrome zip into a folder you keep (for example
   `~/Bridgey extension`). Open `chrome://extensions`, turn on **Developer mode**, choose **Load unpacked** and
   pick the folder. Chrome may remind you at start that developer mode extensions are on.
3. **Edge:** the same with the Edge zip at `edge://extensions` (**Developer mode**, **Load unpacked**).
4. **Firefox:** Firefox installs only signed add-ons for good. Until the add-on is signed by Mozilla, open
   `about:debugging#/runtime/this-firefox`, choose **Load Temporary Add-on** and pick the Firefox zip. It stays
   until Firefox quits. Firefox Developer Edition and Nightly can keep it: set
   `xpinstall.signatures.required` to false in `about:config`, then install the zip from `about:addons`.
5. Pin the Bridgey button to the toolbar.

The unpacked extension has a fixed ID (`aajelmcjgfjbhemgofnompobgbcdfcin`) because its manifest carries the
extension's public key, so the helper accepts it. To update, unzip the new release over the same folder and
choose the reload button on the extension's card.

## How it works

```
extension (popup, menus, shortcut)
   runtime.sendNativeMessage("in.roundrobin.bridgey", {v, type, device, url})
browser starts the helper named in the host manifest, one process per message
   bridgey-browser-host  (checks the caller and the message, stdin/stdout, 32-bit length + JSON)
private local channel, same user only
   Mac: Unix socket ~/Library/Application Support/<bundle ID>/browser.sock
   Windows: named pipe \\.\pipe\in.roundrobin.bridgey.browser.<user SID>
Bridgey app
   links: quick.request to that device (open if it shows links_open_draft1, else offer)
   tel:   calls.request from that phone (Mac), after Settings > Calls allows it
   mailto: clipboard text to that device
```

The extension holds no keys and opens no network connection. The app sends with the session it already has with
the device, end to end encrypted as always.

### Why native messaging, not a port on localhost

Native messaging is the channel browsers provide for talking to an app on the same computer, and it is the better
choice here:

- **Only our extension can start the helper.** The browser reads the host manifest and starts the helper only for
  the extension IDs listed in it. A web page cannot reach it at all. A port on `127.0.0.1` is reachable by every
  web page in every browser (fetch, WebSocket, image requests), so it would need its own pairing, tokens, Origin
  checks and DNS rebinding defences, and any of those can be got wrong.
- **No secret to store.** A localhost design needs a shared secret between the app and the extension, kept in
  extension storage. Native messaging needs none: the caller is the browser's own process, and the helper checks
  the extension ID the browser passes.
- **Nothing listening on the network.** No port to collide with other apps, no firewall prompt on Windows, and
  nothing for local network scanners to find.
- **Works with Manifest V3.** `runtime.sendNativeMessage` starts the helper on demand, so the service worker can
  stop between sends.

The costs are an install step (the app writes the host manifests) and one small helper per platform. Both apps
already ship native code, so the helper is one more Rust binary built in the same jobs.

### Why a separate helper

The browser starts the native host as a new process for every message. Starting the whole Bridgey app for that
would load its UI frameworks and, on the Mac, the code model runtime. The helper is a few hundred kilobytes, starts
in milliseconds, and is the same code on macOS, Windows and Linux, so its checks are tested once
(`cargo test -p bridgey-browser-host`). It holds no pairing data: it only forwards a checked request to the running
app, which owns the sessions.

## What crosses, and the checks at each step

Only two requests exist, and only addresses (http, https, mailto, tel) and the device choice cross.

1. **The extension** reads the page address only when you click the button, a menu item or the shortcut
   (`activeTab`). It has no `tabs` or host permissions and no content scripts. It normalises the address the way
   browsers write it and refuses anything else (`file:`, `data:`, `javascript:`, browser and extension pages, user
   names in addresses, more than 4,096 bytes).
2. **The helper** refuses callers that are not Bridgey's extension IDs, even if a manifest names it: the IDs are
   built in from `native-host.json`. Chromium browsers pass `chrome-extension://<id>/`; Firefox passes the
   manifest path and the add-on ID. The message must be at most 8 KiB, one JSON object with exactly the expected
   keys, no repeated keys, `v: 1`, a device ID of letters, digits and hyphens, and an address that passes the same
   rules every Bridgey device applies to links (host, no user name or password, valid port, printable ASCII, no
   backslash). `tel:` numbers are reduced to 3 to 15 digits with an optional `+`. The helper uses the app's channel
   only when it belongs to the same user: on macOS and Linux the socket and its folder must be owned by the user,
   the socket must be `0600` and not a symlink, and the peer's user ID is checked with `getpeereid` or
   `SO_PEERCRED`; on Windows the process serving the pipe must run as the same user (its token SID), so a pipe
   another account created first never gets the address. The app's answer is reduced to known fields (device ID,
   name, platform, connected, links, calls) before it goes to the browser.
3. **The app** checks the request again (strict JSON, exact keys, address rules), answers only while browser
   support is on, only to the same user, at most eight connections at a time, and gives every request at most 12
   seconds. The device must be paired, connected and have Links on at both ends; a second link to the same device
   waits until the first is answered.

Nothing is stored except in the extension: the last device used and the last five sends (page title and site
name, never the full address), in this browser only, cleared with **Clear**.

A note on IDs: a store-installed extension's ID is guaranteed by the store. An unpacked extension's ID comes from
the key in its manifest, so someone who can load unpacked extensions in your browser (developer mode, on your
account) could reuse Bridgey's key. That person can already run code as you, so it adds no new risk, but it is why
the helper's checks never rely on the ID alone for what it may do: it can only ask for the device list and send
an address to a device you paired.

## Messages

Extension to helper (native messaging, at most 8 KiB):

```json
{"v": 1, "type": "devices"}
{"v": 1, "type": "send", "device": "6c1f0c1e-3a5b-4b8e-9d2a-0f7e1c2b3a4d", "url": "https://example.com/"}
```

Helper to extension:

```json
{"v": 1, "ok": true, "devices": [{"id": "...", "name": "Pixel 8", "platform": "android", "connected": true, "links": true, "calls": true}]}
{"v": 1, "ok": true, "result": "opened"}
{"v": 1, "ok": false, "error": "links_off"}
```

`result` is `opened` (the device opened it), `waiting` (it waits there for Open), `calling` (the phone was asked to
call), `asking` (the Mac asks first) or `copied` (an email address is on the device's clipboard). `error` is one
of `forbidden`, `bad_request`, `too_large`, `bad_url`, `app_not_running`, `unsafe_endpoint`, `no_answer`,
`unknown_device`, `not_connected`, `links_off`, `calls_off`, `busy`, `declined`, `rate_limited`, `unsupported` or
`failed`. When the helper is not installed the browser itself fails the call, and the popup says to turn on browser
support.

Helper to app: one newline-terminated line per connection, `{"version":1,"type":"devices"}` or
`{"version":1,"type":"send","device":"...","url":"..."}`; the app answers with one line, `{"version":1,"ok":...}`
and the fields above.

## Where the host manifests go

The manifest name is `in.roundrobin.bridgey`. Chromium browsers read `allowed_origins`
(`chrome-extension://<id>/`); Firefox reads `allowed_extensions` (the add-on ID). Everything is per user; nothing
is written system-wide and no administrator password is needed.

**Mac** (written only for browsers whose folder exists, under `~/Library/Application Support/`):

| Browser | Folder (each with `NativeMessagingHosts/` inside) |
| --- | --- |
| Chrome and its channels | `Google/Chrome`, `Google/Chrome Beta`, `Google/Chrome Dev`, `Google/Chrome Canary` |
| Chromium | `Chromium` |
| Edge and its channels | `Microsoft Edge`, `Microsoft Edge Beta`, `Microsoft Edge Dev`, `Microsoft Edge Canary` |
| Brave | `BraveSoftware/Brave-Browser` |
| Arc | `Arc/User Data` |
| Vivaldi | `Vivaldi` |
| Firefox | `Mozilla` |

The manifests name `<app>/Contents/Helpers/bridgey-browser-host`. They are written again each time Bridgey starts
with browser support on, so a moved or updated app keeps working. Bridgey refuses to install while macOS runs it
from a temporary copy (App Translocation) and asks to move it to Applications first. **Remove** deletes every
Bridgey manifest (other apps' files stay). A test instance writes its manifests to `/tmp/<bundle ID>-browsers`
and never touches the browsers.

**Windows** (`HKEY_CURRENT_USER`, the default value names the manifest in
`%LOCALAPPDATA%\Bridgey by Round Robin\NativeMessagingHosts\`):

| Browser | Key under `Software\` |
| --- | --- |
| Chrome | `Google\Chrome\NativeMessagingHosts\in.roundrobin.bridgey` |
| Edge | `Microsoft\Edge\NativeMessagingHosts\in.roundrobin.bridgey` |
| Chromium | `Chromium\NativeMessagingHosts\in.roundrobin.bridgey` |
| Brave | `BraveSoftware\Brave-Browser\NativeMessagingHosts\in.roundrobin.bridgey` |
| Firefox | `Mozilla\NativeMessagingHosts\in.roundrobin.bridgey` |

The keys are written for all five whether or not the browser is installed, so one installed later works at once.
Edge also falls back to the Chromium and Chrome keys. `bridgey-browser-host.exe` sits next to `Bridgey.exe`; the
manifests are written again at each start with the switch on, so a moved folder keeps working. A separate profile
(`BRIDGEY_DATA_DIR`) never touches the registry.

**Linux** (designed for the future Linux app, not built): manifests in `~/.config/google-chrome/`,
`~/.config/chromium/`, `~/.config/microsoft-edge/`, `~/.config/BraveSoftware/Brave-Browser/` and
`~/.config/vivaldi/` (each `NativeMessagingHosts/`), and `~/.mozilla/native-messaging-hosts/` for Firefox; the
helper already looks for the app at `$XDG_RUNTIME_DIR/bridgey/browser.sock` (`0700` folder, `0600` socket,
`SO_PEERCRED`). Browsers installed as Flatpak or Snap run sandboxed and cannot start a helper outside their
sandbox without extra setup, so the Linux app should support distribution packages of the browsers first.

## Safari

**In plain words:** Safari can have the same extension, but only inside a Mac app, and Safari hides extensions
from apps that are not signed by Apple's Developer ID and notarised. Bridgey is ad-hoc signed today, so a Safari
extension inside it would appear only after you turn on **Allow unsigned extensions** in Safari's Developer
settings, which asks for your password and turns itself off every time Safari quits. That is not usable day to
day, so this change does not ship the Safari extension. Safari's **Share > Bridgey** (the Share extension) already
sends the current page from Safari today.

What Safari requires:

- A Safari Web Extension is an app extension (`.appex`, extension point `com.apple.Safari.web-extension`) inside a
  containing app, with the web extension files in its Resources and a principal class that answers
  `browser.runtime.sendNativeMessage` (`NSExtensionRequestHandling`). It must be sandboxed. Safari lists it after
  the containing app has run once; the person turns it on in Safari > Settings > Extensions.
- **Signing:** Safari ignores ad-hoc ("Sign to Run Locally") and unsigned extensions unless **Allow unsigned
  extensions** is on (Safari 17 and later: Settings > Advanced > Show features for web developers, then Settings >
  Developer). It needs the user's password and resets when Safari quits. An Apple Development certificate only
  helps on the Mac that built it. Since Safari 18.4 (March 2025, also on macOS 13 and 14), extensions in apps
  signed with **Developer ID and notarised** load without that setting
  ([WebKit: Safari 18.4](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/)). Mac App Store apps always
  could. **Developer ID signing alone, without notarisation, is not enough.**
- Safari's **Add Temporary Extension** (Developer settings) loads a web extension folder for up to 24 hours or
  until Safari quits, but it has no containing app, so native messaging has nothing to talk to.

The design for when Developer ID and notarisation are set up (docs/macos-developer-id-readiness.md):

1. `macos/SafariExtension/`: `Info.plist` (`NSExtensionPointIdentifier` `com.apple.Safari.web-extension`,
   `NSExtensionPrincipalClass` `SafariExtension.WebExtensionHandler`), `Safari.entitlements`
   (`com.apple.security.app-sandbox`, `com.apple.security.application-groups` `<TeamID>.in.roundrobin.bridgey`),
   and `WebExtensionHandler.swift`.
2. `build-app.sh` builds it like the Share extension (`swiftc -application-extension`, entry `_NSExtensionMain`),
   copies the extension's files with a Safari manifest (no `key`, `background.scripts`) into
   `BridgeySafari.appex/Contents/Resources/`, and signs it before the app.
3. The handler receives the same two requests. Sandboxed, it cannot reach the app's socket in Application Support,
   so the app also listens on `browser.sock` inside the app group container, which both may use. App group IDs on
   macOS begin with the Team ID, and macOS 15 and later check that the group belongs to the app's team, which an
   ad-hoc signed app does not have: another reason this waits for Developer ID.
4. The extension's `sendNativeMessage` in Safari ignores the application name and goes to the containing app's
   handler, so the JavaScript stays the same.

What it needs from Rahul: the Developer ID Application certificate on the build Mac (or in RR CI's secret store),
an App Store Connect API key for `notarytool`, and his OK to sign and notarise releases. The Apple Developer
membership already exists. The Mac App Store edition (docs/macos-store-edition.md) could carry the Safari extension
too, as part of that separate review.

## Store submission

Nothing has been submitted. What each store needs from Rahul:

| Store | Account and fee | What happens | After approval |
| --- | --- | --- | --- |
| Chrome Web Store | A Google developer account, one-time US$5 registration, 2-Step Verification; optionally a verified publisher name "Round Robin" | Upload `Bridgey-RR-<version>-Chrome-store.zip` (no `key`; the store assigns the ID), the listing, screenshots, the privacy answers and the justification for `nativeMessaging`. Review takes days. | Add the store's ID to `chromiumExtensionIds` in `native-host.json` and ship the apps, so the helper and manifests accept it |
| Microsoft Edge Add-ons | A Microsoft Partner Center developer account (free) | Upload `-Edge-store.zip`, listing and privacy answers. Review takes up to seven business days. | Add Edge's ID the same way |
| Firefox Add-ons (AMO) | A Firefox account (free) | **Unlisted** signing: upload the Firefox zip, Mozilla signs it automatically within minutes, and the signed `.xpi` can go in our releases for permanent installs. **Listed** adds the public listing and a review. | Nothing: the add-on ID `bridgey@roundrobin.in` is fixed in the manifest |
| Safari | The existing Apple Developer membership | Developer ID signing and notarisation of the Mac app (see Safari above), or the Mac App Store edition | |

The stores also need a privacy policy URL; the website's privacy page (roundrobin.in/bridgey/privacy-security)
covers it once it says what the extension does (a draft paragraph is in the listing folder). Build the store
packages with `python3 extensions/browser/build.py --version <version> --out <dir> --store`.

Listing text, privacy answers and screenshots, ready for approval:
[extensions/browser/store/README.md](../extensions/browser/store/README.md).

## Tests

| What | Where it runs |
| --- | --- |
| Extension logic (address checks, requests, device list, recent sends): `node --test extensions/browser/test/*.test.js` | rr-ci/python (through `scripts/rr/tests/test_browser_extension.py` when node is there) |
| Packaging (manifests per browser, versions, fixed ID, reproducible zips, locales, no em dashes) and the release assets in `SHA256SUMS` and the provenance: `scripts/rr/tests/test_browser_extension.py` | rr-ci/python |
| Helper: framing, strict requests, address rules, unknown extension IDs refused, the app's answers reduced, socket owner and mode checks, the real binary over stdio against a fake app: `cargo test -p bridgey-browser-host` | rr-ci/python (when cargo is there) and rr-ci/windows (`build-windows.ps1`) |
| Mac: addresses, strict requests, manifests per browser, install and remove, the socket (mode, other users refused, timeouts), browser links to one device: `swift test --filter BrowserSupport` | rr-ci/macos |
| Windows: requests, addresses, replies, manifests and registry keys, the link path and refusals: `dotnet test --project tests/Bridgey.Core.Tests` | rr-ci/windows (and Linux) |
| End to end, browser: a headless Chromium loads the built Chrome package with a test-only host permission; its native host is the real helper; a stub app answers on a Unix socket: `NODE_PATH=$(npm root -g) node extensions/browser/test/e2e.mjs --chrome <chromium>` | by hand (needs puppeteer-core and Chromium) |
| End to end, Mac: the real helper, run the way a browser runs it, against a throwaway test instance paired with the scripted peer: `extensions/browser/test/mac-live.sh` | by hand on a Mac (no browser is started and no real browser folder is touched) |

## Not verified yet

- A real browser on a Mac or a Windows PC with the installed app: the checks above cover the extension in Chromium
  on Linux, and the helper with a Mac test instance, but not Chrome, Edge, Firefox, Brave or Arc starting the
  helper from an installed Bridgey.
- A Mac where the app still carries the download quarantine (installed from the DMG rather than Homebrew, which
  clears it): macOS may refuse to start the helper for the browser. If so, the fix belongs in the app (clear the
  flag on the helper when installing) rather than in instructions.
- Windows end to end: the pipe and registry code is built and unit tested on the Windows lane, not exercised with
  a browser.

## Later

- The store IDs in `native-host.json` once the stores assign them, and signed Firefox builds in releases.
- Safari, after Developer ID and notarisation.
- Calls from `tel:` links on Windows, when the Windows app can ask a phone to call.
- Receiving: the extension could also show links other devices send, instead of the app opening them.
