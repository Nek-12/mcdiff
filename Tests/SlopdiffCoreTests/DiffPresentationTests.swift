import XCTest
@testable import SlopdiffCore

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

    func testUnsafeOrIncompleteImportsRemainVisible() {
        for (ext, texts) in [
            ("ts", ["import('module').then(run)"]),
            ("ts", ["import X from 'module'; run();"]),
            ("py", ["import os; run()"]),
            ("py", ["\"\"\"", "import os", "\"\"\""]),
            ("rs", ["use std::{", "run();"]),
            ("go", ["import (", "\"fmt\""])
        ] {
            let rows = DiffPresentation.rows(for: file(ext, texts))
            XCTAssertFalse(rows.contains { if case .imports = $0 { return true }; return false }, "\(ext): \(texts)")
        }
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
}
