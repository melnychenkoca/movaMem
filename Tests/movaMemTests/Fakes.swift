import Foundation
@testable import movaMem

/// Test double for the keyboard-layout system.
final class FakeInputSource: InputSourceProviding {
    var currentLayoutID: String?
    var onLayoutChanged: (() -> Void)?

    /// Layout IDs that select() will accept. Anything else fails, which is how
    /// an uninstalled layout is simulated.
    var installedLayoutIDs: [String] = []

    /// Every layout ID passed to select(), in order. Tests assert on this to
    /// prove a switch did or did not happen.
    var selectCalls: [String] = []

    init(current: String? = nil, installed: [String] = []) {
        self.currentLayoutID = current
        self.installedLayoutIDs = installed
    }

    func availableLayouts() -> [KeyboardLayout] {
        var result: [KeyboardLayout] = []
        for id in installedLayoutIDs {
            result.append(KeyboardLayout(id: id, name: id))
        }
        return result
    }

    func select(layoutID: String) -> Bool {
        selectCalls.append(layoutID)
        if installedLayoutIDs.contains(layoutID) == false {
            return false   // simulates a layout the user has uninstalled
        }
        currentLayoutID = layoutID
        return true
    }

    // MARK: - Simulation helpers

    /// Simulates the OS notification firing. Does NOT change currentLayoutID —
    /// callers set that first, mirroring the real API where the current layout is
    /// already updated by the time the notification arrives.
    func fireLayoutChangedNotification() {
        onLayoutChanged?()
    }

    /// Simulates the user switching layout by hand: sets the new value and fires.
    func simulateUserSwitch(to layoutID: String) {
        currentLayoutID = layoutID
        onLayoutChanged?()
    }
}

/// Test double for the window system.
final class FakeAppMonitor: AppMonitoring {
    var frontmostBundleID: String?
    var onAppActivated: ((String) -> Void)?

    init(frontmost: String? = nil) {
        self.frontmostBundleID = frontmost
    }

    /// Simulates an app activation that already passed the dwell filter.
    func simulateActivation(of bundleID: String) {
        frontmostBundleID = bundleID
        onAppActivated?(bundleID)
    }
}
