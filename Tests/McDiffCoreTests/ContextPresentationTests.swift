import XCTest
@testable import McDiffCore

final class ContextPresentationTests: XCTestCase {
    private func file(path: String, old: [String], new: [String], ranges: [Range<Int>]) -> FileDiff {
        FileDiff(path: path, hunks: ranges.map { range in
            DiffHunk(header: "", lines: range.flatMap { index -> [DiffLine] in
                if old[index] == new[index] {
                    return [DiffLine(kind: .context, text: old[index], oldNumber: index + 1, newNumber: index + 1)]
                }
                return [
                    DiffLine(kind: .deletion, text: old[index], oldNumber: index + 1, newNumber: nil),
                    DiffLine(kind: .addition, text: new[index], oldNumber: nil, newNumber: index + 1)
                ]
            }, oldRange: range, newRange: range)
        }, fingerprint: "same-diff")
    }
    private func resolve(_ file: FileDiff, old: [String], new: [String]) -> [PresentedRow] {
        DiffPresentation.rows(for: file, oldSource: old.joined(separator: "\n") + "\n",
                              newSource: new.joined(separator: "\n") + "\n", resolveContext: true)
    }
    private func sections(_ rows: [PresentedRow]) -> [UnchangedSection] {
        rows.compactMap { if case .context(let section) = $0 { return section }; return nil }
    }
    private func imports(_ rows: [PresentedRow]) -> [[DiffPair]] {
        rows.compactMap { if case .imports(let pairs) = $0 { return pairs }; return nil }
    }
    private func code(_ rows: [PresentedRow]) -> [DiffPair] {
        rows.compactMap { if case .code(let pair) = $0 { return pair }; return nil }
    }

    func testPackageDeclarationJoinsImportsAcrossOmittedContext() throws {
        for (ext, package, changedPackage, imported) in [
            ("go", "package sample", "package changed", "import \"fmt\""),
            ("kt", "package sample.app", "package changed.app", "import sample.Type"),
            ("kts", "package sample.app;", "package changed.app;", "import sample.Type"),
            ("java", "package sample.app;", "package changed.app;", "import sample.Type;")
        ] {
            let old = [package, "", "", imported, "", "code"]
            var new = old
            new[0] = changedPackage
            let file = file(path: "source.\(ext)", old: old, new: new, ranges: [0..<1])
            let rows = resolve(file, old: old, new: new)
            let folded = try XCTUnwrap(imports(rows).first, ext)
            XCTAssertEqual(imports(rows).count, 1, ext)
            XCTAssertEqual(folded.compactMap { $0.old?.text }, Array(old.prefix(4)), ext)
            XCTAssertEqual(folded.compactMap { $0.new?.text }, Array(new.prefix(4)), ext)
            XCTAssertEqual(folded.first?.old?.kind, .deletion, ext)
            XCTAssertEqual(folded.first?.new?.kind, .addition, ext)
            XCTAssertEqual(code(rows).compactMap { $0.new?.text }, ["", "code"], ext)
        }
    }

    func testPackageOnlyAndAddedFileHeadersAreFoldable() {
        for (ext, declaration) in [("go", "package sample"), ("kt", "package sample.app"),
                                   ("java", "package sample.app;")] {
            let file = FileDiff(path: "source.\(ext)", status: "A", hunks: [
                DiffHunk(header: "", lines: [
                    DiffLine(kind: .addition, text: declaration, oldNumber: nil, newNumber: 1),
                    DiffLine(kind: .addition, text: "", oldNumber: nil, newNumber: 2),
                    DiffLine(kind: .addition, text: "code", oldNumber: nil, newNumber: 3)
                ])
            ], fingerprint: "added")
            let rows = DiffPresentation.rows(for: file)
            XCTAssertEqual(imports(rows).flatMap { $0.compactMap { $0.new?.text } }, [declaration], ext)
            XCTAssertEqual(code(rows).compactMap { $0.new?.text }, ["", "code"], ext)
        }
    }

    func testPackageLikeTextInCommentsStringsOrOtherLanguagesStaysVisible() {
        for (ext, old) in [
            ("kt", ["val text = \"\"\"", "package sample", "\"\"\"", "code"]),
            ("go", ["var text = `", "package sample", "`", "code"]),
            ("java", ["/*", "package sample;", "*/", "code"]),
            ("ts", ["package sample", "", "import Thing from 'thing';", "code"])
        ] {
            var new = old
            new[3] = "changed code"
            let file = file(path: "source.\(ext)", old: old, new: new, ranges: [3..<4])
            let rows = resolve(file, old: old, new: new)
            XCTAssertFalse(imports(rows).flatMap { $0 }.contains { $0.new?.text.hasPrefix("package ") == true }, ext)
            XCTAssertTrue(code(rows).contains { $0.new?.text.hasPrefix("package ") == true }, ext)
        }
    }

    func testCommentsSeparatePackageAndImportFolds() {
        let old = ["package sample", "", "// Why this dependency exists", "", "import sample.Type", "", "code"]
        var new = old
        new[6] = "changed code"
        let file = file(path: "source.kt", old: old, new: new, ranges: [6..<7])
        let rows = resolve(file, old: old, new: new)
        XCTAssertEqual(imports(rows).map { $0.compactMap { $0.new?.text } },
                       [["package sample"], ["import sample.Type"]])
        XCTAssertEqual(code(rows).compactMap { $0.new?.text },
                       ["", "// Why this dependency exists", "", "", "changed code"])
    }

    func testFiveLineThresholdAtBeginningBetweenHunksAndAtEOF() {
        for count in 1...5 {
            let old = (1...(count * 3 + 2)).map { "let value\($0) = \($0)" }
            var new = old
            new[count] = "first change"
            new[count * 2 + 1] = "second change"
            let file = file(path: "source.swift", old: old, new: new,
                            ranges: [count..<(count + 1), (count * 2 + 1)..<(count * 2 + 2)])
            let rows = resolve(file, old: old, new: new)
            XCTAssertEqual(sections(rows).count, count < 5 ? 0 : 3, "gap \(count)")
            let context = code(rows).filter { $0.old?.kind == .context }
            XCTAssertEqual(context.count, count < 5 ? count * 3 : 0)
            for pair in context {
                XCTAssertEqual(pair.old, pair.new)
                XCTAssertEqual(pair.old?.text, old[pair.old!.oldNumber! - 1])
            }
            XCTAssertEqual(DiffPresentation.sourceRows(code(rows), layout: .unified).filter {
                $0.pair.old?.kind == .context
            }.count, context.count)
        }
    }

    func testGoImportsAbsorbOmittedPrefixMiddleAndSuffixIntoOneFold() throws {
        let old = ["package sample", "", "import ("] + (1...40).map { "\t\"module\($0)\"" } +
            [")", "", "func changed() {}"] + (1...12).map { "// ordinary \($0)" }
        var new = old
        new[12] = "\t\"replacement10\""
        new[30] = "\t\"replacement28\""
        let file = file(path: "source.go", old: old, new: new, ranges: [9..<16, 27..<34])
        let rows = resolve(file, old: old, new: new)
        let folded = try XCTUnwrap(imports(rows).first)
        XCTAssertEqual(imports(rows).count, 1)
        XCTAssertEqual(folded.compactMap { $0.old?.oldNumber }, Array(1...44))
        XCTAssertEqual(folded.compactMap { $0.new?.newNumber }, Array(1...44))
        XCTAssertEqual(folded.filter { $0.old?.kind == .deletion }.count, 2)
        XCTAssertEqual(sections(rows).map(\.oldStart), [44])
        XCTAssertTrue(code(rows).isEmpty)
    }

    func testWhitespaceBetweenImportsBelongsToFoldButCommentsAndSurroundingSpaceDoNot() {
        let old = ["", "import first.One"] + Array(repeating: "", count: 7) +
            ["import second.Two", "// separator", "import third.Three", "", "fun run() {}"]
        var new = old
        new[1] = "import first.Changed"
        new[11] = "import third.Changed"
        let file = file(path: "source.kt", old: old, new: new, ranges: [1..<2, 11..<12])
        let rows = resolve(file, old: old, new: new)
        XCTAssertEqual(imports(rows).map { $0.compactMap { $0.new?.newNumber } }, [Array(2...10), [12]])
        XCTAssertEqual(code(rows).compactMap { $0.new?.newNumber }, [1, 11, 13, 14])
        XCTAssertTrue(sections(rows).isEmpty)
    }

    func testOrdinaryGapCanHaveIndependentControlsOnBothSidesOfAnImportRun() {
        let old = ["changed"] + (1...8).map { "// before \($0)" } +
            ["import first.One", "import second.Two"] + (1...8).map { "// after \($0)" } + ["changed again"]
        var new = old
        new[0] = "new"
        new[19] = "new again"
        let file = file(path: "source.kt", old: old, new: new, ranges: [0..<1, 19..<20])
        let rows = resolve(file, old: old, new: new)
        XCTAssertEqual(sections(rows).map(\.oldStart), [1, 11])
        XCTAssertEqual(sections(rows).map(\.count), [8, 8])
        XCTAssertEqual(Set(sections(rows).map(\.id)).count, 2)
        XCTAssertEqual(imports(rows).map { $0.compactMap { $0.new?.newNumber } }, [[10, 11]])
    }

    func testUnresolvedAndResolvedQuotedFragmentsNeverBecomeImportFolds() {
        let old = ["text = \"\"\""] + (1...15).map { "import fake\($0).Name" } + ["\"\"\""]
        var new = old
        new[7] = "import changed.Name"
        let file = file(path: "source.py", old: old, new: new, ranges: [4..<11])
        XCTAssertTrue(imports(DiffPresentation.rows(for: file)).isEmpty)
        XCTAssertTrue(imports(resolve(file, old: old, new: new)).isEmpty)
    }

    func testEmptyTailDisappearsAndAutomaticContextPreservesDifferentSideNumbers() throws {
        let file = try XCTUnwrap(DiffParser.parse("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -2 +2,2 @@
        -old
        +new
        +inserted

        """).first)
        let rows = resolve(file, old: ["prefix", "old", "tail"], new: ["prefix", "new", "inserted", "tail"])
        XCTAssertTrue(sections(rows).isEmpty)
        let tail = try XCTUnwrap(code(rows).last)
        XCTAssertEqual(tail.old?.oldNumber, 3)
        XCTAssertEqual(tail.new?.newNumber, 4)
        XCTAssertEqual(tail.old?.text, "tail")
        let noTail = resolve(file, old: ["prefix", "old"], new: ["prefix", "new", "inserted"])
        XCTAssertTrue(sections(noTail).isEmpty)
        XCTAssertEqual(code(noTail).count, 3)
    }
}
