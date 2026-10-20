// Run with: node --test test/
// The app runs natively on iPhone and iPad. These tests pin the settings that needs, and the
// presentations that crash on iPad without a popover anchor.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(ROOT, f), 'utf8');
// project.yml without comments, so a commented-out line doesn't count
const yml = read('project.yml').split('\n').map((l) => l.replace(/(^|\s)#.*$/, '')).join('\n');

function list(key) {
	const re = new RegExp('^(\\s*)' + key.replace(/[~.]/g, '\\$&') + ':\\n((?:\\1\\s+- .*\\n)+)', 'm');
	const m = yml.match(re);
	return m ? m[2].split('\n').map((l) => l.trim().replace(/^- /, '')).filter(Boolean) : null;
}

const ALL = ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
	'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'];

test('built for iPhone and iPad', () => {
	assert.match(yml, /^\s*TARGETED_DEVICE_FAMILY: "1,2"\s*$/m);
});

test('iPad: all four orientations, so Split View and Stage Manager work', () => {
	// App Store validation rejects an iPad app that supports multitasking without all four.
	assert.deepEqual([...(list('UISupportedInterfaceOrientations~ipad') || [])].sort(), [...ALL].sort());
	assert.doesNotMatch(yml, /UIRequiresFullScreen:\s*true/);
});

test('iPhone: orientations unchanged (no upside down)', () => {
	assert.deepEqual(list('UISupportedInterfaceOrientations'),
		['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']);
});

test('the app icon covers iPad (a single universal 1024 icon)', () => {
	const c = JSON.parse(read('CstimerApp/Assets.xcassets/AppIcon.appiconset/Contents.json'));
	assert.ok(c.images.some((i) => i.idiom == 'universal' && i.size == '1024x1024' && i.filename));
});

const swift = fs.readdirSync(path.join(ROOT, 'CstimerApp')).filter((f) => f.endsWith('.swift'))
	.map((f) => [f, read('CstimerApp/' + f)]);

test('no action sheets (they need a popover anchor on iPad)', () => {
	for (const [f, src] of swift) assert.doesNotMatch(src, /\.actionSheet\b/, f);
});

test('every share sheet has a popover anchor', () => {
	for (const [f, src] of swift) {
		if (!/UIActivityViewController\(/.test(src)) continue;
		assert.match(src, /popoverPresentationController[\s\S]*sourceView = /, f);
	}
});
