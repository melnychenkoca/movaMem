import Foundation
import Testing
@testable import movaMem

private func isSystem(_ path: String) -> Bool {
    return SystemAppDetector.isSystemApp(bundleURL: URL(fileURLWithPath: path))
}

// MARK: - System locations

@Test func appsUnderSystemAreSystemApps() {
    // The three the feature was actually asked about.
    #expect(isSystem("/System/Library/CoreServices/loginwindow.app"))
    #expect(isSystem("/System/Library/CoreServices/Finder.app"))
    #expect(isSystem("/System/Applications/System Settings.app"))
}

@Test func appsUnderTopLevelCoreServicesAreSystemApps() {
    // Not under /System, but still an OS location.
    #expect(isSystem("/Library/CoreServices/Language Chooser.app"))
}

@Test func facelessAgentsUnderLibexecAreSystemApps() {
    #expect(isSystem("/usr/libexec/UserEventAgent"))
}

// MARK: - Normal apps

@Test func appsInApplicationsAreNotSystemApps() {
    #expect(isSystem("/Applications/Slack.app") == false)
    #expect(isSystem("/Applications/Visual Studio Code.app") == false)
}

@Test func appleAppsOutsideSystemAreNotSystemApps() {
    // The case that makes a "com.apple." bundle-ID check wrong: Safari ships
    // with macOS but installs to /Applications, and people type in it.
    #expect(isSystem("/Applications/Safari.app") == false)
    #expect(isSystem("/Applications/Xcode.app") == false)
}

@Test func userInstalledAppsAreNotSystemApps() {
    #expect(isSystem("/Users/someone/Applications/Tool.app") == false)
}

// MARK: - Path edge cases

@Test func pathTraversalOutOfSystemIsNotASystemApp() {
    // standardizedFileURL resolves the "..", so this is /Applications/Slack.app
    // and must not be classified by the raw "/System/" prefix it starts with.
    #expect(isSystem("/System/../Applications/Slack.app") == false)
}

@Test func aDirectoryNamedLikeSystemIsNotASystemApp() {
    // Prefix matching must not treat a similarly-named top-level directory as
    // the real one.
    #expect(isSystem("/SystemThings/Fake.app") == false)
    #expect(isSystem("/Users/someone/System/Fake.app") == false)
}
