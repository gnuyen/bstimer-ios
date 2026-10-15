// Run with: node --test test/
// Loads server/sw.js into a fake service worker global with mocked fetch and CacheStorage.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SW = fs.readFileSync(path.join(__dirname, '..', 'server', 'sw.js'), 'utf8');
const SCOPE = 'https://cstimer.gnuyen.org/';
const CACHE = 'bstimer-offline-v1';

const INDEX_HTML = `<html><head>
<link rel="manifest" href="cstimer.webmanifest">
<link rel='stylesheet' type='text/css' href='css/style.css'>
<script type="text/javascript" src="js/app-auth.js"></script>
<script type="text/javascript" src="js/kernel.js?v=2"></script>
<script src="https://www.googletagmanager.com/gtag.js"></script>
<script src="//cdn.example.com/x.js"></script>
<a href="timer.php">t</a>
<a href="#top">t</a>
<a href="mailto:a@b.c">m</a>
</head></html>`;

function keyOf(req) {
	return typeof req === 'string' ? req : req.url;
}

function makeCaches() {
	const stores = new Map();
	function open(name) {
		if (!stores.has(name)) stores.set(name, new Map());
		const m = stores.get(name);
		return {
			async match(req, opts) {
				const k = keyOf(req);
				let r = m.get(k);
				if (!r && opts && opts.ignoreSearch) {
					const base = k.split('?')[0];
					for (const [kk, v] of m) if (kk.split('?')[0] === base) { r = v; break; }
				}
				return r ? r.clone() : undefined;
			},
			async put(req, res) { m.set(keyOf(req), res); },
			async keys() { return [...m.keys()].map((url) => ({ url })); },
			async delete(req) { return m.delete(keyOf(req)); },
		};
	}
	return {
		stores,
		async open(name) { return open(name); },
		async keys() { return [...stores.keys()]; },
		async delete(name) { return stores.delete(name); },
		async has(name) { return stores.has(name); },
		async match(req, opts) {
			for (const name of stores.keys()) {
				const r = await open(name).match(req, opts);
				if (r) return r;
			}
			return undefined;
		},
	};
}

function body(text, status = 200, type = 'basic') {
	const r = new Response(text, { status, headers: { 'content-type': 'text/plain' } });
	Object.defineProperty(r, 'type', { value: type });
	return r;
}

// routes: {url: string | Response | (() => Promise<Response>) | Error}
function load(routes = {}, { navTimeoutMs } = {}) {
	const listeners = {};
	const fetchCalls = [];
	const caches = makeCaches();
	let skipped = false;
	let claimed = false;
	async function fetch(req, init) {
		const url = keyOf(req);
		fetchCalls.push({ url, init });
		const r = routes[url];
		if (r === undefined) throw new TypeError('offline: ' + url);
		if (r instanceof Error) throw r;
		if (typeof r === 'function') return r();
		if (typeof r === 'string') return body(r);
		return r.clone();
	}
	const self = {
		registration: { scope: SCOPE },
		location: { href: SCOPE + 'sw.js', origin: 'https://cstimer.gnuyen.org' },
		addEventListener(type, fn) { listeners[type] = fn; },
		skipWaiting() { skipped = true; return Promise.resolve(); },
		clients: { claim() { claimed = true; return Promise.resolve(); } },
	};
	if (navTimeoutMs !== undefined) self.__navTimeoutMs = navTimeoutMs;
	const ctx = { self, caches, fetch, Response, Request, URL, Promise, console, setTimeout, clearTimeout };
	ctx.globalThis = ctx;
	vm.createContext(ctx);
	vm.runInContext(SW, ctx);

	async function lifecycle(type) {
		const waits = [];
		listeners[type]({ waitUntil(p) { waits.push(p); } });
		await Promise.all(waits);
	}
	// Returns {responded, response, waits}
	async function dispatchFetch(request) {
		let responded = null;
		const waits = [];
		const ev = {
			request,
			respondWith(p) { responded = Promise.resolve(p); },
			waitUntil(p) { waits.push(p); },
		};
		listeners.fetch(ev);
		const response = responded ? await responded : undefined;
		return { responded: !!responded, response, waits };
	}
	return {
		listeners, fetchCalls, caches, routes, lifecycle, dispatchFetch,
		get skipped() { return skipped; },
		get claimed() { return claimed; },
	};
}

const get = (url) => ({ url, method: 'GET', mode: 'no-cors' });
const nav = (url) => ({ url, method: 'GET', mode: 'navigate' });

async function cached(sw, url) {
	const store = sw.caches.stores.get(CACHE);
	return store && store.has(url) ? await store.get(url).clone().text() : undefined;
}

test('install precaches the page and its same-origin assets, skips waiting', async () => {
	const sw = load({
		[SCOPE]: INDEX_HTML,
		[SCOPE + 'cstimer.webmanifest']: 'manifest',
		[SCOPE + 'css/style.css']: 'css',
		[SCOPE + 'js/app-auth.js']: 'auth',
		[SCOPE + 'js/kernel.js?v=2']: 'kernel',
		[SCOPE + 'js/cstimer.js']: 'worker',
		[SCOPE + 'cstimer512x512.png']: 'png',
	});
	await sw.lifecycle('install');
	assert.equal(sw.skipped, true);
	assert.equal(await cached(sw, SCOPE), INDEX_HTML);
	assert.equal(await cached(sw, SCOPE + 'css/style.css'), 'css');
	assert.equal(await cached(sw, SCOPE + 'js/kernel.js?v=2'), 'kernel');
	assert.equal(await cached(sw, SCOPE + 'js/cstimer.js'), 'worker');
	assert.equal(await cached(sw, SCOPE + 'cstimer512x512.png'), 'png');
	const urls = sw.fetchCalls.map((c) => c.url);
	assert.ok(!urls.some((u) => u.includes('googletagmanager') || u.includes('example.com')), 'no cross-origin precache');
	assert.ok(!urls.some((u) => u.endsWith('.php')), 'no php precache');
	assert.ok(!urls.some((u) => u.includes('mailto') || u.includes('#')), 'no junk urls');
	const pageFetch = sw.fetchCalls.find((c) => c.url === SCOPE);
	assert.equal(pageFetch.init && pageFetch.init.cache, 'reload');
});

test('install succeeds when offline or when single assets fail', async () => {
	const off = load({});
	await off.lifecycle('install');
	assert.equal(off.skipped, true);

	const partial = load({ [SCOPE]: INDEX_HTML, [SCOPE + 'css/style.css']: body('nope', 404) });
	await partial.lifecycle('install');
	assert.equal(await cached(partial, SCOPE), INDEX_HTML);
	assert.equal(await cached(partial, SCOPE + 'css/style.css'), undefined, '404 not cached');
});

test('activate deletes other caches and claims clients', async () => {
	const sw = load({});
	await (await sw.caches.open('cstimer_cache_old')).put(SCOPE, body('old'));
	await (await sw.caches.open(CACHE)).put(SCOPE, body('keep'));
	await sw.lifecycle('activate');
	assert.deepEqual(await sw.caches.keys(), [CACHE]);
	assert.equal(sw.claimed, true);
});

test('navigation is network-first and refreshes the cached page', async () => {
	const sw = load({ [SCOPE]: 'new page' });
	await (await sw.caches.open(CACHE)).put(SCOPE, body('old page'));
	const { response, waits } = await sw.dispatchFetch(nav(SCOPE));
	assert.equal(await response.text(), 'new page');
	await Promise.all(waits);
	assert.equal(await cached(sw, SCOPE), 'new page');
});

test('navigation with a query string or index.php is stored as the page', async () => {
	const sw = load({ [SCOPE + '?t=1']: 'page q', [SCOPE + 'index.php?lang=de-de']: 'page de' });
	let r = await sw.dispatchFetch(nav(SCOPE + '?t=1'));
	await Promise.all(r.waits);
	assert.equal(await cached(sw, SCOPE), 'page q');
	r = await sw.dispatchFetch(nav(SCOPE + 'index.php?lang=de-de'));
	await Promise.all(r.waits);
	assert.equal(await cached(sw, SCOPE), 'page de');
});

test('navigation offline falls back to the cached page', async () => {
	const sw = load({});
	await (await sw.caches.open(CACHE)).put(SCOPE, body('cached page'));
	for (const url of [SCOPE, SCOPE + '?t=1', SCOPE + 'index.php']) {
		const { response } = await sw.dispatchFetch(nav(url));
		assert.equal(await response.text(), 'cached page', url);
	}
});

test('navigation that times out serves the cache, then still updates it', async () => {
	let finish;
	const sw = load({ [SCOPE]: () => new Promise((res) => { finish = () => res(body('late page')); }) }, { navTimeoutMs: 20 });
	await (await sw.caches.open(CACHE)).put(SCOPE, body('cached page'));
	const { response, waits } = await sw.dispatchFetch(nav(SCOPE));
	assert.equal(await response.text(), 'cached page');
	finish();
	await Promise.all(waits);
	assert.equal(await cached(sw, SCOPE), 'late page');
});

test('navigation server error falls back to cache when available', async () => {
	const sw = load({ [SCOPE]: body('oops', 500) });
	await (await sw.caches.open(CACHE)).put(SCOPE, body('cached page'));
	const { response } = await sw.dispatchFetch(nav(SCOPE));
	assert.equal(await response.text(), 'cached page');
	assert.equal(await cached(sw, SCOPE), 'cached page', 'error page not cached');
});

test('navigation offline with nothing cached gives an offline response', async () => {
	const sw = load({});
	const { response } = await sw.dispatchFetch(nav(SCOPE));
	assert.ok(response, 'responds');
	assert.equal(response.status, 503);
});

test('other php pages are not stored as the main page', async () => {
	const sw = load({ [SCOPE + 'timer.php']: 'timer page' });
	await (await sw.caches.open(CACHE)).put(SCOPE, body('main page'));
	const r = await sw.dispatchFetch(nav(SCOPE + 'timer.php'));
	if (r.responded) assert.equal(await r.response.text(), 'timer page');
	await Promise.all(r.waits);
	assert.equal(await cached(sw, SCOPE), 'main page');
});

test('assets are served from cache and revalidated in the background', async () => {
	const sw = load({ [SCOPE + 'js/kernel.js?v=2']: 'kernel v2' });
	await (await sw.caches.open(CACHE)).put(SCOPE + 'js/kernel.js?v=2', body('kernel v1'));
	const { response, waits } = await sw.dispatchFetch(get(SCOPE + 'js/kernel.js?v=2'));
	assert.equal(await response.text(), 'kernel v1');
	await Promise.all(waits);
	assert.equal(await cached(sw, SCOPE + 'js/kernel.js?v=2'), 'kernel v2');
});

test('uncached assets come from the network and are stored', async () => {
	const sw = load({ [SCOPE + 'lang/de-de.js']: 'de' });
	const { response, waits } = await sw.dispatchFetch(get(SCOPE + 'lang/de-de.js'));
	assert.equal(await response.text(), 'de');
	await Promise.all(waits);
	assert.equal(await cached(sw, SCOPE + 'lang/de-de.js'), 'de');
});

test('cached asset is still served when revalidation fails offline', async () => {
	const sw = load({});
	await (await sw.caches.open(CACHE)).put(SCOPE + 'css/style.css', body('css'));
	const { response, waits } = await sw.dispatchFetch(get(SCOPE + 'css/style.css'));
	assert.equal(await response.text(), 'css');
	await Promise.all(waits); // must not reject
});

test('failed asset responses are not cached', async () => {
	const sw = load({ [SCOPE + 'js/missing.js']: body('nf', 404) });
	const { response, waits } = await sw.dispatchFetch(get(SCOPE + 'js/missing.js'));
	assert.equal(response.status, 404);
	await Promise.all(waits);
	assert.equal(await cached(sw, SCOPE + 'js/missing.js'), undefined);
});

test('ignores non-GET, cross-origin, php and the service worker itself', async () => {
	const sw = load({});
	const cases = [
		{ url: SCOPE + 'oauthwca.php', method: 'POST', mode: 'cors' },
		{ url: SCOPE + 'comp.php', method: 'POST', mode: 'cors' },
		get(SCOPE + 'userdata.php?id=1'),
		get('https://www.googleapis.com/drive/v3/about'),
		get('https://www.worldcubeassociation.org/api/v0/me'),
		get(SCOPE + 'sw.js'),
	];
	for (const req of cases) {
		const r = await sw.dispatchFetch(req);
		assert.equal(r.responded, false, req.method + ' ' + req.url);
	}
	assert.equal(sw.fetchCalls.length, 0);
});

test('cross-origin navigations are left alone', async () => {
	const sw = load({});
	const r = await sw.dispatchFetch(nav('https://www.worldcubeassociation.org/oauth/authorize?x=1'));
	assert.equal(r.responded, false);
});
