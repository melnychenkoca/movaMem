import AppKit
import Testing
@testable import movaMem

// These metrics were arrived at by measuring against real menu rows (see the
// comments on MenuRowMetrics itself). They are shared by every custom row view,
// so a change here silently shifts the alignment of all of them at once — which
// is exactly the kind of regression that is easy to introduce and hard to spot.

@MainActor
@Test func titleInsetMatchesTheCheckmarkColumnWidth() {
    // The inset exists to line a custom row's text up with a standard item's
    // title, and the checkmark column is what sets that position. If AppKit ever
    // reports a materially different width, the constant is the thing that is
    // wrong, not this test.
    let checkmarkWidth = NSMenuItem().onStateImage?.size.width ?? 0
    #expect(checkmarkWidth > 0)
    #expect(abs(MenuRowMetrics.titleInset - checkmarkWidth) < 4)
}

@Test func titleInsetLeavesRoomForTheTextBezel() {
    // The bezel is subtracted from the inset when positioning a label, so a
    // bezel at or above the inset would push text to or past the menu edge.
    #expect(MenuRowMetrics.labelTextBezel < MenuRowMetrics.titleInset)
}

@MainActor
@Test func stayOpenRowUsesTheSharedTitleInset() {
    // Both custom row types must agree on where text starts, or the stay-open
    // rows would not line up with the toggle rows in the same menu.
    let row = StayOpenRowView(title: "Calculator", onClick: {})
    #expect(row.labelLeadingInset == MenuRowMetrics.titleInset - MenuRowMetrics.labelTextBezel)
}

// MARK: - StayOpenRowView behavior

@MainActor
@Test func clickingAStayOpenRowReportsExactlyOnce() {
    // The row owns its own click because it must not dismiss the menu. A missed
    // or doubled report would either strand the app in the forgotten list or
    // un-forget something twice.
    var clicks = 0
    let row = StayOpenRowView(title: "Calculator", onClick: { clicks += 1 })

    row.simulateClick()

    #expect(clicks == 1)
}

@MainActor
@Test func aStayOpenRowShowsTheTitleItWasGiven() {
    // The title is the only way the user identifies which app a row refers to,
    // including the raw-bundle-ID fallback for an uninstalled app.
    let row = StayOpenRowView(title: "com.todesktop.230313mzl4w4u92", onClick: {})
    #expect(row.displayedTitle == "com.todesktop.230313mzl4w4u92")
}

@MainActor
@Test func aStayOpenRowStartsUnhighlighted() {
    // The highlight is painted by the row itself, so it must begin in the
    // resting state rather than drawing a selection the pointer is not over.
    let row = StayOpenRowView(title: "Calculator", onClick: {})
    #expect(row.isShowingHighlight == false)
}

@MainActor
@Test func aStayOpenRowHighlightsWhileThePointerIsInside() {
    // Without this the row would stay flat while every standard row lights up,
    // which reads as the row being disabled.
    let row = StayOpenRowView(title: "Calculator", onClick: {})

    row.mouseEntered(with: MenuRowTestSupport.dummyMouseEvent())
    #expect(row.isShowingHighlight == true)

    row.mouseExited(with: MenuRowTestSupport.dummyMouseEvent())
    #expect(row.isShowingHighlight == false)
}

@MainActor
@Test func aStayOpenRowAsksForAWidthThatFitsItsTitle() {
    // A row narrower than its text would clip the app name. Long bundle IDs are
    // the realistic worst case here.
    let row = StayOpenRowView(title: "com.todesktop.230313mzl4w4u92", onClick: {})
    let fitting = row.fittingSize

    let textWidth = NSAttributedString(
        string: "com.todesktop.230313mzl4w4u92",
        attributes: [.font: NSFont.menuFont(ofSize: 0)]
    ).size().width

    #expect(fitting.width > textWidth)
    #expect(fitting.height > 0)
}

enum MenuRowTestSupport {
    /// A minimal event for driving the mouse handlers directly. The handlers only
    /// flip state and never read the event, so the fields just have to be valid.
    ///
    /// .mouseMoved rather than the .mouseEntered/.mouseExited these are passed to:
    /// mouseEvent(with:) validates the type against its own mouse mask and throws
    /// NSInternalInconsistencyException for the enter/exit types, which are posted
    /// by the tracking-area machinery rather than constructed by hand.
    static func dummyMouseEvent() -> NSEvent {
        return NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }
}
