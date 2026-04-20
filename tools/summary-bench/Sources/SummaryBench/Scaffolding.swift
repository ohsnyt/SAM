import Foundation

/// Detected structural scaffold across all chunk extracts. Fed to the
/// synthesis pass as a hypothesis so it has an organizing spine before
/// it starts writing.
struct Scaffold: Codable {
    /// Entities that appear in 2+ chunks — these are the spine of the talk.
    let recurringEntities: [String]
    /// Structural markers in the order they appeared across chunks.
    let orderedMarkers: [String]
    /// Anecdotes grouped by first appearance; the longest-recurring is likely the main frame.
    let primaryAnecdote: String?
    /// Ordered list of all citations.
    let citations: [String]
    /// Data points in order of appearance.
    let dataPoints: [String]
    /// Detected ordinal structure, e.g. ["first pillar", "second pillar", ...]
    let ordinalSequence: [String]
    /// Per-chunk thesis sentences in source order — the spine of the talk.
    let orderedTheses: [String]
    /// If consecutive theses share a leading clause (e.g. "Jesus listens..., \
    /// Jesus brings..., Jesus transforms..."), this is the shared prefix.
    /// Nil when no repetition is detected.
    let repeatedThesisPrefix: String?
}

enum ScaffoldDetector {
    static func detect(from extracts: [ChunkExtraction]) -> Scaffold {
        // Entity counts across chunks (not per-chunk-occurrence).
        var entityChunkCounts: [String: Int] = [:]
        for extract in extracts {
            let unique = Set(extract.entities.map { $0.lowercased() })
            for entityLower in unique {
                entityChunkCounts[entityLower, default: 0] += 1
            }
        }
        // Preserve original casing from first occurrence.
        var firstCasing: [String: String] = [:]
        for extract in extracts {
            for ent in extract.entities where firstCasing[ent.lowercased()] == nil {
                firstCasing[ent.lowercased()] = ent
            }
        }
        let recurring = entityChunkCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .prefix(12)
            .compactMap { firstCasing[$0.key] }

        // Structure markers in source order.
        let orderedMarkers: [String] = extracts.flatMap(\.structureMarkers)

        // Ordinal sequence detection: scan markers for patterns like
        // "first", "second", "third", ... or "pillar", "point", "principle".
        let ordinalWords = ["first", "second", "third", "fourth", "fifth",
                            "sixth", "seventh", "eighth", "ninth", "tenth",
                            "1)", "2)", "3)", "4)", "5)", "6)", "7)", "8)",
                            "1.", "2.", "3.", "4.", "5.", "6.", "7.", "8."]
        let ordinal = orderedMarkers.filter { marker in
            let lower = marker.lowercased()
            return ordinalWords.contains { lower.contains($0) }
        }

        // Primary anecdote: the one appearing most often across chunks.
        var anecdoteCounts: [String: Int] = [:]
        var firstAnecdoteCasing: [String: String] = [:]
        for extract in extracts {
            for a in extract.anecdotes {
                let key = a.lowercased()
                anecdoteCounts[key, default: 0] += 1
                if firstAnecdoteCasing[key] == nil { firstAnecdoteCasing[key] = a }
            }
        }
        let primaryAnecdoteKey = anecdoteCounts.max { $0.value < $1.value }?.key
        let primaryAnecdote = primaryAnecdoteKey.flatMap { firstAnecdoteCasing[$0] }

        // Citations & data points in source order, de-duped preserving first order.
        func orderedDedup(_ items: [String]) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for i in items {
                let k = i.lowercased()
                if seen.insert(k).inserted { out.append(i) }
            }
            return out
        }
        let citations = orderedDedup(extracts.flatMap(\.citations))
        let dataPoints = orderedDedup(extracts.flatMap(\.dataPoints))

        let theses = extracts.map(\.thesis).filter { !$0.isEmpty }
        let repeatedPrefix = Self.longestRepeatedLeadingPhrase(in: theses)

        return Scaffold(
            recurringEntities: recurring,
            orderedMarkers: orderedMarkers,
            primaryAnecdote: primaryAnecdote,
            citations: citations,
            dataPoints: dataPoints,
            ordinalSequence: ordinal,
            orderedTheses: theses,
            repeatedThesisPrefix: repeatedPrefix
        )
    }

    /// Scan raw chunks for sentences that signal outline structure (numbered
    /// points, "another point", "one more point", pillar enumeration, or
    /// sentences that share a leading phrase recurring across the corpus).
    /// Returns verbatim sentences in source order. Used to give the reasoner
    /// an outline hint when the extractor's structureMarkers miss the cues.
    static func outlineCueSentences(in chunks: [String]) -> [String] {
        // Sermon/lecture point-introducing words. Sentence must contain one
        // of these AND a number/ordinal for us to count it as an outline cue.
        let pointWords = ["point", "pillar", "principle", "step"]
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth",
                        "seventh", "eighth", "ninth", "tenth",
                        "one", "two", "three", "four", "five", "six",
                        "1", "2", "3", "4", "5", "6"]
        var phrases: Set<String> = [
            "there's another point",
            "there is another point",
            "one more point",
            "another point",
            "next point",
        ]
        for w in pointWords {
            for o in ordinals {
                phrases.insert("\(o) \(w)")        // "first pillar"
                phrases.insert("\(w) \(o)")        // "pillar one"
                phrases.insert("the \(o) \(w)")    // "the first pillar"
                phrases.insert("\(w) number \(o)") // "pillar number two"
            }
        }
        let cuePatterns = Array(phrases)
        var out: [String] = []
        var seen = Set<String>()
        let maxSnippetLen = 120
        for chunk in chunks {
            let rawSentences = chunk
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: { ".!?".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for s in rawSentences where !s.isEmpty {
                let lower = s.lowercased()
                guard cuePatterns.contains(where: { lower.contains($0) }) else { continue }
                // Trim around the matched cue to avoid copying unrelated
                // trailing text into the reasoner's input.
                let snippet = s.count > maxSnippetLen ? String(s.prefix(maxSnippetLen)) + "..." : s
                if seen.insert(snippet.lowercased()).inserted {
                    out.append(snippet)
                }
            }
        }
        return Array(out.prefix(12))
    }

    /// Parse outline cues into short content phrases suitable for orderedPoints.
    /// For each cue, strips the trigger phrase ("first pillar is", "another
    /// point", etc.) and returns the remaining content clause. Used to
    /// enforce that the reasoner's orderedPoints actually cover the cues.
    static func cueContentPhrases(_ cues: [String]) -> [String] {
        // Strip these trigger patterns (case-insensitive regex). The first
        // match in a cue is removed; the remaining text (trimmed of leading
        // connector tokens) becomes the content phrase.
        // Require SINGULAR pillar/point/principle/step to avoid matching
        // meta-references like "there are six pillars..." or "five steps".
        // Use (?!s) negative lookahead so "pillars" (plural) is excluded.
        let triggerPatterns = [
            // "the first/second/... pillar/point/principle/step [is|:|-|,]"
            #"(?i).*?\b(?:the\s+)?(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:pillar|point|principle|step)\b(?!s)[\s,:\-]*"#,
            // "pillar/point/principle/step one/two/... or number N"
            #"(?i).*?\b(?:pillar|point|principle|step)\b(?!s)\s+(?:number\s+)?(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)\b[\s,:\-]*"#,
            // "number N is" — e.g. "number five is the system"
            #"(?i).*?\bnumber\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+(?:is|are)?\s*"#,
            // "another/next/one more point"
            #"(?i).*?\b(?:there(?:\s+is|'s)?\s+)?(?:another|next|one\s+more)\s+(?:point|pillar|principle|step)\b(?!s)[\s,:\-]*"#,
        ]
        var out: [String] = []
        var seen = Set<String>()
        for cue in cues {
            var content = cue
            var matched = false
            for pattern in triggerPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: content,
                                                range: NSRange(content.startIndex..., in: content)),
                   let range = Range(match.range, in: content) {
                    content = String(content[range.upperBound...])
                    matched = true
                    break
                }
            }
            // Skip cues that didn't match any trigger pattern — those are
            // not genuine outline introductions (e.g. "five steps for
            // dealing with exhaustion" is a meta-reference).
            if !matched { continue }
            // Strip leading connectors that often follow a trigger: "is ",
            // "— ", ": ", ", ".
            let leadStrip: Set<Character> = [" ", ",", ":", "-", "—", "–"]
            while let first = content.first, leadStrip.contains(first) {
                content.removeFirst()
            }
            for lead in ["is ", "are ", "was ", "were ", "it's "] {
                if content.lowercased().hasPrefix(lead) {
                    content.removeFirst(lead.count)
                    break
                }
            }
            // Cap at sentence boundary or 80 chars.
            if let end = content.firstIndex(where: { ".!?".contains($0) }) {
                content = String(content[..<end])
            }
            if content.count > 80 {
                content = String(content.prefix(80))
            }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip if content is empty, too short, or begins with a
            // meta-filler that signals this is not a real point intro
            // (e.g. "what makes our company...", "that you should...").
            guard content.count >= 4 else { continue }
            let startsWithFiller = ["what ", "that ", "of ", "we ",
                                    "i ", "those ", "these ", "how ",
                                    "the fact ", "it's just ", "it was "]
                .contains(where: { content.lowercased().hasPrefix($0) })
            if startsWithFiller { continue }
            let key = content.lowercased()
            if seen.insert(key).inserted { out.append(content) }
        }
        return out
    }

    /// Significant keywords (>4 chars, not a stopword) in a cue-content phrase,
    /// used to test whether the reasoner's orderedPoints already cover this
    /// cue's content. Heuristic, not perfect.
    static func distinctiveKeywords(in phrase: String) -> [String] {
        // Stopwords are lowercase. Inclusive enough to cover common 4+ char
        // filler so "news" / "good" / "plan" remain as distinctive signal.
        let stop: Set<String> = [
            "about", "after", "again", "also", "always", "another", "around",
            "back", "because", "been", "before", "being", "below", "between",
            "both", "brings", "bring", "came", "come", "comes", "could",
            "does", "doing", "done", "down", "during", "each", "else", "even",
            "ever", "every", "from", "further", "gets", "give", "given", "goes",
            "going", "gone", "have", "having", "here", "into", "just", "keep",
            "kind", "know", "knows", "later", "like", "looking", "make", "makes",
            "many", "might", "more", "most", "much", "must", "need", "needs",
            "never", "next", "none", "once", "only", "other", "over", "over",
            "part", "parts", "people", "pillar", "pillars", "point", "points",
            "principle", "principles", "quite", "really", "said", "same", "says",
            "seen", "shall", "should", "show", "shows", "since", "some", "step",
            "steps", "still", "such", "sure", "take", "taken", "takes", "than",
            "that", "them", "then", "there", "these", "they", "thing", "things",
            "think", "this", "those", "through", "time", "times", "told", "tell",
            "turns", "turn", "very", "walks", "walk", "want", "wants", "well",
            "went", "were", "what", "when", "where", "which", "while", "with",
            "within", "without", "would", "your", "yours",
        ]
        func stem(_ w: String) -> String {
            var s = w.lowercased()
            for suffix in ["tions", "tion", "ings", "ing", "edly", "ed", "es",
                           "ers", "er", "ly", "s"] {
                if s.count > suffix.count + 2, s.hasSuffix(suffix) {
                    s.removeLast(suffix.count); return s
                }
            }
            return s
        }
        return phrase
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !stop.contains($0.lowercased()) }
            .map(stem)
    }

    /// If a substantial leading word-sequence recurs in 2+ theses (e.g.
    /// "Jesus walks with us"), return it. Used to detect an explicit
    /// repeated-frame structure the speaker uses (three-point sermon,
    /// "the first pillar / the second pillar / ...", etc.).
    private static func longestRepeatedLeadingPhrase(in theses: [String]) -> String? {
        guard theses.count >= 2 else { return nil }

        func words(_ s: String) -> [String] {
            s.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }

        let tokenized = theses.map(words)
        var longest: String?
        var longestLen = 2  // require at least 3 words to count as a frame

        for i in 0..<tokenized.count {
            for j in (i + 1)..<tokenized.count {
                let a = tokenized[i], b = tokenized[j]
                var k = 0
                while k < a.count, k < b.count, a[k] == b[k] { k += 1 }
                if k > longestLen {
                    longestLen = k
                    longest = a.prefix(k).joined(separator: " ")
                }
            }
        }
        return longest
    }
}
