import AuthenticationServices
import CloudKit
import UIKit
import WebKit

final class CloudBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "bsCloud"
    static let containerIdentifier = "iCloud.org.gnuyen.bstimer"

    weak var webView: WKWebView?

    private let allowedHosts: Set<String>
    private lazy var container = CKContainer(identifier: CloudBridge.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let kvs = NSUbiquitousKeyValueStore.default
    private let recordID = CKRecord.ID(recordName: "snapshot")
    private let recordType = "Snapshot"
    private let codeKey = "serverCode"
    private var lastRecord: CKRecord?
    private var appleReply: ((Any?, String?) -> Void)?
    private var appleController: ASAuthorizationController?

    // MARK: - Init

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(codeChangedExternally(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs
        )
        kvs.synchronize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Helpers

    private func reject(_ r: @escaping (Any?, String?) -> Void, _ msg: String) {
        r(nil, msg)
    }

    private func resolve(_ r: @escaping (Any?, String?) -> Void, _ v: Any? = nil) {
        r(v, nil)
    }

    // MARK: - WKScriptMessageHandlerWithReply

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        if !message.frameInfo.isMainFrame || origin.protocol != "https" || !allowedHosts.contains(origin.host) {
            reject(replyHandler, "not allowed")
            return
        }
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            reject(replyHandler, "bad message")
            return
        }

        switch op {
        case "status":
            handleStatus(replyHandler)
        case "get":
            handleGet(replyHandler)
        case "put":
            handlePut(body, replyHandler)
        case "setCode":
            handleSetCode(body, replyHandler)
        case "appleSignIn":
            handleAppleSignIn(replyHandler)
        case "deleteAll":
            handleDeleteAll(replyHandler)
        default:
            reject(replyHandler, "unknown op")
        }
    }

    // MARK: - Ops

    private func handleStatus(_ r: @escaping (Any?, String?) -> Void) {
        Task { @MainActor in
            let status = try? await container.accountStatus()
            let available = (status == .available)
            let code: Any = kvs.string(forKey: codeKey) ?? NSNull()
            let reply: [String: Any] = ["available": available, "code": code]
            #if DEBUG
            NSLog("[cloud] op status -> available=%d", available ? 1 : 0)
            #endif
            resolve(r, reply)
        }
    }

    private func handleGet(_ r: @escaping (Any?, String?) -> Void) {
        Task { @MainActor in
            do {
                let record = try await database.record(for: recordID)
                lastRecord = record
                guard let asset = record["data"] as? CKAsset, let url = asset.fileURL else {
                    reject(r, "iCloud: no data")
                    return
                }
                let data = try Data(contentsOf: url)
                let text: String
                if record["encoding"] as? String == "zlib" {
                    let decompressed = try (data as NSData).decompressed(using: .zlib) as Data
                    guard let s = String(data: decompressed, encoding: .utf8) else {
                        reject(r, "iCloud: unreadable data")
                        return
                    }
                    text = s
                } else {
                    guard let s = String(data: data, encoding: .utf8) else {
                        reject(r, "iCloud: unreadable data")
                        return
                    }
                    text = s
                }
                let tag = record.recordChangeTag ?? ""
                let reply: [String: Any] = ["data": text, "tag": tag]
                #if DEBUG
                NSLog("[cloud] op get -> size=%d tag=%@", text.utf8.count, tag)
                #endif
                resolve(r, reply)
            } catch let ckError as CKError where ckError.code == .unknownItem {
                resolve(r, NSNull())
            } catch {
                reject(r, "iCloud: " + error.localizedDescription)
            }
        }
    }

    private func handlePut(_ body: [String: Any], _ r: @escaping (Any?, String?) -> Void) {
        guard let text = body["data"] as? String else {
            reject(r, "bad message")
            return
        }
        let tag = body["tag"] as? String

        Task { @MainActor in
            do {
                let record: CKRecord
                if tag == nil {
                    record = CKRecord(recordType: recordType, recordID: recordID)
                } else if let last = lastRecord, last.recordChangeTag == tag {
                    record = last
                } else {
                    let fetched: CKRecord
                    do {
                        fetched = try await database.record(for: recordID)
                    } catch let ckError as CKError where ckError.code == .unknownItem {
                        #if DEBUG
                        NSLog("[cloud] op put -> conflict (no record)")
                        #endif
                        resolve(r, ["conflict": true])
                        return
                    }
                    if fetched.recordChangeTag != tag {
                        lastRecord = fetched
                        #if DEBUG
                        NSLog("[cloud] op put -> conflict (tag mismatch)")
                        #endif
                        resolve(r, ["conflict": true])
                        return
                    }
                    record = fetched
                }

                let packed = try (Data(text.utf8) as NSData).compressed(using: .zlib) as Data
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
                defer {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                try packed.write(to: tempURL)
                record["data"] = CKAsset(fileURL: tempURL)
                record["encoding"] = "zlib"
                record["size"] = text.utf8.count as NSNumber
                record["updated"] = Date()

                let (saveResults, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let result = saveResults[recordID] else {
                    reject(r, "iCloud: not saved")
                    return
                }
                switch result {
                case .success(let saved):
                    lastRecord = saved
                    let newTag = saved.recordChangeTag ?? ""
                    #if DEBUG
                    NSLog("[cloud] op put -> ok size=%d tag=%@", text.utf8.count, newTag)
                    #endif
                    resolve(r, ["ok": true, "tag": newTag])
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
                        if let serverRecord = ckError.serverRecord {
                            lastRecord = serverRecord
                        }
                        #if DEBUG
                        NSLog("[cloud] op put -> conflict (server changed)")
                        #endif
                        resolve(r, ["conflict": true])
                    } else {
                        reject(r, "iCloud: " + error.localizedDescription)
                    }
                }
            } catch let ckError as CKError where ckError.code == .serverRecordChanged {
                if let serverRecord = ckError.serverRecord {
                    lastRecord = serverRecord
                }
                #if DEBUG
                NSLog("[cloud] op put -> conflict (server changed)")
                #endif
                resolve(r, ["conflict": true])
            } catch {
                reject(r, "iCloud: " + error.localizedDescription)
            }
        }
    }

    /// Deletes the synced data from iCloud and the server code (the user deleted their data).
    private func handleDeleteAll(_ r: @escaping (Any?, String?) -> Void) {
        Task { @MainActor in
            do {
                _ = try await database.deleteRecord(withID: recordID)
            } catch let ckError as CKError where ckError.code == .unknownItem {
                // nothing stored
            } catch {
                reject(r, "iCloud: " + error.localizedDescription)
                return
            }
            lastRecord = nil
            kvs.removeObject(forKey: codeKey)
            kvs.synchronize()
            #if DEBUG
            NSLog("[cloud] op deleteAll -> ok")
            #endif
            resolve(r, true)
        }
    }

    private func handleSetCode(_ body: [String: Any], _ r: @escaping (Any?, String?) -> Void) {
        let code = body["code"] as? String
        if let code = code, !code.isEmpty {
            kvs.set(code, forKey: codeKey)
        } else {
            kvs.removeObject(forKey: codeKey)
        }
        kvs.synchronize()
        #if DEBUG
        NSLog("[cloud] op setCode -> %d", (code?.isEmpty == false) ? 1 : 0)
        #endif
        resolve(r, true)
    }

    private func handleAppleSignIn(_ r: @escaping (Any?, String?) -> Void) {
        if appleReply != nil {
            reject(r, "busy")
            return
        }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        appleReply = r
        appleController = controller
        controller.performRequests()
    }

    // MARK: - KVS Changes

    @objc private func codeChangedExternally(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            if let keys = keys, !keys.contains(self.codeKey) {
                return
            }
            let code: Any = self.kvs.string(forKey: self.codeKey) ?? NSNull()
            let json: String
            if let data = try? JSONSerialization.data(withJSONObject: [code]),
               let s = String(data: data, encoding: .utf8) {
                json = s
            } else {
                json = "[null]"
            }
            self.webView?.evaluateJavaScript("window.bsSync && window.bsSync.cloudCodeChanged(\(json)[0])", completionHandler: nil)
        }
    }
}

// MARK: - Sign in with Apple

extension CloudBridge: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let r = appleReply
        appleReply = nil
        appleController = nil
        guard let r = r else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            #if DEBUG
            NSLog("[cloud] op appleSignIn -> error (no token)")
            #endif
            reject(r, "Sign in with Apple: no token")
            return
        }
        #if DEBUG
        NSLog("[cloud] op appleSignIn -> ok")
        #endif
        // The authorization code lets the server revoke this sign-in when the user deletes their data.
        var reply: [String: Any] = ["token": token]
        if let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8) {
            reply["code"] = code
        }
        resolve(r, reply)
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let r = appleReply
        appleReply = nil
        appleController = nil
        guard let r = r else { return }
        if (error as? ASAuthorizationError)?.code == .canceled {
            #if DEBUG
            NSLog("[cloud] op appleSignIn -> cancelled")
            #endif
            reject(r, "cancelled")
        } else {
            #if DEBUG
            NSLog("[cloud] op appleSignIn -> error")
            #endif
            reject(r, "Sign in with Apple: " + error.localizedDescription)
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        webView?.window ?? ASPresentationAnchor()
    }
}
