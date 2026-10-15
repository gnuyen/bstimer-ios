import UIKit
import WebKit

/// Saves web downloads (cstimer's "export to file") to a temporary file and offers them
/// through the share sheet, which includes "Save to Files".
final class DownloadHandler: NSObject, WKDownloadDelegate {
    private let presenter: () -> UIViewController?
    private var destinations: [ObjectIdentifier: URL] = [:]

    init(presenter: @escaping () -> UIViewController?) {
        self.presenter = presenter
    }

    func attach(_ download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            completionHandler(nil)
            return
        }
        let name = (suggestedFilename as NSString).lastPathComponent
        let url = dir.appendingPathComponent(name.isEmpty ? "bstimer-export.txt" : name)
        destinations[ObjectIdentifier(download)] = url
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = destinations.removeValue(forKey: ObjectIdentifier(download)),
              let presenter = presenter() else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        guard let presenter = presenter() else { return }
        let alert = UIAlertController(title: "Export failed", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }
}
