import XCTest
@testable import SlopdiffCore

final class DiffParserTests: XCTestCase {
    func testLineNumbersAndNoNewlineMarker() throws {
        let file = try XCTUnwrap(DiffParser.parse("""
        diff --git a/file.txt b/file.txt
        index abc..def 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -7,2 +7,2 @@ function
         same
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """).first)
        XCTAssertEqual(file.path, "file.txt")
        XCTAssertEqual(file.hunks[0].lines.map(\.oldNumber), [7, 8, nil])
        XCTAssertEqual(file.hunks[0].lines.map(\.newNumber), [7, nil, 8])
        XCTAssertEqual(file.additions, 1)
        XCTAssertEqual(file.deletions, 1)
        XCTAssertTrue(file.hasMetadataChanges)
    }

    func testQuotedUnicodeTabsNewlinesAndSpaces() throws {
        for (encoded, expected) in [
            (#""a/caf\303\251\tname\n.txt" "b/caf\303\251\tname\n.txt""#, "café\tname\n.txt"),
            ("a/a space b/name.txt b/a space b/name.txt", "a space b/name.txt"),
            (#""a/a\"quote.txt" "b/a\"quote.txt""#, "a\"quote.txt")
        ] {
            let file = try XCTUnwrap(DiffParser.parse("diff --git \(encoded)\nold mode 100644\nnew mode 100755\n").first)
            XCTAssertEqual(file.path, expected)
            XCTAssertEqual(file.oldPath, expected)
        }
    }

    func testRenameBinaryAndMetadataIdentity() throws {
        let renamed = try XCTUnwrap(DiffParser.parse("""
        diff --git a/old name b/new name
        similarity index 100%
        rename from old name
        rename to new name
        """).first)
        XCTAssertEqual(renamed.oldPath, "old name")
        XCTAssertEqual(renamed.path, "new name")
        XCTAssertEqual(renamed.status, "R")
        let a = try XCTUnwrap(DiffParser.parse("diff --git a/x b/x\nindex aa..bb 100644\nBinary files a/x and b/x differ\n").first)
        let b = try XCTUnwrap(DiffParser.parse("diff --git a/x b/x\nindex aa..cc 100644\nBinary files a/x and b/x differ\n").first)
        XCTAssertTrue(a.isBinary)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        let mode = try XCTUnwrap(DiffParser.parse("diff --git a/x b/x\nold mode 100644\nnew mode 100755\n").first)
        XCTAssertFalse(mode.isFormattingOnly)
        XCTAssertTrue(mode.hasMetadataChanges)
        XCTAssertNotEqual(a.fingerprint, mode.fingerprint)
    }

    func testInvalidPatchesThrowInsteadOfDroppingRecords() {
        for patch in [
            "not a patch", "diff --git a/x b/x", "diff --git a/x b/x\n@@ -1,2 +1 @@\n-old\n+new\n",
            "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n+extra\n",
            "diff --git a/x b/x\nmysterious record\n",
            "diff --git \"a/unterminated b/x",
            "diff --git a/x b/x\n@@ -99999999999999999999999 +1 @@\n-x\n+y"
        ] { XCTAssertThrowsError(try DiffParser.parse(patch), patch) }
        XCTAssertEqual(try DiffParser.parse("").count, 0)
    }

    func testFormattingSafety() throws {
        func file(_ path: String, _ old: String, _ new: String) throws -> FileDiff {
            try XCTUnwrap(DiffParser.parse("diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1 @@\n-\(old)\n+\(new)\n").first)
        }
        XCTAssertTrue(try file("data.json", #"{"x": 1}"#, #"{ "x" : 1 }"#).isFormattingOnly)
        XCTAssertFalse(try file("data.json", #"{"x": "a b"}"#, #"{"x": "ab"}"#).isFormattingOnly)
        XCTAssertFalse(try file("x.py", "  return 1", "    return 1").isFormattingOnly)
        XCTAssertFalse(try file("x.kt", #"val x = "a b""#, #"val x = "ab""#).isFormattingOnly)
        XCTAssertFalse(try file("x.md", "one", "one  ").isFormattingOnly)
    }

    func testStress400Files30000ChangedLines() throws {
        let body = (0..<75).map { "+let value\($0) = \($0)" }.joined(separator: "\n")
        let patch = (0..<400).map {
            "diff --git a/source\($0).swift b/source\($0).swift\nnew file mode 100644\n--- /dev/null\n+++ b/source\($0).swift\n@@ -0,0 +1,75 @@\n\(body)\n"
        }.joined()
        let start = ContinuousClock.now
        let files = try DiffParser.parse(patch)
        let duration = start.duration(to: .now)
        XCTAssertEqual(files.count, 400)
        XCTAssertEqual(files.reduce(0) { $0 + $1.additions }, 30_000)
        print("STRESS parse 400 files / 30,000 added lines / \(patch.utf8.count) bytes: \(duration)")
    }
}
