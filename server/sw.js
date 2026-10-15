// bsTimer offline support: replaces csTimer's placeholder sw.js on the server.
// The page is network-first (falls back to the cached copy offline or after a few
// seconds); scripts, styles and images are served from cache and refreshed in the
// background, so a deploy shows up on the second launch.
'use strict';

const CACHE = 'bstimer-offline-v1';
const SCOPE = self.registration.scope;
const ORIGIN = new URL(SCOPE).origin;
const PAGE = SCOPE;
const NAV_TIMEOUT_MS = self.__navTimeoutMs || 4000;
const EXTRA = ['js/cstimer.js', 'cstimer512x512.png', 'cstimer.webmanifest'];

function isPageUrl(url) {
	const pageUrl = new URL(SCOPE);
	if (url.origin !== pageUrl.origin) return false;
	const p = pageUrl.pathname;
	return url.pathname === p || url.pathname === p + 'index.php';
}

function cacheable(res) {
	return res && res.status === 200 && res.type === 'basic';
}

function offline() {
	return new Response('<h1>Offline</h1><p>bsTimer needs an internet connection the first time it opens.</p>', {
		status: 503,
		headers: { 'Content-Type': 'text/html; charset=utf-8' }
	});
}

function put(key, res) {
	return caches.open(CACHE).then(c => c.put(key, res));
}

function precache() {
	return fetch(PAGE, { cache: 'reload' })
		.then(res => {
			if (!cacheable(res)) return;
			return put(PAGE, res.clone()).then(() => res.text());
		})
		.then(html => {
			if (!html) return [];
			const urls = new Set();
			const regex = /(?:src|href)\s*=\s*["']([^"']+)["']/gi;
			let match;
			while ((match = regex.exec(html)) !== null) {
				const v = match[1];
				try {
					const u = new URL(v, SCOPE);
					if (u.protocol !== 'http:' && u.protocol !== 'https:') continue;
					if (u.origin !== ORIGIN) continue;
					if (u.pathname.endsWith('.php')) continue;
					u.hash = '';
					if (u.href === PAGE) continue;
					urls.add(u.href);
				} catch (e) {
					// skip parse errors
				}
			}
			EXTRA.forEach(rel => {
				try {
					const u = new URL(rel, SCOPE);
					urls.add(u.href);
				} catch (e) {
					// skip
				}
			});
			return [...urls];
		})
		.then(urls => {
			if (!urls) return;
			return Promise.all(urls.map(url => {
				return fetch(url, { cache: 'reload' })
					.then(res => {
						if (cacheable(res)) {
							return put(url, res.clone());
						}
					})
					.catch(() => {});
			}));
		})
		.catch(() => {});
}

self.addEventListener('install', event => {
	event.waitUntil(precache());
	self.skipWaiting();
});

self.addEventListener('activate', event => {
	event.waitUntil(
		caches.keys().then(keys => {
			return Promise.all(keys.map(key => {
				if (key !== CACHE) {
					return caches.delete(key);
				}
			}));
		}).then(() => self.clients.claim())
	);
});

function navigate(event) {
	const network = fetch(event.request).then(res => {
		if (cacheable(res)) {
			return put(PAGE, res.clone()).then(() => res);
		}
		return res;
	});
	event.waitUntil(network.catch(() => {}));

	return new Promise((resolve) => {
		let settled = false;
		const timer = setTimeout(() => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			caches.open(CACHE).then(c => c.match(PAGE)).then(cached => {
				if (cached) {
					resolve(cached);
				} else {
					// If nothing cached and timer fired, keep waiting for network
					network.then(res => resolve(res)).catch(() => {
						resolve(offline());
					});
				}
			});
		}, NAV_TIMEOUT_MS);

		network.then(res => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			if (res.ok) {
				resolve(res);
			} else {
				caches.open(CACHE).then(c => c.match(PAGE)).then(cached => {
					resolve(cached || res);
				});
			}
		}).catch(() => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			caches.open(CACHE).then(c => c.match(PAGE)).then(cached => {
				if (cached) {
					resolve(cached);
				} else {
					resolve(offline());
				}
			});
		});
	});
}

function asset(event) {
	return caches.open(CACHE).then(c => c.match(event.request).then(hit => {
		const network = fetch(event.request, { cache: 'no-cache' }).then(res => {
			if (cacheable(res)) {
				return c.put(event.request, res.clone()).then(() => res);
			}
			return res;
		});
		if (hit) {
			event.waitUntil(network.catch(() => {}));
			return hit;
		}
		return network;
	}));
}

self.addEventListener('fetch', event => {
	const req = event.request;
	const url = new URL(req.url);

	if (req.method !== 'GET') return;
	if (url.origin !== ORIGIN) return;
	if (url.pathname.endsWith('/sw.js')) return;

	if (req.mode === 'navigate' && isPageUrl(url)) {
		event.respondWith(navigate(event));
		return;
	}

	if (url.pathname.endsWith('.php')) {
		return;
	}

	event.respondWith(asset(event));
});
