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

let store = LayoutStore(fileURL: storeFileURL())
let inputSource = InputSourceService()
let appMonitor = AppMonitor()

let coordinator = SwitchCoordinator(
    inputSource: inputSource,
    appMonitor: appMonitor,
    store: store
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
