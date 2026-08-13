import Foundation

/// The app's own version, as shown on the Quit row at the bottom of the menu.
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
    /// Formats the name-and-version part, e.g. "movaMem 1.0.1".
    ///
    /// The version is passed in rather than read from Bundle.main so this stays
    /// pure and testable; `currentQuitTitleParts()` supplies the real value.
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

    /// Formats the Quit row with the version folded into it, e.g. "Quit movaMem 1.0.1".
    ///
    /// The version used to have a row of its own directly above Quit. Both rows
    /// say the app's name, and the menu is long enough that a line spent on a
    /// name we already print is a line worth reclaiming. "Quit <app>" is the
    /// standard macOS title anyway, so the version rides along on a row the menu
    /// needs regardless. The ⌘Q key equivalent draws at the right edge, so this
    /// has to read left to right rather than sit right-aligned like a badge.
    static func quitTitle(appName: String, version: String?) -> String {
        let parts = quitTitleParts(appName: appName, version: version)
        return parts.command + parts.version
    }

    /// The Quit row split where its grey run starts, so the caller can dim the
    /// name and version while leaving the command itself at full contrast.
    ///
    /// The split is produced here rather than recovered by the caller: searching
    /// the finished title for where "Quit " ends would re-derive something this
    /// type already knows, and would go wrong on any name that itself contained
    /// the word. `command` keeps its trailing separator so the two parts
    /// concatenate back into exactly `quitTitle`, which is what lets that stay
    /// the one definition of the row's text.
    ///
    /// The separator is a plain space here. The menu replaces it with a tab to
    /// push the version clear of the command, but a tab is a drawing detail of
    /// that one row: it needs a paragraph style to mean anything, and would read
    /// as a stray control character to anything else that used this text.
    static func quitTitleParts(appName: String, version: String?) -> (command: String, version: String) {
        ("Quit ", menuTitle(appName: appName, version: version))
    }

    /// The running app's Quit row, split for styling, read from its own bundle.
    static func currentQuitTitleParts() -> (command: String, version: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return quitTitleParts(appName: "movaMem", version: version)
    }
}
