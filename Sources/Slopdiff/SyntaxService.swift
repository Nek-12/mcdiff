import AppKit
import Highlightr
import SlopdiffCore

struct HighlightedFile {
    let old: [Int: NSAttributedString]
    let new: [Int: NSAttributedString]
    var cost: Int { (old.values.reduce(0) { $0 + $1.length } + new.values.reduce(0) { $0 + $1.length }) * 24 }
}

/// The highlighter and its JavaScript VM belong to this actor, never the scrolling thread.
actor SyntaxService {
    static let pageSize = 256
    private let highlighter = Highlightr()
    static func language(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return [
            "kt": "kotlin", "kts": "kotlin", "java": "java", "go": "go", "ts": "typescript",
            "tsx": "typescript", "js": "javascript", "jsx": "javascript", "mjs": "javascript",
            "rs": "rust", "py": "python", "pyi": "python", "swift": "swift", "c": "c",
            "h": "cpp", "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "cs": "csharp",
            "rb": "ruby", "php": "php", "sh": "bash", "zsh": "bash", "bash": "bash",
            "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini",
            "xml": "xml", "html": "xml", "svg": "xml", "css": "css", "scss": "scss",
            "md": "markdown", "markdown": "markdown", "sql": "sql", "dart": "dart",
            "ex": "elixir", "exs": "elixir", "lua": "lua", "r": "r", "scala": "scala",
            "vue": "xml", "svelte": "xml", "proto": "protobuf"
        ][ext] ?? ((path as NSString).lastPathComponent.lowercased() == "dockerfile" ? "dockerfile" : nil)
    }
    func highlight(file: FileDiff, dark: Bool, page: Int = 0) throws -> HighlightedFile {
        guard let language = Self.language(for: file.path) else { return HighlightedFile(old: [:], new: [:]) }
        guard let highlighter else { throw SyntaxError.unavailable }
        highlighter.setTheme(to: dark ? "atom-one-dark" : "atom-one-light")
        highlighter.ignoreIllegals = true
        var old = [Int: NSAttributedString](), new = [Int: NSAttributedString]()
        let firstLine = page * Self.pageSize + 1
        let lastLine = firstLine + Self.pageSize - 1
        for hunk in file.hunks {
            try Task.checkCancellation()
            for side in [DiffSide.old, .new] {
                let lines = hunk.lines.filter {
                    guard let number = side == .old ? $0.oldNumber : $0.newNumber else { return false }
                    return (firstLine...lastLine).contains(number)
                }
                for offset in stride(from: 0, to: lines.count, by: Self.pageSize) {
                    try Task.checkCancellation()
                    let chunk = Array(lines[offset..<min(offset + Self.pageSize, lines.count)])
                    let text = chunk.map { $0.text.replacingOccurrences(of: "\t", with: "    ") }.joined(separator: "\n")
                    guard text.utf8.count < 500_000 else { continue }
                    guard let rich = highlighter.highlight(text, as: language) else { throw SyntaxError.failed(file.path) }
                    // Never use highlighter output that changes the source text or line mapping.
                    guard rich.string == text else { throw SyntaxError.failed(file.path) }
                    var location = 0
                    for line in chunk {
                        let count = (line.text.replacingOccurrences(of: "\t", with: "    ") as NSString).length
                        let part = NSMutableAttributedString(attributedString: rich.attributedSubstring(from: NSRange(location: location, length: count)))
                        part.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: part.length))
                        part.addAttribute(.font, value: Style.codeFont, range: NSRange(location: 0, length: part.length))
                        if side == .old { old[line.oldNumber!] = part } else { new[line.newNumber!] = part }
                        location += count + 1
                    }
                }
            }
        }
        return HighlightedFile(old: old, new: new)
    }
    enum SyntaxError: LocalizedError {
        case unavailable, failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The syntax highlighter could not start."
            case .failed(let path): return "Syntax highlighting failed for \(path). The original source is shown."
            }
        }
    }
}
