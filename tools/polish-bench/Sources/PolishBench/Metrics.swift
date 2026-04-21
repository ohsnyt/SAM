//
//  Metrics.swift
//  polish-bench
//
//  Objective, deterministic metrics that score a polish run without human
//  review. Everything is computed from string comparisons between the
//  original transcript and the polished output — no LLM-as-judge, no
//  external calls, no randomness.
//
//  Retention metrics (nouns, jargon, numbers) are the headline signal:
//  if a new model scores lower on noun or number retention, it is
//  actively making Sarah's recordings worse, and that should block
//  adoption regardless of any narrative improvements.
//

import Foundation

struct MetricRow: Codable, Sendable {
    var latencyMs: Int = 0
    var inputChars: Int = 0
    var outputChars: Int = 0
    /// outputChars / inputChars. Sanity target ≈ 1.0, polish should not
    /// grow or shrink the transcript meaningfully.
    var lengthRatio: Double = 0.0
    /// Fraction of supplied proper nouns that survive case-insensitive
    /// substring match in the output. 1.0 = all survived.
    var properNounRetention: Double = 0.0
    /// Same treatment for the jargon companion list.
    var jargonRetention: Double = 0.0
    /// Fraction of numeric tokens from the input that also appear in the
    /// output (allowing for the space-fix normalizations the prompt asks
    /// the model to perform — see `normalizeNumeric`).
    var numberRetention: Double = 0.0
    /// |speaker-label-count(output) - speaker-label-count(input)|. Non-zero
    /// means the model invented or dropped a speaker turn.
    var speakerLabelDelta: Int = 0
    /// Characters the model emitted inside `<think>…</think>` that leaked
    /// past the sanitizer. Should always be 0.
    var thinkLeakChars: Int = 0
    /// True if a preamble like "Here is the cleaned transcript:" survived
    /// the sanitizer.
    var preambleLeaked: Bool = false
    /// Number of hedge phrases ("I think", "I believe", "it seems") the
    /// model added that weren't in the input. Higher = model is narrating
    /// instead of polishing.
    var addedHedgeCount: Int = 0
    /// If the pipeline failed, a one-line reason. Present ⇒ all other
    /// numeric fields are 0 and should be ignored.
    var error: String?

    init(
        latencyMs: Int = 0,
        inputChars: Int = 0,
        outputChars: Int = 0,
        lengthRatio: Double = 0,
        properNounRetention: Double = 0,
        jargonRetention: Double = 0,
        numberRetention: Double = 0,
        speakerLabelDelta: Int = 0,
        thinkLeakChars: Int = 0,
        preambleLeaked: Bool = false,
        addedHedgeCount: Int = 0,
        error: String? = nil
    ) {
        self.latencyMs = latencyMs
        self.inputChars = inputChars
        self.outputChars = outputChars
        self.lengthRatio = lengthRatio
        self.properNounRetention = properNounRetention
        self.jargonRetention = jargonRetention
        self.numberRetention = numberRetention
        self.speakerLabelDelta = speakerLabelDelta
        self.thinkLeakChars = thinkLeakChars
        self.preambleLeaked = preambleLeaked
        self.addedHedgeCount = addedHedgeCount
        self.error = error
    }
}

enum Metrics {

    static func score(
        original: String,
        polished: String,
        knownNouns: [String],
        jargon: [String],
        latencyMs: Int
    ) -> MetricRow {
        let inLen = original.count
        let outLen = polished.count
        let ratio = inLen > 0 ? Double(outLen) / Double(inLen) : 0

        return MetricRow(
            latencyMs: latencyMs,
            inputChars: inLen,
            outputChars: outLen,
            lengthRatio: ratio,
            properNounRetention: retention(tokens: knownNouns, in: polished),
            jargonRetention: retention(tokens: jargon, in: polished),
            numberRetention: numberRetention(original: original, polished: polished),
            speakerLabelDelta: speakerLabelDelta(original: original, polished: polished),
            thinkLeakChars: thinkLeakChars(polished),
            preambleLeaked: preambleLeaked(polished),
            addedHedgeCount: addedHedgeCount(original: original, polished: polished)
        )
    }

    // MARK: - Retention

    private static func retention(tokens: [String], in text: String) -> Double {
        guard !tokens.isEmpty else { return 1.0 }
        let lower = text.lowercased()
        let hits = tokens.filter { lower.contains($0.lowercased()) }.count
        return Double(hits) / Double(tokens.count)
    }

    // MARK: - Numbers

    /// Extract numeric tokens from the input, normalize them (strip spaces
    /// that the prompt explicitly instructs the model to remove — "9 %" →
    /// "9%", "$12 ,000" → "$12,000"), and check what fraction survives in
    /// the normalized output.
    ///
    /// We normalize BOTH sides before comparing so the expected fixes
    /// count as retention, not drops.
    private static func numberRetention(original: String, polished: String) -> Double {
        let origNumbers = extractNumbers(from: normalizeNumeric(original))
        guard !origNumbers.isEmpty else { return 1.0 }
        let polishedNormalized = normalizeNumeric(polished)
        let hits = origNumbers.filter { polishedNormalized.contains($0) }.count
        return Double(hits) / Double(origNumbers.count)
    }

    /// Matches dollar amounts ($12,000 / $1.5M), percentages (9%, 1.25%),
    /// and bare numbers with separators (2026, 401(k)-adjacent digits).
    /// Tuned toward tokens that would be lost if the model "rounded" or
    /// dropped a digit.
    private static func extractNumbers(from text: String) -> Set<String> {
        // NB: Character class uses escaped brackets to match literal braces
        // isn't needed here — this is a conventional regex across digits,
        // commas, periods, dollar signs, and percent signs.
        let pattern = #"\$?\d[\d,.]*%?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = Set<String>()
        for m in matches {
            let token = ns.substring(with: m.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",."))
            if token.count >= 1 { out.insert(token) }
        }
        return out
    }

    /// Apply the prompt's required space-fix normalizations to both sides
    /// so "9 %" in the input and "9%" in the output count as a match, not
    /// a drop.
    private static func normalizeNumeric(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"(\d)\s+%"#, with: "$1%", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\d)\s+,(\d)"#, with: "$1,$2", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\d)\s+-(\w)"#, with: "$1-$2", options: .regularExpression)
        return t
    }

    // MARK: - Speaker integrity

    /// Count unique speaker-label prefixes ("Speaker 1:", "ALEX:", "Karen:")
    /// in the source. Uses the `LABEL:` heading convention the production
    /// polish prompt enforces.
    private static func speakerLabelDelta(original: String, polished: String) -> Int {
        abs(uniqueSpeakerLabels(original).count - uniqueSpeakerLabels(polished).count)
    }

    private static func uniqueSpeakerLabels(_ text: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: #"(?m)^([A-Z][A-Za-z0-9 ]{0,40}):"#) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return Set(matches.compactMap {
            let r = $0.range(at: 1)
            guard r.location != NSNotFound else { return nil }
            return ns.substring(with: r).trimmingCharacters(in: .whitespaces)
        })
    }

    // MARK: - Hygiene

    private static func thinkLeakChars(_ text: String) -> Int {
        var total = 0
        var cursor = text.startIndex
        while let open = text.range(of: "<think>", range: cursor..<text.endIndex, locale: nil) {
            let after = open.upperBound
            if let close = text.range(of: "</think>", range: after..<text.endIndex) {
                total += text.distance(from: after, to: close.lowerBound)
                cursor = close.upperBound
            } else {
                total += text.distance(from: after, to: text.endIndex)
                break
            }
        }
        return total
    }

    private static func preambleLeaked(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("here is")
            || lower.hasPrefix("here's")
            || lower.hasPrefix("cleaned transcript")
            || lower.hasPrefix("transcript:")
    }

    private static let hedges: [String] = [
        "i think",
        "i believe",
        "it seems",
        "perhaps",
        "i'd guess",
        "most likely"
    ]

    /// Count of hedge phrases that appear in the polished output but not in
    /// the original. Non-zero means the model editorialized.
    private static func addedHedgeCount(original: String, polished: String) -> Int {
        let origLower = original.lowercased()
        let outLower = polished.lowercased()
        var added = 0
        for h in hedges {
            let outCount = countOccurrences(of: h, in: outLower)
            let origCount = countOccurrences(of: h, in: origLower)
            if outCount > origCount { added += (outCount - origCount) }
        }
        return added
    }

    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
