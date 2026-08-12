import Foundation
import Testing
@testable import movaMem

/// A scheduler that runs nothing until the test says so, letting dwell behavior
/// be tested without any real waiting.
private final class ManualScheduler {
    private var pending: [(delay: Double, work: () -> Void)] = []

    func schedule(after delay: Double, work: @escaping () -> Void) {
        pending.append((delay: delay, work: work))
    }

    /// Runs every scheduled block, simulating enough time passing.
    func fireAll() {
        let toRun = pending
        pending = []
        for item in toRun {
            item.work()
        }
    }

    var pendingCount: Int { return pending.count }
}

@Test func activationIsReportedAfterDwellPeriod() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    monitor.handleActivation(bundleID: "com.microsoft.VSCode")
    #expect(reported.isEmpty)   // nothing yet — still inside the dwell window

    scheduler.fireAll()
    #expect(reported == ["com.microsoft.VSCode"])
}

@Test func transientFocusIsNotReported() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    // Spotlight steals focus, then the user lands on VS Code before the dwell
    // period elapses. Only VS Code should be reported.
    monitor.handleActivation(bundleID: "com.apple.Spotlight")
    monitor.handleActivation(bundleID: "com.microsoft.VSCode")
    scheduler.fireAll()

    #expect(reported == ["com.microsoft.VSCode"])
}

@Test func ignoredBundleIDsAreNeverReported() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    monitor.handleActivation(bundleID: "com.apple.Spotlight")
    scheduler.fireAll()

    #expect(reported.isEmpty)
    // Ignored apps should not even be scheduled.
    #expect(scheduler.pendingCount == 0)
}

@Test func rapidSwitchingReportsOnlyTheSettledApp() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    monitor.handleActivation(bundleID: "com.tinyspeck.slackmacgap")
    monitor.handleActivation(bundleID: "ru.keepcoder.Telegram")
    monitor.handleActivation(bundleID: "com.microsoft.VSCode")
    scheduler.fireAll()

    #expect(reported == ["com.microsoft.VSCode"])
}

@Test func returningToSameAppWithinDwellWindowReportsItTwice() {
    let scheduler = ManualScheduler()
    let monitor = AppMonitor(dwellSeconds: 0.3) { delay, work in
        scheduler.schedule(after: delay, work: work)
    }

    var reported: [String] = []
    monitor.onAppActivated = { bundleID in reported.append(bundleID) }

    // A -> B -> A inside one dwell window: the user Cmd-Tabs to Slack and
    // immediately back to VS Code before 300ms elapses. Both VS Code
    // activations pass the "still pending" check (pendingBundleID settled
    // back on VS Code), so onAppActivated fires twice for the same app.
    // This is accepted, not fixed: dedup here is by bundle-ID identity, not
    // by activation instance, and SwitchCoordinator's early-return when the
    // wanted layout already matches the current one makes the duplicate
    // call a harmless no-op downstream.
    monitor.handleActivation(bundleID: "com.microsoft.VSCode")
    monitor.handleActivation(bundleID: "com.tinyspeck.slackmacgap")
    monitor.handleActivation(bundleID: "com.microsoft.VSCode")
    scheduler.fireAll()

    #expect(reported == ["com.microsoft.VSCode", "com.microsoft.VSCode"])
}
