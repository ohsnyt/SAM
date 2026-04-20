import Foundation
import FoundationModels

enum BenchError: Error {
    case modelUnavailable(String)
    case timeout(String)
    case emptyTranscript
    case allChunksFailed
}

enum Pipeline {

    static let maxChunkChars = 2_800

    // MARK: - Extract prompt

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

    // MARK: - Synthesis prompt

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

    static func reasonerUserPrompt(scaffold: Scaffold, extracts: [ChunkExtraction], outlineCues: [String]) -> String {
        func cap(_ s: String, _ max: Int) -> String {
            s.count <= max ? s : String(s.prefix(max)) + "..."
        }
        var out = ""

        // Outline cues FIRST and most prominent — they directly drive
        // orderedPoints and must not be missed.
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

    static func coreUserPrompt(reasoned: ReasonedScaffold, extracts: [ChunkExtraction]) -> String {
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

        // Numeric/distance data points are often critical anchors (e.g.
        // "seven miles", "12,000 steps", "125%"). Highlight them so the
        // writer doesn't abstract them away.
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

    static func detailsUserPrompt(core: LectureCore, reasoned: ReasonedScaffold, extracts: [ChunkExtraction]) -> String {
        // Cap the narrative core we echo back — long cores can blow the
        // context window on 15+-chunk transcripts.
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

        // Aggregate extracts into compact pooled lists rather than per-chunk
        // dumps — keeps the prompt bounded even for long transcripts.
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

        // Filter data points down to meaningful ones: percentages, money,
        // named quantities. Raw integers without units are low-signal noise.
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
        // Resolve spelling variants of the same proper noun (e.g. "Aegon"
        // and "A-Gon", "WFG" and "WFT") — prefer the variant that is a
        // single clean alphabetic word, no hyphens / digits / "$defs" junk.
        // This helps the summary avoid parroting the transcription-corrupted
        // form when a correct form also appears elsewhere.
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

    // MARK: - Run

    static func run(transcript: String, transcriptStem: String, logger: RunLogger) async throws -> LectureSummary {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BenchError.emptyTranscript }

        await logger.line("Transcript: \(transcriptStem) — \(trimmed.count) chars")

        // Availability check
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            let msg = "FoundationModels not available: \(model.availability)"
            await logger.line("❌ \(msg)")
            throw BenchError.modelUnavailable(msg)
        }

        // 1) Chunking
        let chunks = Chunker.chunk(trimmed, maxChars: maxChunkChars)
        await logger.line("Chunked into \(chunks.count) pieces (max \(maxChunkChars) chars)")
        try await logger.writeText("chunks.txt",
            chunks.enumerated().map { "### Chunk \($0.offset + 1) (\($0.element.count) chars)\n\($0.element)" }
                .joined(separator: "\n\n---\n\n"))

        // 2) Extract pass — sequential for now (simpler error handling, and
        // FoundationModels is memory-bound so parallelism's win is modest).
        let extractStart = Date()
        var successfulExtracts: [ChunkExtraction] = []
        var failures: [(Int, String)] = []

        for (i, chunk) in chunks.enumerated() {
            do {
                let extracted = try await extractOneChunk(chunk, index: i, total: chunks.count, logger: logger, depth: 0)
                successfulExtracts.append(extracted)
                await logger.line("  ✓ extract chunk \(i + 1)/\(chunks.count) — thesis: \"\(extracted.thesis.prefix(120))\"")
            } catch {
                failures.append((i + 1, error.localizedDescription))
                await logger.line("  ✗ extract chunk \(i + 1)/\(chunks.count) FAILED — \(error.localizedDescription)")
            }
        }

        await logger.line("Extract pass done in \(String(format: "%.1f", Date().timeIntervalSince(extractStart)))s — \(successfulExtracts.count)/\(chunks.count) succeeded")
        if !failures.isEmpty {
            await logger.line("⚠️  \(failures.count) chunk(s) dropped: \(failures.map { "chunk \($0.0): \($0.1)" }.joined(separator: "; "))")
        }
        try await logger.writeJSON("extracts.json", successfulExtracts)

        guard !successfulExtracts.isEmpty else {
            await logger.line("❌ All chunks failed")
            throw BenchError.allChunksFailed
        }

        // 3a) Deterministic scaffold detection — cheap, no LLM call.
        let scaffold = ScaffoldDetector.detect(from: successfulExtracts)
        try await logger.writeJSON("scaffold.json", scaffold)
        await logger.line("Scaffold: \(scaffold.recurringEntities.count) recurring entities, \(scaffold.ordinalSequence.count) ordinal markers")

        // 3b) Reasoner pass — an LLM looks at the distilled scaffold + thesis
        // arc and produces the organizing interpretation of the lecture.
        let outlineCues = ScaffoldDetector.outlineCueSentences(in: chunks)
        if !outlineCues.isEmpty {
            try await logger.writeText("outline-cues.txt", outlineCues.joined(separator: "\n"))
            await logger.line("Outline cues detected: \(outlineCues.count)")
        }
        let reasonerStart = Date()
        let reasonerSession = LanguageModelSession(instructions: reasonerSystemPrompt)
        let reasonerPrompt = reasonerUserPrompt(scaffold: scaffold, extracts: successfulExtracts, outlineCues: outlineCues)
        try await logger.writeText("reasoner-prompt.txt",
            "SYSTEM:\n\(reasonerSystemPrompt)\n\n-------\n\nUSER:\n\(reasonerPrompt)")
        let reasoned: ReasonedScaffold
        do {
            reasoned = try await Self.generateWithTimeout(
                session: reasonerSession,
                prompt: reasonerPrompt,
                type: ReasonedScaffold.self,
                timeout: 90
            )
        } catch {
            await logger.line("❌ Reasoner failed: \(error.localizedDescription). Falling back to empty scaffold.")
            reasoned = ReasonedScaffold(narrativeFrame: "", centralThesis: "", orderedPoints: [], primaryIllustration: "")
        }
        try await logger.writeJSON("reasoned.json", reasoned)
        await logger.line("Reasoner done in \(String(format: "%.1f", Date().timeIntervalSince(reasonerStart)))s — frame: \"\(reasoned.narrativeFrame)\", \(reasoned.orderedPoints.count) ordered points")

        // 3c) Deterministic ordered-points enforcement. The reasoner often
        // paraphrases cue content away (e.g. the speaker says "Jesus
        // brings us good news" but the reasoner emits "Jesus offers hope
        // and joy" — an anchor checking for "good news" then fails).
        // For each outline cue, if its distinctive keywords are absent
        // from the reasoner's orderedPoints, append the cue content as
        // an additional point so synthesis can anchor on it.
        let enforcedReasoned: ReasonedScaffold
        if outlineCues.isEmpty {
            enforcedReasoned = reasoned
        } else {
            // First filter junk reasoner output — short fragments, stream-of-
            // consciousness clauses, and meta-reference phrases that slip
            // through when the reasoner loses focus.
            let junkPrefixes = ["look at ", "and then ", "and my ", "and the ",
                                "selective ", "just ", "that you ", "here ",
                                "so ", "well "]
            let cleanedReasonerPoints = reasoned.orderedPoints.filter { p in
                let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                if trimmed.count < 4 { return false }
                if junkPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
                return !ScaffoldDetector.distinctiveKeywords(in: p).isEmpty
            }
            if cleanedReasonerPoints.count != reasoned.orderedPoints.count {
                await logger.line("Enforcement: dropped \(reasoned.orderedPoints.count - cleanedReasonerPoints.count) junk reasoner point(s)")
            }

            let cuePhrases = ScaffoldDetector.cueContentPhrases(outlineCues)
            let existingText = cleanedReasonerPoints.joined(separator: " ").lowercased()
            let existingStems = Set(ScaffoldDetector.distinctiveKeywords(in: existingText))
            // Identify frame stems that appear in MOST ordered points (e.g.
            // "jesu" in a "Jesus walks / Jesus listens / Jesus transforms"
            // outline). Those are subject-name stems, not distinguishing
            // content — coverage of just the subject stem does not mean
            // the cue's actual content is represented.
            var stemFrequency: [String: Int] = [:]
            for p in cleanedReasonerPoints {
                for s in Set(ScaffoldDetector.distinctiveKeywords(in: p)) {
                    stemFrequency[s, default: 0] += 1
                }
            }
            let frameThreshold = max(2, cleanedReasonerPoints.count / 2)
            let frameStems = Set(stemFrequency.filter { $0.value >= frameThreshold }.keys)
            var augmented = cleanedReasonerPoints
            for phrase in cuePhrases {
                let phraseStems = ScaffoldDetector.distinctiveKeywords(in: phrase)
                guard !phraseStems.isEmpty else { continue }
                // The distinguishing stems are those NOT shared by every
                // reasoner point. If a cue's distinguishing stems are all
                // absent from existingStems, append it.
                let distinguishing = phraseStems.filter { !frameStems.contains($0) }
                let checkAgainst = distinguishing.isEmpty ? phraseStems : distinguishing
                let covered = checkAgainst.contains(where: { existingStems.contains($0) })
                if !covered {
                    augmented.append(phrase)
                }
            }
            if augmented.count != cleanedReasonerPoints.count {
                await logger.line("Enforcement: appended \(augmented.count - cleanedReasonerPoints.count) cue phrase(s) missing from reasoner output")
            }
            enforcedReasoned = ReasonedScaffold(
                narrativeFrame: reasoned.narrativeFrame,
                centralThesis: reasoned.centralThesis,
                orderedPoints: augmented,
                primaryIllustration: reasoned.primaryIllustration
            )
            try await logger.writeJSON("reasoned-enforced.json", enforcedReasoned)
        }

        // 4a) Synthesis Pass A — narrative core
        let synthStart = Date()
        let coreSession = LanguageModelSession(instructions: coreSystemPrompt)
        let corePrompt = coreUserPrompt(reasoned: enforcedReasoned, extracts: successfulExtracts)
        try await logger.writeText("synthesis-core-prompt.txt",
            "SYSTEM:\n\(coreSystemPrompt)\n\n-------\n\nUSER:\n\(corePrompt)")
        let core: LectureCore
        do {
            core = try await Self.generateWithTimeout(
                session: coreSession,
                prompt: corePrompt,
                type: LectureCore.self,
                timeout: 90
            )
        } catch {
            await logger.line("❌ Synthesis (core) failed: \(error.localizedDescription)")
            try await logger.writeText("synthesis-core-error.txt", "\(error)")
            throw error
        }
        await logger.line("Synthesis core done in \(String(format: "%.1f", Date().timeIntervalSince(synthStart)))s")

        // 4b) Synthesis Pass B — supporting lists, seeded by core
        let detailsStart = Date()
        let detailsSession = LanguageModelSession(instructions: detailsSystemPrompt)
        let detailsPrompt = detailsUserPrompt(core: core, reasoned: enforcedReasoned, extracts: successfulExtracts)
        try await logger.writeText("synthesis-details-prompt.txt",
            "SYSTEM:\n\(detailsSystemPrompt)\n\n-------\n\nUSER:\n\(detailsPrompt)")
        let details: LectureDetails
        do {
            details = try await Self.generateWithTimeout(
                session: detailsSession,
                prompt: detailsPrompt,
                type: LectureDetails.self,
                timeout: 90
            )
        } catch {
            await logger.line("❌ Synthesis (details) failed: \(error.localizedDescription)")
            try await logger.writeText("synthesis-details-error.txt", "\(error)")
            throw error
        }
        await logger.line("Synthesis details done in \(String(format: "%.1f", Date().timeIntervalSince(detailsStart)))s")

        // 4c) Post-synthesis enforcement. For each ordered point, verify at
        // least one distinctive stem appears in keyPoints OR reviewNotes. If
        // absent, append the ordered point verbatim as a keyPoint so the
        // speaker's actual outline wording is preserved.
        let enforcedDetails: LectureDetails
        if enforcedReasoned.orderedPoints.isEmpty {
            enforcedDetails = details
        } else {
            let existingText = (details.keyPoints + [core.reviewNotes])
                .joined(separator: " ")
                .lowercased()
            let existingStems = Set(ScaffoldDetector.distinctiveKeywords(in: existingText))
            // Identify frame stems shared by most ordered points (subject
            // names are not distinguishing content — see enforcement note
            // above for the same reasoning).
            var stemFrequencyB: [String: Int] = [:]
            for p in enforcedReasoned.orderedPoints {
                for s in Set(ScaffoldDetector.distinctiveKeywords(in: p)) {
                    stemFrequencyB[s, default: 0] += 1
                }
            }
            let frameThresholdB = max(2, enforcedReasoned.orderedPoints.count / 2)
            let frameStemsB = Set(stemFrequencyB.filter { $0.value >= frameThresholdB }.keys)
            var augmentedKeyPoints = details.keyPoints
            var appendedCount = 0
            for point in enforcedReasoned.orderedPoints {
                let pointStems = ScaffoldDetector.distinctiveKeywords(in: point)
                guard !pointStems.isEmpty else { continue }
                let distinguishing = pointStems.filter { !frameStemsB.contains($0) }
                let checkAgainst = distinguishing.isEmpty ? pointStems : distinguishing
                let covered = checkAgainst.contains(where: { existingStems.contains($0) })
                if !covered {
                    augmentedKeyPoints.append(point)
                    appendedCount += 1
                }
            }
            if appendedCount > 0 {
                await logger.line("Post-synthesis: appended \(appendedCount) keyPoint(s) missing from details output")
            }
            enforcedDetails = LectureDetails(
                topics: details.topics,
                learningObjectives: details.learningObjectives,
                keyPoints: augmentedKeyPoints,
                openQuestions: details.openQuestions
            )
        }

        let summary = LectureSummary(core: core, details: enforcedDetails)

        try await logger.writeJSON("summary.json", summary)
        try await logger.writeText("summary.md", renderMarkdown(summary))

        return summary
    }

    // MARK: - Extract with overflow recovery

    private static let maxExtractDepth = 3

    private static func extractOneChunk(
        _ chunk: String,
        index: Int,
        total: Int,
        logger: RunLogger,
        depth: Int
    ) async throws -> ChunkExtraction {
        let session = LanguageModelSession(instructions: extractSystemPrompt)
        let prompt = extractPrompt(chunk: chunk, index: index, total: total)
        do {
            return try await Self.generateWithTimeout(
                session: session,
                prompt: prompt,
                type: ChunkExtraction.self,
                timeout: 90
            )
        } catch {
            let overflow = isContextWindowOverflow(error)
            await logger.line("     ! chunk \(index + 1) depth=\(depth) chars=\(chunk.count) overflow=\(overflow) err=\(error.localizedDescription)")

            guard overflow,
                  depth < maxExtractDepth,
                  chunk.count > 800,
                  let (a, b) = splitInHalf(chunk)
            else { throw error }

            await logger.line("     🔁 split chunk \(index + 1): \(chunk.count) → \(a.count) + \(b.count) (depth \(depth + 1))")
            let first = try await extractOneChunk(a, index: index, total: total, logger: logger, depth: depth + 1)
            let second = try await extractOneChunk(b, index: index, total: total, logger: logger, depth: depth + 1)
            return merge(first, second)
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

    private static func merge(_ a: ChunkExtraction, _ b: ChunkExtraction) -> ChunkExtraction {
        func orderedDedup(_ items: [String]) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for i in items {
                let k = i.lowercased()
                if seen.insert(k).inserted { out.append(i) }
            }
            return out
        }
        // When merging halves of the same chunk, prefer concatenation for
        // thesis (both halves have a thesis of their sub-section) — the
        // downstream synthesis will see both as adjacent ordered theses.
        return ChunkExtraction(
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

    // MARK: - Helpers

    private static func generateWithTimeout<T: Generable & Sendable>(
        session: LanguageModelSession,
        prompt: String,
        type: T.Type,
        timeout: TimeInterval
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                let resp = try await session.respond(to: prompt, generating: T.self)
                return resp.content
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw BenchError.timeout("Generation exceeded \(Int(timeout))s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func renderMarkdown(_ s: LectureSummary) -> String {
        var out = "# \(s.title.isEmpty ? "Untitled Lecture" : s.title)\n\n"
        out += "## Opening\n\n\(s.opening)\n\n"
        out += "## Review Notes\n\n\(s.reviewNotes)\n\n"
        if !s.topics.isEmpty {
            out += "## Topics\n\n"
            out += s.topics.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !s.learningObjectives.isEmpty {
            out += "## Learning Objectives\n\n"
            out += s.learningObjectives.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !s.keyPoints.isEmpty {
            out += "## Key Points\n\n"
            out += s.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !s.openQuestions.isEmpty {
            out += "## Open Questions\n\n"
            out += s.openQuestions.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return out
    }
}
