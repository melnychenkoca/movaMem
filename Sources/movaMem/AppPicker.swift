import Foundation
import os

/// What happened when the user picked an app in the Add App... panel.
///
/// Three outcomes, each needing a different response from the menu, which is why
/// this decision lives in a plain function that can be tested rather than inside
/// the AppKit panel code.
enum AppPickResult {
    /// Usable and not already in the store.
    case valid(bundleID: String)
    /// Already in the store. Nothing to do, but the user must be told, or the
    /// menu item will look broken.
    case alreadyManaged(appName: String)
    /// The bundle has no CFBundleIdentifier, so movaMem cannot identify it.
    case noBundleIdentifier(appName: String)
}

/// Decides whether a chosen application can be managed.
///
/// This type holds no state and touches no UI. The NSOpenPanel that produces the
/// URL lives in MenuController; everything worth testing is here.
struct AppPicker {
    private static let log = Logger(subsystem: "com.movamem.app", category: "AppPicker")

    /// Classifies a chosen app bundle.
    ///
    /// managedBundleIDs is passed in rather than read from LayoutStore, so this
    /// function stays pure and this file has no dependency on the store.
    static func evaluate(appBundleURL: URL, managedBundleIDs: Set<String>) -> AppPickResult {
        let appName = displayName(forBundleAt: appBundleURL)

        // Bundle(url:) returns nil for anything that is not a real bundle, and
        // bundleIdentifier is nil when Info.plist has no CFBundleIdentifier.
        // Neither case crashes; both mean the same thing to us.
        guard let bundle = Bundle(url: appBundleURL) else {
            log.error("Not a readable bundle: \(appName, privacy: .public)")
            return .noBundleIdentifier(appName: appName)
        }
        guard let bundleID = bundle.bundleIdentifier else {
            log.error("Bundle has no identifier: \(appName, privacy: .public)")
            return .noBundleIdentifier(appName: appName)
        }

        if managedBundleIDs.contains(bundleID) {
            return .alreadyManaged(appName: appName)
        }
        return .valid(bundleID: bundleID)
    }

    /// Human-readable name for an app bundle on disk.
    ///
    /// Prefers the names inside Info.plist and uses the filename only as a last
    /// resort. That matters because the filename can be something unhelpful — a
    /// downloaded app may sit at a path with a generated name, and putting that
    /// in an alert would be confusing.
    static func displayName(forBundleAt url: URL) -> String {
        let filenameFallback = url.deletingPathExtension().lastPathComponent

        guard let bundle = Bundle(url: url) else {
            return filenameFallback
        }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        if let name = displayName {
            return name
        }
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        if let name = bundleName {
            return name
        }
        return filenameFallback
    }
}
