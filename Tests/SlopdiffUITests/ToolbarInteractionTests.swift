import AppKit
import SlopdiffCore
import XCTest
@testable import Slopdiff

final class ToolbarInteractionTests: XCTestCase {
    @MainActor
    func testLayoutToggleShowsDestinationAndUpdatesViewport() throws {
        _ = NSApplication.shared
        let controller = ReviewWindowController()
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        let items = controller.toolbarAllowedItemIdentifiers(toolbar).compactMap {
            controller.toolbar(toolbar, itemForItemIdentifier: $0, willBeInsertedIntoToolbar: false)
        }
        let toggle = try XCTUnwrap(items.first { $0.title == "Unified" })
        let viewport = try XCTUnwrap(descendants(of: try XCTUnwrap(window.contentView)).compactMap { $0 as? DiffViewport }.first)
        let action = try XCTUnwrap(toggle.action)
        XCTAssertEqual(viewport.diffLayout, .split)
        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertEqual(viewport.diffLayout, .unified)
        XCTAssertEqual(toggle.title, "Split")
        XCTAssertEqual(toggle.toolTip, "Switch to split diff")
        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertEqual(viewport.diffLayout, .split)
        XCTAssertEqual(toggle.title, "Unified")
        XCTAssertEqual(toggle.toolTip, "Switch to unified diff")
    }

    @MainActor
    func testToolbarActionsHaveReadableTooltips() throws {
        _ = NSApplication.shared
        let controller = ReviewWindowController()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        for identifier in controller.toolbarAllowedItemIdentifiers(toolbar) {
            guard let item = controller.toolbar(toolbar, itemForItemIdentifier: identifier,
                                                willBeInsertedIntoToolbar: false), item.action != nil else { continue }
            let actions = (item as? NSToolbarItemGroup)?.subitems ?? [item]
            for action in actions {
                XCTAssertFalse(action.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                               "Missing tooltip for \(action.label)")
            }
        }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
