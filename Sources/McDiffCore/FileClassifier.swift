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

    public static func supportsWhitespaceAndImportsComparison(path: String) -> Bool {
        ["kt", "kts", "java", "go", "ts", "tsx", "js", "jsx", "mjs", "cjs", "rs",
         "py", "pyi", "swift", "c", "h", "cpp", "hpp", "cs", "proto", "json", "jsonc"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    /// Requires complete source on both sides: a hunk may begin inside a literal.
    public static func isWhitespaceAndImportsOnly(path: String, oldContent: String, newContent: String) -> Bool {
        guard supportsWhitespaceAndImportsComparison(path: path), oldContent != newContent else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        let old = SourceLexing(oldContent, ext: ext), new = SourceLexing(newContent, ext: ext)
        return isWhitespaceAndImportsOnly(old: old, new: new, oldExtension: ext, newExtension: ext)
    }

    static func ignoredChanges(file: FileDiff, oldContent: String, newContent: String)
        -> (wholeFile: Bool, lines: [WhitespaceChange]) {
        let oldExtension = (file.oldPath as NSString).pathExtension.lowercased()
        let newExtension = (file.path as NSString).pathExtension.lowercased()
        let old = SourceLexing(oldContent, ext: oldExtension), new = SourceLexing(newContent, ext: newExtension)
        let wholeFile = file.status == "M" && !file.hasMetadataChanges &&
            isWhitespaceAndImportsOnly(old: old, new: new, oldExtension: oldExtension, newExtension: newExtension)
        guard let oldNormalized = old.normalized, let newNormalized = new.normalized else { return (wholeFile, []) }
        var changes: [WhitespaceChange] = []
        for hunk in file.hunks {
            changes += whitespaceMatches(old: hunk.lines.filter { $0.kind != .addition },
                                          new: hunk.lines.filter { $0.kind != .deletion },
                                          oldNormalized: oldNormalized, newNormalized: newNormalized)
        }
        return (wholeFile, changes)
    }

    private static func isWhitespaceAndImportsOnly(old: SourceLexing, new: SourceLexing,
                                                  oldExtension: String, newExtension: String) -> Bool {
        let oldImports = DiffPresentation.sourceImportNumbers(old, ext: oldExtension)
        let newImports = DiffPresentation.sourceImportNumbers(new, ext: newExtension)
        func remaining(_ lines: [String], imports: Set<Int>) -> [String] {
            lines.enumerated().compactMap { imports.contains($0.offset + 1) ? nil : $0.element }
        }
        if let oldNormalized = old.normalized, let newNormalized = new.normalized {
            return remaining(oldNormalized, imports: oldImports).joined().utf8.elementsEqual(
                remaining(newNormalized, imports: newImports).joined().utf8)
        }
        // Even an ambiguous regex/JSX construct does not prevent recognizing
        // imports-only changes when the rest of the source is byte-for-byte equal.
        return remaining(old.lines, imports: oldImports).joined(separator: "\n").utf8.elementsEqual(
            remaining(new.lines, imports: newImports).joined(separator: "\n").utf8)
    }

    /// Stable ordered anchors and equal gaps match repeated formatting lines
    /// without a quadratic edit matrix or interpreting moved code as whitespace.
    private static func whitespaceMatches(old: [DiffLine], new: [DiffLine],
                                          oldNormalized: [String], newNormalized: [String]) -> [WhitespaceChange] {
        func normalized(_ line: DiffLine, side: DiffSide) -> String? {
            guard let number = side == .old ? line.oldNumber : line.newNumber else { return nil }
            let source = side == .old ? oldNormalized : newNormalized
            guard number > 0, number <= source.count else { return nil }
            return source[number - 1]
        }
        func equivalent(_ lhs: DiffLine, _ rhs: DiffLine) -> Bool {
            guard let old = normalized(lhs, side: .old), let new = normalized(rhs, side: .new) else { return false }
            return old.utf8.elementsEqual(new.utf8)
        }
        let oldNonblank = old.filter { normalized($0, side: .old)?.isEmpty == false }
        let newNonblank = new.filter { normalized($0, side: .new)?.isEmpty == false }
        var oldPositions: [String: [Int]] = [:], newPositions: [String: [Int]] = [:]
        for (index, line) in oldNonblank.enumerated() {
            if let key = normalized(line, side: .old) { oldPositions[key, default: []].append(index) }
        }
        for (index, line) in newNonblank.enumerated() {
            if let key = normalized(line, side: .new) { newPositions[key, default: []].append(index) }
        }
        var result: [WhitespaceChange] = []
        for line in old where normalized(line, side: .old)?.isEmpty == true {
            result.append(.init(oldNumber: line.oldNumber, newNumber: nil))
        }
        for line in new where normalized(line, side: .new)?.isEmpty == true {
            result.append(.init(oldNumber: nil, newNumber: line.newNumber))
        }
        let sameInventory = oldPositions.mapValues { $0.count } == newPositions.mapValues { $0.count }
        let sameOrder = oldNonblank.count == newNonblank.count && zip(oldNonblank, newNonblank).allSatisfy {
            equivalent($0.0, $0.1)
        }
        if sameInventory && !sameOrder { return result }
        let newIndices = Dictionary(uniqueKeysWithValues: newNonblank.enumerated().compactMap { index, line -> (Int, Int)? in
            line.newNumber.map { ($0, index) }
        })
        var contextPrefix = Array(repeating: -1, count: oldNonblank.count + 1)
        var contextSuffix = Array(repeating: newNonblank.count, count: oldNonblank.count + 1)
        for (index, line) in oldNonblank.enumerated() {
            let counterpart = line.kind == .context ? line.newNumber.flatMap { newIndices[$0] } : nil
            contextPrefix[index + 1] = max(contextPrefix[index], counterpart ?? -1)
            contextSuffix[index] = counterpart ?? newNonblank.count
        }
        for index in oldNonblank.indices.reversed() {
            contextSuffix[index] = min(contextSuffix[index], contextSuffix[index + 1])
        }
        let candidates = newNonblank.enumerated().compactMap { index, line -> (old: Int, new: Int)? in
            guard let key = normalized(line, side: .new),
                  let positions = oldPositions[key], positions.count == 1, newPositions[key]?.count == 1,
                  index > contextPrefix[positions[0]], index < contextSuffix[positions[0] + 1],
                  let oldKey = normalized(oldNonblank[positions[0]], side: .old),
                  key.utf8.elementsEqual(oldKey.utf8) else { return nil }
            return (positions[0], index)
        }
        var suffixMinimum = Array(repeating: oldNonblank.count, count: candidates.count + 1)
        for index in candidates.indices.reversed() {
            suffixMinimum[index] = min(suffixMinimum[index + 1], candidates[index].old)
        }
        var prefixMaximum = -1, anchors: [(old: Int, new: Int)] = []
        for (index, anchor) in candidates.enumerated() {
            if anchor.old > prefixMaximum && anchor.old < suffixMinimum[index + 1] { anchors.append(anchor) }
            prefixMaximum = max(prefixMaximum, anchor.old)
        }
        func append(_ lhs: DiffLine, _ rhs: DiffLine) {
            let retargetedContext = (lhs.kind == .context && lhs.newNumber != rhs.newNumber) ||
                (rhs.kind == .context && rhs.oldNumber != lhs.oldNumber)
            if !lhs.text.utf8.elementsEqual(rhs.text.utf8) || retargetedContext {
                result.append(.init(oldNumber: lhs.oldNumber, newNumber: rhs.newNumber))
            }
        }
        var oldStart = 0, newStart = 0
        for anchor in anchors + [(oldNonblank.count, newNonblank.count)] {
            // Equal ordered prefixes/suffixes also cover repeated braces next
            // to a real insertion or edit, without choosing a moved occurrence.
            var left = oldStart, right = newStart
            while left < anchor.old && right < anchor.new &&
                    equivalent(oldNonblank[left], newNonblank[right]) {
                append(oldNonblank[left], newNonblank[right])
                left += 1; right += 1
            }
            var oldEnd = anchor.old, newEnd = anchor.new
            while oldEnd > left && newEnd > right &&
                    equivalent(oldNonblank[oldEnd - 1], newNonblank[newEnd - 1]) {
                oldEnd -= 1; newEnd -= 1
                append(oldNonblank[oldEnd], newNonblank[newEnd])
            }
            if anchor.old < oldNonblank.count && anchor.new < newNonblank.count {
                append(oldNonblank[anchor.old], newNonblank[anchor.new])
            }
            oldStart = anchor.old + 1; newStart = anchor.new + 1
        }
        return result
    }
}
