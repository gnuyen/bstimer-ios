# JS ⇄ native Bluetooth bridge protocol

The app injects `bluetooth-shim.js` into `https://cstimer.gnuyen.org` at document
start. The shim implements the subset of Web Bluetooth that cstimer uses and
forwards every call to Swift (`BluetoothBridge`).

## Conventions

- **UUIDs** cross the bridge as lowercase 128-bit strings
  (`0000fff0-0000-1000-8000-00805f9b34fb`). The shim canonicalizes whatever the
  page passes (16-/32-bit numbers, 4- or 8-hex-digit strings, 128-bit strings in
  any case). Swift converts with `CBUUID(string:)` and back with a helper that
  expands short `CBUUID.uuidString` values to 128-bit lowercase.
- **Bytes** cross the bridge as standard base64 strings.
- **Device ids** are `CBPeripheral.identifier.uuidString`.
- **Errors**: native rejects with a string `"<Name>: <message>"` where `<Name>`
  is a DOMException name (`NotFoundError`, `NetworkError`, `NotSupportedError`,
  `InvalidStateError`, `SecurityError`). The shim rejects with
  `new DOMException(message, Name)`.

## Calls (JS → native)

`window.webkit.messageHandlers.cstimerBLE.postMessage({op, ...args})` returns a
Promise (native side is a `WKScriptMessageHandlerWithReply`).

| op | args | resolves with |
|----|------|---------------|
| `getAvailability` | – | `true` if Bluetooth is powered on, else `false` (waits for CoreBluetooth to leave `.unknown`/`.resetting`: up to 120 s while the permission prompt may be showing, otherwise 3 s) |
| `requestDevice` | `filters: [{namePrefix?, name?, services?: [uuid]}]`, `acceptAllDevices: bool` | `{deviceId, name}`; shows the native picker; rejects `NotFoundError` on cancel |
| `connect` | `deviceId` | `null` once connected (10 s timeout → `NetworkError`) |
| `disconnect` | `deviceId` | `null` |
| `getPrimaryServices` | `deviceId`, `service?: uuid` | `[uuid]`; `NotFoundError` if `service` given and absent |
| `getCharacteristics` | `deviceId`, `service`, `characteristic?: uuid` | `[{uuid, properties: {read, write, writeWithoutResponse, notify, indicate}}]`; `NotFoundError` if absent |
| `readValue` | `deviceId`, `service`, `characteristic` | base64 |
| `writeValue` | `deviceId`, `service`, `characteristic`, `value` (base64), `mode`: `"auto"` \| `"withResponse"` \| `"withoutResponse"` | `null`. `auto` = with response if the characteristic has `.write`, else without |
| `startNotifications` | `deviceId`, `service`, `characteristic` | `null` once `isNotifying` |
| `stopNotifications` | same | `null` |
| `watchAdvertisements` | `deviceId` | `null`; native scans and emits `advertisement` events for that device until unwatched |
| `unwatchAdvertisements` | `deviceId` | `null` |
| `setKeepAwake` | `on: bool` | `null`; sets `UIApplication.isIdleTimerDisabled`. Sent by the shim when cstimer's `timerStatus` signal leaves or returns to idle (`-1`); reset to `false` on page reload |
| `userActivity` | none | `null`; restarts the screen's sleep countdown (turns the idle timer off and back on) unless `setKeepAwake` is on. Sent by the shim, at most every 5 s, when a smart cube reports a face turn through `GiikerCube.callback`; gyro updates don't count |

## Events (native → JS)

Native calls `window.__cstimerBLE.dispatch(evt)` via `evaluateJavaScript`:

- `{type: "value", deviceId, service, characteristic, value}` (base64): a notification
  or a completed read. The shim sets `characteristic.value` to a fresh `DataView`
  and fires `characteristicvaluechanged`.
- `{type: "disconnected", deviceId}`: fires `gattserverdisconnected` on the device
  and sets `device.gatt.connected = false`.
- `{type: "advertisement", deviceId, name, rssi, manufacturerData: {"<companyId decimal>": base64}, serviceData: {"<uuid>": base64}}`:
  fires `advertisementreceived` with `manufacturerData` / `serviceData` as `Map`s.
  `manufacturerData` keys are numbers; CoreBluetooth's raw manufacturer data is
  split as company id = little-endian first 2 bytes, value = the rest.

Every `DataView` the shim hands to the page must sit at byte offset 0 of its own
`ArrayBuffer` (cstimer drivers call `.buffer.slice(...)` on them).

## iCloud bridge (bsCloud)

The app registers a second handler, `bsCloud`, only in bsTimer mode. It answers
only main-frame `https` pages on the bsTimer host.
`window.webkit.messageHandlers.bsCloud.postMessage(msg)` returns a Promise (native
side is a `WKScriptMessageHandlerWithReply`).

| op | args | resolves with |
|----|------|---------------|
| `status` | – | `{available: bool (iCloud account usable), code: string\|null (server sync code from key-value storage)}` |
| `get` | – | `null` when nothing is stored yet, else `{data: JSON text, tag: string}` |
| `put` | `data: JSON text`, `tag: string\|null` | `{ok: true, tag: new tag}`, or `{conflict: true}` when the stored record's tag is not `tag` (`null` means "expect no record"); the page then gets, merges and tries again |
| `setCode` | `code: string\|null` | `true` (`null` removes it) |
| `appleSignIn` | – | `{token: Apple identity token (JWT), code?: authorization code}`; rejects with `"cancelled"` if the user closes the sheet. The server exchanges the code for a refresh token so it can revoke the sign-in when the data is deleted |
| `deleteAll` | – | `true`; deletes the `snapshot` record and the `serverCode` key (the user deleted their synced data) |

Errors reject the Promise with a message starting `"iCloud: "`.

Event (native → JS): when another device changes the code in key-value storage, the
app calls `window.bsSync.cloudCodeChanged(code)`.
