import Foundation

/// Compares version strings the way Sparkle does: the string is split into runs of
/// digits, letters and separators, and runs are compared pairwise.
///
///     "1.10" > "1.9"      "2.0" > "2.0b3"      "1.0.1" > "1.0"
public enum VersionComparator {
    private enum Part: Equatable {
        case number(Int)
        case text(String)
        case separator
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parts(of: lhs)
        let b = parts(of: rhs)

        for i in 0..<min(a.count, b.count) {
            switch (a[i], b[i]) {
            case let (.number(x), .number(y)):
                if x != y { return x < y ? .orderedAscending : .orderedDescending }
            case let (.text(x), .text(y)):
                let result = x.compare(y, options: .caseInsensitive)
                if result != .orderedSame { return result }
            case (.separator, .separator):
                continue
            // Numbers beat text ("1.0.1" > "1.0b"), separators beat text.
            case (.number, _):
                return .orderedDescending
            case (_, .number):
                return .orderedAscending
            case (.separator, .text):
                return .orderedDescending
            case (.text, .separator):
                return .orderedAscending
            }
        }

        if a.count == b.count { return .orderedSame }

        // One version is a prefix of the other; look at what the longer one adds.
        let lhsIsLonger = a.count > b.count
        let extra = lhsIsLonger ? a[b.count...] : b[a.count...]
        let longerIsNewer: Bool
        switch extra.first(where: { $0 != .separator }) {
        case .text?:
            // "1.0b1" is a pre-release of "1.0".
            longerIsNewer = false
        case .number?:
            // "1.0.1" > "1.0", but "1.0.0" == "1.0".
            let addsSomething = extra.contains { part in
                if case .number(let n) = part { return n > 0 }
                if case .text = part { return true }
                return false
            }
            if !addsSomething { return .orderedSame }
            longerIsNewer = true
        default:
            // Only trailing separators ("1.0.").
            return .orderedSame
        }
        return (lhsIsLonger == longerIsNewer) ? .orderedDescending : .orderedAscending
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func parts(of version: String) -> [Part] {
        var result: [Part] = []
        var buffer = ""
        var bufferKind: Int = -1 // 0 digit, 1 letter, 2 separator

        func flush() {
            guard !buffer.isEmpty else { return }
            switch bufferKind {
            case 0: result.append(.number(Int(buffer.prefix(18)) ?? 0))
            case 1: result.append(.text(buffer))
            default: result.append(.separator)
            }
            buffer = ""
        }

        for ch in version.trimmingCharacters(in: .whitespaces) {
            let kind: Int
            if ch.isASCII && ch.isNumber { kind = 0 }
            else if ch.isLetter { kind = 1 }
            else { kind = 2 }

            // Each separator character is its own part so "1..2" stays sane.
            if kind != bufferKind || kind == 2 {
                flush()
                bufferKind = kind
            }
            buffer.append(ch)
        }
        flush()
        return result
    }
}
