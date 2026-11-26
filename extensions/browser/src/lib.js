/*
 * Bridgey browser extension: the parts shared by the popup and the background, kept free of browser APIs so they
 * run under node --test (extensions/browser/test). See docs/browser-extensions.md.
 *
 * The extension talks to the Bridgey app only through the native messaging host "in.roundrobin.bridgey" (the
 * bridgey-browser-host helper the app ships). Two requests exist: the device list, and sending one address to one
 * device. The helper checks everything again; these checks only keep the extension from asking for what it would
 * refuse.
 */
(function (root) {
  'use strict';

  const HOST = 'in.roundrobin.bridgey';
  /** Addresses are at most 4,096 UTF-8 bytes, like links between devices. */
  const MAX_URL_BYTES = 4096;
  /** The popup keeps at most this many recent sends, in this browser only. */
  const RECENT_LIMIT = 5;
  const DEVICE_ID = /^[A-Za-z0-9-]{1,64}$/;

  function utf8Length(text) {
    return new TextEncoder().encode(text).length;
  }

  function decode(value) {
    try {
      return decodeURIComponent(value);
    } catch (e) {
      return null;
    }
  }

  /**
   * The address to send, normalised the way browsers write it (punycode host, percent-encoded path), or null.
   * http and https need a host and no user name or password; mailto needs an address with an @; tel needs 3 to 15
   * digits. Nothing else is sent: not file:, data:, javascript:, the browser's own pages or extension pages.
   */
  function normaliseUrl(raw) {
    if (typeof raw !== 'string' || raw.trim().length === 0) return null;
    let url;
    try {
      url = new URL(raw.trim());
    } catch (e) {
      return null;
    }
    // Opaque paths (tel:, mailto:) keep spaces; write them as %20 like every other address.
    const href = url.protocol === 'tel:' || url.protocol === 'mailto:' ? url.href.replace(/ /g, '%20') : url.href;
    if (utf8Length(href) > MAX_URL_BYTES || /[\s\\]/.test(href) || /[^\x21-\x7e]/.test(href)) return null;
    switch (url.protocol) {
      case 'http:':
      case 'https:':
        if (!url.hostname || url.username || url.password) return null;
        return href;
      case 'mailto:': {
        const addresses = decode(url.pathname);
        if (!addresses || !addresses.split(',').every((a) => /^[^@\s<>"(),;:]+@[^@\s<>"(),;:]+$/.test(a.trim()))) return null;
        return href;
      }
      case 'tel:': {
        const number = decode(url.pathname.split(';')[0]);
        if (number === null || !/^\+?[0-9().\- ]+$/.test(number.trim())) return null;
        const digits = number.replace(/[^0-9]/g, '');
        if (digits.length < 3 || digits.length > 15) return null;
        return href;
      }
      default:
        return null;
    }
  }

  /** web, mailto or tel, for a normalised address. */
  function kindOf(url) {
    if (/^https?:/i.test(url)) return 'web';
    if (/^mailto:/i.test(url)) return 'mailto';
    if (/^tel:/i.test(url)) return 'tel';
    return null;
  }

  function devicesRequest() {
    return { v: 1, type: 'devices' };
  }

  /** The send request, or null when the device or the address would be refused. */
  function sendRequest(deviceId, rawUrl) {
    const url = normaliseUrl(rawUrl);
    if (!url || typeof deviceId !== 'string' || !DEVICE_ID.test(deviceId)) return null;
    return { v: 1, type: 'send', device: deviceId, url };
  }

  /** Keeps only well-formed devices from the helper's answer: connected ones first, then by name. Null on an error. */
  function readDevices(reply) {
    if (!reply || reply.v !== 1 || reply.ok !== true || !Array.isArray(reply.devices)) return null;
    return reply.devices
      .filter((d) => d && typeof d.id === 'string' && DEVICE_ID.test(d.id) && typeof d.name === 'string')
      .map((d) => ({
        id: d.id,
        name: d.name.slice(0, 64),
        platform: typeof d.platform === 'string' ? d.platform : '',
        connected: d.connected === true,
        links: d.links === true,
        calls: d.calls === true,
      }))
      .sort((a, b) => Number(b.connected) - Number(a.connected) || a.name.localeCompare(b.name));
  }

  /** Whether `device` can take this kind of address now. Email addresses go to the device's clipboard. */
  function canSend(device, kind) {
    if (!device || !device.connected) return false;
    if (kind === 'web') return device.links;
    if (kind === 'tel') return device.calls;
    return kind === 'mailto';
  }

  /** The message key for a device's state line. */
  function stateKey(device) {
    if (!device.connected) return 'stateOffline';
    return device.links ? 'stateConnected' : 'stateLinksOff';
  }

  /** phone, computer or device, for the row's glyph. */
  function glyphOf(device) {
    if (device.platform === 'android' || device.platform === 'ios') return 'phone';
    if (device.platform === 'macos' || device.platform === 'windows' || device.platform === 'linux') return 'computer';
    return 'device';
  }

  /**
   * The device a shortcut or a menu item without a device sends to: the last one used while it can take the
   * address, else the only one that can. Null means the person has to choose.
   */
  function pickDevice(devices, lastId, kind) {
    const usable = (devices || []).filter((d) => canSend(d, kind));
    const last = usable.find((d) => d.id === lastId);
    if (last) return last;
    return usable.length === 1 ? usable[0] : null;
  }

  const RESULTS = { opened: 'resultOpened', waiting: 'resultWaiting', calling: 'resultCalling', asking: 'resultAsking', copied: 'resultCopied' };
  const ERRORS = {
    not_installed: 'errorNotInstalled',
    app_not_running: 'errorAppNotRunning',
    unsafe_endpoint: 'errorUnsafe',
    unknown_device: 'errorUnknownDevice',
    not_connected: 'errorNotConnected',
    links_off: 'errorLinksOff',
    calls_off: 'errorCallsOff',
    busy: 'errorBusy',
    declined: 'errorDeclined',
    rate_limited: 'errorRateLimited',
    unsupported: 'errorUnsupported',
    bad_url: 'errorBadUrl',
    no_answer: 'errorNoAnswer',
  };

  /** What a send's answer means: ok, the result or error code, and the message key for its line. */
  function describeSend(reply) {
    if (reply && reply.v === 1 && reply.ok === true && Object.prototype.hasOwnProperty.call(RESULTS, reply.result)) {
      return { ok: true, result: reply.result, key: RESULTS[reply.result] };
    }
    const code = reply && reply.v === 1 && reply.ok === false && typeof reply.error === 'string' ? reply.error : 'failed';
    return { ok: false, result: code, key: Object.prototype.hasOwnProperty.call(ERRORS, code) ? ERRORS[code] : 'errorFailed' };
  }

  /** The message key for an answer that was not a device list. */
  function describeError(code) {
    return Object.prototype.hasOwnProperty.call(ERRORS, code) ? ERRORS[code] : 'errorFailed';
  }

  /** The error code for a failed sendNativeMessage call: the host is not installed, or it ended without answering. */
  function errorFromException(error) {
    const text = String((error && error.message) || error || '');
    if (/not found|no such native application|not registered|forbidden/i.test(text)) return 'not_installed';
    return 'failed';
  }

  /** The recent list with `entry` first: at most RECENT_LIMIT, without an older send of the same page to the same device. */
  function addRecent(list, entry) {
    const rest = (Array.isArray(list) ? list : []).filter(
      (e) => e && !(e.host === entry.host && e.title === entry.title && e.deviceId === entry.deviceId)
    );
    return [entry].concat(rest).slice(0, RECENT_LIMIT);
  }

  /** A recent entry keeps the page's title and host only, never the full address. */
  function recentEntry(url, title, device, outcome, now) {
    let host = '';
    try {
      const parsed = new URL(url);
      host = parsed.protocol === 'http:' || parsed.protocol === 'https:' ? parsed.hostname : parsed.protocol.slice(0, -1);
    } catch (e) {
      host = '';
    }
    return {
      title: String(title || host).slice(0, 80),
      host,
      deviceId: device.id,
      deviceName: device.name,
      ok: outcome.ok,
      key: outcome.key,
      at: now,
    };
  }

  /** How long ago, as a message key and a number: now, minutes, hours or days. */
  function ago(then, now) {
    const minutes = Math.max(0, Math.floor((now - then) / 60000));
    if (minutes < 1) return { key: 'agoNow', n: 0 };
    if (minutes < 60) return { key: 'agoMinutes', n: minutes };
    if (minutes < 60 * 24) return { key: 'agoHours', n: Math.floor(minutes / 60) };
    return { key: 'agoDays', n: Math.floor(minutes / (60 * 24)) };
  }

  const api = {
    HOST,
    MAX_URL_BYTES,
    RECENT_LIMIT,
    normaliseUrl,
    kindOf,
    devicesRequest,
    sendRequest,
    readDevices,
    canSend,
    stateKey,
    glyphOf,
    pickDevice,
    describeSend,
    describeError,
    errorFromException,
    addRecent,
    recentEntry,
    ago,
  };
  root.BridgeyLib = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
