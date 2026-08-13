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
    private static let trackSystemAppsKey = "trackSystemApps"

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

    /// When true, apps belonging to macOS itself — Finder, System Settings, the
    /// login window — may be learned automatically like any other app.
    ///
    /// Defaults to false for the same reason as the preference above: an absent
    /// key reads as false, so an install that updates into this version gains no
    /// system-app entries it did not already have.
    ///
    /// This gates *learning only*. An app the user added by hand through
    /// Add App… keeps working with this off, because naming one specific app is
    /// a deliberate choice and this setting is a blanket default — the same
    /// precedence Forget This App already follows in SwitchCoordinator. It also
    /// never removes what is already stored: turning this off changes what may
    /// be added, not what the user has.
    static var trackSystemApps: Bool {
        get {
            return UserDefaults.standard.bool(forKey: trackSystemAppsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: trackSystemAppsKey)
        }
    }
}
