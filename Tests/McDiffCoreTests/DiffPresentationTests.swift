import XCTest
@testable import McDiffCore

final class DiffPresentationTests: XCTestCase {
    private func file(_ ext: String, _ texts: [String]) -> FileDiff {
        FileDiff(path: "source.\(ext)", hunks: [
            DiffHunk(header: "@@ -1 +1 @@", lines: texts.enumerated().map {
                DiffLine(kind: .context, text: $0.element, oldNumber: $0.offset + 1, newNumber: $0.offset + 1)
            })
        ], fingerprint: "test")
    }

    func testAllImportLanguagesAndAdjacentExecutableCode() {
        let examples: [(String, [String])] = [
            ("kt", ["import org.example.Model", "import org.example.Other as Alias"]),
            ("java", ["import java.util.List;", "import static java.lang.Math.*;"]),
            ("go", ["import (", "    \"fmt\"", "    alias \"net/http\"", ")"]),
            ("ts", ["import {", "    One,", "    Two", "} from 'module';"]),
            ("tsx", ["import type {", "    Model", "} from 'module';"]),
            ("js", ["import 'module';"]),
            ("rs", ["use std::{", "    io,", "    fmt::Debug,", "};"]),
            ("py", ["from package import (", "    one,", "    two as alias,", ")"])
        ]
        for (ext, imports) in examples {
            let rows = DiffPresentation.rows(for: file(ext, imports + ["executeWork()"]))
            guard rows.count == 3, case .imports(let folded) = rows[1], case .code(let code) = rows[2] else {
                XCTFail("Expected exactly one import block then executable code for \(ext)"); continue
            }
            XCTAssertEqual(folded.count, imports.count, ext)
            XCTAssertEqual(code.new?.text, "executeWork()")
        }
    }

    func testWhitespaceBetweenImportsFoldsButSurroundingWhitespaceStaysVisible() {
        let examples = [
            ("kt", "import org.example.Model", "import org.example.Other as Alias"),
            ("java", "import java.util.List;", "import static java.lang.Math.*;"),
            ("go", "import \"fmt\"", "import alias \"net/http\""),
            ("ts", "import One from 'one';", "import { Two } from 'two';"),
            ("rs", "use std::io;", "use std::fmt::Debug;"),
            ("py", "import os", "from package import other")
        ]
        for (ext, first, second) in examples {
            let block = [first, "", " \t ", second]
            let rows = DiffPresentation.rows(for: file(ext, [""] + block + ["\t", "executeWork()"]))
            guard rows.count == 5, case .code(let leading) = rows[1],
                  case .imports(let folded) = rows[2], case .code(let trailing) = rows[3],
                  case .code(let code) = rows[4] else {
                XCTFail("Expected one import block with visible surrounding whitespace for \(ext)")
                continue
            }
            XCTAssertEqual(leading.new?.text, "")
            XCTAssertEqual(trailing.new?.text, "\t")
            XCTAssertEqual(code.new?.text, "executeWork()")
            XCTAssertEqual(folded.compactMap { $0.new?.text }, block)
            XCTAssertEqual(folded.compactMap { $0.old?.oldNumber }, [2, 3, 4, 5])
            XCTAssertEqual(folded.compactMap { $0.new?.newNumber }, [2, 3, 4, 5])
        }
    }

    func testWhitespaceInsideExplicitMultilineImportsFoldsWithoutChangingText() {
        let examples: [(String, [String])] = [
            ("go", ["import (", "", "    \"fmt\"", " \t", "    alias \"net/http\"", "", ")"]),
            ("ts", ["import {", "", "    One,", " \t", "    Two", "", "} from 'module';"]),
            ("rs", ["use std::{", "", "    io,", " \t", "    fmt::Debug,", "", "};"]),
            ("py", ["from package import (", "", "    one,", " \t", "    two as alias,", "", ")"])
        ]
        for (ext, texts) in examples {
            let rows = DiffPresentation.rows(for: file(ext, texts))
            guard rows.count == 2, case .imports(let folded) = rows[1] else {
                XCTFail("Expected one multiline import block for \(ext)"); continue
            }
            XCTAssertEqual(folded.compactMap { $0.new?.text }, texts)
            XCTAssertEqual(folded.compactMap { $0.new?.newNumber }, Array(1...texts.count))
        }
    }

    func testUnsafeOrIncompleteImportsRemainVisible() {
        for (ext, texts) in [
            ("ts", ["import('module').then(run)"]),
            ("ts", ["import X from 'module'; run();"]),
            ("ts", ["import {", "", "// explanation", "Value", "} from 'module';"]),
            ("ts", ["import {", "", "run()", "} from 'module';"]),
            ("ts", ["import { Value } from 'module", "", "name';"]),
            ("ts", ["const text = `", "import X from 'module';", "", "import Y from 'other';", "`"]),
            ("java", ["/*", "import java.util.List;", "", "import java.util.Map;", "*/"]),
            ("py", ["import os; run()"]),
            ("py", ["\"\"\"", "import os", "\"\"\""]),
            ("py", ["'''", "import os", " \t", "import sys", "'''"]),
            ("py", ["from package import (", "", "# explanation", "one,", ")"]),
            ("rs", ["use std::{", "run();"]),
            ("go", ["import (", "\"fmt\""]),
            ("go", ["import (", "", "\"fmt\"", " \t"]),
            ("txt", ["import os", "", "import sys"])
        ] {
            let rows = DiffPresentation.rows(for: file(ext, texts))
            XCTAssertFalse(rows.contains { if case .imports = $0 { return true }; return false }, "\(ext): \(texts)")
            XCTAssertEqual(rows.compactMap { row -> String? in
                if case .code(let pair) = row { return pair.new?.text }; return nil
            }, texts)
        }
    }

    func testCodeAndCommentsSeparateImportBlocks() {
        for separator in ["run();", "// explanation", "/* explanation */"] {
            let texts = ["import One from 'one';", "", separator, " \t", "import Two from 'two';"]
            let rows = DiffPresentation.rows(for: file("ts", texts))
            let visible = rows.compactMap { row -> String? in
                if case .code(let pair) = row { return pair.new?.text }; return nil
            }
            if separator.hasPrefix("/*") {
                XCTAssertEqual(visible, texts, "Block comments disable folding without full lexical state")
            } else {
                XCTAssertEqual(visible, ["", separator, " \t"])
                XCTAssertEqual(rows.compactMap { row -> [String]? in
                    if case .imports(let pairs) = row { return pairs.compactMap { $0.new?.text } }; return nil
                }, [[texts[0]], [texts[4]]])
            }
        }
    }

    func testImportWhitespaceDoesNotBridgeHunks() {
        let first = file("ts", ["import One from 'one';", ""])
        let second = DiffHunk(header: "@@ -10,2 +10,2 @@", lines: [
            DiffLine(kind: .context, text: "\t", oldNumber: 10, newNumber: 10),
            DiffLine(kind: .context, text: "import Two from 'two';", oldNumber: 11, newNumber: 11)
        ])
        let rows = DiffPresentation.rows(for: FileDiff(
            path: first.path, hunks: first.hunks + [second], fingerprint: "test"))
        XCTAssertEqual(rows.compactMap { row -> [Int]? in
            if case .imports(let pairs) = row { return pairs.compactMap { $0.new?.newNumber } }; return nil
        }, [[1], [11]])
        XCTAssertEqual(rows.compactMap { row -> Int? in
            if case .code(let pair) = row { return pair.new?.newNumber }; return nil
        }, [2, 10])
    }

    func testMixedImportEditsRetainWhitespaceLineIdentityCountsAndLayoutOrder() {
        let lines = [
            DiffLine(kind: .context, text: "import Base from 'base';", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .deletion, text: "", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .deletion, text: "import Old from 'old';", oldNumber: 3, newNumber: nil),
            DiffLine(kind: .addition, text: " \t", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .addition, text: "", oldNumber: nil, newNumber: 3),
            DiffLine(kind: .addition, text: "import New from 'new';", oldNumber: nil, newNumber: 4),
            DiffLine(kind: .context, text: "", oldNumber: 4, newNumber: 5)
        ]
        let file = FileDiff(path: "source.ts", hunks: [DiffHunk(header: "header", lines: lines)], fingerprint: "test")
        let rows = DiffPresentation.rows(for: file)
        guard rows.count == 3, case .imports(let folded) = rows[1], case .code(let trailing) = rows[2] else {
            return XCTFail("Expected one folded changed import block with trailing whitespace visible")
        }
        XCTAssertEqual(folded.compactMap(\.old), Array(lines[0...2]))
        XCTAssertEqual(folded.compactMap(\.new), [lines[0]] + Array(lines[3...5]))
        XCTAssertEqual(trailing.old, lines[6])
        XCTAssertEqual(trailing.new, lines[6])
        XCTAssertEqual(folded.filter { $0.old?.kind == .deletion }.count, 2)
        XCTAssertEqual(folded.filter { $0.new?.kind == .addition }.count, 3)
        XCTAssertEqual(file.deletions, 2)
        XCTAssertEqual(file.additions, 3)
        let unified = DiffPresentation.sourceRows(folded, layout: .unified)
        XCTAssertEqual(unified.compactMap { $0.side == .old ? $0.pair.old : $0.pair.new }, Array(lines[0...5]))
        let split = DiffPresentation.sourceRows(folded, layout: .split)
        XCTAssertEqual(split.compactMap { $0.pair.old }, Array(lines[0...2]))
        XCTAssertEqual(split.compactMap { $0.pair.new }, [lines[0]] + Array(lines[3...5]))
    }

    func testImportOnOneSideDoesNotHideExecutableCodeOnTheOther() {
        let lines = [
            DiffLine(kind: .context, text: "import Base from 'base';", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .deletion, text: "run();", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .addition, text: "", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .context, text: "import Other from 'other';", oldNumber: 3, newNumber: 3)
        ]
        let rows = DiffPresentation.rows(for: FileDiff(
            path: "source.ts", hunks: [DiffHunk(header: "header", lines: lines)], fingerprint: "test"))
        let visible = rows.compactMap { row -> DiffPair? in
            if case .code(let pair) = row { return pair }; return nil
        }
        XCTAssertEqual(visible.compactMap(\.old), [lines[1]])
        XCTAssertEqual(visible.compactMap(\.new), [lines[2]])
    }

    func testPairingUnbalancedEditsAndContext() {
        let lines = [
            DiffLine(kind: .context, text: "same", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .deletion, text: "old", oldNumber: 2, newNumber: nil),
            DiffLine(kind: .addition, text: "new", oldNumber: nil, newNumber: 2),
            DiffLine(kind: .addition, text: "extra", oldNumber: nil, newNumber: 3)
        ]
        let file = FileDiff(path: "x.swift", hunks: [DiffHunk(header: "header", lines: lines)], fingerprint: "x")
        let pairs = DiffPresentation.rows(for: file).compactMap { row -> DiffPair? in
            if case .code(let pair) = row { return pair }; return nil
        }
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs[0].old, pairs[0].new)
        XCTAssertEqual(pairs[1].old?.text, "old")
        XCTAssertEqual(pairs[1].new?.text, "new")
        XCTAssertNil(pairs[2].old)
        XCTAssertEqual(pairs[2].new?.text, "extra")
    }

    func testWholeTokensOperatorsAndUTF16() {
        let old = "😀 caféCounter >= 12", new = "😀 caféTotal <= 12"
        let ranges = WordDiff.ranges(old: old, new: new)
        XCTAssertEqual(ranges.old.map { (old as NSString).substring(with: $0) }, ["caféCounter", ">="])
        XCTAssertEqual(ranges.new.map { (new as NSString).substring(with: $0) }, ["caféTotal", "<="])
        XCTAssertTrue(WordDiff.ranges(old: old, new: old).old.isEmpty)
        XCTAssertEqual(WordDiff.ranges(old: "", new: "hello").new, [NSRange(location: 0, length: 5)])
        let long = String(repeating: "x", count: 100_000)
        XCTAssertEqual(WordDiff.ranges(old: long, new: long + "y").old, [NSRange(location: 0, length: 100_000)])
    }

    func testUnifiedOrdersEachEditBlockWithoutDuplicatingContextOrLosingCounterpart() {
        let context = DiffLine(kind: .context, text: "same", oldNumber: 4, newNumber: 6)
        let pairs = [
            DiffPair(old: DiffLine(kind: .deletion, text: "old one", oldNumber: 1, newNumber: nil),
                     new: DiffLine(kind: .addition, text: "new one", oldNumber: nil, newNumber: 1)),
            DiffPair(old: DiffLine(kind: .deletion, text: "old two", oldNumber: 2, newNumber: nil),
                     new: DiffLine(kind: .addition, text: "new two", oldNumber: nil, newNumber: 2)),
            DiffPair(old: nil, new: DiffLine(kind: .addition, text: "extra", oldNumber: nil, newNumber: 3)),
            DiffPair(old: context, new: context),
            DiffPair(old: DiffLine(kind: .deletion, text: "removed", oldNumber: 5, newNumber: nil), new: nil)
        ]
        let rows = DiffPresentation.sourceRows(pairs, layout: .unified)
        XCTAssertEqual(rows.map { $0.side == .old ? $0.pair.old?.text : $0.pair.new?.text },
                       ["old one", "old two", "new one", "new two", "extra", "same", "removed"])
        XCTAssertEqual(rows.map(\.side), [.old, .old, .new, .new, .new, .new, .old])
        XCTAssertEqual(rows[0].pair.new?.text, "new one", "Keep paired text for word emphasis")
        XCTAssertEqual(rows[5].pair.old?.oldNumber, 4)
        XCTAssertEqual(rows[5].pair.new?.newNumber, 6)
        XCTAssertEqual(DiffPresentation.sourceRows(pairs, layout: .split).count, pairs.count)
    }
}
