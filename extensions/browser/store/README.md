# Store listings (drafts, not submitted)

Drafts for the Chrome Web Store, Microsoft Edge Add-ons and Firefox Add-ons. Nothing is submitted until Rahul
approves. What each store needs (accounts, fees, IDs) is in
[docs/browser-extensions.md](../../../docs/browser-extensions.md#store-submission).

## Name

Bridgey by Round Robin

## Short description (132 characters at most; also the manifest description)

Send the page you are on, or any link, to your phone or another computer with Bridgey.

Russian: Отправляйте открытую страницу или любую ссылку на телефон или другой компьютер через Bridgey.

## Long description

Bridgey connects your phone and your computers. This extension adds a Send button to your browser.

Click it to send the page you are on to a phone or computer you paired with Bridgey. Right-click a link to send
just the link. Alt+Shift+S sends the page to the device you used last.

On the other device the page opens straight away, or waits for you to open it, depending on that device's
settings. Phone numbers can be called from your phone, and email addresses go to the device's clipboard.

The extension needs the Bridgey app on this computer (Mac or Windows) with browser support turned on in its
Settings. It talks only to that app. Nothing goes to Round Robin or anyone else: the link travels encrypted
between your own devices.

Bridgey is free and open source: https://github.com/round-robin-solutions/bridgey

## Category and language

- Chrome and Edge: Productivity. Firefox: Other (or Tabs).
- Languages: English (UK) and Russian.

## Images

| File | Use |
| --- | --- |
| [`../src/icons/icon-128.png`](../src/icons/icon-128.png) | Store icon, 128 x 128 |
| [`screenshot-1-send.png`](screenshot-1-send.png) | Screenshot, 1280 x 800 |
| [`screenshot-2-devices.png`](screenshot-2-devices.png) | Screenshot, 1280 x 800 |
| [`promo-tile-440x280.png`](promo-tile-440x280.png) | Chrome small promo tile, 440 x 280 |

The screenshots are the real popup (rendered by the end-to-end check) on a plain background.

## Privacy

**Single purpose (Chrome):** Send the current page or a link to one of the user's own devices through the Bridgey
app installed on the same computer.

**Permissions:**

| Permission | Why |
| --- | --- |
| `nativeMessaging` | Talks to the Bridgey app on this computer, which delivers the link to the chosen device. |
| `contextMenus` | Adds Send to device items to the page and link menus. |
| `activeTab` | Reads the address of the current tab only when you click the button, a menu item or the shortcut. |
| `storage` | Keeps the last device used and your last five sends (page title and site name) in this browser. |

No host permissions, no content scripts, no remote code.

**Data (Chrome's and Edge's forms):** no user data collected. Recommended answers: none of the data types; not sold;
not used or transferred for purposes unrelated to the single purpose; not used for creditworthiness or lending.
The address you choose to send goes from the browser to the Bridgey app on the same computer and from there,
encrypted, to your own device. It never reaches Round Robin. Rahul to confirm this reading of "collect" before
submitting.

**Firefox:** the manifest declares `data_collection_permissions: { required: ["none"] }`.

**Privacy policy URL:** https://roundrobin.in/bridgey/privacy-security, once it has this paragraph:

> The Bridgey browser extension sends the page or link you choose to the Bridgey app on the same computer, which
> sends it, encrypted, to a device you paired. The extension keeps the last device you used and your last five
> sends (page title and site name) in your browser, and you can clear them. It collects nothing and sends nothing
> to Round Robin or anyone else.

## Packages

- Chrome Web Store: `Bridgey-RR-<version>-Chrome-store.zip`, Edge: `-Edge-store.zip` (no `key`; the store assigns
  the ID), from `python3 extensions/browser/build.py --version <version> --out <dir> --store`.
- Firefox: the release's `Bridgey-RR-<version>-Firefox.zip` as is.
- After Chrome's and Edge's first approval, add their IDs to `chromiumExtensionIds` in
  [`native-host.json`](../native-host.json), then release the apps so they accept the store-installed extension.
