import Foundation

struct EvalResult: Codable {
    let transcriptStem: String
    let passes: [String]
    let fails: [String]
    let antiAnchorHits: [String]  // anti-anchors that MATCHED (bad)
    let score: Double              // passes / (passes + fails)

    var asMarkdown: String {
        var out = "# Evaluation — \(transcriptStem)\n\n"
        out += "**Score:** \(passes.count) / \(passes.count + fails.count) "
        out += String(format: "(%.0f%%)\n\n", score * 100)

        if !antiAnchorHits.isEmpty {
            out += "## Anti-anchors HIT (transcription corruption survived)\n\n"
            for a in antiAnchorHits { out += "- ❌ \(a)\n" }
            out += "\n"
        }

        out += "## Passes\n\n"
        if passes.isEmpty { out += "_(none)_\n\n" }
        for a in passes { out += "- ✅ \(a)\n" }
        out += "\n## Failures\n\n"
        if fails.isEmpty { out += "_(none)_\n\n" }
        for a in fails { out += "- ❌ \(a)\n" }
        return out
    }
}

enum Evaluator {
    static func evaluate(_ summary: LectureSummary, transcriptStem: String) -> EvalResult {
        let anchors = AnchorLibrary.anchors(for: transcriptStem)
        let antiAnchors = AnchorLibrary.antiAnchors(for: transcriptStem)

        var passes: [String] = []
        var fails: [String] = []
        for anchor in anchors {
            if matches(anchor, in: summary) {
                passes.append(anchor.label)
            } else {
                fails.append(anchor.label)
            }
        }

        var antiHits: [String] = []
        for anti in antiAnchors {
            if matches(anti, in: summary) {
                antiHits.append(anti.label)
            }
        }

        let total = passes.count + fails.count
        let score = total == 0 ? 0 : Double(passes.count) / Double(total)
        return EvalResult(
            transcriptStem: transcriptStem,
            passes: passes,
            fails: fails,
            antiAnchorHits: antiHits,
            score: score
        )
    }

    /// True if any of the anchor's mustMatchAny substrings appears (ci) in
    /// the restricted fields (or any field if fields is nil).
    private static func matches(_ anchor: Anchor, in summary: LectureSummary) -> Bool {
        let haystacks = selectedFields(summary, fields: anchor.fields)
            .map { $0.lowercased() }
        for needle in anchor.mustMatchAny {
            let n = needle.lowercased()
            if haystacks.contains(where: { $0.contains(n) }) { return true }
        }
        return false
    }

    private static func selectedFields(_ s: LectureSummary, fields: [String]?) -> [String] {
        let all: [(String, String)] = [
            ("title", s.title),
            ("opening", s.opening),
            ("reviewNotes", s.reviewNotes),
            ("topics", s.topics.joined(separator: " | ")),
            ("keyPoints", s.keyPoints.joined(separator: " | ")),
            ("learningObjectives", s.learningObjectives.joined(separator: " | ")),
            ("openQuestions", s.openQuestions.joined(separator: " | ")),
        ]
        guard let whitelist = fields, !whitelist.isEmpty else {
            return all.map(\.1)
        }
        let lowerSet = Set(whitelist.map { $0.lowercased() })
        return all.filter { lowerSet.contains($0.0.lowercased()) }.map(\.1)
    }
}
