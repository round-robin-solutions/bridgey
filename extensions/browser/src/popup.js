/*
 * Bridgey browser extension, the toolbar popup: the page, the devices with their state, Send and recent sends.
 * Every native message goes through the background (background.js), so a send finishes even when the popup closes.
 */
'use strict';

(function () {
  const ext = globalThis.browser || globalThis.chrome;
  const Lib = globalThis.BridgeyLib;
  const t = (key, ...subs) => ext.i18n.getMessage(key, subs.map(String)) || key;
  const $ = (id) => document.getElementById(id);
  const GET_BRIDGEY = 'https://roundrobin.in/bridgey';

  const GLYPHS = {
    phone: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="6.5" y="2.5" width="11" height="19" rx="2.5"/><path d="M11 18.5h2"/></svg>',
    computer: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4.5" width="18" height="12" rx="2"/><path d="M2 19.5h20"/></svg>',
    device: '<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="3"/><path d="M9 12h6"/></svg>',
  };

  const state = { url: null, kind: null, title: '', devices: [], selected: null, busy: false };

  function translateStatic() {
    document.documentElement.lang = (ext.i18n.getUILanguage() || 'en').split('-')[0];
    for (const node of document.querySelectorAll('[data-i18n]')) node.textContent = t(node.dataset.i18n);
  }

  function device(id) {
    return state.devices.find((d) => d.id === id) || null;
  }

  function setStatus(text, tone) {
    const status = $('status');
    status.textContent = text || '';
    status.className = 'status' + (tone ? ' ' + tone : '');
  }

  function showEmpty(titleKey, detailKey, action) {
    $('devices').replaceChildren();
    $('empty').hidden = false;
    $('empty-title').textContent = t(titleKey);
    $('empty-detail').textContent = detailKey ? t(detailKey) : '';
    $('empty-detail').hidden = !detailKey;
    const button = $('empty-action');
    button.hidden = !action;
    if (action) {
      button.textContent = t(action.key);
      button.onclick = action.run;
    }
    $('foot').hidden = true;
  }

  function renderDevices() {
    $('empty').hidden = true;
    $('foot').hidden = false;
    const list = $('devices');
    const rows = state.devices.map((d, index) => {
      const usable = state.kind !== null && Lib.canSend(d, state.kind);
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'device';
      row.setAttribute('role', 'radio');
      row.setAttribute('aria-checked', String(d.id === state.selected));
      row.setAttribute('aria-disabled', String(!usable));
      row.tabIndex = d.id === state.selected || (state.selected === null && index === 0) ? 0 : -1;
      row.style.animationDelay = index * 30 + 'ms';
      row.dataset.id = d.id;
      const radio = document.createElement('span');
      radio.className = 'radio';
      const text = document.createElement('span');
      text.className = 'device-text';
      const name = document.createElement('span');
      name.className = 'device-name';
      name.textContent = d.name;
      const line = document.createElement('span');
      const key = Lib.stateKey(d);
      line.className = 'device-state' + (key === 'stateConnected' ? ' connected' : '');
      line.textContent = t(key);
      text.append(name, line);
      const glyph = document.createElement('span');
      glyph.className = 'glyph';
      glyph.innerHTML = GLYPHS[Lib.glyphOf(d)];
      row.append(radio, text, glyph);
      row.addEventListener('click', () => {
        if (usable) select(d.id, true);
      });
      row.addEventListener('dblclick', () => {
        if (usable) send();
      });
      return row;
    });
    list.replaceChildren(...rows);
    updateSend();
  }

  function select(id, focus) {
    state.selected = id;
    for (const row of $('devices').children) {
      const on = row.dataset.id === id;
      row.setAttribute('aria-checked', String(on));
      row.tabIndex = on ? 0 : -1;
      if (on && focus) row.focus();
    }
    updateSend();
  }

  function updateSend() {
    const target = device(state.selected);
    const button = $('send');
    button.disabled = state.busy || !target || !Lib.canSend(target, state.kind);
    button.textContent = state.busy ? t('sending') : t('send');
  }

  /** Arrow keys move between the devices that can take the page; Enter sends. */
  function onKey(event) {
    const usable = state.devices.filter((d) => Lib.canSend(d, state.kind));
    if (usable.length === 0) return;
    const at = Math.max(0, usable.findIndex((d) => d.id === state.selected));
    if (event.key === 'ArrowDown' || event.key === 'ArrowRight') {
      select(usable[(at + 1) % usable.length].id, true);
      event.preventDefault();
    } else if (event.key === 'ArrowUp' || event.key === 'ArrowLeft') {
      select(usable[(at - 1 + usable.length) % usable.length].id, true);
      event.preventDefault();
    } else if (event.key === 'Enter' && !$('send').disabled) {
      send();
      event.preventDefault();
    }
  }

  async function renderRecent() {
    const { recent } = await ext.storage.local.get('recent');
    const list = Array.isArray(recent) ? recent : [];
    $('recent').hidden = list.length === 0;
    const now = Date.now();
    $('recent-list').replaceChildren(
      ...list.map((entry) => {
        const item = document.createElement('li');
        const title = document.createElement('span');
        title.className = 'recent-title';
        title.textContent = entry.title || entry.host;
        const line = document.createElement('span');
        line.className = 'recent-line' + (entry.ok ? '' : ' bad');
        const when = Lib.ago(entry.at, now);
        line.textContent = t(entry.key, entry.deviceName) + ' · ' + t(when.key, when.n);
        item.append(title, line);
        return item;
      })
    );
  }

  async function send() {
    const target = device(state.selected);
    if (!target || state.busy) return;
    state.busy = true;
    updateSend();
    setStatus('', null);
    const outcome = await ext.runtime.sendMessage({ type: 'send', device: { id: target.id, name: target.name }, url: state.url, title: state.title });
    state.busy = false;
    updateSend();
    if (outcome) setStatus(t(outcome.key, target.name), outcome.ok ? 'good' : 'bad');
    await renderRecent();
  }

  async function loadDevices() {
    $('empty').hidden = true;
    $('foot').hidden = false;
    $('devices').replaceChildren(...[0, 1].map(() => Object.assign(document.createElement('div'), { className: 'skeleton' })));
    const result = (await ext.runtime.sendMessage({ type: 'devices' })) || { error: 'failed' };
    if (result.error) {
      const retry = { key: 'retry', run: loadDevices };
      if (result.error === 'not_installed') {
        showEmpty('errorNotInstalled', 'errorNotInstalledDetail', { key: 'getBridgey', run: () => ext.tabs.create({ url: GET_BRIDGEY }) });
      } else if (result.error === 'app_not_running') {
        showEmpty('errorAppNotRunning', 'errorAppNotRunningDetail', retry);
      } else {
        showEmpty(Lib.describeError(result.error), null, retry);
      }
      return;
    }
    state.devices = result.devices;
    if (state.devices.length === 0) {
      showEmpty('emptyNoDevices', 'emptyNoDevicesDetail', null);
      return;
    }
    const { lastDevice } = await ext.storage.local.get('lastDevice');
    const chosen = state.kind ? Lib.pickDevice(state.devices, lastDevice, state.kind) : null;
    const first = state.devices.find((d) => Lib.canSend(d, state.kind));
    state.selected = (chosen || first || {}).id || null;
    renderDevices();
    if (state.kind === null) setStatus(t('popupCantSend'), null);
  }

  async function start() {
    translateStatic();
    const [tab] = await ext.tabs.query({ active: true, currentWindow: true });
    state.url = Lib.normaliseUrl((tab && tab.url) || '');
    state.kind = state.url ? Lib.kindOf(state.url) : null;
    state.title = (tab && tab.title) || '';
    let where = '';
    try {
      where = state.url ? new URL(state.url).hostname : '';
    } catch (e) {
      where = '';
    }
    $('page').textContent = where || t('popupCantSendShort');
    $('page').title = state.title;
    $('send').addEventListener('click', send);
    $('devices').addEventListener('keydown', onKey);
    $('clear').addEventListener('click', async () => {
      await ext.runtime.sendMessage({ type: 'clear-recent' });
      await renderRecent();
    });
    await Promise.all([renderRecent(), loadDevices()]);
  }

  start();
})();
