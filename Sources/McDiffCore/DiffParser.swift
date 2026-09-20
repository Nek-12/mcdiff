import Foundation
import CryptoKit

public enum DiffParseError: Error, LocalizedError {
    case malformed(line: Int, detail: String)
    public var errorDescription: String? {
        switch self { case let .malformed(line, detail): return "Invalid Git patch at line \(line): \(detail)" }
    }
}

public enum DiffParser {
    private static let hunkHeader = try! NSRegularExpression(pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@(?:.*)$"#)

    public static func parse(_ patch: String) throws -> [FileDiff] {
        if patch.isEmpty { return [] }
        var lines = patch.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var files: [FileDiff] = []
        var i = 0
        func fail(_ detail: String) -> DiffParseError { .malformed(line: i + 1, detail: detail) }
        while i < lines.count {
            guard lines[i].hasPrefix("diff --git ") else { throw fail("Expected a diff --git file header.") }
            let start = i
            let paths = try headerPaths(String(lines[i].dropFirst(11)), line: i + 1)
            var oldPath = paths.0, path = paths.1, status = "M"
            var binary = false, metadataChanged = false, hunks: [DiffHunk] = []
            i += 1
            while i < lines.count && !lines[i].hasPrefix("diff --git ") {
                let line = lines[i]
                if line.hasPrefix("@@ ") {
                    let ns = line as NSString
                    guard let match = hunkHeader.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { throw fail("Malformed hunk header.") }
                    func number(_ n: Int, default fallback: Int? = nil) throws -> Int {
                        let r = match.range(at: n)
                        if r.location == NSNotFound, let fallback { return fallback }
                        guard let value = Int(ns.substring(with: r)), value < Int.max / 2 else { throw fail("Invalid hunk range.") }
                        return value
                    }
                    var old = try number(1), new = try number(3)
                    var oldRemaining = try number(2, default: 1), newRemaining = try number(4, default: 1)
                    var content: [DiffLine] = []
                    i += 1
                    while i < lines.count {
                        let body = lines[i]
                        if body == "\\ No newline at end of file" {
                            guard !content.isEmpty else { throw fail("Newline marker without a preceding line.") }
                            metadataChanged = true
                            i += 1; continue
                        }
                        if oldRemaining == 0 && newRemaining == 0 { break }
                        guard let prefix = body.first, [" ", "+", "-"].contains(prefix) else { throw fail("Hunk ended before its declared line counts.") }
                        let kind: LineKind = prefix == "+" ? .addition : prefix == "-" ? .deletion : .context
                        guard (kind == .addition || oldRemaining > 0), (kind == .deletion || newRemaining > 0) else { throw fail("Hunk exceeds its declared line counts.") }
                        content.append(DiffLine(kind: kind, text: String(body.dropFirst()), oldNumber: kind == .addition ? nil : old, newNumber: kind == .deletion ? nil : new))
                        if kind != .addition { old += 1; oldRemaining -= 1 }
                        if kind != .deletion { new += 1; newRemaining -= 1 }
                        i += 1
                    }
                    guard oldRemaining == 0 && newRemaining == 0 else { throw fail("Truncated hunk.") }
                    hunks.append(DiffHunk(header: line, lines: content))
                    continue
                } else if line.hasPrefix("--- ") {
                    let value = try markerPath(String(line.dropFirst(4)), line: i + 1)
                    if value == "/dev/null" { status = "A"; metadataChanged = true } else { oldPath = stripPrefix(value) }
                } else if line.hasPrefix("+++ ") {
                    let value = try markerPath(String(line.dropFirst(4)), line: i + 1)
                    if value == "/dev/null" { status = "D"; metadataChanged = true } else { path = stripPrefix(value) }
                } else if line.hasPrefix("rename from ") || line.hasPrefix("copy from ") {
                    let prefix = line.hasPrefix("rename") ? "rename from " : "copy from "
                    oldPath = try markerPath(String(line.dropFirst(prefix.count)), line: i + 1)
                    status = line.hasPrefix("rename") ? "R" : "C"; metadataChanged = true
                } else if line.hasPrefix("rename to ") || line.hasPrefix("copy to ") {
                    let prefix = line.hasPrefix("rename") ? "rename to " : "copy to "
                    path = try markerPath(String(line.dropFirst(prefix.count)), line: i + 1)
                    status = line.hasPrefix("rename") ? "R" : "C"; metadataChanged = true
                } else if line.hasPrefix("new file mode ") {
                    status = "A"; metadataChanged = true
                } else if line.hasPrefix("deleted file mode ") {
                    status = "D"; metadataChanged = true
                } else if line.hasPrefix("old mode ") || line.hasPrefix("new mode ") {
                    metadataChanged = true
                } else if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
                    binary = true
                } else if line == "GIT binary patch" {
                    binary = true
                    // Binary payload is opaque; its complete bytes still participate in identity.
                    i += 1
                    while i < lines.count && !lines[i].hasPrefix("diff --git ") { i += 1 }
                    continue
                } else if line.hasPrefix("index ") || line.hasPrefix("similarity index ") || line.hasPrefix("dissimilarity index ") {
                    // Content identities and rename similarity are retained in the fingerprint.
                } else { throw fail("Unrecognized patch record: \(line.prefix(120))") }
                i += 1
            }
            guard i > start + 1 else { throw fail("File header has no patch records.") }
            guard !path.isEmpty, !oldPath.isEmpty else { throw fail("Empty file path.") }
            let raw = lines[start..<i].joined(separator: "\n")
            let fingerprint = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            files.append(FileDiff(path: path, oldPath: oldPath, status: status, hunks: hunks, isBinary: binary,
                                  fingerprint: fingerprint, category: FileClassifier.classify(path),
                                  isFormattingOnly: !binary && FileClassifier.isFormattingOnly(path: path, hunks: hunks, metadataChanged: metadataChanged),
                                  hasMetadataChanges: metadataChanged))
        }
        return files
    }

    private static func stripPrefix(_ path: String) -> String {
        path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
    }

    private static func markerPath(_ value: String, line: Int) throws -> String {
        if value.hasPrefix("\"") {
            let (path, rest) = try quoted(value, line: line)
            guard rest.isEmpty || rest.hasPrefix("\t") else { throw DiffParseError.malformed(line: line, detail: "Trailing quoted path data.") }
            return path
        }
        return String(value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    private static func headerPaths(_ value: String, line: Int) throws -> (String, String) {
        if value.hasPrefix("\"") {
            let (old, rest) = try quoted(value, line: line)
            guard rest.hasPrefix(" ") else { throw DiffParseError.malformed(line: line, detail: "Missing second path.") }
            return (stripPrefix(old), stripPrefix(try markerPath(String(rest.dropFirst()), line: line)))
        }
        // Git leaves spaces unquoted. Prefer the split with identical paths, then
        // use extended rename headers / --- +++ records to disambiguate renames.
        let separators = [" b/", " \"b/"]
        var candidates: [(String, String)] = []
        for separator in separators {
            var cursor = value.startIndex
            while let range = value.range(of: separator, range: cursor..<value.endIndex) {
                let old = stripPrefix(String(value[..<range.lowerBound]))
                let new = stripPrefix(try markerPath(String(value[value.index(after: range.lowerBound)...]), line: line))
                candidates.append((old, new))
                cursor = range.upperBound
            }
        }
        guard let pair = candidates.first(where: { $0.0 == $0.1 }) ?? candidates.first else {
            throw DiffParseError.malformed(line: line, detail: "Cannot read file paths.")
        }
        return pair
    }

    private static func quoted(_ value: String, line: Int) throws -> (String, String) {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = [], i = 1
        while i < bytes.count {
            let b = bytes[i]; i += 1
            if b == 34 {
                guard let path = String(bytes: decoded, encoding: .utf8) else { throw DiffParseError.malformed(line: line, detail: "Path is not valid UTF-8.") }
                return (path, String(decoding: bytes[i...], as: UTF8.self))
            }
            if b != 92 { decoded.append(b); continue }
            guard i < bytes.count else { break }
            let escaped = bytes[i]; i += 1
            let escapes: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 92: 92, 34: 34]
            if let replacement = escapes[escaped] { decoded.append(replacement) }
            else if (48...55).contains(escaped) {
                var number = Int(escaped - 48), count = 1
                while count < 3 && i < bytes.count && (48...55).contains(bytes[i]) {
                    number = number * 8 + Int(bytes[i] - 48); i += 1; count += 1
                }
                guard number <= 255 else { throw DiffParseError.malformed(line: line, detail: "Invalid octal path escape.") }
                decoded.append(UInt8(number))
            } else { throw DiffParseError.malformed(line: line, detail: "Unknown path escape.") }
        }
        throw DiffParseError.malformed(line: line, detail: "Unterminated quoted path.")
    }
}
