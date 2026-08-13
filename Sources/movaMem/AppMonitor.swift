import AppKit
import Foundation
import os

/// Watches which application is frontmost, filtering out focus that does not
/// represent a real user switch.
///
/// In practice every call into this class happens on the main thread — it is
/// driven by NSWorkspace notifications and by DispatchQueue.main — but the
/// type cannot be marked @MainActor without making its methods asynchronous
/// from the caller's point of view, which would break both the synchronous
/// AppMonitoring protocol and the synchronous test calls into
/// handleActivation. @unchecked Sendable documents that the real safety
/// guarantee (single-threaded, main-queue-only use) is enforced by
/// convention rather than by the type system.
final class AppMonitor: AppMonitoring, @unchecked Sendable {
    private let log = Logger(subsystem: "com.movamem.app", category: "AppMonitor")
    var onAppActivated: ((String) -> Void)?

    /// How long an app must stay frontmost to count as a real switch.
    ///
    /// 300ms is long enough to filter Spotlight, notification banners, and
    /// permission dialogs, and short enough to be imperceptible: it delays only
    /// the layout switch, and no meaningful typing happens in the first 300ms
    /// after activating an app.
    private let dwellSeconds: Double

    /// Injected so tests can control time instead of sleeping.
    private let scheduler: (Double, @escaping @Sendable () -> Void) -> Void

    /// Apps that take focus without representing a user switch.
    static let ignoredBundleIDs: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
        "com.movamem.app",
        // The lock screen and the logout transition, not an app the user
        // switched to. Ignored regardless of the system-app preference: with
        // that preference on, this would otherwise record layouts against the
        // moment the screen locked, which is never something the user meant.
        "com.apple.loginwindow",
    ]

    /// The app we are currently waiting on. If another activation arrives first,
    /// this changes and the earlier pending check does nothing.
    ///
    /// Dedup here is by bundle-ID identity, not by activation instance: if the
    /// user returns to the same app within one dwell window (A -> B -> A, all
    /// inside 300ms), both of the A activations see pendingBundleID settled
    /// back on A and both report it, so onAppActivated can fire twice in a row
    /// for the same bundle ID. This is accepted rather than fixed — see
    /// returningToSameAppWithinDwellWindowReportsItTwice in AppMonitorTests —
    /// because SwitchCoordinator already no-ops when the wanted layout matches
    /// the current one, making the duplicate harmless downstream.
    private var pendingBundleID: String?

    static let defaultScheduler: @Sendable (Double, @escaping @Sendable () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    init(
        dwellSeconds: Double = 0.3,
        scheduler: @escaping (Double, @escaping @Sendable () -> Void) -> Void = AppMonitor.defaultScheduler
    ) {
        self.dwellSeconds = dwellSeconds
        self.scheduler = scheduler
    }

    /// Begins watching. Nothing is reported until this is called.
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        log.debug("Watching for app activations")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var frontmostBundleID: String? {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// @objc is required: the notification system is Objective-C and needs a
    /// runtime-visible selector.
    @objc private func appDidActivate(_ notification: Notification) {
        let userInfo = notification.userInfo
        guard let app = userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard let bundleID = app.bundleIdentifier else {
            // Some processes have no bundle ID. Nothing to remember them by.
            return
        }
        handleActivation(bundleID: bundleID)
    }

    /// Applies the ignore list and the dwell filter. Called by the notification
    /// above, and directly by tests.
    func handleActivation(bundleID: String) {
        if AppMonitor.ignoredBundleIDs.contains(bundleID) {
            log.debug("Ignoring \(bundleID, privacy: .public)")
            return
        }

        pendingBundleID = bundleID

        scheduler(dwellSeconds) { [weak self] in
            guard let self = self else { return }
            // If another app activated in the meantime, this check is stale and
            // must do nothing. This is what prevents flicker during fast switching.
            if self.pendingBundleID != bundleID {
                return
            }
            self.log.debug("Activated: \(bundleID, privacy: .public)")
            self.onAppActivated?(bundleID)
        }
    }
}
