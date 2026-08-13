import AppKit
import Foundation

/// Answers "is this app still on this Mac?", caching each answer for the life of
/// the process.
///
/// Launch Services is the only way to resolve a bundle ID to an installed app,
/// and `urlForApplication` is a real lookup rather than a free property read.
/// Both callers ask repeatedly — the launch prune walks the whole forgotten
/// list, and the menu re-filters its rows every time it opens — so the answers
/// are cached.
///
/// Caching for the whole process is the same trade SystemAppCache makes, but the
/// reasoning is not identical, so it is worth stating: an app CAN be uninstalled
/// while movaMem is running, and this cache will keep saying it is installed
/// until the next launch. That is accepted deliberately. The alternative — a
/// Launch Services call per row per menu open — costs more than it gains, and
/// the stale answer is self-correcting on the next launch, which is exactly when
/// the prune runs anyway.
///
/// A nil URL means Launch Services has no record of the app, which is what
/// "not installed" means here.
final class InstalledAppDetector: @unchecked Sendable {
    private var known: [String: Bool] = [:]
    private let lock = NSLock()

    func isInstalled(bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let cached = known[bundleID] {
            return cached
        }
        let result = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        known[bundleID] = result
        return result
    }
}
