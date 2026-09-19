import XCTest
import SlopdiffCore
@testable import Slopdiff

final class FilterTransitionTests: XCTestCase {
    @MainActor
    func testTestFilterPreservesManualExpansionOutsideItsEffectiveChanges() {
        let files = [
            file("docs/guide.md", category: .documentation),
            file("docs/closed.md", category: .documentation),
            file("Tests/ExampleTests.swift", category: .tests),
            file("Sources/main.swift"),
            file("Sources/closed.swift"),
            file("Tests/binary.bin", category: .tests, binary: true),
            file("Tests/deleted.swift", category: .tests, deleted: true),
            file("Tests/formatting.swift", category: .tests, formatting: true)
        ]
        let manuallyExpanded: Set<String> = [
            "docs/guide.md", "Sources/main.swift",
            "Tests/binary.bin", "Tests/deleted.swift", "Tests/formatting.swift"
        ]
        let testsOn = ReviewFilters(tests: true, documentation: true, generated: true)
        let testsOff = ReviewFilters(tests: false, documentation: true, generated: true)
        let expanded = ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: manuallyExpanded, from: testsOn, to: testsOff)
        XCTAssertEqual(expanded, manuallyExpanded.union(["Tests/ExampleTests.swift"]))

        let collapsed = ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: expanded, from: testsOff, to: testsOn)
        XCTAssertEqual(collapsed, manuallyExpanded)
    }

    @MainActor
    func testUnchangedFiltersPreserveManualExpansionAndCollapse() {
        let files = [file("docs/open.md", category: .documentation), file("docs/closed.md", category: .documentation)]
        let expanded: Set<String> = ["docs/open.md"]
        XCTAssertEqual(ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: expanded, from: ReviewFilters(), to: ReviewFilters()), expanded)
    }

    @MainActor
    func testTestFilterDoesNotExpandManuallyCollapsedDocumentationWhenDocumentationFilterIsOff() {
        let files = [
            file("docs/open.md", category: .documentation),
            file("docs/closed.md", category: .documentation),
            file("Tests/ExampleTests.swift", category: .tests)
        ]
        let testsOn = ReviewFilters(tests: true, documentation: false, generated: false)
        let testsOff = ReviewFilters(tests: false, documentation: false, generated: false)
        let expanded = ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: ["docs/open.md"], from: testsOn, to: testsOff)
        XCTAssertEqual(expanded, ["docs/open.md", "Tests/ExampleTests.swift"])
        XCTAssertEqual(ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: expanded, from: testsOff, to: testsOn), ["docs/open.md"])
    }

    private func file(_ path: String, category: FileCategory = .production, binary: Bool = false,
                      deleted: Bool = false, formatting: Bool = false) -> FileDiff {
        FileDiff(path: path, status: deleted ? "D" : "A",
                 hunks: deleted ? [] : [DiffHunk(header: "", lines: [
                    DiffLine(kind: .addition, text: "content", oldNumber: nil, newNumber: 1)
                 ])], isBinary: binary, fingerprint: path, category: category, isFormattingOnly: formatting)
    }
}
