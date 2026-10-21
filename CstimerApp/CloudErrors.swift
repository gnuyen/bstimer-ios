import CloudKit

/// Words CloudKit errors for the page (the sync dot and the Export dialog show them). Apple's own
/// text is often just "CKErrorDomain error 15", so the common ones get a plain message, and the
/// code is always added so a report can be looked up.
enum CloudErrors {
    static func describe(_ error: Error) -> String {
        guard let ckError = error as? CKError else {
            return error.localizedDescription
        }
        let base: String
        switch ckError.code {
        case .partialFailure:
            // the error for the one record we save is inside
            if let inner = ckError.partialErrorsByItemID?.values.first {
                return describe(inner)
            }
            base = "error"
        case .notAuthenticated:
            base = "not signed in to iCloud. Sign in from the Settings app"
        case .networkUnavailable, .networkFailure:
            base = "no connection. It will try again"
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            base = "iCloud is busy. It will try again"
        case .quotaExceeded:
            base = "your iCloud storage is full"
        case .permissionFailure, .managedAccountRestricted:
            base = "iCloud is restricted on this device"
        case .accountTemporarilyUnavailable:
            base = "your iCloud account is temporarily unavailable. Check the Settings app"
        case .badContainer, .missingEntitlement, .serverRejectedRequest, .invalidArguments:
            base = "iCloud refused the request"
        default:
            base = "error"
        }
        return "\(base) (CKError \(ckError.code.rawValue))"
    }
}
