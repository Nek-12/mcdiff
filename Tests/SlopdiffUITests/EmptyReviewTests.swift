import AppKit
import XCTest
@testable import Slopdiff

final class EmptyReviewTests: XCTestCase {
    @MainActor
    func testWelcomeUsesFullWindowWithoutReviewControls() throws {
        _ = NSApplication.shared
        let controller = ReviewWindowController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentViewController)
        let split = try XCTUnwrap(content.children.compactMap { $0 as? NSSplitViewController }.first)
        content.view.layoutSubtreeIfNeeded()
        split.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(split.splitViewItems[0].isCollapsed)
        let main = split.splitViewItems[1].viewController.view
        XCTAssertEqual(main.frame.width, split.splitView.bounds.width, accuracy: 1)
        let buttons = descendants(of: main).compactMap { $0 as? NSButton }
        let open = try XCTUnwrap(buttons.first { $0.title == "Open a comparison" })
        let openFrame = open.convert(open.bounds, to: main)
        XCTAssertEqual(openFrame.midX, main.bounds.midX, accuracy: 1)
        XCTAssertFalse(descendants(of: main).contains { ($0 as? NSTextField)?.stringValue == "Less noise. More review." })

        let groups = window.toolbar?.items.compactMap { $0 as? NSToolbarItemGroup } ?? []
        XCTAssertEqual(groups.flatMap(\.subitems).map(\.label), ["Open comparison", "Recent comparisons"])
        XCTAssertFalse(window.toolbar?.items.contains { $0 is NSSearchToolbarItem } ?? true)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
