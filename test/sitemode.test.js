// Run with: node --test test/
// The csTimer.net option is a build switch (CSTIMER_NET_OPTION in project.yml), off until cs0x7f
// approves it. These tests check that everything the switch controls agrees with it.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(ROOT, f), 'utf8');
// project.yml without comments, so a commented-out line doesn't count
const yml = read('project.yml').split('\n').map((l) => l.replace(/(^|\s)#.*$/, '')).join('\n');

const optionOn = /^\s*OTHER_SWIFT_FLAGS:.*-D CSTIMER_NET_OPTION\b/m.test(yml);

function boundDomains() {
	const m = yml.match(/^(\s*)WKAppBoundDomains:\n((?:\1\s+- .*\n|\s*\n)+)/m);
	assert.ok(m, 'WKAppBoundDomains in project.yml');
	return m[2].split('\n').map((l) => l.trim().replace(/^- /, '')).filter(Boolean);
}

function resourceExcludes() {
	const m = yml.match(/- path: CstimerApp\/Resources\n((?:\s+\S.*\n)*)/);
	assert.ok(m, 'the Resources source in project.yml');
	return [...m[1].matchAll(/^\s+- "?([^"\n]+)"?$/gm)].map((x) => x[1]);
}

test('the App Store build has the csTimer.net option off', () => {
	assert.equal(optionOn, false, 'turn it on only once cs0x7f has approved it');
});

test('Settings.bundle (the Website choice) is in the app only with the option on', () => {
	assert.equal(resourceExcludes().includes('Settings.bundle'), !optionOn);
	assert.ok(fs.existsSync(path.join(ROOT, 'CstimerApp/Resources/Settings.bundle/Root.plist')), 'kept in the repository');
});

test('cstimer.net is an app-bound domain only with the option on', () => {
	const d = boundDomains();
	for (const h of ['cstimer.net', 'www.cstimer.net']) assert.equal(d.includes(h), optionOn, h);
	for (const h of ['bstimer.manoagames.com', 'www.worldcubeassociation.org', 'worldcubeassociation.org']) assert.ok(d.includes(h), h);
});

test('SiteMode.current reads the Settings choice only with the option on', () => {
	const src = read('CstimerApp/SiteMode.swift');
	const body = src.match(/static var current: SiteMode \{\n([\s\S]*?)\n    \}\n/);
	assert.ok(body, 'SiteMode.current');
	const lines = body[1].split('\n').map((l) => l.trim());
	assert.deepEqual(lines[0], '#if CSTIMER_NET_OPTION');
	const elseAt = lines.indexOf('#else');
	assert.ok(elseAt > 0 && lines[lines.length - 1] == '#endif', '#if … #else … #endif');
	assert.match(lines.slice(1, elseAt).join('\n'), /UserDefaults\.standard\.string\(forKey: defaultsKey\)/);
	assert.deepEqual(lines.slice(elseAt + 1, -1), ['return .bstimer']);
});
