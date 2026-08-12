import Carbon
import Foundation
import os

/// The only code in the app that talks to Carbon's Text Input Sources API.
///
/// Carbon is old but not deprecated, and Apple has never shipped a replacement
/// for keyboard-layout switching. Reading and setting the layout needs no
/// permissions of any kind — verified on macOS 26.5.
final class InputSourceService: InputSourceProviding {
    private let log = Logger(subsystem: "com.movamem.app", category: "InputSourceService")
    var onLayoutChanged: (() -> Void)?

    init() {
        // The OS broadcasts this whenever the layout changes, for any reason —
        // Cmd+Space, Caps Lock, the system input menu, or our own select() call.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(layoutDidChange),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )
        log.debug("Listening for input source changes")
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// @objc is required because this is called by the notification system, which
    /// is Objective-C and needs a runtime-visible selector.
    @objc private func layoutDidChange() {
        onLayoutChanged?()
    }

    // MARK: - Reading

    var currentLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            log.error("Could not read current input source")
            return nil
        }
        return InputSourceService.readStringProperty(source, kTISPropertyInputSourceID)
    }

    func availableLayouts() -> [KeyboardLayout] {
        // Ask only for keyboard layouts; the unfiltered list also contains input
        // modes and palettes the user cannot select.
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
        ] as CFDictionary

        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
            as? [TISInputSource] else {
            log.error("Could not list input sources")
            return []
        }

        var layouts: [KeyboardLayout] = []
        for source in list {
            // Skip anything the user cannot actually switch to. On some setups
            // this filters nothing; on others it removes several entries.
            if InputSourceService.readBoolProperty(source, kTISPropertyInputSourceIsSelectCapable) == false {
                continue
            }
            guard let id = InputSourceService.readStringProperty(source, kTISPropertyInputSourceID) else {
                continue
            }
            let name = InputSourceService.readStringProperty(source, kTISPropertyLocalizedName) ?? id
            layouts.append(KeyboardLayout(id: id, name: name))
        }
        return layouts
    }

    // MARK: - Writing

    func select(layoutID: String) -> Bool {
        var wanted: TISInputSource?
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String
        ] as CFDictionary

        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
            as? [TISInputSource] else {
            return false
        }
        for source in list {
            if InputSourceService.readStringProperty(source, kTISPropertyInputSourceID) == layoutID {
                wanted = source
                break
            }
        }

        guard let target = wanted else {
            // Normal when a remembered layout has been uninstalled.
            log.error("Layout \(layoutID, privacy: .public) is not installed")
            return false
        }

        let status = TISSelectInputSource(target)
        if status != noErr {
            log.error("TISSelectInputSource failed with status \(status)")
            return false
        }
        return true
    }

    // MARK: - Carbon property helpers
    //
    // Carbon returns properties as raw pointers. Unmanaged<>.fromOpaque() wraps a
    // raw pointer, and takeUnretainedValue() reads it WITHOUT taking ownership —
    // correct here because TISGetInputSourceProperty does not transfer ownership.
    // (By contrast the TISCopy*/TISCreate* calls above return owned objects, hence
    // takeRetainedValue there.) Getting this wrong causes crashes or leaks.

    private static func readStringProperty(
        _ source: TISInputSource,
        _ key: CFString
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func readBoolProperty(
        _ source: TISInputSource,
        _ key: CFString
    ) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}
