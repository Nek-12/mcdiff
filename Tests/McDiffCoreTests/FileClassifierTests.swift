import XCTest
@testable import McDiffCore

final class FileClassifierTests: XCTestCase {
    func testMetaFilterControlsRemovalsAndMetadataWithoutHidingEditedRenames() {
        let deletion = DiffLine(kind: .deletion, text: "removed", oldNumber: 1, newNumber: nil)
        let addition = DiffLine(kind: .addition, text: "replacement", oldNumber: nil, newNumber: 1)
        for (status, lines, metadata) in [
            ("D", [DiffLine](), false),
            ("M", [deletion], false),
            ("R", [DiffLine](), true),
            ("C", [DiffLine](), true),
            ("M", [DiffLine](), true),
            ("R", [deletion], true)
        ] {
            let file = FileDiff(path: "source.swift", status: status,
                                hunks: [.init(header: "", lines: lines)], fingerprint: status,
                                hasMetadataChanges: metadata)
            XCTAssertEqual(ReviewFilters().skipReason(for: file), "Meta changes", status)
            XCTAssertNil(ReviewFilters(metaChanges: false).skipReason(for: file), status)
        }
        for status in ["R", "C", "M"] {
            for lines in [[addition], [deletion, addition]] {
                let file = FileDiff(path: "source.swift", status: status,
                                    hunks: [.init(header: "", lines: lines)], fingerprint: status,
                                    hasMetadataChanges: true)
                XCTAssertNil(ReviewFilters().skipReason(for: file), status)
            }
        }
        let binary = FileDiff(path: "binary", status: "D", hunks: [], isBinary: true, fingerprint: "binary")
        XCTAssertEqual(ReviewFilters(metaChanges: false).skipReason(for: binary), "Binary file")
        let test = FileDiff(path: "Tests/deleted.swift", status: "D", hunks: [],
                            fingerprint: "test", category: .tests)
        XCTAssertEqual(ReviewFilters(metaChanges: false).skipReason(for: test), "Tests")
        XCTAssertNil(ReviewFilters(tests: false, metaChanges: false).skipReason(for: test))
    }

    func testSavedFiltersPreserveExclusionFlagsAndDefaultToSkippingMetaChanges() throws {
        for tests in [false, true] {
            for documentation in [false, true] {
                for generated in [false, true] {
                    for whitespaceAndImports in [false, true] {
                        let legacy = """
                        {"tests":\(tests),"documentation":\(documentation),"generated":\(generated),"whitespaceAndImports":\(whitespaceAndImports)}
                        """
                        let saved = try JSONDecoder().decode(ReviewFilters.self, from: Data(legacy.utf8))
                        XCTAssertEqual(saved.tests, tests)
                        XCTAssertEqual(saved.documentation, documentation)
                        XCTAssertEqual(saved.generated, generated)
                        XCTAssertEqual(saved.whitespaceAndImports, whitespaceAndImports)
                        XCTAssertTrue(saved.metaChanges)
                        for metaChanges in [false, true] {
                            var updated = saved
                            updated.metaChanges = metaChanges
                            let restored = try JSONDecoder().decode(ReviewFilters.self, from: JSONEncoder().encode(updated))
                            XCTAssertEqual(restored.tests, tests)
                            XCTAssertEqual(restored.documentation, documentation)
                            XCTAssertEqual(restored.generated, generated)
                            XCTAssertEqual(restored.whitespaceAndImports, whitespaceAndImports)
                            XCTAssertEqual(restored.metaChanges, metaChanges)
                        }
                    }
                }
            }
        }
    }

    func testPythonIndentationAndImportsCanBeIgnoredTogether() {
        XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.py",
            oldContent: "import old\nif True:\n print('yes')\n",
            newContent: "import new\nif True:\n    print('yes')\n"))
    }

    func testRawAndMultilineLiteralWhitespaceIsNeverIgnored() {
        for (path, source) in [
            ("x.go", "var text = `a \\\n b \" c`\n"),
            ("x.kt", "val text = \"\"\"\na b\nimport misleading.name\n\"\"\"\n"),
            ("x.py", "text = '''\na b\nimport misleading\n'''\n"),
            ("x.js", "const text = `a b ${value}`;\n"),
            ("x.rs", "let text = r##\"a b \" quoted\"##;\n"),
            ("x.cpp", "auto text = R\"tag(a b \" quoted)tag\";\n")
        ] {
            XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: path,
                oldContent: source, newContent: source.replacingOccurrences(of: "a b", with: "ab")), path)
        }
        XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: "x.go",
            oldContent: "var text = `a \\\n b \" c`\n",
            newContent: "var text = `a \\\n  b \" c`\n"))
        XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: "x.kt",
            oldContent: "val text = \"\"\"\nimport old\n\"\"\"\n",
            newContent: "val text = \"\"\"\nimport new\n\"\"\"\n"))
        XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: "x.cpp",
            oldContent: "auto text = R\"tag(before \"two words\" after)tag\";\n",
            newContent: "auto text = R\"tag(before \"twowords\" after)tag\";\n"))
    }

    func testLiteralBytesAndNestedInterpolationCannotBecomeIgnoredWhitespace() {
        for (path, old, new) in [
            ("x.kt", "val text = \"é\"\n", "val text=\"e\u{301}\"\n"),
            ("x.kt", #"val text = "before ${lookup("two words")} after""#,
             #"val text = "before ${lookup("twowords")} after""#),
            ("x.swift", #"let text = "before \(lookup("two words")) after""#,
             #"let text = "before \(lookup("twowords")) after""#),
            ("x.py", #"text = f"before {lookup("two words")} after""#,
             #"text = f"before {lookup("twowords")} after""#),
            ("x.js", "const text = `before ${lookup(`two words`)} after`;",
             "const text = `before ${lookup(`twowords`)} after`;"),
            ("x.cs", #"var text = $"before {lookup("two words")} after";"#,
             #"var text = $"before {lookup("twowords")} after";"#),
            ("x.cs", #"var text = @"before ""two words"" after";"#,
             #"var text = @"before ""twowords"" after";"#)
        ] {
            XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: path, oldContent: old, newContent: new), path)
        }
    }

    func testWholeFileIgnoresImportRunsButKeepsEveryOtherChangeReviewable() {
        let cases = [
            ("x.kt", "package old\nimport a.One\n\nimport b.Two\nval value = 1\n",
             "package new\nimport b.Two\nimport c.Three\n\nimport a.One\nval value=1\n"),
            ("x.java", "package old;\nimport a.One;\nclass Main {}\n",
             "package new;\nimport static a.Two;\nclass Main { }\n"),
            ("x.go", "package old\nimport (\n \"fmt\"\n \"net/http\"\n)\nvar value = 1\n",
             "package new\nimport (\n \"os\"\n)\nvar    value=1\n"),
            ("x.ts", "import {\n one,\n two\n} from 'old';\nconst value = 1;\n",
             "import {\n three\n} from 'new';\nconst value=1;\n"),
            ("x.rs", "use old::{\n One,\n Two\n};\nfn run() {}\n",
             "use new::{\n Three\n};\nfn run( ) { }\n"),
            ("x.py", "from old import (\n one,\n two,\n)\nvalue = 1\n",
             "from new import (\n three,\n)\nvalue=1\n"),
            ("x.kt", "import a.One as Before\nval value = 1\n",
             "import\tb.Two  as  After\nval value=1\n"),
            ("x.go", "import \"fmt\"\nvar value = 1\n", "import\t\"os\"\nvar value=1\n"),
            ("x.rs", "use old::One;\nfn run() {}\n", "pub\tuse new::Two;\nfn run() { }\n")
        ]
        for (path, old, new) in cases {
            XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: path, oldContent: old, newContent: new), path)
            XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: path,
                oldContent: old, newContent: new + "actualCodeChange()\n"), path)
        }
        XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.kt",
            oldContent: "val value = 1\n", newContent: "import example.Value\nval value = 1\n"))
        XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.kt",
            oldContent: "import example.Value\nval value = 1\n", newContent: "val value = 1\n"))
        XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: "x.kt",
            oldContent: "import example.Value\n// important\nval value = 1\n",
            newContent: "import example.Other\n// changed\nval value = 1\n"))
    }

    func testIgnoreFilterIsOptionalAndFallsThroughToOtherCategories() throws {
        let source = FileDiff(path: "x.go", status: "M", hunks: [
            .init(header: "", lines: [.init(kind: .addition, text: "package new", oldNumber: nil, newNumber: 1)])
        ], fingerprint: "source", isWhitespaceAndImportsOnly: true)
        XCTAssertNil(ReviewFilters().skipReason(for: source))
        XCTAssertEqual(ReviewFilters(whitespaceAndImports: true).skipReason(for: source), "Whitespace / imports")
        let test = FileDiff(path: "x_test.go", status: "M", hunks: source.hunks, fingerprint: "test",
                            category: .tests, isWhitespaceAndImportsOnly: true)
        XCTAssertEqual(ReviewFilters(whitespaceAndImports: false).skipReason(for: test), "Tests")
        XCTAssertNil(ReviewFilters(tests: false, whitespaceAndImports: false).skipReason(for: test))
        let saved = try JSONDecoder().decode(ReviewFilters.self,
            from: Data(#"{"tests":false,"documentation":false,"generated":false}"#.utf8))
        XCTAssertFalse(saved.whitespaceAndImports)
        XCTAssertFalse(saved.tests)
        let toggled = ReviewFilters(whitespaceAndImports: false)
        XCTAssertFalse(try JSONDecoder().decode(ReviewFilters.self,
            from: JSONEncoder().encode(toggled)).whitespaceAndImports)
        for ignore in [false, true] {
            let persisted = try JSONDecoder().decode(ReviewFilters.self,
                from: Data("""
                {"tests":true,"documentation":true,"generated":true,"whitespaceAndImports":\(ignore)}
                """.utf8))
            XCTAssertEqual(persisted.whitespaceAndImports, ignore)
            XCTAssertEqual(persisted.skipReason(for: source), ignore ? "Whitespace / imports" : nil)
        }
    }
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

    func testFullSourceIgnorePreservesLiteralsButIgnoresAllOtherWhitespace() {
        for ext in ["kt", "java", "go", "ts", "js", "rs"] {
            XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.\(ext)", oldContent: "let x = 1;\n    work(x);", newContent: "let x=1;\n  work( x );"), ext)
            XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: "x.\(ext)", oldContent: "let x = \"a b\";", newContent: "let x = \"ab\";"), ext)
            XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.\(ext)", oldContent: "return\nvalue", newContent: "return value"), ext)
            XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.\(ext)", oldContent: "a + + b", newContent: "a ++ b"), ext)
            XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.\(ext)", oldContent: "let name = 1", newContent: "letname = 1"), ext)
        }
        for (path, old, new) in [
            ("x.tsx", "<div>a b</div>", "<div>ab</div>"),
            ("x.js", "const x = `a b`", "const x = `ab`"),
            ("x.kt", "val s = \"\"\"a b\"\"\"", "val s = \"\"\"ab\"\"\""),
            ("x.rs", "let s = r#\"a b\"#;", "let s = r#\"ab\"#;"),
            ("x.js", "let re = /a b/;", "let re = /ab/;"),
        ] {
            XCTAssertFalse(FileClassifier.isWhitespaceAndImportsOnly(path: path, oldContent: old, newContent: new), path)
        }
        XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.kt", oldContent: "val s = \"a b\" // exact comment", newContent: "val s=\"a b\"  // exact comment"))
        XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.java", oldContent: "/* comment */\n x()", newContent: "/* comment */\n  x()"))
        XCTAssertTrue(FileClassifier.isWhitespaceAndImportsOnly(path: "x.go", oldContent: "//go:build linux\nx()", newContent: " //go:build linux\nx()"))
    }
}
