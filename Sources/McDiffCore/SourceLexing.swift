import Foundation

/// Full-source lexical context shared by import folding and ignore classification.
/// Ambiguous syntax still permits import folding, but never whitespace auto-review.
struct SourceLexing {
    let lines: [String]
    let importSafe: [Bool]
    let normalized: [String]?

    init(_ source: String, ext: String) {
        lines = source.components(separatedBy: "\n")
        var safeLines: [Bool] = [], normalizedLines: [String] = []
        var delimiter: String?, quote: Character?
        var blockDepth = 0, escaped = false, certain = true, rawDelimiter = false
        var safeForImports = true, braceInterpolation = false
        let python = ["py", "pyi"].contains(ext)
        let javascript = ["js", "jsx", "ts", "tsx", "mjs", "cjs"].contains(ext)
        for (lineIndex, text) in lines.enumerated() {
            var safe = delimiter == nil && quote == nil
            var output = "", index = text.startIndex
            func ambiguousInterpolation(_ rest: Substring, opening: Int, closing: Character) -> Bool {
                let expression = rest.dropFirst(opening).prefix { $0 != closing }
                return !rest.dropFirst(opening).contains(closing) ||
                    expression.contains { $0 == "\"" || $0 == "'" || $0 == "`" }
            }
            func pythonStringPrefix() -> Bool {
                let prefix = text[..<index].suffix(2).lowercased()
                return prefix.hasSuffix("f") || prefix == "fr"
            }
            func advance(_ count: Int, preserving: Bool) {
                let end = text.index(index, offsetBy: count)
                for character in text[index..<end] where preserving || !character.isWhitespace {
                    output.append(character)
                }
                index = end
            }
            while index < text.endIndex {
                let rest = text[index...], character = text[index]
                if let active = delimiter {
                    safe = false
                    let comment = active == "*/"
                    if ((active == "`" && javascript) || (rawDelimiter && ["kt", "kts"].contains(ext))) &&
                        rest.hasPrefix("${") && !escaped &&
                        ambiguousInterpolation(rest, opening: 2, closing: "}") {
                        certain = false; safeForImports = false
                    }
                    if braceInterpolation && character == "{" &&
                        ambiguousInterpolation(rest, opening: 1, closing: "}") {
                        certain = false; safeForImports = false
                    }
                    if comment && rest.hasPrefix("/*") {
                        blockDepth += 1
                        advance(2, preserving: false)
                    } else if rest.hasPrefix(active) && !escaped {
                        if comment { blockDepth -= 1 }
                        if blockDepth == 0 { delimiter = nil }
                        advance(active.count, preserving: !comment)
                        escaped = false
                    } else {
                        escaped = !comment && !rawDelimiter && !(active == "`" && ext == "go") &&
                            !active.hasSuffix("#") && character == "\\" && !escaped
                        advance(1, preserving: !comment)
                    }
                } else if let active = quote {
                    if ["kt", "kts"].contains(ext) && rest.hasPrefix("${") && !escaped &&
                        ambiguousInterpolation(rest, opening: 2, closing: "}") {
                        certain = false; safeForImports = false
                    }
                    if ext == "swift" && rest.hasPrefix("\\(") && !escaped &&
                        ambiguousInterpolation(rest, opening: 2, closing: ")") {
                        certain = false; safeForImports = false
                    }
                    if braceInterpolation && character == "{" &&
                        ambiguousInterpolation(rest, opening: 1, closing: "}") {
                        certain = false; safeForImports = false
                    }
                    if character == active && !escaped { quote = nil }
                    escaped = character == "\\" && !escaped
                    advance(1, preserving: true)
                } else if (rest.hasPrefix("//") && !python) || (python && character == "#") {
                    safe = false
                    advance(rest.count, preserving: false)
                } else if rest.hasPrefix("/*") && !python {
                    safe = false; delimiter = "*/"; blockDepth = 1
                    advance(2, preserving: false)
                } else if rest.hasPrefix("\"\"\"") || (python && rest.hasPrefix("'''")) || character == "`" {
                    safe = false
                    delimiter = character == "`" ? "`" : String(repeating: character, count: 3)
                    rawDelimiter = ["kt", "kts"].contains(ext)
                    braceInterpolation = (python && pythonStringPrefix()) ||
                        (ext == "cs" && text[..<index].suffix(2).contains("$"))
                    advance(delimiter!.count, preserving: true)
                } else if ext == "rs" && character == "r" &&
                            rest.range(of: #"^r#*""#, options: .regularExpression) != nil {
                    let opening = String(rest.prefix { $0 != "\"" }) + "\""
                    delimiter = "\"" + String(opening.dropFirst().dropLast())
                    rawDelimiter = true
                    safe = false
                    advance(opening.count, preserving: true)
                } else if ["c", "h", "cpp", "hpp"].contains(ext) && rest.hasPrefix("R\""),
                          let openingRange = rest.range(of: #"^R"[^\s()\\]{0,16}\("#, options: .regularExpression) {
                    let opening = String(rest[openingRange])
                    delimiter = ")" + String(opening.dropFirst(2).dropLast()) + "\""
                    rawDelimiter = true
                    safe = false
                    advance(opening.count, preserving: true)
                } else {
                    // Regex/JSX and Swift/C# raw strings need richer
                    // grammars. Keep their whitespace changes reviewable.
                    if (javascript && character == "/") ||
                        (["jsx", "tsx"].contains(ext) && character == "<") ||
                        (ext == "swift" && character == "#") ||
                        (ext == "cs" && character == "@") {
                        certain = false
                    }
                    if ext == "rs" && character == "'" {
                        let tail = rest.dropFirst()
                        let identifier = tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                        if !identifier.isEmpty && !tail.dropFirst(identifier.count).hasPrefix("'") {
                            advance(1, preserving: true)
                            continue
                        }
                    }
                    if character == "\"" || character == "'" {
                        braceInterpolation = (python && pythonStringPrefix()) ||
                            (ext == "cs" && text[..<index].suffix(2).contains("$"))
                        quote = character
                    }
                    advance(1, preserving: quote != nil)
                }
            }
            if quote != nil { safe = false }
            if lineIndex < lines.count - 1 && (quote != nil || (delimiter != nil && delimiter != "*/")) {
                output.append("\n")
            }
            escaped = false
            safeLines.append(safe && safeForImports)
            normalizedLines.append(output)
        }
        importSafe = safeLines
        normalized = certain && delimiter == nil && quote == nil ? normalizedLines : nil
    }
}
