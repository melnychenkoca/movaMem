import AppKit

/// Layout metrics shared by every custom menu row view.
///
/// A custom view gets none of AppKit's menu layout for free, so each row has to
/// position its own text to match the standard items above and below it. These
/// values were measured against real rows; they live here rather than in one view
/// so that two custom rows in the same menu cannot drift apart — misaligned text
/// between neighbouring rows is immediately visible.
///
/// Constants rather than runtime queries: being a point or two off is cosmetic,
/// where depending on private layout API is a crash waiting for an OS update.
enum MenuRowMetrics {
    /// Where AppKit starts the title of a standard menu item.
    ///
    /// Menus reserve a column ahead of every title for the checkmark, whether or
    /// not anything in the menu is checked, so a title never starts at the menu's
    /// own edge. At a plain 14pt inset, custom rows started 14pt left of the
    /// standard items directly above and below them, which read as a missing
    /// leading space.
    ///
    /// 18pt is the width of the checkmark column AppKit reserves, taken from
    /// `NSMenuItem.onStateImage.size.width` at the standard menu font. Since these
    /// rows span the menu's full width, that column width is exactly the offset a
    /// standard title sits at.
    ///
    /// A first attempt used 26pt, read from `NSMenuItemCell.titleRect(forBounds:)`.
    /// That number is real but is measured from the *cell's* origin, and AppKit
    /// insets the cell within the menu — so applying it from the row's own edge
    /// double-counted the margin and pushed the labels visibly right of the
    /// standard items. Cross-checked against total chrome: a standard item's menu
    /// is 32.7pt wider than its title text, which splits into roughly this
    /// leading inset plus the trailing one below.
    static let titleInset: CGFloat = 18

    /// The trailing inset. Smaller than the leading one because there is no state
    /// column on that side — this is just the menu's own margin.
    static let trailingInset: CGFloat = 14

    /// How far inside its own frame a label-style NSTextField draws its first
    /// glyph. Subtracted from titleInset so the *text* lands at titleInset rather
    /// than the text field's frame doing so.
    ///
    /// AppKit does not expose this, and it is stable at 2pt for a bezel-less,
    /// border-less label — the configuration NSTextField(labelWithString:)
    /// produces.
    static let labelTextBezel: CGFloat = 2

    static let verticalPadding: CGFloat = 4

    /// Paints the highlight a standard menu row shows under the pointer.
    ///
    /// Shared because the inset and corner radius have to match between row types;
    /// two rows highlighting at different widths in one menu is glaringly obvious.
    /// `selectedContentBackgroundColor` is the color AppKit itself uses, so this
    /// tracks the system accent color and both light and dark appearance.
    static func drawHighlight(in bounds: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        // Inset horizontally to match the rounded highlight macOS draws inside the
        // menu's own padding, rather than bleeding to the full width.
        let highlightRect = bounds.insetBy(dx: 5, dy: 0)
        let path = NSBezierPath(roundedRect: highlightRect, xRadius: 4, yRadius: 4)
        path.fill()
    }
}
