import Foundation

enum SidebarFileNames {
    static func labels(for paths: [String]) -> [String: String] {
        let components = Dictionary(uniqueKeysWithValues: paths.map { ($0, $0.split(separator: "/").map(String.init)) })
        var labels: [String: String] = [:]
        for group in Dictionary(grouping: paths, by: { components[$0]!.last! }).values {
            guard group.count > 1 else {
                labels[group[0]] = components[group[0]]!.last!
                continue
            }
            // Reversed-path neighbours determine the longest shared suffix without
            // comparing every pair in a large group of identical filenames.
            let sorted = group.sorted { components[$0]!.reversed().lexicographicallyPrecedes(components[$1]!.reversed()) }
            var starts: [String: Int] = [:]
            var ends: [String: Int] = [:]
            for (index, path) in sorted.enumerated() {
                let parts = components[path]!
                var shared = 1
                for neighbour in [index - 1, index + 1] where sorted.indices.contains(neighbour) {
                    let common = zip(parts.reversed(), components[sorted[neighbour]]!.reversed())
                        .prefix(while: { $0 == $1 }).count
                    shared = max(shared, common)
                }
                let directory = max(0, parts.count - shared - 1)
                starts[path] = directory
                ends[path] = directory
            }
            func label(_ path: String) -> String {
                let parts = components[path]!
                let start = starts[path]!, end = ends[path]!
                if end >= parts.count - 1 { return parts.last! }
                let prefix = parts[start...end].joined(separator: "/")
                return prefix + (end < parts.count - 2 ? "/…/" : "/") + parts.last!
            }
            // Different suffix groups can choose the same directory name. Keep
            // enough parents to distinguish those collapsed labels too.
            while true {
                let collisions = Dictionary(grouping: sorted, by: label).values.filter { $0.count > 1 }
                var advanced = false
                for collision in collisions {
                    for path in collision {
                        if starts[path]! > 0 {
                            starts[path]! -= 1
                            advanced = true
                        } else if ends[path]! < components[path]!.count - 2 {
                            ends[path]! += 1
                            advanced = true
                        }
                    }
                }
                if !advanced { break }
            }
            for path in sorted { labels[path] = label(path) }
        }
        return labels
    }
}
