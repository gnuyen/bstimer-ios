(function () {
	'use strict';

	var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cstimerBLE;
	if (!handler) {
		return;
	}

	var SUFFIX = '-0000-1000-8000-00805f9b34fb';

	function canon(u) {
		if (typeof u === 'number') {
			var hex = (u >>> 0).toString(16);
			while (hex.length < 8) {
				hex = '0' + hex;
			}
			return (hex + SUFFIX).toLowerCase();
		}
		var s = String(u).toLowerCase();
		if (/^[0-9a-f]{4}$/.test(s)) {
			return ('0000' + s + SUFFIX).toLowerCase();
		}
		if (/^[0-9a-f]{8}$/.test(s)) {
			return (s + SUFFIX).toLowerCase();
		}
		return s;
	}

	function toBase64(bufferSource) {
		var bytes;
		if (bufferSource instanceof DataView) {
			bytes = new Uint8Array(bufferSource.buffer, bufferSource.byteOffset, bufferSource.byteLength);
		} else if (bufferSource instanceof ArrayBuffer) {
			bytes = new Uint8Array(bufferSource);
		} else {
			bytes = new Uint8Array(bufferSource.buffer, bufferSource.byteOffset, bufferSource.byteLength);
		}
		var bin = '';
		for (var i = 0; i < bytes.length; i++) {
			bin += String.fromCharCode(bytes[i]);
		}
		return btoa(bin);
	}

	function toDataView(b64) {
		var bin = atob(b64);
		var buf = new ArrayBuffer(bin.length);
		var view = new Uint8Array(buf);
		for (var i = 0; i < bin.length; i++) {
			view[i] = bin.charCodeAt(i);
		}
		return new DataView(buf);
	}

	function call(op, args) {
		var msg = { op: op };
		if (args) {
			for (var k in args) {
				if (Object.prototype.hasOwnProperty.call(args, k) && args[k] !== undefined) {
					msg[k] = args[k];
				}
			}
		}
		return Promise.resolve(handler.postMessage(msg)).then(function (result) {
			return result;
		}, function (reason) {
			// WebKit rejects with an Error whose message is the native error string
			if (reason && typeof reason !== 'string' && typeof reason.message === 'string') {
				reason = reason.message;
			}
			if (typeof reason === 'string') {
				var m = reason.match(/^(\w+): (.*)$/s);
				if (m) {
					throw new DOMException(m[2], m[1]);
				}
			}
			throw new DOMException(String(reason), 'NetworkError');
		});
	}

	var deviceRegistry = new Map();
	var serviceCache = new Map();
	var characteristicCache = new Map();

	function getDevice(id) {
		return deviceRegistry.get(id);
	}

	function registerDevice(id, name) {
		var device = deviceRegistry.get(id);
		if (!device) {
			device = new BluetoothDevice(id);
			deviceRegistry.set(id, device);
		}
		if (name !== undefined) {
			device.name = name;
		}
		return device;
	}

	function getService(device, uuid) {
		var key = device.id + '|' + uuid;
		var service = serviceCache.get(key);
		if (!service) {
			service = new BluetoothRemoteGATTService(device, uuid);
			serviceCache.set(key, service);
		}
		return service;
	}

	function getCharacteristic(device, serviceUuid, charUuid, properties) {
		var key = device.id + '|' + serviceUuid + '|' + charUuid;
		var chr = characteristicCache.get(key);
		if (!chr) {
			var service = getService(device, serviceUuid);
			chr = new BluetoothRemoteGATTCharacteristic(service, charUuid);
			characteristicCache.set(key, chr);
		}
		if (properties) {
			chr.properties = properties;
		}
		return chr;
	}

	class BluetoothDevice extends EventTarget {
		constructor(id) {
			super();
			this.id = id;
			this.name = null;
			this.watchingAdvertisements = false;
			this.gatt = new BluetoothRemoteGATTServer(this);
		}
	}
	BluetoothDevice.prototype.watchAdvertisements = function (options) {
		var self = this;
		options = options || {};
		if (options.signal) {
			options.signal.addEventListener('abort', function () {
				self.unwatchAdvertisements();
			}, { once: true });
		}
		self.watchingAdvertisements = true;
		return call('watchAdvertisements', { deviceId: self.id });
	};
	BluetoothDevice.prototype.unwatchAdvertisements = function () {
		var self = this;
		self.watchingAdvertisements = false;
		call('unwatchAdvertisements', { deviceId: self.id }).catch(function () {});
	};

	function BluetoothRemoteGATTServer(device) {
		var self = this;
		self.device = device;
		self.connected = false;
	}
	BluetoothRemoteGATTServer.prototype.connect = function () {
		var self = this;
		return call('connect', { deviceId: self.device.id }).then(function () {
			self.connected = true;
			return self;
		});
	};
	BluetoothRemoteGATTServer.prototype.disconnect = function () {
		var self = this;
		self.connected = false;
		call('disconnect', { deviceId: self.device.id }).catch(function () {});
	};
	BluetoothRemoteGATTServer.prototype.getPrimaryService = function (uuid) {
		var self = this;
		var service = canon(uuid);
		return call('getPrimaryServices', { deviceId: self.device.id, service: service }).then(function (uuids) {
			return getService(self.device, uuids[0]);
		});
	};
	BluetoothRemoteGATTServer.prototype.getPrimaryServices = function (uuid) {
		var self = this;
		var args = { deviceId: self.device.id };
		if (uuid !== undefined) {
			args.service = canon(uuid);
		}
		return call('getPrimaryServices', args).then(function (uuids) {
			return uuids.map(function (u) {
				return getService(self.device, u);
			});
		});
	};

	function BluetoothRemoteGATTService(device, uuid) {
		var self = this;
		self.device = device;
		self.uuid = uuid;
		self.isPrimary = true;
	}
	BluetoothRemoteGATTService.prototype.getCharacteristic = function (uuid) {
		var self = this;
		var characteristic = canon(uuid);
		return call('getCharacteristics', {
			deviceId: self.device.id,
			service: self.uuid,
			characteristic: characteristic,
		}).then(function (list) {
			return getCharacteristic(self.device, self.uuid, list[0].uuid, list[0].properties);
		});
	};
	BluetoothRemoteGATTService.prototype.getCharacteristics = function (uuid) {
		var self = this;
		var args = { deviceId: self.device.id, service: self.uuid };
		if (uuid !== undefined) {
			args.characteristic = canon(uuid);
		}
		return call('getCharacteristics', args).then(function (list) {
			return list.map(function (item) {
				return getCharacteristic(self.device, self.uuid, item.uuid, item.properties);
			});
		});
	};

	class BluetoothRemoteGATTCharacteristic extends EventTarget {
		constructor(service, uuid) {
			super();
			this.service = service;
			this.uuid = uuid;
			this.properties = {};
			this.value = null;
		}
	}
	BluetoothRemoteGATTCharacteristic.prototype.readValue = function () {
		var self = this;
		return call('readValue', {
			deviceId: self.service.device.id,
			service: self.service.uuid,
			characteristic: self.uuid,
		}).then(function (result) {
			self.value = toDataView(result);
			return self.value;
		});
	};
	BluetoothRemoteGATTCharacteristic.prototype.writeValue = function (v) {
		return this._write(v, 'auto');
	};
	BluetoothRemoteGATTCharacteristic.prototype.writeValueWithResponse = function (v) {
		return this._write(v, 'withResponse');
	};
	BluetoothRemoteGATTCharacteristic.prototype.writeValueWithoutResponse = function (v) {
		return this._write(v, 'withoutResponse');
	};
	BluetoothRemoteGATTCharacteristic.prototype._write = function (v, mode) {
		var self = this;
		return call('writeValue', {
			deviceId: self.service.device.id,
			service: self.service.uuid,
			characteristic: self.uuid,
			value: toBase64(v),
			mode: mode,
		});
	};
	BluetoothRemoteGATTCharacteristic.prototype.startNotifications = function () {
		var self = this;
		return call('startNotifications', {
			deviceId: self.service.device.id,
			service: self.service.uuid,
			characteristic: self.uuid,
		}).then(function () {
			return self;
		});
	};
	BluetoothRemoteGATTCharacteristic.prototype.stopNotifications = function () {
		var self = this;
		return call('stopNotifications', {
			deviceId: self.service.device.id,
			service: self.service.uuid,
			characteristic: self.uuid,
		}).then(function () {
			return self;
		});
	};

	function dispatch(evt) {
		var device = getDevice(evt.deviceId);
		if (!device) {
			return;
		}
		try {
			if (evt.type === 'value') {
				var key = evt.deviceId + '|' + canon(evt.service) + '|' + canon(evt.characteristic);
				var chr = characteristicCache.get(key);
				if (!chr) {
					return;
				}
				chr.value = toDataView(evt.value);
				chr.dispatchEvent(new Event('characteristicvaluechanged'));
			} else if (evt.type === 'disconnected') {
				device.gatt.connected = false;
				device.dispatchEvent(new Event('gattserverdisconnected'));
			} else if (evt.type === 'advertisement') {
				var manufacturerData = new Map();
				var md = evt.manufacturerData || {};
				for (var mk in md) {
					if (Object.prototype.hasOwnProperty.call(md, mk)) {
						manufacturerData.set(Number(mk), toDataView(md[mk]));
					}
				}
				var serviceData = new Map();
				var sd = evt.serviceData || {};
				for (var sk in sd) {
					if (Object.prototype.hasOwnProperty.call(sd, sk)) {
						serviceData.set(canon(sk), toDataView(sd[sk]));
					}
				}
				var e = new Event('advertisementreceived');
				Object.defineProperty(e, 'device', { value: device, enumerable: true });
				Object.defineProperty(e, 'name', { value: evt.name, enumerable: true });
				Object.defineProperty(e, 'rssi', { value: evt.rssi, enumerable: true });
				Object.defineProperty(e, 'manufacturerData', { value: manufacturerData, enumerable: true });
				Object.defineProperty(e, 'serviceData', { value: serviceData, enumerable: true });
				device.dispatchEvent(e);
			}
		} catch (err) {
			console.error('cstimer BLE dispatch error', err);
		}
	}

	var bluetooth = {
		getAvailability: function () {
			return call('getAvailability');
		},
		requestDevice: function (options) {
			options = options || {};
			var filters = (options.filters || []).map(function (f) {
				var out = {};
				if (f.name !== undefined) {
					out.name = f.name;
				}
				if (f.namePrefix !== undefined) {
					out.namePrefix = f.namePrefix;
				}
				if (f.services !== undefined) {
					out.services = f.services.map(canon);
				}
				return out;
			});
			return call('requestDevice', {
				filters: filters,
				acceptAllDevices: !!options.acceptAllDevices,
			}).then(function (result) {
				return registerDevice(result.deviceId, result.name);
			});
		},
	};

	Object.defineProperty(window.navigator, 'bluetooth', {
		value: bluetooth,
		configurable: true,
		enumerable: true,
	});

	window.__cstimerBLE = {
		dispatch: dispatch,
	};

	// The app decides when the screen stays awake (below), so cstimer's own Screen Wake
	// Lock requests get a sentinel that does nothing instead of locking the screen on.
	Object.defineProperty(window.navigator, 'wakeLock', {
		value: {
			request: function () {
				var sentinel = new EventTarget();
				sentinel.type = 'screen';
				sentinel.released = false;
				sentinel.release = function () {
					if (!sentinel.released) {
						sentinel.released = true;
						sentinel.dispatchEvent(new Event('release'));
					}
					return Promise.resolve();
				};
				return Promise.resolve(sentinel);
			},
		},
		configurable: true,
		enumerable: true,
	});

	// cstimer's import inputs use accept="text/*", which makes the iOS picker grey out
	// exported files it doesn't classify as text. Drop the filter just before the picker
	// opens; cstimer validates the file contents itself.
	window.addEventListener('click', function (e) {
		var t = e.target;
		if (t && t.tagName === 'INPUT' && t.type === 'file') {
			t.removeAttribute('accept');
		}
	}, true);
	// cstimer's import inputs are never inserted into the page; it calls .click() on them
	// directly, and those clicks never reach window. Hook click() itself as well.
	if (window.HTMLInputElement && window.HTMLInputElement.prototype.click) {
		var nativeClick = window.HTMLInputElement.prototype.click;
		window.HTMLInputElement.prototype.click = function () {
			if (this.type === 'file') {
				this.removeAttribute('accept');
			}
			return nativeClick.apply(this, arguments);
		};
	}

	// Keep the screen awake only while cstimer's timer is in use. timerStatus is -1 when
	// idle; inspection, ready and running are all other values.
	window.addEventListener('DOMContentLoaded', function () {
		var kernel = window.kernel;
		if (!kernel || typeof kernel.regListener !== 'function') {
			return;
		}
		var awake = false;
		kernel.regListener('iosapp', 'timerStatus', function (signal, status) {
			var on = status != -1;
			if (on !== awake) {
				awake = on;
				call('setKeepAwake', { on: on }).catch(function () {});
			}
		});
	});
})();
