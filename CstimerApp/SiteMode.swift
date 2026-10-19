import Foundation

/// Which csTimer the app shows, chosen in the iOS Settings app (Settings.bundle, key "site")
/// when the app is built with the csTimer.net option.
/// The two sites are different origins, so each keeps its own solves on the device.
enum SiteMode: String {
    /// bstimer.manoagames.com: csTimer with bsTimer's additions, including iCloud sync.
    case bstimer
    /// cstimer.net: the original csTimer, with its own sign-in and backups. Bluetooth and the
    /// screen lock still work; bsTimer sync is not offered there.
    case cstimer

    static let defaultsKey = "site"

    /// Without the CSTIMER_NET_OPTION build switch (see project.yml) the app always shows bsTimer,
    /// whatever an earlier build saved in Settings.
    static var current: SiteMode {
        #if CSTIMER_NET_OPTION
        return SiteMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .bstimer
        #else
        return .bstimer
        #endif
    }

    var startURL: URL {
        switch self {
        case .bstimer: return URL(string: "https://bstimer.manoagames.com/")!
        case .cstimer: return URL(string: "https://cstimer.net/")!
        }
    }

    /// Hosts the page may run on; the native bridges only answer pages from these.
    var hosts: Set<String> {
        switch self {
        case .bstimer: return ["bstimer.manoagames.com"]
        case .cstimer: return ["cstimer.net", "www.cstimer.net"]
        }
    }

    /// Only bsTimer has the sync code that talks to the iCloud bridge.
    var usesICloudSync: Bool { self == .bstimer }
}
