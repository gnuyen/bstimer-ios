import CoreBluetooth
import WebKit
import UIKit

typealias Reply = (Any?, String?) -> Void

final class BluetoothBridge: NSObject, WKScriptMessageHandlerWithReply, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let handlerName = "cstimerBLE"

    private let allowedHosts: Set<String>
    private var centralCreated = false
    lazy var central: CBCentralManager = {
        centralCreated = true
        return CBCentralManager(delegate: self, queue: .main)
    }()

    weak var webView: WKWebView?
    var presenter: (() -> UIViewController?)?

    // MARK: - State

    private var peripherals: [UUID: CBPeripheral] = [:]
    private var advertisedServices: [UUID: Set<String>] = [:]
    private var watched: Set<UUID> = []

    private var pickerFilters: [[String: Any]] = []
    private var acceptAll = false
    private var pickerReply: Reply?
    private var picker: DevicePickerViewController?
    private var lastSeenNames: [UUID: String] = [:]
    /// Latest advertisement event per device, replayed on watchAdvertisements so cstimer
    /// gets manufacturer data (the cube MAC) without waiting for a fresh packet.
    private var lastAdvert: [UUID: (event: [String: Any], at: Date)] = [:]
    /// Devices whose services were discovered on the current connection.
    private var servicesDiscovered: Set<UUID> = []

    private var availabilityWaiters: [Reply] = []
    private var connectWaiters: [UUID: [Reply]] = [:]
    private var serviceWaiters: [UUID: [(Error?) -> Void]] = [:]
    private var charWaiters: [String: [(Error?) -> Void]] = [:]
    private var readWaiters: [String: [Reply]] = [:]
    private var writeWaiters: [String: [Reply]] = [:]
    private var notifyWaiters: [String: [Reply]] = [:]
    /// The page asked to keep the screen on (a timer is in use).
    private var keepAwake = false

    // MARK: - Init

    private static func bridgeError(_ msg: String) -> NSError {
        NSError(domain: "BluetoothBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
        super.init()
    }

    // MARK: - Helpers

    private func resolve(_ r: @escaping Reply, _ v: Any? = nil) {
        r(v, nil)
    }

    private func reject(_ r: @escaping Reply, _ name: String, _ msg: String) {
        r(nil, "\(name): \(msg)")
    }

    private func canon(_ u: CBUUID) -> String {
        let s = u.uuidString
        var out: String
        if s.count == 4 {
            out = "0000\(s)-0000-1000-8000-00805f9b34fb"
        } else if s.count == 8 {
            out = "\(s)-0000-1000-8000-00805f9b34fb"
        } else {
            out = s
        }
        return out.lowercased()
    }

    private func charKey(_ id: UUID, _ svc: String, _ chr: String) -> String {
        "\(id.uuidString)|\(svc)|\(chr)"
    }

    private func svcKey(_ id: UUID, _ svc: String) -> String {
        "\(id.uuidString)|\(svc)"
    }

    private func findService(_ p: CBPeripheral, _ svc: String) -> CBService? {
        guard let services = p.services else { return nil }
        for s in services where canon(s.uuid) == svc {
            return s
        }
        return nil
    }

    private func requireConnected(_ p: CBPeripheral, _ r: @escaping Reply) -> Bool {
        if p.state == .connected { return true }
        reject(r, "NetworkError", "GATT Server is disconnected")
        return false
    }

    private func findChar(_ p: CBPeripheral, _ svc: String, _ chr: String) -> CBCharacteristic? {
        guard let s = findService(p, svc), let chars = s.characteristics else { return nil }
        for c in chars where canon(c.uuid) == chr {
            return c
        }
        return nil
    }

    private func emit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__cstimerBLE && window.__cstimerBLE.dispatch(\(json))", completionHandler: nil)
    }

    // MARK: - Scanning

    private func updateScan() {
        guard centralCreated else { return }
        let needed = (picker != nil) || (!watched.isEmpty)
        if needed && central.state == .poweredOn && !central.isScanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else if !needed && central.isScanning {
            central.stopScan()
        }
    }

    private func matchesFilters(_ name: String?, _ services: Set<String>) -> Bool {
        if acceptAll { return true }
        for f in pickerFilters {
            var ok = true
            if let fn = f["name"] as? String {
                if name != fn { ok = false }
            }
            if let fp = f["namePrefix"] as? String {
                if name?.hasPrefix(fp) != true { ok = false }
            }
            if let fs = f["services"] as? [String] {
                for s in fs where !services.contains(s.lowercased()) {
                    ok = false
                    break
                }
            }
            if ok {
                // A filter with no keys matches nothing.
                let hasKey = (f["name"] != nil) || (f["namePrefix"] != nil) || (f["services"] != nil)
                if hasKey { return true }
            }
        }
        return false
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        if !message.frameInfo.isMainFrame || origin.protocol != "https" || !allowedHosts.contains(origin.host) {
            reject(replyHandler, "SecurityError", "Origin not allowed")
            return
        }
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            reject(replyHandler, "NotSupportedError", "Unknown op")
            return
        }
        switch op {
        case "getAvailability":
            handleGetAvailability(replyHandler)
        case "requestDevice":
            handleRequestDevice(body, replyHandler)
        case "connect":
            handleConnect(body, replyHandler)
        case "disconnect":
            handleDisconnect(body, replyHandler)
        case "getPrimaryServices":
            handleGetPrimaryServices(body, replyHandler)
        case "getCharacteristics":
            handleGetCharacteristics(body, replyHandler)
        case "readValue":
            handleReadValue(body, replyHandler)
        case "writeValue":
            handleWriteValue(body, replyHandler)
        case "startNotifications":
            handleStartNotifications(body, replyHandler)
        case "stopNotifications":
            handleStopNotifications(body, replyHandler)
        case "watchAdvertisements":
            handleWatchAdvertisements(body, replyHandler)
        case "unwatchAdvertisements":
            handleUnwatchAdvertisements(body, replyHandler)
        case "setKeepAwake":
            keepAwake = (body["on"] as? Bool) ?? false
            UIApplication.shared.isIdleTimerDisabled = keepAwake
            resolve(replyHandler)
        case "userActivity":
            restartIdleTimer()
            resolve(replyHandler)
        default:
            reject(replyHandler, "NotSupportedError", "Unknown op \(op)")
        }
    }

    /// Turning the cube's faces doesn't touch the screen, so iOS would let it sleep mid-scramble.
    /// Switching the idle timer off and back on restarts its countdown.
    private func restartIdleTimer() {
        guard !keepAwake else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.keepAwake else { return }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Ops

    private func handleGetAvailability(_ r: @escaping Reply) {
        if central.state == .unknown || central.state == .resetting {
            availabilityWaiters.append(r)
            // The state stays .unknown while the Bluetooth permission prompt is on screen,
            // so give the user time to answer it.
            let timeout: Double = CBManager.authorization == .notDetermined ? 120 : 3
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                let waiters = self.availabilityWaiters
                self.availabilityWaiters = []
                for w in waiters {
                    self.resolve(w, false)
                }
            }
        } else {
            let poweredOn = central.state == .poweredOn
            if !poweredOn {
                explainUnavailable()
            }
            resolve(r, poweredOn)
        }
    }

    /// cstimer's own "not available" message talks about Chrome flags, so say what is actually wrong.
    private func explainUnavailable() {
        guard let presenter = presenter?() else { return }
        let title: String
        let message: String
        switch central.state {
        case .unauthorized:
            title = "Bluetooth access is off"
            message = "Allow bsTimer to use Bluetooth in Settings to connect cubes and timers."
        case .poweredOff:
            title = "Bluetooth is off"
            message = "Turn on Bluetooth in Control Center or Settings."
        case .unsupported:
            title = "Bluetooth unavailable"
            message = "This device does not support Bluetooth Low Energy."
        default:
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if central.state == .unauthorized, let url = URL(string: UIApplication.openSettingsURLString) {
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presenter.present(alert, animated: true)
    }

    private func handleRequestDevice(_ body: [String: Any], _ r: @escaping Reply) {
        if picker != nil {
            reject(r, "InvalidStateError", "A device chooser is already open")
            return
        }
        if central.state != .poweredOn && central.state != .unknown {
            reject(r, "NotFoundError", "Bluetooth is not available")
            return
        }
        pickerFilters = (body["filters"] as? [[String: Any]]) ?? []
        acceptAll = (body["acceptAllDevices"] as? Bool) ?? false
        pickerReply = r

        let vc = DevicePickerViewController(
            onSelect: { [weak self] id in
                self?.pickerSelected(id)
            },
            onCancel: { [weak self] in
                self?.pickerCancelled()
            }
        )
        picker = vc

        guard let presenter = presenter?() else {
            endPickerSession()
            reject(r, "NotFoundError", "No presenter available")
            return
        }
        presenter.present(vc, animated: true)
        updateScan()
    }

    private func pickerSelected(_ id: UUID) {
        guard let r = pickerReply else { return }
        let name = lastSeenNames[id]
        let result: [String: Any] = ["deviceId": id.uuidString, "name": name ?? NSNull()]
        endPickerSession()
        resolve(r, result)
    }

    private func pickerCancelled() {
        guard let r = pickerReply else { return }
        endPickerSession()
        reject(r, "NotFoundError", "User cancelled the requestDevice() chooser.")
    }

    private func endPickerSession() {
        picker?.dismissSilently()
        picker = nil
        pickerReply = nil
        pickerFilters = []
        acceptAll = false
        updateScan()
    }

    private func handleConnect(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr) else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        var p = peripherals[id]
        if p == nil {
            p = central.retrievePeripherals(withIdentifiers: [id]).first
            if let p = p { peripherals[id] = p }
        }
        guard let peripheral = p else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        if peripheral.state == .connected {
            resolve(r)
            return
        }
        let wasEmpty = (connectWaiters[id]?.isEmpty ?? true)
        connectWaiters[id, default: []].append(r)
        if wasEmpty {
            central.connect(peripheral)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self else { return }
            guard let waiters = self.connectWaiters[id], !waiters.isEmpty else { return }
            self.connectWaiters[id] = nil
            self.central.cancelPeripheralConnection(peripheral)
            for w in waiters {
                self.reject(w, "NetworkError", "Connection timed out")
            }
        }
    }

    private func handleDisconnect(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr) else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        if let p = peripherals[id] {
            central.cancelPeripheralConnection(p)
        }
        resolve(r)
    }

    private func handleGetPrimaryServices(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr),
              let p = peripherals[id] else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        if p.state != .connected {
            reject(r, "NetworkError", "GATT Server is disconnected")
            return
        }
        let service = (body["service"] as? String)?.lowercased()
        if !servicesDiscovered.contains(id) {
            let wasEmpty = (serviceWaiters[id]?.isEmpty ?? true)
            serviceWaiters[id, default: []].append { [weak self] err in
                self?.rerunGetPrimaryServices(id: id, service: service, r: r, err: err)
            }
            if wasEmpty {
                p.discoverServices(nil)
            }
        } else {
            answerGetPrimaryServices(p: p, service: service, r: r)
        }
    }

    private func rerunGetPrimaryServices(id: UUID, service: String?, r: @escaping Reply, err: Error?) {
        if let err = err {
            reject(r, "NetworkError", err.localizedDescription)
            return
        }
        guard let p = peripherals[id] else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        answerGetPrimaryServices(p: p, service: service, r: r)
    }

    private func answerGetPrimaryServices(p: CBPeripheral, service: String?, r: @escaping Reply) {
        guard let services = p.services else {
            reject(r, "NetworkError", "GATT Server is disconnected")
            return
        }
        var list: [String]
        if let svc = service {
            list = services.filter { canon($0.uuid) == svc }.map { canon($0.uuid) }
            if list.isEmpty {
                reject(r, "NotFoundError", "No Services matching UUID \(svc) found in Device.")
                return
            }
        } else {
            list = services.map { canon($0.uuid) }
        }
        resolve(r, list)
    }

    private func handleGetCharacteristics(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr),
              let p = peripherals[id],
              let svcStr = body["service"] as? String else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        if p.state != .connected {
            reject(r, "NetworkError", "GATT Server is disconnected")
            return
        }
        let svc = svcStr.lowercased()
        let chr = (body["characteristic"] as? String)?.lowercased()
        guard let s = findService(p, svc) else {
            reject(r, "NotFoundError", "No Services matching UUID \(svc) found in Device.")
            return
        }
        if s.characteristics == nil {
            let key = svcKey(id, svc)
            let wasEmpty = (charWaiters[key]?.isEmpty ?? true)
            charWaiters[key, default: []].append { [weak self] err in
                self?.rerunGetCharacteristics(id: id, svc: svc, chr: chr, r: r, err: err)
            }
            if wasEmpty {
                p.discoverCharacteristics(nil, for: s)
            }
        } else {
            answerGetCharacteristics(p: p, svc: svc, chr: chr, r: r)
        }
    }

    private func rerunGetCharacteristics(id: UUID, svc: String, chr: String?, r: @escaping Reply, err: Error?) {
        if let err = err {
            reject(r, "NetworkError", err.localizedDescription)
            return
        }
        guard let p = peripherals[id] else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        answerGetCharacteristics(p: p, svc: svc, chr: chr, r: r)
    }

    private func answerGetCharacteristics(p: CBPeripheral, svc: String, chr: String?, r: @escaping Reply) {
        guard let s = findService(p, svc), let chars = s.characteristics else {
            reject(r, "NotFoundError", "No Services matching UUID \(svc) found in Device.")
            return
        }
        var list: [[String: Any]]
        if let c = chr {
            let filtered = chars.filter { canon($0.uuid) == c }
            if filtered.isEmpty {
                reject(r, "NotFoundError", "No Characteristics matching UUID \(c) found in Service.")
                return
            }
            list = filtered.map { charInfo($0) }
        } else {
            list = chars.map { charInfo($0) }
        }
        resolve(r, list)
    }

    private func charInfo(_ c: CBCharacteristic) -> [String: Any] {
        let props = c.properties
        return [
            "uuid": canon(c.uuid),
            "properties": [
                "read": props.contains(.read),
                "write": props.contains(.write),
                "writeWithoutResponse": props.contains(.writeWithoutResponse),
                "notify": props.contains(.notify),
                "indicate": props.contains(.indicate),
            ]
        ]
    }

    private func handleReadValue(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr),
              let p = peripherals[id],
              let svcStr = body["service"] as? String,
              let chrStr = body["characteristic"] as? String else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        let svc = svcStr.lowercased()
        let chr = chrStr.lowercased()
        guard requireConnected(p, r) else { return }
        guard let c = findChar(p, svc, chr) else {
            reject(r, "NotFoundError", "No Characteristics matching UUID \(chr) found in Service.")
            return
        }
        let key = charKey(id, svc, chr)
        readWaiters[key, default: []].append(r)
        p.readValue(for: c)
    }

    private func handleWriteValue(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr),
              let p = peripherals[id],
              let svcStr = body["service"] as? String,
              let chrStr = body["characteristic"] as? String,
              let valueStr = body["value"] as? String else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        let svc = svcStr.lowercased()
        let chr = chrStr.lowercased()
        guard requireConnected(p, r) else { return }
        guard let c = findChar(p, svc, chr) else {
            reject(r, "NotFoundError", "No Characteristics matching UUID \(chr) found in Service.")
            return
        }
        guard let data = Data(base64Encoded: valueStr) else {
            reject(r, "NotSupportedError", "Bad value")
            return
        }
        let mode = (body["mode"] as? String) ?? "auto"
        let key = charKey(id, svc, chr)
        let type: CBCharacteristicWriteType
        switch mode {
        case "withResponse":
            type = .withResponse
        case "withoutResponse":
            type = .withoutResponse
        default:
            type = c.properties.contains(.write) ? .withResponse : .withoutResponse
        }
        if type == .withResponse {
            writeWaiters[key, default: []].append(r)
            p.writeValue(data, for: c, type: .withResponse)
        } else {
            p.writeValue(data, for: c, type: .withoutResponse)
            resolve(r)
        }
    }

    private func handleStartNotifications(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr),
              let p = peripherals[id],
              let svcStr = body["service"] as? String,
              let chrStr = body["characteristic"] as? String else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        let svc = svcStr.lowercased()
        let chr = chrStr.lowercased()
        guard requireConnected(p, r) else { return }
        guard let c = findChar(p, svc, chr) else {
            reject(r, "NotFoundError", "No Characteristics matching UUID \(chr) found in Service.")
            return
        }
        let key = charKey(id, svc, chr)
        notifyWaiters[key, default: []].append(r)
        p.setNotifyValue(true, for: c)
    }

    private func handleStopNotifications(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr),
              let p = peripherals[id],
              let svcStr = body["service"] as? String,
              let chrStr = body["characteristic"] as? String else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        let svc = svcStr.lowercased()
        let chr = chrStr.lowercased()
        guard requireConnected(p, r) else { return }
        guard let c = findChar(p, svc, chr) else {
            reject(r, "NotFoundError", "No Characteristics matching UUID \(chr) found in Service.")
            return
        }
        let key = charKey(id, svc, chr)
        notifyWaiters[key, default: []].append(r)
        p.setNotifyValue(false, for: c)
    }

    private func handleWatchAdvertisements(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr) else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        watched.insert(id)
        updateScan()
        resolve(r)
        if let cached = lastAdvert[id], Date().timeIntervalSince(cached.at) < 30 {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.watched.contains(id) else { return }
                self.emit(cached.event)
            }
        }
    }

    private func handleUnwatchAdvertisements(_ body: [String: Any], _ r: @escaping Reply) {
        guard let idStr = body["deviceId"] as? String, let id = UUID(uuidString: idStr) else {
            reject(r, "NotFoundError", "Unknown device")
            return
        }
        watched.remove(id)
        updateScan()
        resolve(r)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .unknown && central.state != .resetting {
            let waiters = availabilityWaiters
            availabilityWaiters = []
            let poweredOn = central.state == .poweredOn
            if !poweredOn && !waiters.isEmpty {
                explainUnavailable()
            }
            for w in waiters {
                resolve(w, poweredOn)
            }
        }
        updateScan()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        peripherals[id] = peripheral
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        lastSeenNames[id] = name

        var services = Set<String>()
        if let arr = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            for u in arr { services.insert(canon(u)) }
        }
        if let arr = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            for u in arr { services.insert(canon(u)) }
        }
        advertisedServices[id] = services

        if picker != nil {
            if matchesFilters(name, services) {
                picker?.upsert(id: id, name: name ?? "Unknown device", rssi: RSSI.intValue)
            }
        }

        do {
            var manufacturerData: [String: String] = [:]
            if let md = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, md.count >= 2 {
                let companyId = UInt16(md[md.startIndex]) | (UInt16(md[md.startIndex + 1]) << 8)
                let value = md.dropFirst(2)
                manufacturerData["\(companyId)"] = Data(value).base64EncodedString()
            }
            var serviceData: [String: String] = [:]
            if let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
                for (k, v) in sd {
                    serviceData[canon(k)] = v.base64EncodedString()
                }
            }
            let event: [String: Any] = [
                "type": "advertisement",
                "deviceId": id.uuidString,
                "name": name ?? NSNull(),
                "rssi": RSSI.intValue,
                "manufacturerData": manufacturerData,
                "serviceData": serviceData,
            ]
            lastAdvert[id] = (event, Date())
            if watched.contains(id) {
                emit(event)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        let id = peripheral.identifier
        servicesDiscovered.remove(id)
        let waiters = connectWaiters[id] ?? []
        connectWaiters[id] = nil
        for w in waiters {
            resolve(w)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        let waiters = connectWaiters[id] ?? []
        connectWaiters[id] = nil
        for w in waiters {
            reject(w, "NetworkError", error?.localizedDescription ?? "Failed to connect")
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        let prefix = "\(id.uuidString)|"
        for key in readWaiters.keys where key.hasPrefix(prefix) {
            let waiters = readWaiters[key] ?? []
            readWaiters[key] = nil
            for w in waiters { reject(w, "NetworkError", "Device disconnected") }
        }
        for key in writeWaiters.keys where key.hasPrefix(prefix) {
            let waiters = writeWaiters[key] ?? []
            writeWaiters[key] = nil
            for w in waiters { reject(w, "NetworkError", "Device disconnected") }
        }
        for key in notifyWaiters.keys where key.hasPrefix(prefix) {
            let waiters = notifyWaiters[key] ?? []
            notifyWaiters[key] = nil
            for w in waiters { reject(w, "NetworkError", "Device disconnected") }
        }
        for key in charWaiters.keys where key.hasPrefix(prefix) {
            let waiters = charWaiters[key] ?? []
            charWaiters[key] = nil
            for w in waiters { w(error ?? Self.bridgeError("Device disconnected")) }
        }
        let svcWaiters = serviceWaiters[id] ?? []
        serviceWaiters[id] = nil
        for w in svcWaiters { w(error ?? Self.bridgeError("Device disconnected")) }
        servicesDiscovered.remove(id)
        let connWaiters = connectWaiters[id] ?? []
        connectWaiters[id] = nil
        for w in connWaiters { reject(w, "NetworkError", "Device disconnected") }

        emit(["type": "disconnected", "deviceId": id.uuidString])
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        if error == nil {
            servicesDiscovered.insert(id)
        }
        let waiters = serviceWaiters[id] ?? []
        serviceWaiters[id] = nil
        for w in waiters { w(error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        let key = svcKey(id, canon(service.uuid))
        let waiters = charWaiters[key] ?? []
        charWaiters[key] = nil
        for w in waiters { w(error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let service = characteristic.service else { return }
        let id = peripheral.identifier
        let svc = canon(service.uuid)
        let chr = canon(characteristic.uuid)
        let key = charKey(id, svc, chr)

        if let error = error {
            if var waiters = readWaiters[key], !waiters.isEmpty {
                let w = waiters.removeFirst()
                readWaiters[key] = waiters.isEmpty ? nil : waiters
                reject(w, "NetworkError", error.localizedDescription)
            }
            return
        }

        let b64 = (characteristic.value ?? Data()).base64EncodedString()
        let event: [String: Any] = [
            "type": "value",
            "deviceId": id.uuidString,
            "service": svc,
            "characteristic": chr,
            "value": b64,
        ]
        emit(event)

        if var waiters = readWaiters[key], !waiters.isEmpty {
            let w = waiters.removeFirst()
            readWaiters[key] = waiters.isEmpty ? nil : waiters
            resolve(w, b64)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let service = characteristic.service else { return }
        let id = peripheral.identifier
        let key = charKey(id, canon(service.uuid), canon(characteristic.uuid))
        guard var wWaiters = writeWaiters[key], !wWaiters.isEmpty else { return }
        let w = wWaiters.removeFirst()
        writeWaiters[key] = wWaiters.isEmpty ? nil : wWaiters
        if let error = error {
            reject(w, "NetworkError", error.localizedDescription)
        } else {
            resolve(w)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let service = characteristic.service else { return }
        let id = peripheral.identifier
        let key = charKey(id, canon(service.uuid), canon(characteristic.uuid))
        guard var waiters = notifyWaiters[key], !waiters.isEmpty else { return }
        let w = waiters.removeFirst()
        notifyWaiters[key] = waiters.isEmpty ? nil : waiters
        if let error = error {
            reject(w, "NetworkError", error.localizedDescription)
        } else {
            resolve(w)
        }
    }

    // MARK: - Reset

    func reset() {
        keepAwake = false
        UIApplication.shared.isIdleTimerDisabled = false
        if picker != nil {
            picker?.dismissSilently()
            if let r = pickerReply {
                reject(r, "NotFoundError", "Page reloaded")
            }
            picker = nil
            pickerReply = nil
            pickerFilters = []
            acceptAll = false
        }
        watched = []

        for w in availabilityWaiters { reject(w, "NetworkError", "Page reloaded") }
        availabilityWaiters = []

        for (id, waiters) in connectWaiters {
            for w in waiters { reject(w, "NetworkError", "Page reloaded") }
            _ = id
        }
        connectWaiters = [:]

        for (id, waiters) in serviceWaiters {
            for w in waiters { w(Self.bridgeError("Page reloaded")) }
            _ = id
        }
        serviceWaiters = [:]

        for (key, waiters) in charWaiters {
            for w in waiters { w(Self.bridgeError("Page reloaded")) }
            _ = key
        }
        charWaiters = [:]

        for (key, waiters) in readWaiters {
            for w in waiters { reject(w, "NetworkError", "Page reloaded") }
            _ = key
        }
        readWaiters = [:]

        for (key, waiters) in writeWaiters {
            for w in waiters { reject(w, "NetworkError", "Page reloaded") }
            _ = key
        }
        writeWaiters = [:]

        for (key, waiters) in notifyWaiters {
            for w in waiters { reject(w, "NetworkError", "Page reloaded") }
            _ = key
        }
        notifyWaiters = [:]

        if centralCreated {
            for (_, p) in peripherals where p.state == .connected || p.state == .connecting {
                central.cancelPeripheralConnection(p)
            }
            updateScan()
        }
    }
}
