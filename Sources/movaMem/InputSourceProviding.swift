/// One selectable keyboard layout.
struct KeyboardLayout {
    /// TIS input source ID, e.g. "com.apple.keylayout.Ukrainian-PC".
    let id: String
    /// Localized display name, e.g. "Ukrainian".
    let name: String
}

/// Everything the app needs from the keyboard-layout system.
///
/// This protocol exists so SwitchCoordinator can be tested without Carbon. The
/// real implementation is InputSourceService (Task 5).
protocol InputSourceProviding: AnyObject {
    /// The layout active right now, or nil if it cannot be determined.
    var currentLayoutID: String? { get }

    /// Layouts the user can actually switch to.
    func availableLayouts() -> [KeyboardLayout]

    /// Switches to the given layout. Returns false if it failed, which happens
    /// when a remembered layout has since been uninstalled.
    func select(layoutID: String) -> Bool

    /// Called after the active layout changes, for any reason — including changes
    /// this app caused itself.
    var onLayoutChanged: (() -> Void)? { get set }
}
