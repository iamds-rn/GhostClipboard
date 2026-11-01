import Foundation

/// Thread-safe pre-compiled NSRegularExpression cache so classification, secret detection,
/// developer actions, and syntax highlighting never re-compile regexes on each clipboard event or render.
public final class RegexCache: @unchecked Sendable {
    public static let shared = RegexCache()

    private let lock = NSLock()
    private var storage: [String: NSRegularExpression] = [:]
    private var hits: Int = 0
    private var misses: Int = 0

    public init(prewarm: Bool = true) {
        if prewarm {
            prewarmCommonPatterns()
        }
    }

    public func regex(for pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = options.rawValue == 0 ? pattern : "\(options.rawValue):\(pattern)"
        lock.lock()
        if let existing = storage[key] {
            hits += 1
            lock.unlock()
            return existing
        }
        misses += 1
        lock.unlock()

        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        lock.lock()
        storage[key] = compiled
        lock.unlock()
        return compiled
    }

    public func matches(_ text: String, pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = regex(for: pattern, options: options) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    public func firstMatchGroups(_ text: String, pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = regex(for: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        var results: [String] = []
        results.reserveCapacity(match.numberOfRanges)
        for idx in 0..<match.numberOfRanges {
            let groupRange = match.range(at: idx)
            if groupRange.location != NSNotFound,
               let swiftRange = Range(groupRange, in: text) {
                results.append(String(text[swiftRange]))
            } else {
                results.append("")
            }
        }
        return results
    }

    public func replace(_ text: String, pattern: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = regex(for: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    public var stats: (hits: Int, misses: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (hits, misses, storage.count)
    }

    public func clearCache() {
        lock.lock()
        storage.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func prewarmCommonPatterns() {
        let commonPatterns: [String] = [
            #"(?:^|[^A-Za-z0-9])(AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}(?:[^A-Za-z0-9]|$)"#,
            #"(?:^|[^A-Za-z0-9_])(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,255}(?:[^A-Za-z0-9_]|$)"#,
            #"github_pat_[A-Za-z0-9_]{40,255}"#,
            #"(?:^|[^A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{20,255}"#,
            #"(?:^|[^A-Za-z0-9_-])sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{28,255}"#,
            #"(?:^|[^A-Za-z0-9_])(sk|rk)_(live|test)_[0-9a-zA-Z]{20,99}"#,
            #"xox[baprs]-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9-]*"#,
            #"(?:^|[^A-Za-z0-9_-])AIza[0-9A-Za-z_-]{35}(?:[^A-Za-z0-9_-]|$)"#,
            #"^eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}$"#,
            #"^(?:#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})|0x([0-9a-fA-F]{6}|[0-9a-fA-F]{8}))$"#,
            #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        ]
        for pattern in commonPatterns {
            if let compiled = try? NSRegularExpression(pattern: pattern, options: []) {
                storage[pattern] = compiled
            }
        }
    }
}
