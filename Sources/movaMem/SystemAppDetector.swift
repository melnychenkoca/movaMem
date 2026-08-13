import Foundation

/// Decides whether an app bundle belongs to macOS itself.
///
/// This type holds no state and performs no lookups. It takes a URL that the
/// caller has already resolved, for the same reason AppPicker does: resolving a
/// bundle ID to a URL is an OS call, and keeping it out of here is what lets
/// every rule below be tested against plain paths with no filesystem access.
struct SystemAppDetector {
    /// Directories macOS owns.
    ///
    /// These are prefixes, not exact paths, because the apps sit at varying
    /// depths beneath them — Finder is in /System/Library/CoreServices, System
    /// Settings is directly in /System/Applications.
    ///
    /// /Library/CoreServices is included without a /System prefix because it is
    /// a separate top-level location that still holds OS components, and
    /// /usr/libexec because a few faceless system agents live there and can take
    /// focus.
    private static let systemPrefixes = [
        "/System/",
        "/Library/CoreServices/",
        "/usr/libexec/",
    ]

    /// True when the bundle lives in a system-owned location.
    ///
    /// This deliberately tests where the app *lives*, not who wrote it. A
    /// "com.apple." bundle-ID check would be simpler and wrong in both
    /// directions: it would catch Safari, Mail, Notes, and Xcode — apps people
    /// genuinely type in and want layouts for — while gaining nothing, since
    /// every real OS component is already under one of the prefixes above.
    /// Safari in particular ships with macOS but installs to /Applications, so
    /// it is correctly *not* a system app by this rule.
    ///
    /// standardizedFileURL resolves the ".." and symlink-ish path noise that
    /// would otherwise let a path slip past a plain prefix comparison.
    static func isSystemApp(bundleURL: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        return systemPrefixes.contains { prefix in
            path.hasPrefix(prefix)
        }
    }
}
