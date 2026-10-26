import AppKit
import McDiffCore
import XCTest
@testable import McDiff

final class ReviewFooterTests: XCTestCase {
    private func file(_ path: String) -> FileDiff {
        FileDiff(path: path, hunks: [DiffHunk(header: "", lines: [
            DiffLine(kind: .addition, text: "new code", oldNumber: nil, newNumber: 1)
        ])], fingerprint: path)
    }

    @MainActor
    private func makeViewport() -> (DiffViewport, NSWindow) {
        _ = NSApplication.shared
        let view = DiffViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        return (view, window)
    }

    @MainActor
    private func ready(_ view: DiffViewport) async throws {
        for _ in 0..<400 {
            view.layoutSubtreeIfNeeded()
            if !view.isLayoutPending && !view.isSearchPending { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Footer viewport layout did not finish")
    }

    @MainActor
    private func footer(_ view: DiffViewport) throws -> ReviewFooterView {
        view.table.scrollRowToVisible(view.rows.count - 1)
        view.table.layoutSubtreeIfNeeded()
        return try XCTUnwrap(view.table.view(atColumn: 0, row: view.rows.count - 1, makeIfNecessary: true) as? ReviewFooterView)
    }

    @MainActor
    func testFooterCountsAllUncheckedFilesRegardlessOfExpansionOrSearch() async throws {
        let (view, window) = makeViewport()
        defer { window.orderOut(nil) }
        let files = [file("a.swift"), file("b.swift"), file("generated.swift")]
        var reviewed: Set<String> = ["generated.swift"]
        view.isReviewed = { reviewed.contains($0.path) }
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        try await ready(view)
        XCTAssertEqual(try footer(view).message.stringValue, "2 files left to review")
        view.setExpanded(true, file: 0)
        view.search(query: "a.swift")
        try await ready(view)
        XCTAssertEqual(try footer(view).message.stringValue, "2 files left to review")

        reviewed.insert("a.swift")
        view.redraw()
        XCTAssertEqual(try footer(view).message.stringValue, "1 file left to review")
        reviewed.insert("b.swift")
        view.redraw()
        XCTAssertEqual(try footer(view).message.stringValue, "0 files left to review. Well done!")
        reviewed.remove("a.swift")
        view.redraw()
        XCTAssertEqual(try footer(view).message.stringValue, "1 file left to review")
    }

    @MainActor
    func testFooterUsesNativeProminentFinishButtonAndSharedActionAvailability() async throws {
        let (view, window) = makeViewport()
        defer { window.orderOut(nil) }
        let file = file("a.swift")
        view.setFiles([file], presentations: [file.path: DiffPresentation.rows(for: file)])
        try await ready(view)
        let footer = try footer(view)
        XCTAssertEqual(footer.finishButton.title, "Finish review")
        XCTAssertEqual(footer.finishButton.toolTip, "Finish review")
        XCTAssertEqual(footer.finishButton.bezelStyle, .glass)
        XCTAssertEqual(footer.finishButton.tintProminence, .primary)
        XCTAssertEqual(footer.finishButton.controlSize, .regular)
        XCTAssertEqual(footer.finishButton.imagePosition, .imageLeading)
        XCTAssertNotNil(footer.finishButton.image)
        var finishes = 0
        view.onFinishReview = { finishes += 1 }
        footer.finishButton.performClick(nil)
        XCTAssertEqual(finishes, 0)
        view.finishReviewEnabled = true
        XCTAssertTrue(footer.finishButton.isEnabled)
        footer.finishButton.performClick(nil)
        XCTAssertEqual(finishes, 1)
        view.finishReviewEnabled = false
        footer.finishButton.performClick(nil)
        XCTAssertEqual(finishes, 1)
    }

    @MainActor
    func testFooterPreservesLastHeaderAnchoringAndRemainsCenteredInBothLayouts() async throws {
        let (view, window) = makeViewport()
        defer { window.orderOut(nil) }
        let files = [file("a.swift"), file("b.swift")]
        view.setFiles(files, presentations: Dictionary(uniqueKeysWithValues: files.map { ($0.path, DiffPresentation.rows(for: $0)) }))
        for layout in [DiffLayout.split, .unified] {
            view.diffLayout = layout
            try await ready(view)
            let footer = try footer(view)
            footer.layoutSubtreeIfNeeded()
            XCTAssertEqual(footer.finishButton.convert(footer.finishButton.bounds, to: footer).midX, footer.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(footer.message.convert(footer.message.bounds, to: footer).midX, footer.bounds.midX, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(view.table.rect(ofRow: view.rows.count - 1).height, view.scroll.contentSize.height - 38)
            let header = try XCTUnwrap(view.headerRows[1])
            let headerY = view.table.rect(ofRow: header).minY
            view.scroll.contentView.scroll(to: NSPoint(x: 0, y: headerY))
            XCTAssertEqual(view.scroll.documentVisibleRect.minY, headerY, accuracy: 0.5)
            view.setExpanded(true, file: 1)
            try await ready(view)
            XCTAssertEqual(view.table.rect(ofRow: try XCTUnwrap(view.headerRows[1])).minY - view.scroll.documentVisibleRect.minY, 0, accuracy: 0.5)
        }
    }
}
