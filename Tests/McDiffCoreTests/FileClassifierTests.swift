import XCTest
@testable import McDiffCore

final class FileClassifierTests: XCTestCase {
    func testMarkdownIsControlledByDocumentationFilterRegardlessOfDirectory() {
        let testsOnly = ReviewFilters(tests: true, documentation: false, generated: false)
        let noiseOnly = ReviewFilters(tests: false, documentation: false, generated: true)
        let documentationOnly = ReviewFilters(tests: false, documentation: true, generated: false)
        for directory in ["docs/dev/specs", "tests/fixtures", "generated", "node_modules/package", "src"] {
            for ext in ["md", "markdown", "mdown", "mkd", "mdx", "MD"] {
                let path = "\(directory)/workflow-orchestration.\(ext)"
                let category = FileClassifier.classify(path)
                XCTAssertEqual(category, .documentation, path)
                let file = FileDiff(path: path, status: "A", hunks: [
                    DiffHunk(header: "", lines: [DiffLine(kind: .addition, text: "# Plan", oldNumber: nil, newNumber: 1)])
                ], fingerprint: path, category: category)
                XCTAssertNil(testsOnly.skipReason(for: file), path)
                XCTAssertNil(noiseOnly.skipReason(for: file), path)
                XCTAssertNotNil(documentationOnly.skipReason(for: file), path)
            }
        }
    }

    func testNonMarkdownKeepsExistingDirectoryPrecedence() {
        for path in ["tests/fixtures/input.json", "docs/dev/specs/example.swift", "tests/notes.rst"] {
            XCTAssertEqual(FileClassifier.classify(path), .tests, path)
        }
        for path in ["generated/settings.json", "generated/tests/ExampleTests.swift", "node_modules/package/guide.rst"] {
            XCTAssertEqual(FileClassifier.classify(path), .generated, path)
        }
    }

    func testConventions() {
        for path in ["src/test/kotlin/Thing.kt", "src/commonTest/Thing.kt", "tests/test_x.py", "foo_test.go", "ThingTests.swift", "x.spec.ts", "__tests__/x.js"] {
            XCTAssertEqual(FileClassifier.classify(path), .tests, path)
        }
        for path in ["README.md", "docs/guide.html", "LICENSE", "assets/icon.svg", "README.txt", "config.json", ".editorconfig", "config.yaml", "Cargo.toml"] {
            XCTAssertEqual(FileClassifier.classify(path), .documentation, path)
        }
        for path in ["yarn.lock", "requirements.txt", "version.json", "App.xcodeproj/project.pbxproj", "App.xcworkspace/contents.xcworkspacedata", "src/__generated__/Model.ts", "foo.pb.go", "Package.resolved"] {
            XCTAssertEqual(FileClassifier.classify(path), .generated, path)
        }
        for path in ["src/Contest.kt", "src/Latest.java", "app/main.py", "Package.swift", "src/model.ts", "build.gradle.kts", "Makefile", "Dockerfile", "schema.proto", "unknown.xyz", "notes.txt", "CMakeLists.txt"] {
            XCTAssertEqual(FileClassifier.classify(path), .production, path)
        }
    }

    func testFullSourceFormattingPreservesLiteralsTokensAndNewlines() {
        for ext in ["kt", "java", "go", "ts", "js", "rs"] {
            XCTAssertTrue(FileClassifier.isFormattingOnly(path: "x.\(ext)", oldContent: "let x = 1;\n    work(x);", newContent: "let x=1;\n  work( x );"), ext)
            XCTAssertFalse(FileClassifier.isFormattingOnly(path: "x.\(ext)", oldContent: "let x = \"a b\";", newContent: "let x = \"ab\";"), ext)
            XCTAssertFalse(FileClassifier.isFormattingOnly(path: "x.\(ext)", oldContent: "return\nvalue", newContent: "return value"), ext)
            XCTAssertFalse(FileClassifier.isFormattingOnly(path: "x.\(ext)", oldContent: "a + + b", newContent: "a ++ b"), ext)
            XCTAssertFalse(FileClassifier.isFormattingOnly(path: "x.\(ext)", oldContent: "let name = 1", newContent: "letname = 1"), ext)
        }
        for (path, old, new) in [
            ("x.py", "  work()", "    work()"),
            ("x.tsx", "<div>a b</div>", "<div>ab</div>"),
            ("x.js", "const x = `a b`", "const x = `ab`"),
            ("x.kt", "val s = \"\"\"a b\"\"\"", "val s = \"\"\"ab\"\"\""),
            ("x.rs", "let s = r#\"a b\"#;", "let s = r#\"ab\"#;"),
            ("x.js", "let re = /a b/;", "let re = /ab/;"),
            ("x.go", "//go:build linux\nx()", " //go:build linux\nx()"),
            ("x.java", "/* comment */\n x()", "/* comment */\n  x()")
        ] {
            XCTAssertFalse(FileClassifier.isFormattingOnly(path: path, oldContent: old, newContent: new), path)
        }
        XCTAssertTrue(FileClassifier.isFormattingOnly(path: "x.kt", oldContent: "val s = \"a b\" // exact comment", newContent: "val s=\"a b\"  // exact comment"))
    }
}
