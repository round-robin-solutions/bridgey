// Unit tests for the extension's shared logic: node --test extensions/browser/test
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Lib = require('../src/lib.js');

test('web pages are normalised and checked', () => {
  assert.equal(Lib.normaliseUrl('https://example.com'), 'https://example.com/');
  assert.equal(Lib.normaliseUrl('  HTTPS://Example.COM/a b?q=ü#x '), 'https://example.com/a%20b?q=%C3%BC#x');
  assert.equal(Lib.normaliseUrl('https://bücher.example/'), 'https://xn--bcher-kva.example/');
  assert.equal(Lib.normaliseUrl('http://[::1]:8080/'), 'http://[::1]:8080/');
  for (const bad of [
    '',
    '   ',
    null,
    undefined,
    42,
    'not a url',
    'https://user:pass@example.com/',
    'https://user@example.com/',
    'file:///etc/passwd',
    'javascript:alert(1)',
    'data:text/html,hi',
    'chrome://settings/',
    'edge://settings/',
    'about:blank',
    'chrome-extension://aajelmcjgfjbhemgofnompobgbcdfcin/popup.html',
    'moz-extension://abc/popup.html',
    'view-source:https://example.com/',
    'ftp://example.com/',
    'blob:https://example.com/uuid',
  ]) {
    assert.equal(Lib.normaliseUrl(bad), null, String(bad));
  }
  assert.equal(Lib.normaliseUrl('https://example.com/' + 'a'.repeat(4096)), null);
  assert.ok(Lib.normaliseUrl('https://example.com/' + 'a'.repeat(4000)));
});

test('mailto and tel addresses', () => {
  assert.equal(Lib.normaliseUrl('mailto:hello@roundrobin.in'), 'mailto:hello@roundrobin.in');
  assert.equal(Lib.normaliseUrl('mailto:a@b.c,d@e.f?subject=Hi there'), 'mailto:a@b.c,d@e.f?subject=Hi%20there');
  assert.equal(Lib.normaliseUrl('tel:+44 20 7946 0958'), 'tel:+44%2020%207946%200958');
  assert.equal(Lib.normaliseUrl('tel:+1-555-123-4567;ext=12'), 'tel:+1-555-123-4567;ext=12');
  for (const bad of ['mailto:', 'mailto:nobody', 'mailto:<a@b>', 'tel:', 'tel:12', 'tel:1234567890123456', 'tel:abc', 'tel:12+34']) {
    assert.equal(Lib.normaliseUrl(bad), null, bad);
  }
  assert.equal(Lib.kindOf('https://a.b/'), 'web');
  assert.equal(Lib.kindOf('mailto:a@b.c'), 'mailto');
  assert.equal(Lib.kindOf('tel:112'), 'tel');
  assert.equal(Lib.kindOf('ftp://a.b/'), null);
});

test('requests carry only the device and the address', () => {
  assert.deepEqual(Lib.devicesRequest(), { v: 1, type: 'devices' });
  assert.deepEqual(Lib.sendRequest('0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0', 'https://example.com'), {
    v: 1,
    type: 'send',
    device: '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
    url: 'https://example.com/',
  });
  assert.equal(Lib.sendRequest('bad id', 'https://example.com'), null);
  assert.equal(Lib.sendRequest('', 'https://example.com'), null);
  assert.equal(Lib.sendRequest('x'.repeat(65), 'https://example.com'), null);
  assert.equal(Lib.sendRequest({ id: 'a' }, 'https://example.com'), null);
  assert.equal(Lib.sendRequest('abc', 'file:///etc/hosts'), null);
  assert.deepEqual(Object.keys(Lib.sendRequest('abc', 'tel:112')).sort(), ['device', 'type', 'url', 'v']);
});

test('device lists are checked and sorted', () => {
  const devices = Lib.readDevices({
    v: 1,
    ok: true,
    devices: [
      { id: 'b', name: 'Work Mac', platform: 'macos', connected: false, links: true },
      { id: 'a', name: 'Pixel 8', platform: 'android', connected: true, links: true, calls: true },
      { id: 'bad id', name: 'x' },
      { id: 'c', name: 42 },
      null,
      { id: 'd', name: 'Desk PC', platform: 'windows', connected: true, links: false },
    ],
  });
  assert.deepEqual(devices.map((d) => d.id), ['d', 'a', 'b']);
  assert.equal(devices[0].calls, false);
  assert.equal(Lib.readDevices({ v: 1, ok: false, error: 'app_not_running' }), null);
  assert.equal(Lib.readDevices(null), null);
  assert.equal(Lib.readDevices({ v: 2, ok: true, devices: [] }), null);
});

test('who can take what', () => {
  const phone = { id: 'a', connected: true, links: true, calls: true, platform: 'android' };
  const mac = { id: 'b', connected: true, links: true, calls: false, platform: 'macos' };
  const off = { id: 'c', connected: false, links: true, calls: true, platform: '' };
  const linksOff = { id: 'd', connected: true, links: false, calls: false, platform: 'windows' };
  assert.ok(Lib.canSend(phone, 'web') && Lib.canSend(phone, 'tel') && Lib.canSend(phone, 'mailto'));
  assert.ok(Lib.canSend(mac, 'web') && !Lib.canSend(mac, 'tel'));
  assert.ok(!Lib.canSend(off, 'web') && !Lib.canSend(off, 'mailto'));
  assert.ok(!Lib.canSend(linksOff, 'web') && Lib.canSend(linksOff, 'mailto'));
  assert.ok(!Lib.canSend(phone, null));
  assert.equal(Lib.stateKey(phone), 'stateConnected');
  assert.equal(Lib.stateKey(off), 'stateOffline');
  assert.equal(Lib.stateKey(linksOff), 'stateLinksOff');
  assert.equal(Lib.glyphOf(phone), 'phone');
  assert.equal(Lib.glyphOf(mac), 'computer');
  assert.equal(Lib.glyphOf(off), 'device');
});

test('the shortcut picks the last device, or the only one', () => {
  const a = { id: 'a', connected: true, links: true };
  const b = { id: 'b', connected: true, links: true };
  const off = { id: 'c', connected: false, links: true };
  assert.equal(Lib.pickDevice([a, b], 'b', 'web'), b);
  assert.equal(Lib.pickDevice([a, b], 'x', 'web'), null);
  assert.equal(Lib.pickDevice([a, off], 'c', 'web'), a);
  assert.equal(Lib.pickDevice([off], 'c', 'web'), null);
  assert.equal(Lib.pickDevice([], '', 'web'), null);
  assert.equal(Lib.pickDevice(undefined, '', 'web'), null);
});

test('answers become message keys', () => {
  assert.deepEqual(Lib.describeSend({ v: 1, ok: true, result: 'opened' }), { ok: true, result: 'opened', key: 'resultOpened' });
  assert.equal(Lib.describeSend({ v: 1, ok: true, result: 'waiting' }).key, 'resultWaiting');
  assert.equal(Lib.describeSend({ v: 1, ok: true, result: 'copied' }).key, 'resultCopied');
  assert.deepEqual(Lib.describeSend({ v: 1, ok: false, error: 'links_off' }), { ok: false, result: 'links_off', key: 'errorLinksOff' });
  assert.equal(Lib.describeSend({ v: 1, ok: false, error: 'something_new' }).key, 'errorFailed');
  assert.equal(Lib.describeSend({ v: 1, ok: true, result: 'toString' }).key, 'errorFailed');
  assert.equal(Lib.describeSend({ v: 1, ok: false, error: 'constructor' }).key, 'errorFailed');
  assert.equal(Lib.describeSend(undefined).key, 'errorFailed');
  assert.equal(Lib.describeError('app_not_running'), 'errorAppNotRunning');
  assert.equal(Lib.describeError('__proto__'), 'errorFailed');
  assert.equal(Lib.errorFromException(new Error('Specified native messaging host not found.')), 'not_installed');
  assert.equal(Lib.errorFromException(new Error('No such native application in.roundrobin.bridgey')), 'not_installed');
  assert.equal(Lib.errorFromException(new Error('Access to the specified native messaging host is forbidden.')), 'not_installed');
  assert.equal(Lib.errorFromException(new Error('Native host has exited.')), 'failed');
  assert.equal(Lib.errorFromException(undefined), 'failed');
});

test('recent sends keep the title and host only, five at most', () => {
  const device = { id: 'a', name: 'Pixel 8' };
  const entry = Lib.recentEntry('https://news.example/story?id=secret#part', 'A story', device, { ok: true, key: 'resultOpened' }, 1000);
  assert.deepEqual(entry, { title: 'A story', host: 'news.example', deviceId: 'a', deviceName: 'Pixel 8', ok: true, key: 'resultOpened', at: 1000 });
  assert.ok(!JSON.stringify(entry).includes('secret'));
  assert.equal(Lib.recentEntry('tel:+44', '', device, { ok: true, key: 'resultCalling' }, 0).host, 'tel');
  assert.equal(Lib.recentEntry('mailto:a@b.c', '', device, { ok: true, key: 'resultCopied' }, 0).title, 'mailto');
  let list = [];
  for (let i = 0; i < 8; i++) list = Lib.addRecent(list, { ...entry, title: 'Page ' + i, at: i });
  assert.equal(list.length, Lib.RECENT_LIMIT);
  assert.equal(list[0].title, 'Page 7');
  list = Lib.addRecent(list, { ...entry, title: 'Page 5', at: 99 });
  assert.deepEqual(list.map((e) => e.title), ['Page 5', 'Page 7', 'Page 6', 'Page 4', 'Page 3']);
  assert.deepEqual(Lib.addRecent('junk', entry), [entry]);
});

test('how long ago', () => {
  assert.deepEqual(Lib.ago(0, 30 * 1000), { key: 'agoNow', n: 0 });
  assert.deepEqual(Lib.ago(0, 5 * 60 * 1000), { key: 'agoMinutes', n: 5 });
  assert.deepEqual(Lib.ago(0, 3 * 3600 * 1000), { key: 'agoHours', n: 3 });
  assert.deepEqual(Lib.ago(0, 50 * 3600 * 1000), { key: 'agoDays', n: 2 });
  assert.deepEqual(Lib.ago(10, 0), { key: 'agoNow', n: 0 });
});
