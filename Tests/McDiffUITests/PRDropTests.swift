import AppKit
import XCTest
@testable import McDiff

final class PRDropTests: XCTestCase {
    @MainActor
    func testAcceptsCanonicalPRFromTextAndURL() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for type in [NSPasteboard.PasteboardType.string, .URL] {
            board.clearContents()
            board.setString("https://github.com/owner/repo/pull/12/files", forType: type)
            XCTAssertEqual(PRDropView.pullRequest(from: board)?.url, "https://github.com/owner/repo/pull/12")
        }
    }

    @MainActor
    func testRejectsUnrelatedTextAndMultipleLinks() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for value in ["hello", "file:///tmp/repo", "https://example.com/o/r/pull/1",
                      "https://github.com/o/r/pull/1\nhttps://github.com/o/r/pull/2"] {
            board.clearContents()
            board.setString(value, forType: .string)
            XCTAssertNil(PRDropView.pullRequest(from: board))
        }
        board.clearContents()
        let items = (1...2).map { number in
            let item = NSPasteboardItem()
            item.setString("https://github.com/o/r/pull/\(number)", forType: .URL)
            return item
        }
        board.writeObjects(items)
        XCTAssertNil(PRDropView.pullRequest(from: board))
    }
}
