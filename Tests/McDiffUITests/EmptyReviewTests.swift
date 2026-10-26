import AppKit
import XCTest
@testable import McDiff

final class EmptyReviewTests: XCTestCase {
    @MainActor
    func testHomeUsesFullWindowWithoutReviewControls() throws {
        _ = NSApplication.shared
        let controller = ReviewWindowController(github: testGitHubClient())
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentViewController)
        let split = try XCTUnwrap(content.children.compactMap { $0 as? NSSplitViewController }.first)
        content.view.layoutSubtreeIfNeeded()
        split.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(split.splitViewItems[0].isCollapsed)
        XCTAssertTrue(split.view.isHidden)
        let main = controller.home.view
        XCTAssertEqual(main.frame.width, content.view.bounds.width, accuracy: 1)
        let groups = window.toolbar?.items.compactMap { $0 as? NSToolbarItemGroup } ?? []
        XCTAssertEqual(groups.flatMap(\.subitems).map(\.label), ["Open comparison", "Recent comparisons"])
        XCTAssertTrue(window.toolbar?.items.contains { $0 === controller.home.searchItem } ?? false)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
