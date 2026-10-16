import Foundation

/// Which csTimer the app shows, chosen in the iOS Settings app (Settings.bundle, key "site").
/// csTimer.net is the default, since that is where most people's solves already are.
/// The two sites are different origins, so each keeps its own solves on the device.
enum SiteMode: String {
    /// cstimer.gnuyen.org: csTimer with bsTimer's additions, including iCloud sync.
    case bstimer
    /// cstimer.net: the original csTimer, with its own sign-in and backups. Bluetooth and the
    /// screen lock still work; bsTimer sync is not offered there.
    case cstimer

    static let defaultsKey = "site"

    static var current: SiteMode {
        SiteMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .cstimer
    }

    var startURL: URL {
        switch self {
        case .bstimer: return URL(string: "https://cstimer.gnuyen.org/")!
        case .cstimer: return URL(string: "https://cstimer.net/")!
        }
    }

    /// Hosts the page may run on; the native bridges only answer pages from these.
    var hosts: Set<String> {
        switch self {
        case .bstimer: return ["cstimer.gnuyen.org"]
        case .cstimer: return ["cstimer.net", "www.cstimer.net"]
        }
    }

    /// Only bsTimer has the sync code that talks to the iCloud bridge.
    var usesICloudSync: Bool { self == .bstimer }
}
