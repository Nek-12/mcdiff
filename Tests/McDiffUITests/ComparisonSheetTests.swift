import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class ComparisonSheetTests: XCTestCase {
    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private func controls(_ sheet: ComparisonSheet) throws -> (NSPopUpButton, NSTextField, NSButton) {
        let views = descendants(of: try XCTUnwrap(sheet.window?.contentView))
        let tabs = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        let repository = try XCTUnwrap(views.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Choose a local Git checkout…" })
        repository.stringValue = "/tmp/review-checkout"
        return (
            try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first),
            try XCTUnwrap(views.compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "Tag, commit, or ref" }),
            try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Open review" })
        )
    }

    @MainActor
    func testCustomTargetPassesTrimmedRevisionAndKeepsBase() throws {
        _ = NSApplication.shared
        for revision in ["v1.2.0", "abcdef123", "refs/remotes/origin/topic", "HEAD~3"] {
            var request: ComparisonRequest?
            let sheet = ComparisonSheet(recent: nil) { _, value in request = value }
            let (target, field, open) = try controls(sheet)
            XCTAssertEqual(target.titleOfSelectedItem, "Working tree")
            XCTAssertTrue(field.isHidden)
            target.selectItem(withTitle: "Revision…")
            target.sendAction(target.action, to: target.target)
            XCTAssertFalse(field.isHidden)
            field.stringValue = "  \(revision) \n"
            open.performClick(nil)
            XCTAssertEqual(request?.target, revision)
            XCTAssertEqual(request?.base, "main")
            XCTAssertEqual(request?.mergeBase, true)
        }
    }

    @MainActor
    func testReturningToWorkingTreeIgnoresCustomRevision() throws {
        _ = NSApplication.shared
        var request: ComparisonRequest?
        let sheet = ComparisonSheet(recent: nil) { _, value in request = value }
        let (target, field, open) = try controls(sheet)
        target.selectItem(withTitle: "Revision…")
        target.sendAction(target.action, to: target.target)
        field.stringValue = "HEAD~2"
        target.selectItem(withTitle: "Working tree")
        target.sendAction(target.action, to: target.target)
        XCTAssertTrue(field.isHidden)
        open.performClick(nil)
        XCTAssertNotNil(request)
        XCTAssertNil(request?.target)
    }

    @MainActor
    func testEmptyCustomRevisionDoesNotOpenReview() throws {
        _ = NSApplication.shared
        var opened = false
        let sheet = ComparisonSheet(recent: nil) { _, _ in opened = true }
        let (target, field, open) = try controls(sheet)
        target.selectItem(withTitle: "Revision…")
        target.sendAction(target.action, to: target.target)
        field.stringValue = " \n "
        open.performClick(nil)
        XCTAssertFalse(opened)
        if let alert = sheet.window?.attachedSheet {
            sheet.window?.endSheet(alert)
            alert.orderOut(nil)
        }
        field.stringValue = "v2"
        open.performClick(nil)
        XCTAssertTrue(opened)
    }
}
