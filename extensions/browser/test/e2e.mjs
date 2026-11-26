// End-to-end check: a headless Chromium loads the unpacked Chrome package, whose native messaging host is the real
// bridgey-browser-host helper, which talks to a stub Bridgey app on a Unix socket. Not part of CI (it needs a browser).
//
//   cargo build -p bridgey-browser-host --manifest-path rust/Cargo.toml
//   NODE_PATH="$(npm root -g)" node extensions/browser/test/e2e.mjs --chrome <chrome> [--screenshots <dir>]
//
// Needs puppeteer-core and a Chromium or Chrome for Testing build (branded Chrome ignores --load-extension). It builds
// the extension with a test-only host permission for the test site, so the popup can read the test page's address without
// a click on the toolbar button (activeTab). Everything it creates goes in one temporary folder, removed at the end.

import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const puppeteer = require('puppeteer-core');
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../../..');
const args = process.argv.slice(2);
const option = (name, fallback) => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const chrome = option('--chrome');
const screenshots = option('--screenshots', '');
const helper = option('--helper', path.join(repo, 'rust/target/debug/bridgey-browser-host'));
if (!chrome) throw new Error('pass --chrome <path to Chromium or Chrome for Testing>');
if (!fs.existsSync(helper)) throw new Error(`no helper at ${helper}; run cargo build -p bridgey-browser-host`);

const EXTENSION_ID = 'aajelmcjgfjbhemgofnompobgbcdfcin';
const PHONE = '6c1f0c1e-3a5b-4b8e-9d2a-0f7e1c2b3a4d';
const MAC = '0b9a8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d';
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'bridgey-e2e-'));
fs.chmodSync(work, 0o700);
const results = [];
const check = (name, ok, detail = '') => {
  results.push({ name, ok });
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ': ' + detail : ''}`);
};

// The extension, built with the test host permission.
const unpacked = path.join(work, 'unpacked');
execFileSync('python3', [path.join(repo, 'extensions/browser/build.py'), '--version', '1.0.0-dev', '--out', path.join(work, 'zips'),
  '--unpacked', unpacked, '--browsers', 'chrome', '--test-host-permission', 'http://ferries.example/*']);
const extensionDir = path.join(unpacked, 'chrome');

// The stub app: the same JSON lines the Mac and Windows apps answer.
const socketDir = path.join(work, 'app');
fs.mkdirSync(socketDir, { mode: 0o700 });
const socketPath = path.join(socketDir, 'browser.sock');
const heard = [];
let appServer = null;
const connections = new Set();
function startApp() {
  appServer = net.createServer((connection) => {
    connections.add(connection);
    connection.on('close', () => connections.delete(connection));
    let buffer = '';
    connection.on('data', (chunk) => {
      buffer += chunk;
      const end = buffer.indexOf('\n');
      if (end < 0) return;
      const request = JSON.parse(buffer.slice(0, end));
      heard.push(request);
      let answer;
      if (request.type === 'devices') {
        answer = { version: 1, ok: true, devices: [
          { id: PHONE, name: 'Pixel 8', platform: 'android', connected: true, links: true, calls: true },
          { id: MAC, name: 'Work Mac', platform: 'macos', connected: false, links: true, calls: false },
        ] };
      } else if (request.url.startsWith('tel:')) {
        answer = { version: 1, ok: true, result: 'asking' };
      } else {
        answer = { version: 1, ok: true, result: request.device === PHONE ? 'waiting' : 'opened' };
      }
      setTimeout(() => connection.end(JSON.stringify(answer) + '\n'), 150);
    });
  });
  return new Promise((resolve) => appServer.listen(socketPath, () => {
    fs.chmodSync(socketPath, 0o600);
    resolve();
  }));
}
const stopApp = () => new Promise((resolve) => {
  appServer.close(() => resolve());
  for (const connection of connections) connection.destroy();
});

// The host manifest, in the profile's own NativeMessagingHosts folder (Chromium on Linux reads it there).
const profile = path.join(work, 'profile');
const hostDir = path.join(profile, 'NativeMessagingHosts');
fs.mkdirSync(hostDir, { recursive: true });
const hostManifest = path.join(hostDir, 'in.roundrobin.bridgey.json');
const writeHostManifest = () => fs.writeFileSync(hostManifest, JSON.stringify({
  name: 'in.roundrobin.bridgey', description: 'Bridgey test', path: helper, type: 'stdio',
  allowed_origins: [`chrome-extension://${EXTENSION_ID}/`],
}));

// The page to send.
const site = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end('<!doctype html><title>Ferry timetable</title><h1>Ferry timetable</h1><a href="tel:+44 20 7946 0958">Call</a>');
});
await new Promise((resolve) => site.listen(0, '127.0.0.1', resolve));
// A name the browser maps to the test server, so the popup shows a site name rather than an address.
const pageUrl = `http://ferries.example:${site.address().port}/timetable.html`;

await startApp();
writeHostManifest();
const browser = await puppeteer.launch({
  executablePath: chrome,
  headless: true,
  userDataDir: profile,
  pipe: true,
  enableExtensions: [extensionDir],
  // CHROME_ARGS adds flags a host needs, for example --no-sandbox where user namespaces are off.
  args: ['--no-first-run', '--no-default-browser-check', '--lang=en-GB', '--host-resolver-rules=MAP ferries.example 127.0.0.1',
    ...(process.env.CHROME_ARGS || '').split(' ').filter(Boolean)],
  env: { ...process.env, BRIDGEY_BROWSER_SOCKET: socketPath },
});

try {
  const workerTarget = await browser.waitForTarget((t) => t.type() === 'service_worker' && t.url().startsWith(`chrome-extension://${EXTENSION_ID}/`), { timeout: 15000 });
  check('the extension loads with its fixed ID', true, workerTarget.url());
  const worker = await workerTarget.worker();
  const site1 = await browser.newPage();
  await site1.goto(pageUrl);

  async function openPopup(scheme) {
    await worker.evaluate(() => chrome.tabs.create({ url: chrome.runtime.getURL('popup.html'), active: false }));
    const target = await browser.waitForTarget((t) => t.url().endsWith('/popup.html') && !t._bridgeySeen, { timeout: 10000 });
    target._bridgeySeen = true;
    const popup = await target.asPage();
    await popup.setViewport({ width: 360, height: 640, deviceScaleFactor: 2 });
    await popup.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }]);
    return popup;
  }

  async function shot(popup, name) {
    if (!screenshots) return;
    fs.mkdirSync(screenshots, { recursive: true });
    await popup.bringToFront();
    await new Promise((r) => setTimeout(r, 400));
    const box = await (await popup.$('main')).boundingBox();
    await popup.screenshot({ path: path.join(screenshots, name), clip: { x: 0, y: 0, width: 360, height: Math.ceil(box.height) } });
    await site1.bringToFront();
  }

  // 1. Devices from the app, through the real helper.
  let popup = await openPopup('dark');
  await popup.waitForSelector('.device', { timeout: 10000 });
  const rows = await popup.$$eval('.device', (els) => els.map((e) => ({ name: e.querySelector('.device-name').textContent, state: e.querySelector('.device-state').textContent, checked: e.getAttribute('aria-checked'), disabled: e.getAttribute('aria-disabled') })));
  check('the popup lists the app\'s devices, connected first', rows.length === 2 && rows[0].name === 'Pixel 8' && rows[0].state === 'Connected' && rows[1].state === 'Not connected', JSON.stringify(rows));
  check('the only usable device is chosen', rows[0].checked === 'true' && rows[1].disabled === 'true');
  check('the page is the active tab', (await popup.$eval('#page', (e) => e.textContent)) === 'ferries.example');
  await shot(popup, 'popup-devices-dark.png');

  // 2. Send the page.
  // A background tab draws no frames: click through the DOM and poll on a timer, not on animation frames.
  await popup.$eval('#send', (button) => button.click());
  await popup.waitForFunction(() => document.querySelector('#status').textContent.length > 0, { timeout: 15000, polling: 100 });
  const status = await popup.$eval('#status', (e) => e.textContent);
  check('Send reports the device\'s answer', status === 'Waiting on Pixel 8 for you to open', status);
  const sent = heard.find((r) => r.type === 'send');
  check('the app got the page address and the device', sent && sent.url === pageUrl && sent.device === PHONE, JSON.stringify(sent));
  await popup.waitForSelector('#recent:not([hidden]) li', { timeout: 5000 });
  const recent = await popup.$eval('#recent-list li', (e) => e.textContent);
  check('the send shows under Recent', recent.startsWith('Ferry timetable') && recent.includes('Pixel 8'), recent);
  await shot(popup, 'popup-sent-dark.png');
  await popup.close();

  popup = await openPopup('light');
  await popup.waitForSelector('.device', { timeout: 10000 });
  await shot(popup, 'popup-devices-light.png');
  await popup.close();

  // 3. The menu items' and the shortcut's path in the background: a tel: link to a chosen device, then the page to
  // the last device used.
  heard.length = 0;
  await worker.evaluate((id) => sendToChosen('tel:+44 20 7946 0958', 'Call', id), PHONE);
  check('a tel: link goes to the app as a checked number', heard.some((r) => r.type === 'send' && r.url === 'tel:+442079460958'), JSON.stringify(heard));
  heard.length = 0;
  await worker.evaluate((url) => sendToChosen(url, 'Ferry timetable', ''), pageUrl);
  check('the shortcut sends to the last device used', heard.some((r) => r.type === 'send' && r.device === PHONE && r.url === pageUrl), JSON.stringify(heard));
  const badge = await worker.evaluate(() => chrome.action.getBadgeText({}));
  check('the toolbar button shows the outcome', badge === '✓', badge);
  const menus = await worker.evaluate(async () => {
    await refreshDevices();
    return new Promise((resolve) => setTimeout(resolve, 200));
  });
  void menus;

  // 4. Bridgey not running.
  await stopApp();
  popup = await openPopup('dark');
  await popup.waitForSelector('#empty:not([hidden])', { timeout: 10000 });
  const notRunning = await popup.$eval('#empty-title', (e) => e.textContent);
  check('a stopped app says to open Bridgey', notRunning === 'Open Bridgey on this computer', notRunning);
  await shot(popup, 'popup-not-running-dark.png');
  await popup.close();

  // 5. Browser support not installed (no host manifest).
  fs.rmSync(hostManifest);
  popup = await openPopup('light');
  await popup.waitForSelector('#empty:not([hidden])', { timeout: 10000 });
  const notInstalled = await popup.$eval('#empty-title', (e) => e.textContent);
  check('a missing helper says to turn on browser support', notInstalled === 'Turn on browser support in Bridgey', notInstalled);
  await shot(popup, 'popup-not-installed-light.png');
  await popup.close();

  // 6. A page that is not a web page.
  writeHostManifest();
  await startApp();
  const settings = await browser.newPage();
  await settings.goto('about:blank');
  popup = await openPopup('dark');
  await popup.waitForSelector('.device', { timeout: 10000 });
  const cant = await popup.$eval('#status', (e) => e.textContent);
  const disabled = await popup.$eval('#send', (e) => e.disabled);
  check('a page that is not a web page cannot be sent', disabled && cant.startsWith('Only web pages'), cant);
  await shot(popup, 'popup-not-a-page-dark.png');
} catch (error) {
  check('no unexpected error', false, error.stack);
} finally {
  await browser.close();
  await stopApp().catch(() => {});
  site.close();
  fs.rmSync(work, { recursive: true, force: true });
}

const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed} of ${results.length} checks passed`);
process.exit(failed ? 1 : 0);
