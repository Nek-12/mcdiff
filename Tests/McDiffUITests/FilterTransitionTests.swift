import XCTest
import McDiffCore
@testable import McDiff

final class FilterTransitionTests: XCTestCase {
    @MainActor
    func testMetaFilterChangesOnlyFilesWhoseEffectiveSkipStatusChanges() {
        let files = [
            file("deleted.swift", deleted: true),
            FileDiff(path: "removal.swift", hunks: [.init(header: "", lines: [
                .init(kind: .deletion, text: "removed", oldNumber: 1, newNumber: nil)
            ])], fingerprint: "removal"),
            FileDiff(path: "renamed.swift", status: "R", hunks: [], fingerprint: "rename", hasMetadataChanges: true),
            file("Tests/deleted.swift", category: .tests, deleted: true),
            file("binary", binary: true, deleted: true),
            file("format.swift", formatting: true),
            file("manual.swift"),
            file("closed.swift")
        ]
        let skipped = ReviewFilters(whitespaceAndImports: true)
        let included = ReviewFilters(whitespaceAndImports: true, metaChanges: false)
        let manual: Set<String> = ["Tests/deleted.swift", "binary", "format.swift", "manual.swift"]
        let expanded = ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: manual, from: skipped, to: included)
        XCTAssertEqual(expanded, manual.union(["deleted.swift", "removal.swift", "renamed.swift"]))
        XCTAssertEqual(ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: expanded, from: included, to: skipped), manual)
    }

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
        let testsOn = ReviewFilters(tests: true, documentation: true, generated: true, whitespaceAndImports: true)
        let testsOff = ReviewFilters(tests: false, documentation: true, generated: true, whitespaceAndImports: true)
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

    @MainActor
    func testWhitespaceAndImportsSwitchChangesOnlyItsEffectiveFiles() {
        let files = [
            file("format.go", formatting: true),
            file("manual.swift"),
            file("closed.swift"),
            file("Tests/imports.go", category: .tests, formatting: true),
            file("docs/open.md", category: .documentation)
        ]
        let enabled = ReviewFilters(whitespaceAndImports: true)
        let disabled = ReviewFilters(whitespaceAndImports: false)
        let manuallyExpanded: Set<String> = ["manual.swift", "Tests/imports.go", "docs/open.md"]
        let expanded = ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: manuallyExpanded, from: enabled, to: disabled)
        XCTAssertEqual(expanded, manuallyExpanded.union(["format.go"]))
        XCTAssertEqual(ReviewWindowController.expansionAfterFilterChange(
            files: files, expanded: expanded, from: disabled, to: enabled), manuallyExpanded)
    }

    private func file(_ path: String, category: FileCategory = .production, binary: Bool = false,
                      deleted: Bool = false, formatting: Bool = false) -> FileDiff {
        FileDiff(path: path, status: deleted ? "D" : "A",
                 hunks: deleted ? [] : [DiffHunk(header: "", lines: [
                    DiffLine(kind: .addition, text: "content", oldNumber: nil, newNumber: 1)
                 ])], isBinary: binary, fingerprint: path, category: category, isWhitespaceAndImportsOnly: formatting)
    }
}
