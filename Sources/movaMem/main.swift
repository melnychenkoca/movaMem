import AppKit
import Foundation

/// Wires the pieces together and starts the app. Deliberately contains no logic:
/// everything testable lives in the components this file constructs.
///
/// This file has no unit tests. A wiring mistake here is caught by the manual
/// smoke test in Task 9, because a composition-only file cannot be meaningfully
/// unit tested.

private func storeFileURL() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    let supportDirectory = base.first ?? URL(fileURLWithPath: NSHomeDirectory())
    return supportDirectory
        .appendingPathComponent("movaMem")
        .appendingPathComponent("layouts.json")
}

/// Resolves a bundle ID to a URL and asks SystemAppDetector about it, caching
/// the answer.
///
/// The cache exists because this runs on every app activation, and
/// urlForApplication is a Launch Services call rather than a free property
/// read. The answer is also stable in practice — an app does not move between
/// /Applications and /System while the user is switching to it — so a cache
/// that lives as long as the process is safe here.
///
/// A nil URL means Launch Services could not find the app at all. That is
/// treated as "not a system app", which fails toward the existing behavior:
/// the learning preference alone decides, exactly as it did before this
/// setting existed.
private let systemAppCache = SystemAppCache()

final class SystemAppCache: @unchecked Sendable {
    private var known: [String: Bool] = [:]
    private let lock = NSLock()

    func isSystemApp(bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let cached = known[bundleID] {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            known[bundleID] = false
            return false
        }
        let result = SystemAppDetector.isSystemApp(bundleURL: url)
        known[bundleID] = result
        return result
    }
}

let store = LayoutStore(fileURL: storeFileURL())
let inputSource = InputSourceService()
let appMonitor = AppMonitor()

let coordinator = SwitchCoordinator(
    inputSource: inputSource,
    appMonitor: appMonitor,
    store: store,
    // Read on every activation rather than captured once, so toggling the menu
    // item takes effect on the next app switch.
    shouldLearnOnActivation: { Preferences.learnNewAppsAutomatically },
    shouldLearnSystemApps: { Preferences.trackSystemApps },
    isSystemApp: { systemAppCache.isSystemApp(bundleID: $0) }
)
coordinator.start()
appMonitor.start()

let application = NSApplication.shared
// .accessory means no Dock icon and no windows — a menu-bar-only app. This
// pairs with LSUIElement in Info.plist (Task 8).
application.setActivationPolicy(.accessory)

let menuController = MenuController(
    store: store,
    inputSource: inputSource,
    coordinator: coordinator,
    appMonitor: appMonitor
)
menuController.install()

application.run()
