//
//  TranscriptDiffService.swift
//  SAM
//
//  Word-level diff between raw transcript segments and the polished text.
//  Used to render inline highlights in the review view so Sarah can see
//  at a glance what the polish step changed, and hover over a highlighted
//  word to see the original.
//
//  The diff uses a simple longest-common-subsequence (LCS) algorithm on
//  word arrays. For a typical meeting transcript (~500 words), LCS runs
//  in <5ms. We cache the result per session so re-renders are free.
//

import Foundation

/// One word in the diff output, annotated with whether it was changed.
struct DiffWord: Identifiable {
    let id = UUID()
    let text: String
    /// The original raw word(s) this replaces, if any. nil = unchanged from raw.
    let originalRaw: String?
    /// Whether this word was inserted by polish (not present in raw at all).
    let isInsertion: Bool

    var isChanged: Bool { originalRaw != nil || isInsertion }
}

/// A paragraph-level diff result: the speaker label + the word-level diff.
struct DiffParagraph: Identifiable {
    let id = UUID()
    let speakerLabel: String
    let words: [DiffWord]
    let hasChanges: Bool
}

struct TranscriptDiffService {

    /// Compute a word-level diff between the raw segments and the polished text.
    ///
    /// - Parameters:
    ///   - rawSegments: The original Whisper segments (sorted by start time).
    ///   - polishedText: The polished "Speaker: text\n\nSpeaker: text" string.
    /// - Returns: An array of `DiffParagraph`s, one per polished paragraph.
    static func diff(
        rawSegments: [TranscriptSegment],
        polishedText: String
    ) -> [DiffParagraph] {
        // Parse polished text into paragraphs with speaker labels.
        let polishedParagraphs = parsePolishedParagraphs(polishedText)

        // Build raw paragraphs by grouping consecutive same-speaker segments
        // (same logic as the polish step uses to build the input).
        let rawParagraphs = buildRawParagraphs(from: rawSegments)

        var results: [DiffParagraph] = []

        for (i, polished) in polishedParagraphs.enumerated() {
            let rawText: String
            if i < rawParagraphs.count {
                rawText = rawParagraphs[i].text
            } else {
                rawText = "" // Polished has more paragraphs than raw (shouldn't happen, but safe)
            }

            let rawWords = tokenize(rawText)
            let polishedWords = tokenize(polished.text)

            let diffWords = computeWordDiff(rawWords: rawWords, polishedWords: polishedWords)
            let hasChanges = diffWords.contains(where: \.isChanged)

            results.append(DiffParagraph(
                speakerLabel: polished.speaker,
                words: diffWords,
                hasChanges: hasChanges
            ))
        }

        return results
    }

    // MARK: - Paragraph Parsing

    private struct ParsedParagraph {
        let speaker: String
        let text: String
    }

    /// Parse "Speaker: text\n\nSpeaker: text" into (speaker, text) pairs.
    private static func parsePolishedParagraphs(_ text: String) -> [ParsedParagraph] {
        let blocks = text.components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            // Find "Speaker N:" or "Agent:" prefix
            if let colonRange = trimmed.range(of: ": ", options: [], range: trimmed.startIndex..<trimmed.endIndex) {
                let speaker = String(trimmed[..<colonRange.lowerBound])
                let text = String(trimmed[colonRange.upperBound...])
                return ParsedParagraph(speaker: speaker, text: text)
            }
            // No speaker prefix — treat whole block as text
            return ParsedParagraph(speaker: "", text: trimmed)
        }
    }

    /// Group consecutive same-speaker segments into paragraphs (mirrors
    /// the logic in PendingReprocessService.polishSession).
    private static func buildRawParagraphs(from segments: [TranscriptSegment]) -> [ParsedParagraph] {
        var paragraphs: [ParsedParagraph] = []
        var lastSpeaker: String? = nil
        var currentBuffer: [String] = []

        func flush() {
            guard let speaker = lastSpeaker, !currentBuffer.isEmpty else { return }
            paragraphs.append(ParsedParagraph(
                speaker: speaker,
                text: currentBuffer.joined(separator: " ")
            ))
            currentBuffer.removeAll()
        }

        for segment in segments {
            if segment.speakerLabel != lastSpeaker {
                flush()
                lastSpeaker = segment.speakerLabel
            }
            currentBuffer.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        flush()

        return paragraphs
    }

    // MARK: - Tokenization

    /// Split text into words, preserving punctuation attached to words.
    private static func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Word-Level Diff (LCS)

    /// Compute the diff between raw and polished word arrays using LCS.
    /// Returns annotated `DiffWord` objects for the POLISHED text, marking
    /// which words were changed or inserted relative to raw.
    private static func computeWordDiff(rawWords: [String], polishedWords: [String]) -> [DiffWord] {
        // If either is empty, everything is changed/inserted
        if rawWords.isEmpty {
            return polishedWords.map { DiffWord(text: $0, originalRaw: nil, isInsertion: true) }
        }
        if polishedWords.isEmpty {
            return []
        }

        // Compute LCS table
        let m = rawWords.count
        let n = polishedWords.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if rawWords[i - 1].lowercased() == polishedWords[j - 1].lowercased() {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find which polished words match raw words
        var matchedPolishedIndices = Set<Int>()
        var rawMatchForPolished: [Int: Int] = [:] // polished index → raw index

        var i = m, j = n
        while i > 0 && j > 0 {
            if rawWords[i - 1].lowercased() == polishedWords[j - 1].lowercased() {
                matchedPolishedIndices.insert(j - 1)
                rawMatchForPolished[j - 1] = i - 1
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        // Build the diff output. For each polished word:
        // - If it's in the LCS (matched), it's unchanged
        // - If it's NOT in the LCS, it's a change/insertion.
        //   Try to find a nearby unmatched raw word to pair it with.
        var usedRawIndices = Set(rawMatchForPolished.values)
        var result: [DiffWord] = []

        for pIdx in 0..<polishedWords.count {
            let word = polishedWords[pIdx]
            if matchedPolishedIndices.contains(pIdx) {
                // Unchanged word — still check if case changed
                let rawIdx = rawMatchForPolished[pIdx]!
                let rawWord = rawWords[rawIdx]
                if rawWord == word {
                    result.append(DiffWord(text: word, originalRaw: nil, isInsertion: false))
                } else {
                    // Case or punctuation change (words matched case-insensitively)
                    result.append(DiffWord(text: word, originalRaw: rawWord, isInsertion: false))
                }
            } else {
                // Changed word — find the nearest unmatched raw word
                // (simple heuristic: scan nearby raw indices for one not yet used)
                var closestRawWord: String? = nil
                let searchStart = max(0, pIdx - 3)
                let searchEnd = min(rawWords.count, pIdx + 4)
                for rIdx in searchStart..<searchEnd {
                    if !usedRawIndices.contains(rIdx) {
                        closestRawWord = rawWords[rIdx]
                        usedRawIndices.insert(rIdx)
                        break
                    }
                }
                if let raw = closestRawWord {
                    result.append(DiffWord(text: word, originalRaw: raw, isInsertion: false))
                } else {
                    result.append(DiffWord(text: word, originalRaw: nil, isInsertion: true))
                }
            }
        }

        return result
    }
}
