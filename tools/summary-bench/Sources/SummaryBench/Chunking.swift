import Foundation

/// Split a transcript into chunks of at most `maxChars`, preferring
/// paragraph boundaries (\n\n) then sentence boundaries.
enum Chunker {
    static func chunk(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return [trimmed] }

        var chunks: [String] = []
        var remaining = Substring(trimmed)

        while remaining.count > maxChars {
            let cutoff = remaining.index(remaining.startIndex, offsetBy: maxChars)
            let head = remaining[..<cutoff]
            let splitIndex = Self.preferredSplit(in: head) ?? cutoff
            let piece = remaining[..<splitIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }

            // Advance past any whitespace/newlines at the seam.
            var next = splitIndex
            while next < remaining.endIndex,
                  remaining[next].isWhitespace || remaining[next].isNewline {
                next = remaining.index(after: next)
            }
            remaining = remaining[next...]
        }

        let tail = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    /// Prefer last paragraph break; fall back to last sentence end; else nil.
    private static func preferredSplit(in slice: Substring) -> Substring.Index? {
        if let r = slice.range(of: "\n\n", options: .backwards) {
            return r.lowerBound
        }
        // Sentence-ending punctuation followed by space or newline.
        let terminators: [Character] = [".", "!", "?"]
        var idx = slice.endIndex
        while idx > slice.startIndex {
            idx = slice.index(before: idx)
            if terminators.contains(slice[idx]) {
                let next = slice.index(after: idx)
                if next < slice.endIndex, slice[next].isWhitespace || slice[next].isNewline {
                    return next
                }
            }
        }
        return nil
    }
}
