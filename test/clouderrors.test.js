// Run with: node --test test/
// CloudKit errors reach the page as text (the sync dot and the Export dialog show it). Apple's own
// text is often just "CKErrorDomain error 15", so CloudErrors.swift words the common ones and
// always adds the code. These tests read the Swift source.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const read = (f) => fs.readFileSync(path.join(ROOT, f), 'utf8');
const src = read('CstimerApp/CloudErrors.swift');

// The message returned for a CKError code: finds the `case` line listing it.
function messageFor(code) {
	for (const m of src.matchAll(/^\s*case ((?:\.\w+(?:, )?)+):\s*\n?\s*(?:base = |return )"([^"]*)"/gm)) {
		if (m[1].split(', ').includes('.' + code)) return m[2];
	}
	return null;
}

const EXPECTED = {
	notAuthenticated: 'not signed in to iCloud. Sign in from the Settings app',
	networkUnavailable: 'no connection. It will try again',
	networkFailure: 'no connection. It will try again',
	serviceUnavailable: 'iCloud is busy. It will try again',
	requestRateLimited: 'iCloud is busy. It will try again',
	zoneBusy: 'iCloud is busy. It will try again',
	quotaExceeded: 'your iCloud storage is full',
	permissionFailure: 'iCloud is restricted on this device',
	managedAccountRestricted: 'iCloud is restricted on this device',
	accountTemporarilyUnavailable: 'your iCloud account is temporarily unavailable. Check the Settings app',
	badContainer: 'iCloud refused the request',
	missingEntitlement: 'iCloud refused the request',
	serverRejectedRequest: 'iCloud refused the request',
	invalidArguments: 'iCloud refused the request',
};

test('CloudErrors.describe words the common CloudKit errors', () => {
	assert.match(src, /enum CloudErrors \{/);
	assert.match(src, /static func describe\(_ error: Error\) -> String/);
	for (const [code, msg] of Object.entries(EXPECTED)) assert.equal(messageFor(code), msg, code);
});

test('every CloudKit message ends with its code, so a report can be looked up', () => {
	assert.match(src, /"\\\(base\) \(CKError \\\(ckError\.code\.rawValue\)\)"/);
});

test('a partial failure is described by the error inside it', () => {
	assert.match(src, /case \.partialFailure:[\s\S]*?partialErrorsByItemID[\s\S]*?describe\(/);
});

test('unknown CloudKit codes and other errors still say something', () => {
	assert.match(src, /default:\s*\n\s*base = "error"/);
	assert.match(src, /return error\.localizedDescription/);
});

test('CloudBridge reports every CloudKit failure through CloudErrors.describe', () => {
	const bridge = read('CstimerApp/CloudBridge.swift');
	assert.doesNotMatch(bridge, /"iCloud: " \+ error\.localizedDescription/);
	assert.ok((bridge.match(/"iCloud: " \+ CloudErrors\.describe\(error\)/g) || []).length >= 4);
});
