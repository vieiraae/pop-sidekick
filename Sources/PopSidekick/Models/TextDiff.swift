import Foundation

/// Word-level diff between an original text and an AI revision, grouped into
/// hunks the user can accept or reject individually.
struct TextDiff: Equatable {
    enum Segment: Equatable {
        case same(String)
        /// A change hunk; `index` numbers the changes from 0.
        case change(index: Int, removed: String, inserted: String)
    }

    let segments: [Segment]
    let changeCount: Int
    /// Share of tokens (0...1) the two texts have in common.
    let similarity: Double

    /// Rebuilds the text, taking the revision for accepted hunks and the
    /// original for rejected ones.
    func merged(rejected: Set<Int>) -> String {
        var out = ""
        for s in segments {
            switch s {
            case .same(let t): out += t
            case let .change(i, removed, inserted): out += rejected.contains(i) ? removed : inserted
            }
        }
        return out
    }

    /// Token cap (per side) for the O(n·m) LCS; beyond this, no diff is offered.
    private static let maxTokens = 3000

    init?(original: String, revised: String) {
        let a = Self.tokenize(original)
        let b = Self.tokenize(revised)
        guard !a.isEmpty, !b.isEmpty, a.count <= Self.maxTokens, b.count <= Self.maxTokens else { return nil }

        // LCS lengths from the end, so a forward walk can read off the script.
        let n = a.count, m = b.count
        let width = m + 1
        var lcs = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * width + j] = a[i] == b[j]
                    ? lcs[(i + 1) * width + j + 1] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }

        var raw: [Segment] = []
        var removed = "", inserted = ""
        var same = ""
        var common = 0
        func flushSame() { if !same.isEmpty { raw.append(.same(same)); same = "" } }
        func flushChange() {
            if !removed.isEmpty || !inserted.isEmpty {
                raw.append(.change(index: 0, removed: removed, inserted: inserted))
                removed = ""; inserted = ""
            }
        }
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                flushChange()
                same += a[i]
                common += 1
                i += 1; j += 1
            } else if j < m, i == n || lcs[i * width + j + 1] >= lcs[(i + 1) * width + j] {
                flushSame()
                inserted += b[j]; j += 1
            } else {
                flushSame()
                removed += a[i]; i += 1
            }
        }
        flushChange()
        flushSame()

        // Fold whitespace-only runs sitting between two changes into one hunk,
        // so "a b c" → "x y z" is a single readable change, then number hunks.
        var merged: [Segment] = []
        for s in raw {
            if case let .change(_, r, ins) = s,
               merged.count >= 2,
               case let .same(gap) = merged[merged.count - 1],
               gap.allSatisfy(\.isWhitespace),
               case let .change(_, pr, pins) = merged[merged.count - 2] {
                merged.removeLast(2)
                merged.append(.change(index: 0, removed: pr + gap + r, inserted: pins + gap + ins))
            } else {
                merged.append(s)
            }
        }
        var count = 0
        segments = merged.map { s in
            guard case let .change(_, r, ins) = s else { return s }
            defer { count += 1 }
            return .change(index: count, removed: r, inserted: ins)
        }
        changeCount = count
        similarity = Double(2 * common) / Double(n + m)
    }

    /// Splits into word runs, whitespace runs, and single punctuation marks.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var kind = 0 // 1 word, 2 space
        for ch in s {
            let k = (ch.isLetter || ch.isNumber || ch == "_" || ch == "'") ? 1 : (ch.isWhitespace ? 2 : 3)
            if k == 3 {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(ch))
                kind = 0
            } else if k == kind {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(ch)
                kind = k
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
