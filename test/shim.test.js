// Run with: node --test test/
// Loads the shim into a fake browser global and drives it with a mocked native side.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SHIM = fs.readFileSync(path.join(__dirname, '..', 'CstimerApp', 'Resources', 'bluetooth-shim.js'), 'utf8');

const SVC = '0000fff0-0000-1000-8000-00805f9b34fb';
const CHR = '0000fff6-0000-1000-8000-00805f9b34fb';
const DEV = 'DEVICE-1';

const b64 = (bytes) => Buffer.from(bytes).toString('base64');
const bytesOf = (dv) => Array.from(new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength));

// handlers: {op: (msg) => result | Promise}; unknown ops resolve null
function load(handlers = {}, extraGlobals = {}) {
	const calls = [];
	const navigator = {};
	const win = {
		navigator,
		webkit: {
			messageHandlers: {
				cstimerBLE: {
					postMessage(msg) {
						// WebKit structured-clones messages; this also detaches them from the vm realm
						msg = JSON.parse(JSON.stringify(msg));
						calls.push(msg);
						const h = handlers[msg.op];
						try {
							return Promise.resolve(h ? h(msg) : null);
						} catch (e) {
							return Promise.reject(e);
						}
					},
				},
			},
		},
		EventTarget, Event, DOMException, AbortController, Map, Promise,
		ArrayBuffer, DataView, Uint8Array, atob, btoa, console,
	};
	const et = new EventTarget();
	win.addEventListener = et.addEventListener.bind(et);
	win.dispatchEvent = et.dispatchEvent.bind(et);
	Object.assign(win, extraGlobals);
	win.window = win;
	vm.createContext(win);
	vm.runInContext(SHIM, win);
	return { win, bt: navigator.bluetooth, calls };
}

async function connectedChar(handlers = {}) {
	const env = load(Object.assign({
		requestDevice: () => ({ deviceId: DEV, name: 'GANicXS' }),
		getPrimaryServices: (m) => [m.service || SVC],
		getCharacteristics: (m) => [{ uuid: m.characteristic || CHR, properties: { read: true, write: true, writeWithoutResponse: false, notify: true, indicate: false } }],
	}, handlers));
	const device = await env.bt.requestDevice({ filters: [{ namePrefix: 'GAN' }] });
	const server = await device.gatt.connect();
	const service = await server.getPrimaryService(SVC);
	const chr = await service.getCharacteristic(CHR);
	return Object.assign(env, { device, server, service, chr });
}

test('installs navigator.bluetooth and exposes dispatch', () => {
	const { win, bt } = load();
	assert.equal(typeof bt.requestDevice, 'function');
	assert.equal(typeof bt.getAvailability, 'function');
	assert.equal(typeof win.__cstimerBLE.dispatch, 'function');
});

test('getAvailability forwards to native', async () => {
	const { bt, calls } = load({ getAvailability: () => false });
	assert.equal(await bt.getAvailability(), false);
	assert.equal(calls[0].op, 'getAvailability');
});

test('requestDevice canonicalizes service UUIDs and returns a device', async () => {
	const { bt, calls } = load({ requestDevice: () => ({ deviceId: DEV, name: 'MHC' }) });
	const device = await bt.requestDevice({
		filters: [{ namePrefix: 'GAN' }, { services: ['FFF0'] }, { services: [0x180f] }, { services: ['0000AADB-0000-1000-8000-00805F9B34FB'] }],
		optionalServices: ['fff0'],
		optionalManufacturerData: [1, 2],
	});
	assert.equal(device.id, DEV);
	assert.equal(device.name, 'MHC');
	assert.equal(device.gatt.connected, false);
	assert.deepEqual(calls[0].filters, [
		{ namePrefix: 'GAN' },
		{ services: [SVC] },
		{ services: ['0000180f-0000-1000-8000-00805f9b34fb'] },
		{ services: ['0000aadb-0000-1000-8000-00805f9b34fb'] },
	]);
	assert.equal(calls[0].acceptAllDevices, false);
});

test('native error strings become DOMExceptions', async () => {
	const { bt } = load({ requestDevice: () => { throw 'NotFoundError: User cancelled'; } });
	await assert.rejects(bt.requestDevice({ filters: [{ namePrefix: 'X' }] }), (e) => {
		assert.equal(e.name, 'NotFoundError');
		assert.equal(e.message, 'User cancelled');
		return true;
	});
});

test('WebKit-style Error rejections are parsed too', async () => {
	const { bt } = load({ connect: () => { throw new Error('NetworkError: Connection timed out'); }, requestDevice: () => ({ deviceId: DEV, name: 'A' }) });
	const device = await bt.requestDevice({ acceptAllDevices: true });
	await assert.rejects(device.gatt.connect(), (e) => {
		assert.equal(e.name, 'NetworkError');
		assert.equal(e.message, 'Connection timed out');
		return true;
	});
	assert.equal(device.gatt.connected, false);
});

test('same device id yields the same device object', async () => {
	const { bt } = load({ requestDevice: () => ({ deviceId: DEV, name: 'A' }) });
	const a = await bt.requestDevice({ acceptAllDevices: true });
	const b = await bt.requestDevice({ acceptAllDevices: true });
	assert.equal(a, b);
});

test('connect, services and characteristics', async () => {
	const { device, server, service, chr, calls } = await connectedChar();
	assert.equal(server, device.gatt);
	assert.equal(device.gatt.connected, true);
	assert.equal(service.uuid, SVC);
	assert.equal(service.device, device);
	assert.equal(chr.uuid, CHR);
	assert.equal(chr.service, service);
	assert.equal(chr.properties.notify, true);
	assert.deepEqual(calls.find((c) => c.op === 'getCharacteristics'), { op: 'getCharacteristics', deviceId: DEV, service: SVC, characteristic: CHR });
});

test('getPrimaryServices without argument lists all', async () => {
	const env = load({
		requestDevice: () => ({ deviceId: DEV, name: 'x' }),
		getPrimaryServices: () => [SVC, '0000180f-0000-1000-8000-00805f9b34fb'],
	});
	const device = await env.bt.requestDevice({ acceptAllDevices: true });
	const servs = await (await device.gatt.connect()).getPrimaryServices();
	assert.deepEqual(servs.map((s) => s.uuid), [SVC, '0000180f-0000-1000-8000-00805f9b34fb']);
	assert.equal(env.calls.find((c) => c.op === 'getPrimaryServices').service, undefined);
});

test('characteristic objects are cached per uuid', async () => {
	const { service, chr } = await connectedChar();
	assert.equal(await service.getCharacteristic('fff6'), chr);
	const all = await service.getCharacteristics();
	assert.equal(all[0], chr);
});

test('notifications fire characteristicvaluechanged with a fresh offset-0 DataView', async () => {
	const { win, chr, calls } = await connectedChar();
	assert.equal(await chr.startNotifications(), chr);
	assert.equal(calls.at(-1).op, 'startNotifications');
	const seen = [];
	chr.addEventListener('characteristicvaluechanged', (e) => seen.push(e.target.value));
	win.__cstimerBLE.dispatch({ type: 'value', deviceId: DEV, service: SVC, characteristic: CHR, value: b64([1, 2, 3]) });
	assert.equal(seen.length, 1);
	assert.ok(seen[0] instanceof win.DataView);
	assert.equal(seen[0].byteOffset, 0);
	assert.equal(seen[0].buffer.byteLength, 3);
	assert.deepEqual(bytesOf(seen[0]), [1, 2, 3]);
	assert.equal(chr.value, seen[0]);
	await chr.stopNotifications();
	assert.equal(calls.at(-1).op, 'stopNotifications');
});

test('readValue resolves with a DataView', async () => {
	const { chr } = await connectedChar({ readValue: () => b64([9, 8]) });
	const dv = await chr.readValue();
	assert.deepEqual(bytesOf(dv), [9, 8]);
	assert.equal(chr.value, dv);
});

test('writeValue accepts ArrayBuffer, typed array and DataView, and picks the mode', async () => {
	const { chr, calls } = await connectedChar();
	await chr.writeValue(new Uint8Array([1, 2]).buffer);
	await chr.writeValue(new Uint8Array([0, 3, 4]).subarray(1));
	await chr.writeValueWithoutResponse(new DataView(new Uint8Array([7, 5, 6]).buffer, 1));
	await chr.writeValueWithResponse(new Uint8Array([7]));
	const writes = calls.filter((c) => c.op === 'writeValue');
	assert.deepEqual(writes.map((w) => [w.value, w.mode]), [
		[b64([1, 2]), 'auto'],
		[b64([3, 4]), 'auto'],
		[b64([5, 6]), 'withoutResponse'],
		[b64([7]), 'withResponse'],
	]);
	assert.equal(writes[0].service, SVC);
	assert.equal(writes[0].characteristic, CHR);
});

test('disconnect event fires gattserverdisconnected and clears connected', async () => {
	const { win, device } = await connectedChar();
	let fired = 0;
	device.addEventListener('gattserverdisconnected', () => fired++);
	win.__cstimerBLE.dispatch({ type: 'disconnected', deviceId: DEV });
	assert.equal(fired, 1);
	assert.equal(device.gatt.connected, false);
});

test('gatt.disconnect calls native and clears connected', async () => {
	const { device, calls } = await connectedChar();
	device.gatt.disconnect();
	assert.equal(device.gatt.connected, false);
	assert.equal(calls.at(-1).op, 'disconnect');
});

test('advertisements expose manufacturerData as Map<number, DataView>', async () => {
	const { win, bt, calls } = load({ requestDevice: () => ({ deviceId: DEV, name: 'GAN' }) });
	const device = await bt.requestDevice({ acceptAllDevices: true });
	assert.equal(typeof device.watchAdvertisements, 'function');
	const ac = new AbortController();
	const events = [];
	device.addEventListener('advertisementreceived', (e) => events.push(e));
	await device.watchAdvertisements({ signal: ac.signal });
	assert.equal(calls.at(-1).op, 'watchAdvertisements');
	assert.equal(device.watchingAdvertisements, true);
	win.__cstimerBLE.dispatch({
		type: 'advertisement', deviceId: DEV, name: 'GAN', rssi: -50,
		manufacturerData: { '1281': b64([0xaa, 0xbb, 0xcc]) },
		serviceData: { [SVC]: b64([1]) },
	});
	assert.equal(events.length, 1);
	const md = events[0].manufacturerData;
	assert.ok(md instanceof win.Map);
	assert.equal(md.size, 1);
	assert.ok(md.has(1281));
	const dv = md.get(1281);
	assert.equal(dv.byteOffset, 0);
	assert.deepEqual(bytesOf(dv), [0xaa, 0xbb, 0xcc]);
	assert.deepEqual(bytesOf(events[0].serviceData.get(SVC)), [1]);
	assert.equal(events[0].rssi, -50);
	assert.equal(events[0].device, device);
	ac.abort();
	assert.equal(calls.at(-1).op, 'unwatchAdvertisements');
	assert.equal(device.watchingAdvertisements, false);
});

test('empty manufacturerData is an empty Map', async () => {
	const { win, bt } = load({ requestDevice: () => ({ deviceId: DEV, name: 'GAN' }) });
	const device = await bt.requestDevice({ acceptAllDevices: true });
	let got;
	device.addEventListener('advertisementreceived', (e) => { got = e; });
	win.__cstimerBLE.dispatch({ type: 'advertisement', deviceId: DEV, manufacturerData: {}, serviceData: {} });
	assert.equal(got.manufacturerData.size, 0);
});

test('events for unknown devices are ignored', () => {
	const { win } = load();
	win.__cstimerBLE.dispatch({ type: 'disconnected', deviceId: 'nope' });
	win.__cstimerBLE.dispatch({ type: 'value', deviceId: 'nope', service: SVC, characteristic: CHR, value: b64([1]) });
});

test('keeps the screen awake only while the cstimer timer is not idle', () => {
	const { win, calls } = load();
	let listener;
	win.kernel = {
		regListener(module, signal, cb) {
			assert.equal(signal, 'timerStatus');
			listener = cb;
		},
	};
	win.dispatchEvent(new Event('DOMContentLoaded'));
	assert.equal(typeof listener, 'function');
	const awake = () => calls.filter((c) => c.op === 'setKeepAwake').map((c) => c.on);
	listener('timerStatus', -3); // inspecting
	listener('timerStatus', 1);  // running
	listener('timerStatus', -1); // idle
	listener('timerStatus', -1);
	listener('timerStatus', -2); // ready
	assert.deepEqual(awake(), [true, false, true]);
});

// A stand-in for cstimer's GiikerCube: the cube drivers call GiikerCube.callback for every state report.
function withCube() {
	let t = 0;
	const seen = [];
	const env = load({}, { Date: { now: () => t } });
	env.win.GiikerCube = { callback() { seen.push(Array.from(arguments)); return 'ret'; } };
	env.win.dispatchEvent(new Event('DOMContentLoaded'));
	env.at = (ms) => { t = ms; };
	env.turns = () => env.calls.filter((c) => c.op === 'userActivity').length;
	env.seen = seen;
	return env;
}

test('cube turns count as activity for the screen sleep timer', () => {
	const env = withCube();
	const r = env.win.GiikerCube.callback('UUU', [["R'", 1]], [1, 2], 'GAN');
	assert.equal(r, 'ret');
	assert.equal(env.seen.length, 1, 'cstimer still gets the move');
	assert.deepEqual(env.seen[0][1], [["R'", 1]]);
	assert.equal(env.turns(), 1);
});

test('state reports without a turn (connecting, gyro-only) are not activity', () => {
	const env = withCube();
	env.win.GiikerCube.callback('UUU', [], [null, 2], 'GAN');
	assert.equal(env.seen.length, 1);
	assert.equal(env.turns(), 0);
});

test('turn activity is sent at most once every few seconds', () => {
	const env = withCube();
	const turn = () => env.win.GiikerCube.callback('UUU', [['R', 1]], [1, 2], 'GAN');
	env.at(1000); turn(); turn();
	env.at(3000); turn();
	env.at(6500); turn();
	assert.equal(env.seen.length, 4);
	assert.equal(env.turns(), 2);
});

test('missing cstimer kernel does not break the shim', () => {
	const { win, bt } = load();
	win.dispatchEvent(new Event('DOMContentLoaded'));
	assert.equal(typeof bt.requestDevice, 'function');
});

test('navigator.wakeLock is a no-op so the app controls the screen', async () => {
	const { win, calls } = load();
	const lock = await win.navigator.wakeLock.request('screen');
	assert.equal(lock.released, false);
	let released = 0;
	lock.addEventListener('release', () => released++);
	await lock.release();
	await lock.release();
	assert.equal(lock.released, true);
	assert.equal(released, 1);
	assert.equal(calls.length, 0);
});

test('click() on a detached file input drops the accept filter first', () => {
	// cstimer never inserts its import inputs into the page; it calls .click() on them directly.
	const clicked = [];
	class HTMLInputElement {
		click() { clicked.push(this.type + ':' + (this.accept || '')); }
		removeAttribute(name) { if (name === 'accept') this.accept = ''; }
	}
	const env = load({}, { HTMLInputElement });
	const file = Object.assign(new HTMLInputElement(), { type: 'file', accept: 'text/*' });
	const text = Object.assign(new HTMLInputElement(), { type: 'text', accept: 'x' });
	file.click();
	text.click();
	assert.deepEqual(clicked, ['file:', 'text:x']);
	assert.ok(env.bt);
});

test('file inputs lose their accept filter so the iOS picker allows any file', () => {
	const { win } = load();
	const removed = [];
	const input = Object.assign(new EventTarget(), {
		tagName: 'INPUT', type: 'file',
		removeAttribute(name) { removed.push(name); },
	});
	const other = Object.assign(new EventTarget(), {
		tagName: 'A', type: '',
		removeAttribute(name) { removed.push('other:' + name); },
	});
	// Clicks reach window listeners in the capture phase; simulate that path.
	const fire = (target) => {
		const e = new Event('click');
		Object.defineProperty(e, 'target', { value: target });
		win.dispatchEvent(e);
	};
	fire(input);
	fire(other);
	assert.deepEqual(removed, ['accept']);
});

// App Store rules: no outside donation links (guideline 3.1.1) and no ads setting in the app,
// on bsTimer and on cstimer.net alike. The shim adds a stylesheet once the page has loaded.
function withStyles() {
	const head = { children: [], appendChild(el) { this.children.push(el); return el; } };
	const document = {
		head,
		createElement(tag) { return { tagName: tag.toUpperCase(), textContent: '', id: '' }; },
		getElementById(id) { return head.children.find((c) => c.id === id) || null; },
	};
	const env = load({}, { document });
	env.win.dispatchEvent(new Event('DOMContentLoaded'));
	return { env, head };
}

test("the app hides csTimer's donate button and its advertisements setting", () => {
	const { head } = withStyles();
	const styles = head.children.filter((c) => c.tagName === 'STYLE');
	assert.equal(styles.length, 1, 'one stylesheet');
	const css = styles[0].textContent.replace(/\s+/g, ' ');
	assert.match(css, /#leftbar > \.c5\b[^{]*\{[^}]*display: none/, 'donate button (toolbar slot 5) hidden');
	// only the setting's own row: tr > td > label > input. A plain tr:has(input) would also match
	// the outer row that holds the whole settings table, and hide every setting.
	assert.match(css, /tr:has\(> td > label > input\[name="showad"\]\)[^{]*\{[^}]*display: none/, 'advertisements setting row hidden');
	assert.doesNotMatch(css, /tr:has\(input/, 'no selector that matches ancestor rows');
	assert.equal(styles[0].id, 'bstimer-app-hide');
});

test("the Bluetooth dialog hides csTimer's instructions, since the app explains Bluetooth problems itself", () => {
	// csTimer's .instruction block: "check that Bluetooth is enabled", then advice to use Chrome
	// or Bluefy and change browser flags, which is wrong inside the app. When Bluetooth is off or
	// not allowed, BluetoothBridge.explainUnavailable says so (with Open Settings) after OK.
	const css = withStyles().head.children[0].textContent.replace(/\s+/g, ' ');
	assert.match(css, /\.instruction \{ display: none !important; \}/);
	assert.doesNotMatch(css, /:not\(:first-child\)/, 'no rule that keeps the first line');
	const swift = fs.readFileSync(path.join(__dirname, '../CstimerApp/BluetoothBridge.swift'), 'utf8');
	assert.match(swift, /case \.poweredOff:[\s\S]*?"Bluetooth is off"/, 'the app says when Bluetooth is off');
	assert.match(swift, /case \.unauthorized:[\s\S]*?"Bluetooth access is off"/, 'and when access is denied');
});

test('the Bluetooth dialog shrinks to its few lines instead of the big share-dialog box', () => {
	// csTimer shows it with the 'share' dialog class: a box from 20% to 80% of the screen.
	const css = withStyles().head.children[0].textContent.replace(/\s+/g, ' ');
	const rule = css.match(/\.dialogshare:has\(\.instruction\) \{([^}]*)\}/);
	assert.ok(rule, 'a rule only for the share dialog holding the Bluetooth instructions');
	assert.match(rule[1], /top: 50% !important/);
	assert.match(rule[1], /bottom: auto !important/);
	assert.match(rule[1], /height: [\d.]+em/);
	assert.match(rule[1], /max-height: 90%/, 'still fits a landscape phone');
	assert.match(rule[1], /transform: translateY\(-50%\)/, 'centred');
	assert.doesNotMatch(css, /\.dialogshare \{/, 'the export share dialog keeps its size');
	assert.match(css, /\.dialogshare:has\(\.instruction\) \.value br \{ display: none; \}/, "the timer dialog's blank lines go, so its text fits");
});

test('the stylesheet is added only once', () => {
	const { env, head } = withStyles();
	env.win.dispatchEvent(new Event('DOMContentLoaded'));
	assert.equal(head.children.filter((c) => c.id === 'bstimer-app-hide').length, 1);
});

test('no document head: the shim carries on', () => {
	const env = load({}, { document: { head: null, createElement() { return {}; }, getElementById() { return null; } } });
	env.win.dispatchEvent(new Event('DOMContentLoaded'));
	assert.equal(typeof env.bt.requestDevice, 'function');
});

// Web Bluetooth rejects names that aren't UUIDs with a TypeError before anything reaches the
// device; the shim does the same so malformed values never get to the native bridge.
const BAD_UUIDS = ['heart_rate', 'fff', '0000fff0-0000-1000-8000-00805f9b34f', 'zzzz', '', '0000fff0-0000-1000-8000-00805f9b34fbX', '{0000fff0-0000-1000-8000-00805f9b34fb}'];

test('malformed service UUIDs are refused with a TypeError and never sent to native', async () => {
	const env = await connectedChar();
	for (const bad of BAD_UUIDS) {
		const before = env.calls.length;
		await assert.rejects(env.server.getPrimaryService(bad), (e) => e.name === 'TypeError', `getPrimaryService(${JSON.stringify(bad)})`);
		await assert.rejects(env.server.getPrimaryServices(bad), (e) => e.name === 'TypeError', `getPrimaryServices(${JSON.stringify(bad)})`);
		assert.equal(env.calls.length, before, `nothing sent for ${JSON.stringify(bad)}`);
	}
});

test('malformed characteristic UUIDs are refused with a TypeError and never sent to native', async () => {
	const env = await connectedChar();
	for (const bad of BAD_UUIDS) {
		const before = env.calls.length;
		await assert.rejects(env.service.getCharacteristic(bad), (e) => e.name === 'TypeError', `getCharacteristic(${JSON.stringify(bad)})`);
		await assert.rejects(env.service.getCharacteristics(bad), (e) => e.name === 'TypeError', `getCharacteristics(${JSON.stringify(bad)})`);
		assert.equal(env.calls.length, before, `nothing sent for ${JSON.stringify(bad)}`);
	}
});

test('requestDevice with a malformed filter service is refused with a TypeError', async () => {
	const { bt, calls } = load({ requestDevice: () => ({ deviceId: DEV, name: 'X' }) });
	await assert.rejects(bt.requestDevice({ filters: [{ namePrefix: 'GAN' }, { services: ['not-a-uuid'] }] }), (e) => e.name === 'TypeError');
	assert.equal(calls.length, 0);
});

test('every UUID form csTimer uses is still accepted', async () => {
	const env = await connectedChar();
	// full 128-bit (any case), 16-bit and 32-bit aliases, and numbers
	for (const ok of ['0000FFF0-0000-1000-8000-00805F9B34FB', '6e400001-b5a3-f393-e0a9-e50e24dcca9e', 'fff0', 'FFF0', '0000fff0', 0xfff0]) {
		await env.server.getPrimaryService(ok);
	}
	const sent = env.calls.filter((c) => c.op === 'getPrimaryServices').slice(-6).map((c) => c.service);
	assert.deepEqual(sent, [SVC, '6e400001-b5a3-f393-e0a9-e50e24dcca9e', SVC, SVC, SVC, SVC]);
});

// csTimer alerts GIIKER_NOBLEMSG ("Bluetooth API is not available … try chrome with chrome://flags/…")
// when getAvailability is false. The app explains the actual problem itself, so that alert is dropped.
function withAlert() {
	const shown = [];
	const env = load({}, { alert: (...args) => { shown.push(args); } });
	return Object.assign(env, { shown });
}

test("csTimer's 'Bluetooth API is not available' alert is dropped, in any language", () => {
	const { win, shown } = withAlert();
	// the language file loads after the shim
	win.GIIKER_NOBLEMSG = 'Bluetooth-API ist nicht verfügbar … chrome://flags/#enable-experimental-web-platform-features';
	win.alert(win.GIIKER_NOBLEMSG);
	assert.deepEqual(shown, []);
});

test('other alerts still show, with their arguments', () => {
	const { win, shown } = withAlert();
	win.GIIKER_NOBLEMSG = 'Bluetooth API is not available';
	win.alert('Bluetooth API is not available, really');
	win.alert('Saved');
	assert.deepEqual(shown, [['Bluetooth API is not available, really'], ['Saved']]);
});

test('before the language file defines the message, nothing is dropped', () => {
	const { win, shown } = withAlert();
	win.alert();
	win.alert(undefined);
	win.alert('hello');
	assert.equal(shown.length, 3);
});

test('the native side always explains an unavailable Bluetooth, in one alert', () => {
	const swift = fs.readFileSync(path.join(__dirname, '../CstimerApp/BluetoothBridge.swift'), 'utf8');
	assert.match(swift, /CBCentralManager\(delegate: self, queue: \.main, options: \[CBCentralManagerOptionShowPowerAlertKey: false\]\)/,
		"iOS's own 'Turn On Bluetooth' alert is off, so ours is the only one");
	const avail = swift.match(/private func handleGetAvailability[\s\S]*?\n    \}\n/)[0];
	const timeout = avail.match(/asyncAfter[\s\S]*?\n            \}/)[0];
	assert.match(timeout, /explainUnavailable\(\)/, 'also when the state never settles');
	const explain = swift.match(/private func explainUnavailable[\s\S]*?\n    \}\n/)[0];
	const dflt = explain.match(/default:([\s\S]*?)\n        \}/)[1];
	assert.doesNotMatch(dflt, /return/, 'no state goes unexplained');
	assert.match(dflt, /title = "[^"]+"/);
	assert.match(dflt, /message = "[^"]+"/);
});
