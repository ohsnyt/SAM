//
//  LectureSummaryPipeline.swift
//  SAM
//
//  Map-then-synthesize pipeline for training-lecture summaries.
//  Ported from tools/summary-bench after anchor-eval median stabilized at 88%.
//
//  Pipeline: chunk → extract (per chunk) → deterministic scaffold →
//  reasoner (LLM) → ordered-point enforcement → core (LLM) → details (LLM) →
//  post-synthesis keyPoint enforcement → MeetingSummary.
//
//  The enforcement layers are Swift-side deterministic checks that preserve
//  the speaker's explicit outline against LLM paraphrase drift.
//

import Foundation
import FoundationModels
import os.log

// MARK: - Generable DTOs

@Generable
struct LectureChunkExtraction: Sendable, Codable {
    @Guide(description: "ONE SENTENCE stating the central point the speaker argues in this slice — the claim, not the topic. Use the speaker's vocabulary. Concrete, not abstract.")
    var thesis: String

    @Guide(description: "Proper-noun entities named in the slice: PEOPLE (named individuals), PLACES (cities, geographical locations — include place names from retold stories like 'Emmaus', 'Jericho'), companies, book titles, scripture references, cited authors. Exact spelling from the slice. Up to 8. Empty if none.")
    var entities: [String]

    @Guide(description: "Verbatim phrases from the slice that signal outline structure (another point, the second pillar, a new section). Up to 4. Empty if none.")
    var structureMarkers: [String]

    @Guide(description: "Short labels for stories, illustrations, extended anecdotes, OR retold scripture narratives IN THIS SLICE. If the speaker is retelling a biblical story, label it by location + characters (e.g., 'Road to Emmaus - two disciples'). For secular illustrations, name concretely (e.g., 'facility manager 12,000 steps'). Up to 3. Empty if none.")
    var anecdotes: [String]

    @Guide(description: "Concrete numbers, dates, amounts, percentages, years, DISTANCES, durations, statistics mentioned IN THIS SLICE. Exact value plus short phrase of what it refers to (e.g., 'seven-mile journey to Emmaus', '12,000 steps in a day'). Up to 6. Empty if none.")
    var dataPoints: [String]

    @Guide(description: "Specific claims or assertions the speaker makes in this slice, in the speaker's terms. Up to 4. Empty if none.")
    var claims: [String]

    @Guide(description: "Questions the speaker actually asked aloud in the slice — the slice contains the question ending in '?'. Up to 3. Empty if none.")
    var questionsRaised: [String]

    @Guide(description: "Scripture passages, books, or research sources the speaker cites BY NAME in this slice. Do NOT include liturgical greetings or responses (e.g. 'Christ is risen') — those are not citations. Up to 3. Empty if none.")
    var citations: [String]
}

@Generable
struct LectureReasonedScaffold: Sendable, Codable {
    @Guide(description: "The overarching story, framework, metaphor, or illustration the speaker used to organize the whole lecture. If the lecture references a specific story, text passage, or named framework throughout, name it. Examples of frames: a scripture story told across the whole talk, a named model like 'Six Pillars', a recurring case study. If the lecture has no single organizing frame, use an empty string.")
    var narrativeFrame: String

    @Guide(description: "The single central message or thesis of the ENTIRE lecture — one sentence. What does the speaker want the audience to walk away believing or doing? Ground this in the per-chunk theses you were shown.")
    var centralThesis: String

    @Guide(description: "If the speaker has an explicit multi-point outline (e.g. three points, six pillars, four principles), list each point as one short phrase IN THE ORDER the speaker presented them. MAXIMUM 8 entries. One entry per DISTINCT position in the outline — if multiple cues refer to the same point (e.g. pillar two), emit it once using the fullest/clearest naming. Points are short labels (1-6 words), not sentences. If there is no explicit numbered/named outline, return an empty array.")
    var orderedPoints: [String]

    @Guide(description: "The primary illustration or story the speaker used most prominently — often the opening hook or the story they return to. Ground this in the chunk extracts' anecdotes AND structure markers. If none stands out, use an empty string.")
    var primaryIllustration: String
}

@Generable
struct LectureCorePass: Sendable, Codable {
    @Guide(description: "2-5 word title for the whole lecture. Name the specific topic. Title case, no trailing punctuation.")
    var title: String

    @Guide(description: "2-3 sentences that name the speaker's organizing scaffold (central story, text, framework, or illustration) AND the core message it was used to make. Reference the primary anecdote and any citations from the scaffold by their actual names. Do not abstract the scaffold away.")
    var opening: String

    @Guide(description: "Study notes, 2-3 short paragraphs. Follow the speaker's argument arc in the order the chunk theses appear. Name the specific illustrations and data points the speaker used. Keep specifics; do not collapse to abstract themes.")
    var reviewNotes: String
}

@Generable
struct LectureDetailsPass: Sendable, Codable {
    @Guide(description: "5-7 short topic tags (1-4 words each). Specific subjects from this lecture. No duplicates.")
    var topics: [String]

    @Guide(description: "4-6 single-sentence learning objectives grounded in the speaker's content.")
    var learningObjectives: [String]

    @Guide(description: "6-8 single-sentence takeaways. Each captures a concrete insight the speaker made, naming the specific illustration, number, or entity used.")
    var keyPoints: [String]

    @Guide(description: "Questions the speaker actually raised in the talk. Only include questions that appear in the extracts' questionsRaised list. If none, return an empty array.")
    var openQuestions: [String]
}

// MARK: - Deterministic scaffold

/// Detected structural scaffold across all chunk extracts. Fed to the
/// synthesis pass as a hypothesis so it has an organizing spine.
struct LectureScaffold {
    let recurringEntities: [String]
    let orderedMarkers: [String]
    let primaryAnecdote: String?
    let citations: [String]
    let dataPoints: [String]
    let orderedTheses: [String]
    let repeatedThesisPrefix: String?
}

enum LectureScaffoldDetector {
    static func detect(from extracts: [LectureChunkExtraction]) -> LectureScaffold {
        var entityChunkCounts: [String: Int] = [:]
        for extract in extracts {
            let unique = Set(extract.entities.map { $0.lowercased() })
            for entityLower in unique {
                entityChunkCounts[entityLower, default: 0] += 1
            }
        }
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

        let orderedMarkers = extracts.flatMap(\.structureMarkers)

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
        let repeatedPrefix = longestRepeatedLeadingPhrase(in: theses)

        return LectureScaffold(
            recurringEntities: recurring,
            orderedMarkers: orderedMarkers,
            primaryAnecdote: primaryAnecdote,
            citations: citations,
            dataPoints: dataPoints,
            orderedTheses: theses,
            repeatedThesisPrefix: repeatedPrefix
        )
    }

    /// Scan raw chunks for sentences that signal outline structure (numbered
    /// points, "another point", pillar enumeration). Returns verbatim
    /// sentences in source order — these drive orderedPoints enforcement.
    static func outlineCueSentences(in chunks: [String]) -> [String] {
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
                phrases.insert("\(o) \(w)")
                phrases.insert("\(w) \(o)")
                phrases.insert("the \(o) \(w)")
                phrases.insert("\(w) number \(o)")
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
                let snippet = s.count > maxSnippetLen ? String(s.prefix(maxSnippetLen)) + "..." : s
                if seen.insert(snippet.lowercased()).inserted {
                    out.append(snippet)
                }
            }
        }
        return Array(out.prefix(12))
    }

    /// Parse outline cues into short content phrases suitable for orderedPoints.
    /// Strips trigger phrases ("first pillar is", "another point") and returns
    /// the content clause. Require singular pillar/point/etc. so meta-references
    /// ("five steps for dealing with...") don't match.
    static func cueContentPhrases(_ cues: [String]) -> [String] {
        let triggerPatterns = [
            #"(?i).*?\b(?:the\s+)?(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|one|two|three|four|five|six|seven|eight|nine|ten)\s+(?:pillar|point|principle|step)\b(?!s)[\s,:\-]*"#,
            #"(?i).*?\b(?:pillar|point|principle|step)\b(?!s)\s+(?:number\s+)?(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)\b[\s,:\-]*"#,
            #"(?i).*?\bnumber\s+(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+(?:is|are)?\s*"#,
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
            if !matched { continue }
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
            if let end = content.firstIndex(where: { ".!?".contains($0) }) {
                content = String(content[..<end])
            }
            if content.count > 80 {
                content = String(content.prefix(80))
            }
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Significant keywords (>=4 chars, not a stopword, suffix-stemmed) in a
    /// phrase. Used to test whether enforcing cues are already covered by the
    /// reasoner's orderedPoints.
    static func distinctiveKeywords(in phrase: String) -> [String] {
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

    /// If a substantial leading word-sequence recurs across 2+ theses (e.g.
    /// "Jesus walks with us"), return it — signals an explicit repeated-frame
    /// structure (three-point sermon, "the first pillar / the second pillar").
    private static func longestRepeatedLeadingPhrase(in theses: [String]) -> String? {
        guard theses.count >= 2 else { return nil }
        func words(_ s: String) -> [String] {
            s.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }
        let tokenized = theses.map(words)
        var longest: String?
        var longestLen = 2
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

// MARK: - Chunker

/// Split a transcript into chunks of at most `maxChars`, preferring
/// paragraph then sentence boundaries.
enum LectureChunker {
    static func chunk(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return [trimmed] }

        var chunks: [String] = []
        var remaining = Substring(trimmed)

        while remaining.count > maxChars {
            let cutoff = remaining.index(remaining.startIndex, offsetBy: maxChars)
            let head = remaining[..<cutoff]
            let splitIndex = preferredSplit(in: head) ?? cutoff
            let piece = remaining[..<splitIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }

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

    private static func preferredSplit(in slice: Substring) -> Substring.Index? {
        if let r = slice.range(of: "\n\n", options: .backwards) {
            return r.lowerBound
        }
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

// MARK: - Pipeline

/// Map-then-synthesize lecture summarizer. Produces a `MeetingSummary`
/// shaped for training-lecture content (reviewNotes, keyPoints,
/// learningObjectives, topics, openQuestions populated; client-meeting
/// fields left empty).
actor LectureSummaryPipeline {

    static let shared = LectureSummaryPipeline()
    private init() {}

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LectureSummaryPipeline")

    /// 2,800 chars keeps each extract prompt well under the 4,096-token budget
    /// even after the system instruction overhead. Matches the bench setting
    /// that produced the median 88% anchor score.
    static let maxChunkChars = 2_800

    private static let maxExtractDepth = 3

    enum PipelineError: Error {
        case emptyTranscript
        case allChunksFailed
    }

    /// Run the full pipeline on a raw transcript. Returns a `MeetingSummary`
    /// populated with lecture-shaped fields.
    func generate(transcript: String) async throws -> MeetingSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PipelineError.emptyTranscript }

        // 1) Chunk
        let chunks = LectureChunker.chunk(trimmed, maxChars: Self.maxChunkChars)
        logger.info("Lecture pipeline: chunked \(trimmed.count) chars into \(chunks.count) pieces")

        // 2) Extract per chunk (sequential — FoundationModels is memory-bound)
        var extracts: [LectureChunkExtraction] = []
        var extractFailures = 0
        for (i, chunk) in chunks.enumerated() {
            do {
                let extracted = try await extractOneChunk(chunk, index: i, total: chunks.count, depth: 0)
                extracts.append(extracted)
            } catch {
                extractFailures += 1
                logger.warning("Extract chunk \(i + 1)/\(chunks.count) failed: \(error.localizedDescription)")
            }
        }
        guard !extracts.isEmpty else { throw PipelineError.allChunksFailed }
        if extractFailures > 0 {
            logger.warning("Lecture pipeline: \(extractFailures)/\(chunks.count) chunks dropped during extract")
        }

        // 3a) Deterministic scaffold detection
        let scaffold = LectureScaffoldDetector.detect(from: extracts)

        // 3b) Reasoner pass
        let outlineCues = LectureScaffoldDetector.outlineCueSentences(in: chunks)
        let reasoned: LectureReasonedScaffold
        do {
            reasoned = try await AIService.shared.generateStructured(
                LectureReasonedScaffold.self,
                prompt: reasonerUserPrompt(scaffold: scaffold, extracts: extracts, outlineCues: outlineCues),
                systemInstruction: Self.reasonerSystemPrompt,
                timeout: 90
            )
        } catch {
            logger.warning("Reasoner pass failed, using empty scaffold: \(error.localizedDescription)")
            reasoned = LectureReasonedScaffold(narrativeFrame: "", centralThesis: "",
                                                orderedPoints: [], primaryIllustration: "")
        }

        // 3c) Ordered-point enforcement
        let enforcedReasoned = enforceOrderedPoints(reasoned: reasoned, outlineCues: outlineCues)

        // 4a) Core synthesis
        let core = try await AIService.shared.generateStructured(
            LectureCorePass.self,
            prompt: coreUserPrompt(reasoned: enforcedReasoned, extracts: extracts),
            systemInstruction: Self.coreSystemPrompt,
            timeout: 90
        )

        // 4b) Details synthesis
        let details = try await AIService.shared.generateStructured(
            LectureDetailsPass.self,
            prompt: detailsUserPrompt(core: core, reasoned: enforcedReasoned, extracts: extracts),
            systemInstruction: Self.detailsSystemPrompt,
            timeout: 90
        )

        // 4c) Post-synthesis keyPoint enforcement
        let enforcedDetails = enforceKeyPoints(details: details, reasoned: enforcedReasoned,
                                               coreReviewNotes: core.reviewNotes)

        return MeetingSummary(
            title: core.title,
            tldr: core.opening,
            decisions: [],
            actionItems: [],
            openQuestions: enforcedDetails.openQuestions,
            followUps: [],
            lifeEvents: [],
            topics: enforcedDetails.topics,
            complianceFlags: [],
            sentiment: nil,
            keyPoints: enforcedDetails.keyPoints,
            learningObjectives: enforcedDetails.learningObjectives,
            reviewNotes: core.reviewNotes,
            attendees: [],
            agendaItems: [],
            votes: []
        )
    }

    // MARK: - Extract with overflow recovery

    private func extractOneChunk(
        _ chunk: String,
        index: Int,
        total: Int,
        depth: Int
    ) async throws -> LectureChunkExtraction {
        do {
            return try await AIService.shared.generateStructured(
                LectureChunkExtraction.self,
                prompt: Self.extractPrompt(chunk: chunk, index: index, total: total),
                systemInstruction: Self.extractSystemPrompt,
                timeout: 90
            )
        } catch {
            let overflow = Self.isContextWindowOverflow(error)
            guard overflow,
                  depth < Self.maxExtractDepth,
                  chunk.count > 800,
                  let (a, b) = Self.splitInHalf(chunk)
            else { throw error }
            logger.info("Extract overflow — splitting chunk \(index + 1): \(chunk.count) → \(a.count) + \(b.count) (depth \(depth + 1))")
            let first = try await extractOneChunk(a, index: index, total: total, depth: depth + 1)
            let second = try await extractOneChunk(b, index: index, total: total, depth: depth + 1)
            return Self.mergeExtracts(first, second)
        }
    }

    private static func isContextWindowOverflow(_ error: any Error) -> Bool {
        let d = "\(error)".lowercased() + " " + error.localizedDescription.lowercased()
        return d.contains("context window") || d.contains("exceeded model context") || d.contains("context size")
    }

    private static func splitInHalf(_ text: String) -> (String, String)? {
        guard text.count > 1 else { return nil }
        let target = text.index(text.startIndex, offsetBy: text.count / 2)
        if let r = text.range(of: "\n\n", options: .backwards, range: text.startIndex..<target) {
            return (String(text[..<r.lowerBound]), String(text[r.upperBound...]))
        }
        if let r = text.range(of: ". ", options: .backwards, range: text.startIndex..<target) {
            return (String(text[..<r.upperBound]), String(text[r.upperBound...]))
        }
        return (String(text[..<target]), String(text[target...]))
    }

    private static func mergeExtracts(_ a: LectureChunkExtraction, _ b: LectureChunkExtraction) -> LectureChunkExtraction {
        func orderedDedup(_ items: [String]) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for i in items {
                let k = i.lowercased()
                if seen.insert(k).inserted { out.append(i) }
            }
            return out
        }
        return LectureChunkExtraction(
            thesis: [a.thesis, b.thesis].filter { !$0.isEmpty }.joined(separator: " | "),
            entities: orderedDedup(a.entities + b.entities),
            structureMarkers: orderedDedup(a.structureMarkers + b.structureMarkers),
            anecdotes: orderedDedup(a.anecdotes + b.anecdotes),
            dataPoints: orderedDedup(a.dataPoints + b.dataPoints),
            claims: orderedDedup(a.claims + b.claims),
            questionsRaised: orderedDedup(a.questionsRaised + b.questionsRaised),
            citations: orderedDedup(a.citations + b.citations)
        )
    }

    // MARK: - Enforcement

    /// For each outline cue, if its distinctive keywords are absent from the
    /// reasoner's orderedPoints, append the cue content. Filters junk reasoner
    /// output (short fragments, stream-of-consciousness clauses) first.
    /// Frame-stem detection: stems shared across most ordered points (subject
    /// names like "jesu" in a Jesus-themed sermon) are excluded from the
    /// coverage check since they don't distinguish content.
    private func enforceOrderedPoints(
        reasoned: LectureReasonedScaffold,
        outlineCues: [String]
    ) -> LectureReasonedScaffold {
        guard !outlineCues.isEmpty else { return reasoned }

        let junkPrefixes = ["look at ", "and then ", "and my ", "and the ",
                            "selective ", "just ", "that you ", "here ",
                            "so ", "well "]
        let cleanedReasonerPoints = reasoned.orderedPoints.filter { p in
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if trimmed.count < 4 { return false }
            if junkPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
            return !LectureScaffoldDetector.distinctiveKeywords(in: p).isEmpty
        }

        let cuePhrases = LectureScaffoldDetector.cueContentPhrases(outlineCues)
        let existingText = cleanedReasonerPoints.joined(separator: " ").lowercased()
        let existingStems = Set(LectureScaffoldDetector.distinctiveKeywords(in: existingText))

        var stemFrequency: [String: Int] = [:]
        for p in cleanedReasonerPoints {
            for s in Set(LectureScaffoldDetector.distinctiveKeywords(in: p)) {
                stemFrequency[s, default: 0] += 1
            }
        }
        let frameThreshold = max(2, cleanedReasonerPoints.count / 2)
        let frameStems = Set(stemFrequency.filter { $0.value >= frameThreshold }.keys)

        var augmented = cleanedReasonerPoints
        for phrase in cuePhrases {
            let phraseStems = LectureScaffoldDetector.distinctiveKeywords(in: phrase)
            guard !phraseStems.isEmpty else { continue }
            let distinguishing = phraseStems.filter { !frameStems.contains($0) }
            let checkAgainst = distinguishing.isEmpty ? phraseStems : distinguishing
            let covered = checkAgainst.contains(where: { existingStems.contains($0) })
            if !covered { augmented.append(phrase) }
        }

        return LectureReasonedScaffold(
            narrativeFrame: reasoned.narrativeFrame,
            centralThesis: reasoned.centralThesis,
            orderedPoints: augmented,
            primaryIllustration: reasoned.primaryIllustration
        )
    }

    /// For each ordered point, verify at least one distinctive stem appears
    /// in keyPoints OR reviewNotes. If absent, append the ordered point
    /// verbatim as a keyPoint so the speaker's outline wording survives.
    private func enforceKeyPoints(
        details: LectureDetailsPass,
        reasoned: LectureReasonedScaffold,
        coreReviewNotes: String
    ) -> LectureDetailsPass {
        guard !reasoned.orderedPoints.isEmpty else { return details }

        let existingText = (details.keyPoints + [coreReviewNotes])
            .joined(separator: " ")
            .lowercased()
        let existingStems = Set(LectureScaffoldDetector.distinctiveKeywords(in: existingText))

        var stemFrequency: [String: Int] = [:]
        for p in reasoned.orderedPoints {
            for s in Set(LectureScaffoldDetector.distinctiveKeywords(in: p)) {
                stemFrequency[s, default: 0] += 1
            }
        }
        let frameThreshold = max(2, reasoned.orderedPoints.count / 2)
        let frameStems = Set(stemFrequency.filter { $0.value >= frameThreshold }.keys)

        var augmentedKeyPoints = details.keyPoints
        for point in reasoned.orderedPoints {
            let pointStems = LectureScaffoldDetector.distinctiveKeywords(in: point)
            guard !pointStems.isEmpty else { continue }
            let distinguishing = pointStems.filter { !frameStems.contains($0) }
            let checkAgainst = distinguishing.isEmpty ? pointStems : distinguishing
            let covered = checkAgainst.contains(where: { existingStems.contains($0) })
            if !covered { augmentedKeyPoints.append(point) }
        }

        return LectureDetailsPass(
            topics: details.topics,
            learningObjectives: details.learningObjectives,
            keyPoints: augmentedKeyPoints,
            openQuestions: details.openQuestions
        )
    }

    // MARK: - Prompts

    static let extractSystemPrompt = """
    You are an extraction assistant for a lecture summarizer. You are shown one \
    slice of a longer transcript. Your job is NOT to summarize — it is to pull \
    out the raw material the downstream summarizer will use.

    CRITICAL RULES
    - Output ONLY the structured fields. No prose.
    - Use ASCII characters only — no smart quotes, no em-dashes.
    - NEVER invent content. NEVER copy names, numbers, or phrases from these \
      instructions themselves — only from the transcript slice. If the slice \
      has none of a field's content, return an empty array (or empty string \
      for singular fields).
    - Preserve the speaker's exact terminology. Use the words the speaker used.
    - Every entity, number, anecdote, and citation must be grounded in the slice \
      below — if it is not literally in the slice, it does not go in your output.
    - thesis MUST be filled for every slice. It is the single most important \
      field: it captures the point the speaker is ARGUING in this slice. Read the \
      slice, ask "what claim is the speaker making here?", and write that as one \
      concrete sentence.
    - questionsRaised: ONLY questions the speaker actually asked aloud in the \
      slice. The slice text must contain the question ending in "?". Do not \
      guess at questions the speaker might imply.
    - structureMarkers: verbatim phrases from the slice that signal outline \
      structure (another point, the second pillar, a new section, etc.). If the \
      slice contains no such phrasing, return an empty array.
    - SCRIPTURE NARRATIVES: if the slice is retelling a biblical story (not \
      merely quoting a verse), you MUST capture it in anecdotes labeled by \
      location + characters, capture any named places from that story in \
      entities, and capture any stated distances or durations from the \
      story in dataPoints. Do not copy specific names from these \
      instructions — use whatever names the slice actually contains.
    - Liturgical greetings and responsive refrains are NOT citations — \
      leave them out of the citations field.
    """

    static func extractPrompt(chunk: String, index: Int, total: Int) -> String {
        """
        This is chunk \(index + 1) of \(total) from a single lecture transcript.

        TRANSCRIPT SLICE:
        \(chunk)

        Extract the structured fields. Every item must be explicitly present in \
        the slice above.
        """
    }

    static let reasonerSystemPrompt = """
    You are the reasoner pass of a lecture summarizer. You are shown a compact \
    summary of every chunk of a single lecture: its thesis, structure markers, \
    recurring entities, citations, and the primary anecdote detected across \
    chunks. Your job: identify the speaker's organizing structure.

    CRITICAL RULES
    - ASCII only.
    - Ground every field in the material shown. NEVER invent a frame, point, \
      or illustration that isn't in the extracts.
    - narrativeFrame: if the speaker uses one overarching story, text, or \
      named framework throughout the lecture, name it using the exact wording \
      the extracts use. If there is no single frame (e.g. a general panel \
      discussion), leave it empty.
    - centralThesis: ONE SHORT SENTENCE — under 30 words. The single thing \
      the speaker most wants the audience to walk away with. Do NOT paste \
      in long excerpts. Do NOT use any example wording from these \
      instructions.
    - orderedPoints: IF you were given OUTLINE-CUE SENTENCES, those ARE the \
      outline. Extract each distinct point from them IN THE ORDER SHOWN. \
      Use the speaker's wording from the cue. If two cues name the SAME \
      numbered point/pillar with different words (e.g. one cue says the \
      second item has one name, a later cue explicitly re-introduces the \
      same second item with a different, more complete name), prefer the \
      later/fuller naming since the speaker corrected themselves or \
      restated. Do NOT emit both — emit one entry per distinct position. \
      Do NOT include meta-words like "foundation" or "pillars" themselves \
      as a point. Do NOT invent points not tied to a cue. If NO cues were \
      provided, look for a repeated phrasal stem across structure markers \
      — each recurrence becomes one point. If neither cues nor a repeated \
      stem exist, return an empty array.
    - primaryIllustration: the illustration or story the extracts most \
      consistently point to. May overlap with narrativeFrame. Empty if \
      none. Do NOT use any example wording from these instructions — \
      ground every output in this specific transcript's extracts.
    """

    static let coreSystemPrompt = """
    You write the narrative core of a lecture summary: title, opening, and \
    reviewNotes. You are given the detected scaffold plus one compact extract \
    per chunk. The extracts are your ONLY source of truth about what the \
    speaker said.

    CRITICAL RULES
    - ASCII characters only.
    - NEVER invent content. NEVER copy names, numbers, or phrases from these \
      instructions. Every name, number, anecdote, and citation must trace to \
      the scaffold or extracts.
    - The extract array is IN ORDER. The per-chunk "thesis" lines form the \
      spine of the talk. Read them in sequence — they tell you the speaker's \
      argument arc.
    - OPENING: must name (a) the primary anecdote or scripture/framework from \
      the scaffold, and (b) the central message the speaker used it to make. \
      Do not abstract the scaffold away. Do not write a generic "the speaker \
      discussed X."
    - REVIEW NOTES: follow the order of the thesis arc. If consecutive theses \
      repeat a signature phrasing (the repeatedThesisPrefix field), that is \
      the speaker's explicit outline — name each point in sequence. Preserve \
      specific illustrations, data points, and citations.
    - Preserve the speaker's exact spellings and terminology from the extracts.
    """

    static let detailsSystemPrompt = """
    You write the supporting lists for a lecture summary: topics, learning \
    objectives, key points, and open questions. You are given the already-written \
    narrative core (title, opening, reviewNotes) plus a compact view of each \
    chunk's extract. Build the lists from those sources.

    CRITICAL RULES
    - ASCII characters only.
    - NEVER invent content. NEVER copy names, numbers, or phrases from these \
      instructions. Ground every item in the core or the extracts.
    - topics: specific subjects named in the core or extracts, not generic themes.
    - learningObjectives: what the speaker set out to teach, as evidenced by \
      the theses in the extracts.
    - keyPoints: concrete takeaways, naming the specific illustrations, numbers, \
      or entities the speaker used. Prefer specificity over abstraction.
    - openQuestions: ONLY questions from extracts' questionsRaised. If the \
      extracts contain no genuine questions the speaker asked, return an empty \
      array. Never invent a question.
    """

    private func reasonerUserPrompt(scaffold: LectureScaffold,
                                    extracts: [LectureChunkExtraction],
                                    outlineCues: [String]) -> String {
        func cap(_ s: String, _ max: Int) -> String {
            s.count <= max ? s : String(s.prefix(max)) + "..."
        }
        var out = ""
        if !outlineCues.isEmpty {
            out += "OUTLINE-CUE SENTENCES — VERBATIM FROM TRANSCRIPT. EACH SENTENCE INTRODUCES ONE ORDERED POINT. USE THEM. DO NOT SKIP ANY.\n"
            for (i, s) in outlineCues.enumerated() {
                out += "  cue \(i + 1): \(cap(s, 140))\n"
            }
            out += "\n"
        }
        if !scaffold.recurringEntities.isEmpty {
            out += "Recurring entities (appeared in 2+ chunks): \(scaffold.recurringEntities.prefix(10).joined(separator: ", "))\n"
        }
        if let prim = scaffold.primaryAnecdote {
            out += "Most-referenced anecdote: \(cap(prim, 160))\n"
        }
        if !scaffold.citations.isEmpty {
            out += "Citations (in order): \(scaffold.citations.prefix(8).joined(separator: " | "))\n"
        }
        if let rep = scaffold.repeatedThesisPrefix, !rep.isEmpty {
            out += "Repeated thesis stem across chunks: \"\(rep)\" — likely a multi-point outline.\n"
        }
        out += "\nCHUNK THESIS ARC (use for centralThesis synthesis, NOT for orderedPoints):\n"
        for (i, t) in scaffold.orderedTheses.enumerated() {
            out += "  \(i + 1). \(cap(t, 140))\n"
        }
        if !scaffold.orderedMarkers.isEmpty {
            out += "\nSTRUCTURE MARKERS (source order — may contain additional outline signals):\n"
            for m in scaffold.orderedMarkers.prefix(20) {
                out += "  - \(cap(m, 100))\n"
            }
        }
        out += "\nANECDOTES PER CHUNK:\n"
        for (i, e) in extracts.enumerated() {
            let top = e.anecdotes.prefix(2).map { cap($0, 80) }.joined(separator: " | ")
            if !top.isEmpty {
                out += "  chunk \(i + 1): \(top)\n"
            }
        }
        out += "\nProduce the scaffold now. If cues were provided above, orderedPoints MUST come from those cues. Do not substitute theses for ordered points.\n"
        return out
    }

    private func coreUserPrompt(reasoned: LectureReasonedScaffold,
                                extracts: [LectureChunkExtraction]) -> String {
        var out = "REASONED SCAFFOLD (use this as your guide)\n"
        if !reasoned.narrativeFrame.isEmpty {
            out += "Narrative frame: \(reasoned.narrativeFrame)\n"
        }
        if !reasoned.centralThesis.isEmpty {
            out += "Central thesis: \(reasoned.centralThesis)\n"
        }
        if !reasoned.primaryIllustration.isEmpty {
            out += "Primary illustration: \(reasoned.primaryIllustration)\n"
        }
        if !reasoned.orderedPoints.isEmpty {
            out += "Ordered points the speaker makes:\n"
            for (i, p) in reasoned.orderedPoints.enumerated() {
                out += "  \(i + 1). \(p)\n"
            }
        }

        func cap(_ s: String, _ max: Int) -> String {
            s.count <= max ? s : String(s.prefix(max)) + "..."
        }
        out += "\nCHUNK THESIS ARC (for grounding reviewNotes order):\n"
        for (i, e) in extracts.enumerated() {
            out += "  \(i + 1). \(cap(e.thesis, 180))\n"
        }

        out += "\nSUPPORTING SPECIFICS (ground illustrations, numbers, citations here):\n"
        for (i, e) in extracts.enumerated() {
            var parts: [String] = []
            if !e.anecdotes.isEmpty { parts.append("anec: " + e.anecdotes.joined(separator: "; ")) }
            if !e.citations.isEmpty { parts.append("cite: " + e.citations.joined(separator: "; ")) }
            if !e.dataPoints.isEmpty { parts.append("data: " + e.dataPoints.joined(separator: "; ")) }
            if !e.entities.isEmpty { parts.append("who/what: " + e.entities.joined(separator: ", ")) }
            if !parts.isEmpty {
                out += "  chunk \(i + 1) — \(parts.joined(separator: " | "))\n"
            }
        }

        let numericHint = extracts
            .flatMap(\.dataPoints)
            .filter { $0.rangeOfCharacter(from: .decimalDigits) != nil
                || $0.range(of: #"\b(?:seven|eight|nine|ten|eleven|twelve|hundred|thousand|million)\b"#,
                            options: [.regularExpression, .caseInsensitive]) != nil }
        let numericList = numericHint.prefix(6).joined(separator: " | ")

        out += "\nProduce the narrative core now.\n"
        out += "- title: capture the scaffold.\n"
        out += "- opening: 2-3 sentences of PROSE. Name the narrativeFrame or primaryIllustration VERBATIM — copy the exact wording from the scaffold, including any named participants (e.g. if the frame is \"X - two characters\", keep both the name and the participants). If any numeric data point from the list below ties to that frame (distance, count, duration), include it VERBATIM — do not paraphrase numbers away.\n"
        if !numericList.isEmpty {
            out += "  Numeric data points to preserve: \(numericList)\n"
        }
        out += "- reviewNotes: 3-5 short paragraphs of PROSE, each paragraph 2-3 sentences MAX. Do NOT copy thesis arc sentences verbatim — synthesize. If there are ordered points, cover EVERY ordered point in sequence, and each corresponding paragraph must contain the distinguishing noun or phrase from that point (the speaker's actual word for it). Attach at least one concrete illustration/number/entity from the supporting specifics to each paragraph. If no ordered points, follow the thesis arc. HARD LIMIT: reviewNotes total under 1200 characters.\n"
        return out
    }

    private func detailsUserPrompt(core: LectureCorePass,
                                   reasoned: LectureReasonedScaffold,
                                   extracts: [LectureChunkExtraction]) -> String {
        func cap(_ s: String, _ max: Int) -> String {
            s.count <= max ? s : String(s.prefix(max)) + "..."
        }
        var out = "NARRATIVE CORE (already produced):\n"
        out += "Title: \(core.title)\n"
        out += "Opening: \(cap(core.opening, 400))\n"
        out += "Review Notes:\n\(cap(core.reviewNotes, 1400))\n\n"

        if !reasoned.orderedPoints.isEmpty {
            out += "SPEAKER'S ORDERED POINTS (each MUST appear verbatim or nearly so in keyPoints):\n"
            for (i, p) in reasoned.orderedPoints.enumerated() {
                out += "  \(i + 1). \(p)\n"
            }
            out += "\n"
        }

        func orderedDedup(_ items: [String]) -> [String] {
            var seen = Set<String>(); var out: [String] = []
            for i in items where !i.isEmpty {
                let k = i.lowercased()
                if seen.insert(k).inserted { out.append(i) }
            }
            return out
        }
        let allTheses = extracts.map(\.thesis).filter { !$0.isEmpty }
        let allAnecdotes = orderedDedup(extracts.flatMap(\.anecdotes))
        let allCitations = orderedDedup(extracts.flatMap(\.citations))
        let allEntities  = orderedDedup(extracts.flatMap(\.entities))
        let allData      = orderedDedup(extracts.flatMap(\.dataPoints))
        let allQuestions = orderedDedup(extracts.flatMap(\.questionsRaised))
        let allClaims    = orderedDedup(extracts.flatMap(\.claims))

        let meaningfulData = allData.filter { d in
            d.contains("%") || d.contains("$")
                || d.range(of: #"\b(?:million|billion|thousand|hundred|year|years|month|months|week|weeks|day|days|mile|miles|hour|hours)\b"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
        }

        out += "THESIS ARC (in order):\n"
        for (i, t) in allTheses.enumerated() { out += "  \(i + 1). \(cap(t, 180))\n" }
        if !allClaims.isEmpty {
            out += "\nKEY CLAIMS (named assertions the speaker made — each MUST anchor at least one keyPoint verbatim or near-verbatim. Preserve proper nouns and numbers exactly.):\n"
            for c in allClaims.prefix(16) { out += "  - \(cap(c, 180))\n" }
        }
        out += "\nANECDOTES: \(allAnecdotes.prefix(12).map { cap($0, 100) }.joined(separator: " | "))\n"
        if !allCitations.isEmpty {
            out += "CITATIONS: \(allCitations.prefix(10).joined(separator: " | "))\n"
        }
        // Resolve spelling variants of the same proper noun (e.g. "Aegon" vs
        // "A-Gon") — prefer the clean alphabetic form so the summary doesn't
        // parrot the transcription-corrupted variant.
        let cleanedEntities: [String] = {
            var byStem: [String: String] = [:]
            var order: [String] = []
            for e in allEntities {
                let stem = e.lowercased()
                    .unicodeScalars
                    .filter { CharacterSet.lowercaseLetters.contains($0) }
                    .map(String.init).joined()
                if stem.isEmpty { continue }
                func cleanliness(_ s: String) -> Int {
                    var score = 0
                    if !s.contains("-") { score += 3 }
                    if !s.contains("$") { score += 3 }
                    if !s.contains(where: { $0.isNumber }) { score += 2 }
                    let firstCap = s.first.map { $0.isUppercase } ?? false
                    if firstCap { score += 1 }
                    return score
                }
                if let existing = byStem[stem] {
                    if cleanliness(e) > cleanliness(existing) { byStem[stem] = e }
                } else {
                    byStem[stem] = e
                    order.append(stem)
                }
            }
            return order.compactMap { byStem[$0] }
        }()
        out += "ENTITIES: \(cleanedEntities.prefix(30).joined(separator: ", "))\n"
        out += "DATA POINTS: \(meaningfulData.prefix(24).joined(separator: " | "))\n"
        if !allQuestions.isEmpty {
            out += "QUESTIONS SPEAKER ASKED ALOUD:\n"
            for q in allQuestions.prefix(12) { out += "  - \(cap(q, 160))\n" }
        }
        out += "\nProduce the topics, learningObjectives, keyPoints, and openQuestions arrays now. Ground every item in the core or in the pools above. Do not invent. openQuestions must be drawn ONLY from the QUESTIONS list above.\n"
        return out
    }
}
