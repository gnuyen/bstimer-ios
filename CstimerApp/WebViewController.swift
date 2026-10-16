import AuthenticationServices
import Network
import UIKit
import WebKit

/// The build number (CURRENT_PROJECT_VERSION in project.yml), bumped with every change to the app
/// so the launch badge shows which revision is installed.
let appRevision = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0

final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    
    /// The site chosen in the Settings app when this controller was made. SceneDelegate
    /// makes a new controller when the choice changes.
    let mode = SiteMode.current
    private var startURL: URL { mode.startURL }
    /// Login pages kept inside the app so their redirect back to cstimer lands here, not in Safari.
    /// (Google is not listed: it refuses sign-in inside embedded web views, see startGoogleSignIn.)
    private let inAppLoginHosts: Set<String> = ["www.worldcubeassociation.org", "worldcubeassociation.org"]

    /// Google sign-in runs in a system auth session. The app appends `.cstimer-ios` to the page's
    /// own `state`; the site's app-auth.js forwards the token to this scheme when it sees that
    /// marker, and the app removes it again so the page can check its state.
    private let authCallbackScheme = "cstimerbt"
    private let authState = "cstimer-ios"
    private var authSession: ASWebAuthenticationSession?
    private lazy var downloads = DownloadHandler(presenter: { [weak self] in self?.topPresentedController() })
    #if DEBUG
    private var didRunAuthTest = false
    #endif
    
    private var webView: WKWebView!
    private lazy var bridge = BluetoothBridge(allowedHosts: mode.hosts)
    private lazy var cloud = CloudBridge(allowedHosts: mode.hosts)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Info.plist lists WKAppBoundDomains so the page's service worker (offline support) can
        // run. With that key present WebKit only injects scripts into app-bound pages, and it
        // only treats pages as app-bound when navigation is limited to those domains.
        config.limitsNavigationsToAppBoundDomains = true
        #if DEBUG
        // `-testOffline` (debug only): route the web view through a proxy that doesn't exist,
        // so every request fails as if the device were offline.
        if ProcessInfo.processInfo.arguments.contains("-testOffline") {
            let deadEnd = NWEndpoint.hostPort(host: "127.0.0.1", port: 9)
            config.websiteDataStore.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: deadEnd)]
        }
        #endif
        // Lets the page tell which app build is running (bsTimer's appupdate.js reads this).
        config.applicationNameForUserAgent = "Mobile/15E148 bsTimer/\(appRevision)"
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        var shim = ""
        if let url = Bundle.main.url(forResource: "bluetooth-shim", withExtension: "js") {
            shim = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if shim.isEmpty {
                assertionFailure("Failed to load bluetooth-shim.js")
            }
        } else {
            assertionFailure("bluetooth-shim.js not found in bundle")
        }
        
        #if DEBUG
        // Collect script errors from document start so diagnostics can report shim failures.
        config.userContentController.addUserScript(
            WKUserScript(
                source: "window.__diagErrors = []; window.addEventListener('error', function (e) { window.__diagErrors.push(String(e.message) + ' @' + e.filename + ':' + e.lineno); });",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
        #endif

        config.userContentController.addUserScript(
            WKUserScript(
                source: shim,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            )
        )
        
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: BluetoothBridge.handlerName)
        // iCloud sync is a bsTimer feature; csTimer.net has its own backups.
        if mode.usesICloudSync {
            config.userContentController.addScriptMessageHandler(cloud, contentWorld: .page, name: CloudBridge.handlerName)
        }
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = false
        
        #if DEBUG
        webView.isInspectable = true
        #endif
        
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Edge to edge: the scroll view still keeps the page out of the notch and home bar,
            // and WebKit fills those areas with the page's own background instead of white bands.
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        
        bridge.webView = webView
        if mode.usesICloudSync {
            cloud.webView = webView
        }
        bridge.presenter = { [weak self] in
            self?.topPresentedController()
        }
        
        webView.load(URLRequest(url: startURL))
        showVersionBadge()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    private func topPresentedController() -> UIViewController? {
        var current: UIViewController = self
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
    }
    
    // MARK: - WKNavigationDelegate
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        #if DEBUG
        if navigationAction.targetFrame?.isMainFrame != false {
            NSLog("[nav] main-frame navigation to %@", url?.absoluteString.prefix(120).description ?? "nil")
        }
        #endif
        
        if url == nil {
            decisionHandler(.allow)
            return
        }

        // cstimer's export is a blob: link with a download attribute.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        
        let scheme = url!.scheme?.lowercased()
        if scheme == "about" || scheme == "blob" || scheme == "data" {
            decisionHandler(.allow)
            return
        }
        
        if mode.hosts.contains(url!.host ?? "") || inAppLoginHosts.contains(url!.host ?? "") {
            decisionHandler(.allow)
            return
        }
        
        if let targetFrame = navigationAction.targetFrame, targetFrame.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        
        if url!.host == "accounts.google.com" {
            if mode == .cstimer {
                // csTimer.net's Google login returns to csTimer.net in the system sign-in
                // sheet, which has no way back to the app.
                showMessage("Google sign-in doesn't work in the app on csTimer.net. Use WCA sign-in, or choose bsTimer in the Settings app.")
                decisionHandler(.cancel)
                return
            }
            startGoogleSignIn(url!)
            decisionHandler(.cancel)
            return
        }

        // Main frame navigation to another host or targetFrame is nil
        UIApplication.shared.open(url!)
        decisionHandler(.cancel)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.attach(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.attach(download)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        bridge.reset()
    }
    
    #if DEBUG
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let probe = """
        JSON.stringify({
            href: location.href,
            bluetooth: typeof navigator.bluetooth,
            handler: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cstimerBLE),
            bridge: typeof window.__cstimerBLE,
            kernel: typeof window.kernel,
            errors: window.__diagErrors || null
        })
        """
        webView.evaluateJavaScript(probe) { result, error in
            NSLog("[diag] page: %@", result.map { "\($0)" } ?? String(describing: error))
        }
        // `-testAuthRedirect` (debug only): open the auth sheet straight on the page with a fake
        // token to check that app-auth.js hands the result back to the app.
        // `-testJS=<code>` (debug only): run JavaScript on the page once, e.g. to simulate
        // cstimer's login navigation or export download.
        if let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("-testJS=") }), !didRunAuthTest {
            didRunAuthTest = true
            webView.evaluateJavaScript(String(arg.dropFirst("-testJS=".count))) { _, error in
                if let error = error { NSLog("[test] JS error: %@", String(describing: error)) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-testAuthRedirect"), !didRunAuthTest {
            didRunAuthTest = true
            startGoogleSignIn(URL(string: "https://cstimer.gnuyen.org/?t=1#access_token=TEST&state=cstimer-ios")!, ephemeral: true)
        }
    }
    #endif

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        bridge.reset()
        webView.reload()
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }
    
    private func handleNavigationError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        
        guard topPresentedController() == self else { return }
        
        let alert = UIAlertController(
            title: "Couldn't load bsTimer",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        
        let retryAction = UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.webView.load(URLRequest(url: self.startURL))
        }
        alert.addAction(retryAction)
        
        let okAction = UIAlertAction(title: "OK", style: .cancel)
        alert.addAction(okAction)
        
        present(alert, animated: true)
    }
    
    private func showMessage(_ message: String) {
        guard let presenter = topPresentedController() else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter.present(alert, animated: true)
    }

    // MARK: - WKUIDelegate
    
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let presenter = topPresentedController()
        if let presenter = presenter {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            let okAction = UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler()
            }
            alert.addAction(okAction)
            presenter.present(alert, animated: true)
        } else {
            completionHandler()
        }
    }
    
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let presenter = topPresentedController()
        if let presenter = presenter {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
                completionHandler(false)
            }
            let okAction = UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(true)
            }
            alert.addAction(cancelAction)
            alert.addAction(okAction)
            presenter.present(alert, animated: true)
        } else {
            completionHandler(false)
        }
    }
    
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let presenter = topPresentedController()
        if let presenter = presenter {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { textField in
                textField.text = defaultText
            }
            let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in
                completionHandler(nil)
            }
            let okAction = UIAlertAction(title: "OK", style: .default) { _ in
                let text = alert.textFields?.first?.text
                completionHandler(text ?? "")
            }
            alert.addAction(cancelAction)
            alert.addAction(okAction)
            presenter.present(alert, animated: true)
        } else {
            completionHandler(nil)
        }
    }
    
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        return nil
    }
}

// MARK: - Version badge

extension WebViewController {
    /// "r12 · built Oct 15 01:52": the revision, plus when this binary was built.
    static var versionText: String {
        var text = "r\(appRevision)"
        if let exe = Bundle.main.executableURL,
           let built = (try? exe.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            let f = DateFormatter()
            f.dateFormat = "MMM d HH:mm"
            text += " · built " + f.string(from: built)
        }
        return text
    }

    /// Shows the version in the bottom-trailing corner for a few seconds after launch.
    fileprivate func showVersionBadge() {
        let label = PaddedLabel()
        label.text = Self.versionText
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        label.layer.cornerRadius = 6
        label.clipsToBounds = true
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        NSLog("[version] %@", label.text ?? "")
        UIView.animate(withDuration: 0.4, delay: 1.5, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

// MARK: - Google sign-in

extension WebViewController: ASWebAuthenticationPresentationContextProviding {
    private func startGoogleSignIn(_ url: URL, ephemeral: Bool = false) {
        guard authSession == nil, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var items = comps.queryItems ?? []
        let pageState = items.first(where: { $0.name == "state" })?.value ?? ""
        items.removeAll { $0.name == "state" }
        items.append(URLQueryItem(name: "state", value: pageState.isEmpty ? authState : "\(pageState).\(authState)"))
        comps.queryItems = items
        guard let authURL = comps.url else { return }

        let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callbackURL, error in
            guard let self = self else { return }
            self.authSession = nil
            #if DEBUG
            NSLog("[auth] callback: %@", callbackURL?.absoluteString ?? "nil, error: \(String(describing: error))")
            #endif
            // Cancelled or failed: stay on the current page.
            guard let callbackURL = callbackURL,
                  let fragment = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.fragment,
                  var target = URLComponents(url: self.startURL, resolvingAgainstBaseURL: false) else { return }
            // cstimer finishes the Google login when the page *loads* with #access_token=...
            // Loading the same page with only a new fragment is an in-page jump, not a load,
            // so set the URL and then force a reload.
            // Drop our state marker, or app-auth.js would forward this load to the callback again;
            // the page's own state stays for it to check.
            target.fragment = fragment.split(separator: "&")
                .filter { $0 != "state=\(self.authState)" }
                .map { $0.hasPrefix("state=") && $0.hasSuffix(".\(self.authState)") ? $0.dropLast(self.authState.count + 1) : $0 }
                .joined(separator: "&")
            guard let targetURL = target.url,
                  let data = try? JSONSerialization.data(withJSONObject: [targetURL.absoluteString]),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.webView.evaluateJavaScript("location.replace(\(json)[0]); location.reload();", completionHandler: nil)
        }
        let session: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            session = ASWebAuthenticationSession(url: authURL, callback: .customScheme(authCallbackScheme), completionHandler: completion)
        } else {
            session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: authCallbackScheme, completionHandler: completion)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = ephemeral
        authSession = session
        if !session.start() {
            authSession = nil
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }
}
