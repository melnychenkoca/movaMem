import Foundation

/// The app's user-facing settings.
///
/// Only settings that must survive a relaunch belong here. "Hide Icon" is
/// deliberately absent: it is session-only by design (see MenuController.hideIcon).
enum Preferences {
    /// UserDefaults.standard is read inline rather than held in a static let.
    /// A stored reference is a mutable global of a non-Sendable type, which
    /// strict concurrency checking rejects outright; UserDefaults is itself
    /// thread-safe, so reading it at each use costs nothing.
    private static let learnNewAppsAutomaticallyKey = "learnNewAppsAutomatically"

    /// When true, activating an app that has no remembered layout records
    /// whatever layout is active at that moment.
    ///
    /// Defaults to false, which is what `UserDefaults.bool(forKey:)` returns for
    /// an absent key — so an existing install that updates into this version
    /// keeps behaving exactly as it did, with no surprise entries appearing.
    static var learnNewAppsAutomatically: Bool {
        get {
            return UserDefaults.standard.bool(forKey: learnNewAppsAutomaticallyKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: learnNewAppsAutomaticallyKey)
        }
    }
}
