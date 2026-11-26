/*
 * Bridgey browser extension, background (a service worker in Chrome and Edge, an event page in Firefox).
 * It owns every native message: the popup, the page and link menu items and the keyboard shortcut all come here.
 * Nothing is sent anywhere except to the Bridgey app on this computer, through the native messaging host.
 */
'use strict';

if (typeof BridgeyLib === 'undefined' && typeof importScripts === 'function') {
  importScripts('lib.js');
}

const ext = globalThis.browser || globalThis.chrome;
const Lib = globalThis.BridgeyLib;
const t = (key, ...subs) => ext.i18n.getMessage(key, subs.map(String)) || key;
/** Context menu items name at most this many devices; the popup lists them all. */
const MENU_DEVICES = 8;
const BADGE_MS = 4000;

async function askHost(message) {
  try {
    const reply = await ext.runtime.sendNativeMessage(Lib.HOST, message);
    return reply || { v: 1, ok: false, error: 'failed' };
  } catch (error) {
    return { v: 1, ok: false, error: Lib.errorFromException(error) };
  }
}

async function stored(key, fallback) {
  const values = await ext.storage.local.get(key);
  return values[key] === undefined ? fallback : values[key];
}

/** Asks the app for the device list and rebuilds the menus. Returns { devices } or { error }. */
async function refreshDevices() {
  const reply = await askHost(Lib.devicesRequest());
  const devices = Lib.readDevices(reply);
  if (devices === null) {
    const error = reply && reply.ok === false && typeof reply.error === 'string' ? reply.error : 'failed';
    await rebuildMenus([]);
    return { error };
  }
  await ext.storage.local.set({ devices });
  await rebuildMenus(devices);
  return { devices };
}

let menuWork = Promise.resolve();

/** One item per device for pages and one for links (offline devices say so), or one plain item when none is known. */
function rebuildMenus(devices) {
  menuWork = menuWork
    .then(async () => {
      await ext.contextMenus.removeAll();
      const listed = devices.slice(0, MENU_DEVICES);
      const create = (item) =>
        new Promise((resolve) => {
          ext.contextMenus.create(item, () => {
            void (ext.runtime.lastError);
            resolve();
          });
        });
      if (listed.length === 0) {
        await create({ id: 'page:', title: t('menuSendPage'), contexts: ['page'] });
        await create({ id: 'link:', title: t('menuSendLink'), contexts: ['link'] });
        return;
      }
      for (const device of listed) {
        const page = device.connected ? t('menuSendPageTo', device.name) : t('menuSendPageToOffline', device.name);
        const link = device.connected ? t('menuSendLinkTo', device.name) : t('menuSendLinkToOffline', device.name);
        await create({ id: 'page:' + device.id, title: page, contexts: ['page'] });
        await create({ id: 'link:' + device.id, title: link, contexts: ['link'] });
      }
    })
    .catch(() => {});
  return menuWork;
}

let badgeTimer = null;

function badge(ok) {
  clearTimeout(badgeTimer);
  ext.action.setBadgeBackgroundColor({ color: ok ? '#006C49' : '#B3261E' });
  ext.action.setBadgeText({ text: ok ? '✓' : '!' });
  badgeTimer = setTimeout(() => ext.action.setBadgeText({ text: '' }), BADGE_MS);
}

/** Sends one address to one device, remembers it in the recent list and shows the outcome on the toolbar button. */
async function send(device, url, title) {
  const request = Lib.sendRequest(device.id, url);
  const outcome = request ? Lib.describeSend(await askHost(request)) : Lib.describeSend({ v: 1, ok: false, error: 'bad_url' });
  if (request) {
    const recent = Lib.addRecent(await stored('recent', []), Lib.recentEntry(request.url, title, device, outcome, Date.now()));
    const values = { recent };
    if (outcome.ok) values.lastDevice = device.id;
    await ext.storage.local.set(values);
  }
  badge(outcome.ok);
  return outcome;
}

/** A menu item or the shortcut without a device: the last device used, or the only one that can take it. */
async function sendToChosen(url, title, deviceId) {
  const kind = Lib.kindOf(Lib.normaliseUrl(url) || '');
  if (!kind) {
    badge(false);
    return;
  }
  const fresh = await refreshDevices();
  const devices = fresh.devices || [];
  let device = deviceId ? devices.find((d) => d.id === deviceId) : null;
  if (!device && deviceId === '') device = Lib.pickDevice(devices, await stored('lastDevice', ''), kind);
  if (!device) {
    // Several devices could take it: let the person choose in the popup where the browser allows opening it.
    try {
      await ext.action.openPopup();
    } catch (e) {
      badge(false);
    }
    return;
  }
  await send(device, url, title);
}

ext.contextMenus.onClicked.addListener((info, tab) => {
  const id = String(info.menuItemId || '');
  const split = id.indexOf(':');
  if (split < 0) return;
  const deviceId = id.slice(split + 1);
  const isLink = id.startsWith('link:');
  const url = isLink ? info.linkUrl : info.pageUrl || (tab && tab.url);
  const title = isLink ? info.linkText || '' : (tab && tab.title) || '';
  sendToChosen(url || '', title, deviceId);
});

ext.commands.onCommand.addListener(async (command, tab) => {
  if (command !== 'send-page') return;
  let target = tab;
  if (!target || !target.url) {
    const tabs = await ext.tabs.query({ active: true, currentWindow: true });
    target = tabs[0];
  }
  sendToChosen((target && target.url) || '', (target && target.title) || '', '');
});

ext.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== ext.runtime.id || !message || typeof message.type !== 'string') return false;
  if (message.type === 'devices') {
    refreshDevices().then(reply);
    return true;
  }
  if (message.type === 'send' && message.device && typeof message.device.id === 'string' && typeof message.url === 'string') {
    const device = { id: message.device.id, name: String(message.device.name || '').slice(0, 64) };
    send(device, message.url, String(message.title || '')).then(reply);
    return true;
  }
  if (message.type === 'clear-recent') {
    ext.storage.local.remove('recent').then(() => reply({ ok: true }));
    return true;
  }
  return false;
});

ext.runtime.onInstalled.addListener(() => {
  refreshDevices();
});
ext.runtime.onStartup.addListener(() => {
  refreshDevices();
});
