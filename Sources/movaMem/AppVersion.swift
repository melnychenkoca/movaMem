import Foundation

/// The app's own version, as shown at the bottom of the menu.
///
/// movaMem is an LSUIElement app: no Dock icon, no About window, no Finder
/// "Get Info" habit. The menu is the only place a version can be seen at all,
/// and it is worth seeing — a stale Homebrew tap, a skipped upgrade, and a
/// healthy install all look identical from the outside, since each one is just
/// a glyph in the menu bar.
///
/// The value is read from the bundle rather than written here, so it cannot
/// drift from Info.plist. That plist is already the single source of truth the
/// release workflow checks the git tag against, which makes it the one number
/// that a build, a tag, and a Homebrew cask are all guaranteed to agree on.
struct AppVersion {
    /// Formats the menu row, e.g. "movaMem 1.0.1".
    ///
    /// The version is passed in rather than read from Bundle.main so this stays
    /// pure and testable; `current()` supplies the real value.
    static func menuTitle(appName: String, version: String?) -> String {
        // A bundle with no CFBundleShortVersionString is not a crash, it is just
        // a build we cannot name. Saying so plainly beats showing "movaMem"
        // alone, which would read as a version-less title rather than a fault.
        guard let version = version else {
            return "\(appName) (unknown version)"
        }
        // An empty or whitespace-only string is the same situation as a missing
        // key: the plist has the entry but it says nothing.
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "\(appName) (unknown version)"
        }
        return "\(appName) \(trimmed)"
    }

    /// The running app's version row, read from its own bundle.
    static func current() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return menuTitle(appName: "movaMem", version: version)
    }
}
