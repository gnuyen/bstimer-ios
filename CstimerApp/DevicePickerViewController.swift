import UIKit

final class DevicePickerViewController: UINavigationController, UIAdaptivePresentationControllerDelegate {
    
    private let list: DeviceListViewController
    private var finished = false
    private let onSelect: (UUID) -> Void
    private let onCancel: () -> Void
    
    init(onSelect: @escaping (UUID) -> Void, onCancel: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.list = DeviceListViewController()
        
        super.init(nibName: nil, bundle: nil)
        
        viewControllers = [list]
        
        modalPresentationStyle = .pageSheet
        sheetPresentationController?.detents = [.medium(), .large()]
        sheetPresentationController?.prefersGrabberVisible = true
        presentationController?.delegate = self
        
        list.onSelect = { [weak self] id in
            self?.handleSelect(id)
        }
        list.onCancel = { [weak self] in
            self?.handleCancel()
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func upsert(id: UUID, name: String, rssi: Int) {
        list.upsert(id: id, name: name, rssi: rssi)
    }
    
    func dismissSilently() {
        finished = true
        if presentingViewController != nil && !isBeingDismissed {
            dismiss(animated: true)
        }
    }
    
    private func handleSelect(_ id: UUID) {
        guard !finished else { return }
        finished = true
        onSelect(id)
        if presentingViewController != nil && !isBeingDismissed {
            dismiss(animated: true)
        }
    }
    
    private func handleCancel() {
        guard !finished else { return }
        finished = true
        onCancel()
        if presentingViewController != nil && !isBeingDismissed {
            dismiss(animated: true)
        }
    }
    
    // MARK: - UIAdaptivePresentationControllerDelegate
    
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !finished else { return }
        finished = true
        onCancel()
    }
}

private final class DeviceListViewController: UITableViewController {

    var onSelect: ((UUID) -> Void)?
    var onCancel: (() -> Void)?

    private struct Device {
        let id: UUID
        var name: String
        var rssi: Int
        /// RSSI currently on screen; the row is only reloaded when it drifts noticeably.
        var shownRssi: Int
    }

    private var devices: [Device] = []
    private var deviceIndex: [UUID: Int] = [:]

    init() {
        super.init(style: .insetGrouped)
        title = "Connect a Device"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "device")
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    func upsert(id: UUID, name: String, rssi: Int) {
        if let index = deviceIndex[id] {
            let nameChanged = devices[index].name != name
            devices[index].name = name
            devices[index].rssi = rssi
            if (nameChanged || abs(devices[index].shownRssi - rssi) >= 5) && isViewLoaded {
                devices[index].shownRssi = rssi
                tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
            }
            return
        }
        devices.append(Device(id: id, name: name, rssi: rssi, shownRssi: rssi))
        deviceIndex[id] = devices.count - 1
        guard isViewLoaded else { return }
        if devices.count == 1 {
            // also refreshes the footer text
            tableView.reloadData()
        } else {
            tableView.insertRows(at: [IndexPath(row: devices.count - 1, section: 0)], with: .automatic)
        }
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        devices.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "device", for: indexPath)
        let device = devices[indexPath.row]
        var config = UIListContentConfiguration.subtitleCell()
        config.text = device.name
        config.secondaryText = "Signal \(device.shownRssi) dBm"
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        devices.isEmpty
            ? "Searching for Bluetooth devices… Make sure your cube or timer is awake."
            : "Tap a device to connect."
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(devices[indexPath.row].id)
    }
}
