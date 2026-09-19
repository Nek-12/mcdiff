import Foundation

public enum FileClassifier {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public static func classify(_ path: String) -> FileCategory {
        let lower = path.lowercased()
        let parts = lower.split(separator: "/").map(String.init)
        let name = parts.last ?? lower
        let originalName = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if markdownExtensions.contains(ext) || ext == "mdx" { return .documentation }
        let generatedNames: Set<String> = [
            "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
            "bun.lock", "bun.lockb", "cargo.lock", "gemfile.lock", "poetry.lock", "uv.lock",
            "pipfile.lock", "composer.lock", "go.sum", "packages.lock.json", "pubspec.lock",
            "podfile.lock", "package.resolved", "requirements.txt", "version.json",
            "project.pbxproj", "contents.xcworkspacedata", ".ds_store", "gradle.lockfile", "go.work.sum"
        ]
        if generatedNames.contains(name) || ext == "lock" ||
            ["generated", "__generated__", "node_modules", "vendor", "dist", "build", ".gradle", ".idea"].contains(where: parts.contains) ||
            name.hasSuffix(".min.js") || name.hasSuffix(".min.css") || name.hasSuffix(".map") ||
            name.hasSuffix(".generated.swift") || name.hasSuffix(".g.dart") ||
            name.hasSuffix(".pb.go") || name.hasSuffix("_pb2.py") ||
            parts.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return .generated
        }
        if ["test", "tests", "__tests__", "__snapshots__", "spec", "specs", "testdata", "fixtures", "testfixtures",
            "androidtest", "commontest", "jvmtest", "integrationtest", "integrationtests", "e2e", "cypress"].contains(where: parts.contains) ||
            name.hasPrefix("test_") || name.hasSuffix("_test.go") ||
            name.contains(".test.") || name.contains(".tests.") || name.contains(".spec.") ||
            name.hasSuffix("_test.py") || name.hasSuffix("_spec.rb") ||
            ["Test.kt", "Tests.kt", "Test.java", "Tests.java", "Tests.swift", "Test.swift", "Tests.cs"].contains(where: originalName.hasSuffix) {
            return .tests
        }
        if ["docs", "doc", "documentation"].contains(where: parts.contains) ||
            ["rst", "adoc", "pdf", "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "icns", "mp3", "mp4", "wav", "ogg", "mov", "webm", "woff", "woff2", "ttf", "otf",
             "json", "jsonc", "yaml", "yml", "toml", "ini", "conf", "config", "properties", "xml", "plist", "csv", "tsv", "env", "editorconfig"].contains(ext) ||
            [".gitignore", ".gitattributes", ".editorconfig", ".npmrc", ".nvmrc", ".env"].contains(name) ||
            ["readme", "license", "licence", "copying", "notice", "changelog", "authors"].contains(where: name.hasPrefix) {
            return .documentation
        }
        return .production
    }

    public static func supportsFormattingComparison(path: String) -> Bool {
        ["kt", "kts", "java", "go", "ts", "js", "mjs", "cjs", "rs", "json"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Requires complete source on both sides: a hunk may begin inside a literal.
    public static func isFormattingOnly(path: String, oldContent: String, newContent: String) -> Bool {
        guard supportsFormattingComparison(path: path), oldContent != newContent else { return false }
        func tokens(_ source: String) -> [[String]]? {
            // These constructs need language-specific, potentially nested lexical
            // state. Uncertain files stay visible instead of being auto-reviewed.
            guard !["\"\"\"", "'''", "`", "/*", "*/"].contains(where: source.contains) else { return nil }
            var result: [[String]] = []
            for line in source.components(separatedBy: "\n") {
                let chars = Array(line)
                var row: [String] = [], i = 0
                while i < chars.count {
                    let c = chars[i]
                    if c == " " || c == "\t" { i += 1; continue }
                    if c == "\"" || c == "'" {
                        // Rust raw/byte string prefixes require a different lexer.
                        if i > 0 && (chars[i - 1] == "r" || chars[i - 1] == "b") { return nil }
                        let start = i
                        i += 1
                        var closed = false
                        while i < chars.count {
                            if chars[i] == "\\" { i += 2; continue }
                            if chars[i] == c { i += 1; closed = true; break }
                            i += 1
                        }
                        guard closed, i <= chars.count else { return nil }
                        row.append(String(chars[start..<i]))
                    } else if c == "/" {
                        if i + 1 < chars.count && chars[i + 1] == "/" {
                            // A standalone Go //line or //go directive can depend
                            // on its column; preserve the entire comment line.
                            row.append(row.isEmpty ? line : String(chars[i...])); i = chars.count
                        } else {
                            // JavaScript regex literals make slash ambiguous.
                            return nil
                        }
                    } else if c == "\\" || c == "#" {
                        return nil
                    } else {
                        func word(_ c: Character) -> Bool {
                            c.isLetter || c.isNumber || c == "_" || c == "$" ||
                                c.unicodeScalars.allSatisfy { CharacterSet.nonBaseCharacters.contains($0) }
                        }
                        let operators = "=<>!&|+-*%^~?:."
                        let start = i
                        i += 1
                        if word(c) {
                            while i < chars.count && word(chars[i]) { i += 1 }
                        } else if operators.contains(c) {
                            while i < chars.count && operators.contains(chars[i]) { i += 1 }
                        }
                        row.append(String(chars[start..<i]))
                    }
                }
                result.append(row)
            }
            return result
        }
        guard let old = tokens(oldContent), let new = tokens(newContent) else { return false }
        return old == new
    }

    // JSON has no multiline strings and insignificant whitespace outside strings.
    // Other languages require full-file lexical context to make this decision safely.
    static func isFormattingOnly(path: String, hunks: [DiffHunk], metadataChanged: Bool) -> Bool {
        guard !metadataChanged, (path as NSString).pathExtension.lowercased() == "json",
              hunks.contains(where: { $0.lines.contains { $0.kind != .context } }) else { return false }
        func tokens(_ lines: [DiffLine], excluding kind: LineKind) -> String? {
            var result = "", quoted = false, escaped = false
            for line in lines where line.kind != kind {
                for c in line.text {
                    if quoted {
                        result.append(c)
                        if escaped { escaped = false }
                        else if c == "\\" { escaped = true }
                        else if c == "\"" { quoted = false }
                    } else if c == "\"" {
                        quoted = true; result.append(c)
                    } else if !c.isWhitespace { result.append(c) }
                }
                if quoted { return nil }
            }
            return result
        }
        return hunks.allSatisfy {
            guard let old = tokens($0.lines, excluding: .addition),
                  let new = tokens($0.lines, excluding: .deletion) else { return false }
            return old == new
        }
    }
}
