import XCTest
@testable import SlopdiffCore

final class ReviewCommentTests: XCTestCase {
    func testOverlappingCommentIsRejectedWithoutChangingSavedText() throws {
        var progress = ReviewProgress()
        let original = comment(3, 7)
        try progress.saveComment(original)
        for range in [(1, 3), (5, 5), (7, 10), (1, 10)] {
            XCTAssertThrowsError(try progress.saveComment(comment(range.0, range.1)))
            XCTAssertEqual(progress.comments, [original])
        }
        try progress.saveComment(comment(8, 9))
        var edited = original
        edited.text = "Edited"
        try progress.saveComment(edited)
        XCTAssertEqual(progress.comments.count, 2)
        XCTAssertEqual(progress.comments[0].text, "Edited")
        edited.endLine = 8
        XCTAssertThrowsError(try progress.saveComment(edited))
        XCTAssertEqual(progress.comments[0].endLine, 7)
    }

    func testOtherSideAndFileCanHaveSameRangeButInvalidInputCannotSave() throws {
        var progress = ReviewProgress()
        try progress.saveComment(comment(3, 7))
        var other = comment(3, 7)
        other.side = .old
        try progress.saveComment(other)
        other = comment(3, 7)
        other.path = "Other.kt"
        try progress.saveComment(other)
        XCTAssertEqual(progress.comments.count, 3)
        XCTAssertThrowsError(try progress.saveComment(comment(0, 1)))
        XCTAssertThrowsError(try progress.saveComment(comment(9, 1)))
        other = comment(10, 11)
        other.text = " \n"
        XCTAssertThrowsError(try progress.saveComment(other))
        XCTAssertEqual(progress.comments.count, 3)
    }

    private func comment(_ start: Int, _ end: Int) -> ReviewComment {
        ReviewComment(path: "Main.kt", side: .new, startLine: start, endLine: end,
                      text: "Review note", fingerprint: "same-diff")
    }
}
