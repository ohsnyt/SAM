//
//  MeetingSummaryService.swift
//  SAM
//
//  Generates a structured meeting summary from a speaker-attributed
//  transcript. Runs through the shared AIService facade (FoundationModels
//  on-device) following the same JSON-extraction pattern as
//  NoteAnalysisService / PipelineAnalystService.
//
//  The DTO is Codable so it can be persisted as JSON on TranscriptSession
//  AND transported back to the iPhone over the audio streaming protocol.
//

import Foundation
import FoundationModels
import os.log

// `MeetingSummary` is defined in SAMModels-Transcription.swift so both the
// Mac and iPhone targets can share the wire format.

// MARK: - LectureSynthesis

/// Secondary synthesis produced from a merged lecture's Review Notes.
/// Keeps topics / key points / learning objectives at human-digestible counts
/// regardless of how many chunks the transcript was split into.
@Generable
struct LectureSynthesis: Sendable {
    @Guide(description: "A concise 2-5 word title capturing the central subject of the lecture. Title case, no trailing punctuation.")
    var title: String

    @Guide(description: "6 to 8 short topic tags (1-4 words each) describing the main subjects of the lecture. No duplicates.")
    var topics: [String]

    @Guide(description: "5 to 8 single sentences stating what the lecture was designed to teach. Skip minor points.")
    var learningObjectives: [String]

    @Guide(description: "8 to 12 single-sentence takeaways capturing the core insights. Skip story details — prefer ideas over anecdotes.")
    var keyPoints: [String]
}

// MARK: - Service

actor MeetingSummaryService {

    static let shared = MeetingSummaryService()

    private init() {}

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MeetingSummaryService")

    /// Summary has a much heavier system instruction than polish — the
    /// financial-compliance section alone (with its worked example) is
    /// ~1600 tokens, and the structured output fans out across many fields
    /// that can each contain long strings. Reserve more of the 4096-token
    /// budget for prompt + output by feeding smaller chunks than polish.
    /// `TranscriptPolishService.maxChunkChars` (6000) was overflowing on
    /// content-dense chunks. 3500 chars (~1150 tokens) leaves a wide margin.
    static let maxSummaryChunkChars = 3_500

    /// Maximum recursive split depth when recovering from a context-window
    /// overflow. Each level halves the chunk, so depth 3 = 1/8 of original.
    private static let maxOverflowRecoveryDepth = 3

    // MARK: - Availability

    /// Check whether the underlying AI backend can generate a summary right now.
    func checkAvailability() async -> AIService.ModelAvailability {
        await AIService.shared.checkAvailability()
    }

    // MARK: - Summary Generation

    /// Generate a structured summary from a transcript.
    ///
    /// - Parameter transcript: Formatted transcript with speaker labels
    ///   (e.g. `"Agent: ...\n\nClient: ...\n\nAgent: ..."`).
    /// - Parameter metadata: Optional meta info to include in the prompt
    ///   (duration, number of speakers, etc).
    /// - Returns: A `MeetingSummary` DTO.
    func summarize(
        transcript: String,
        metadata: Metadata = .init()
    ) async throws -> MeetingSummary {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw SummaryError.modelUnavailable
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SummaryError.emptyTranscript
        }

        // Training lectures use the dedicated map-then-synthesize pipeline.
        // Anchor-eval harness measured this at ~88% median vs. the legacy
        // chunk+merge+refine path. On pipeline failure, fall through to the
        // legacy path so the user still gets a summary.
        if metadata.recordingContext == .trainingLecture {
            do {
                return try await LectureSummaryPipeline.shared.generate(transcript: trimmed)
            } catch {
                logger.warning("Lecture pipeline failed, falling back to legacy path: \(error.localizedDescription)")
            }
        }

        // Short transcripts: single-pass (original path).
        if trimmed.count <= Self.maxSummaryChunkChars {
            return try await summarizeSingleChunk(trimmed, metadata: metadata)
        }

        // Long transcripts: summarize each chunk independently, then
        // merge all the per-chunk summaries into one combined result.
        // Action items, decisions, follow-ups accumulate across chunks;
        // the TLDR is re-synthesized from the merged findings.
        let chunks = TranscriptPolishService.chunkTranscript(trimmed, maxChars: Self.maxSummaryChunkChars)
        logger.info("Summarizing long transcript in \(chunks.count) chunks (\(trimmed.count) total chars)")

        var allSummaries: [MeetingSummary] = []
        var failedChunks: [(index: Int, charCount: Int, error: String)] = []
        for (i, chunk) in chunks.enumerated() {
            logger.info("Summarizing chunk \(i + 1)/\(chunks.count) (\(chunk.count) chars)")
            do {
                let chunkSummary = try await summarizeSingleChunk(chunk, metadata: metadata)
                allSummaries.append(chunkSummary)
            } catch {
                // Fail-open: skip this chunk and keep going. Losing one chunk
                // of summary is preferable to losing the entire summary.
                let preview = Self.previewSnippet(chunk)
                failedChunks.append((i + 1, chunk.count, error.localizedDescription))
                logger.error("""
                ❌ SKIPPING summary chunk \(i + 1)/\(chunks.count) after retries — continuing. \
                chars=\(chunk.count, privacy: .public) \
                context=\(metadata.recordingContext.rawValue, privacy: .public) \
                error=\(error.localizedDescription, privacy: .public) \
                preview=\(preview, privacy: .public)
                """)
            }
        }

        guard !allSummaries.isEmpty else {
            logger.error("🛑 Summary FAILED completely — all \(chunks.count) chunks threw. Raising.")
            throw SummaryError.invalidResponse
        }

        if !failedChunks.isEmpty {
            let details = failedChunks
                .map { "chunk \($0.index) (\($0.charCount) chars): \($0.error)" }
                .joined(separator: "; ")
            logger.error("""
            ⚠️ Summary completed with \(failedChunks.count)/\(chunks.count) chunk(s) dropped. \
            This SHOULD NOT happen — treat as a bug, reproduce, and tighten chunking. \
            details=\(details, privacy: .public)
            """)
        }

        let merged = Self.mergeSummaries(allSummaries)
        logger.info("Merged \(allSummaries.count)/\(chunks.count) chunk summaries: \(merged.actionItems.count) action items, \(merged.decisions.count) decisions")

        // For training lectures, per-chunk accumulation over-produces topics,
        // key points, and learning objectives (dozens of each). Re-derive them
        // from the merged Review Notes in a single synthesis pass so they
        // reflect the whole lecture, not the sum of its chunks. Fields that
        // don't apply to lectures (action items, decisions, follow-ups, life
        // events, attendees, tldr) are cleared — Review Notes becomes the
        // opening summary.
        if metadata.recordingContext == .trainingLecture {
            return try await refineLectureSummary(merged)
        }

        return merged
    }

    /// Combine partial summaries produced incrementally during a recording
    /// into one cohesive result. Mirrors the merge+refine tail of
    /// `summarize()` — but skips the per-chunk summarization step because
    /// those partials were produced while the recording was still running.
    func synthesize(
        from partials: [MeetingSummary],
        metadata: Metadata = .init()
    ) async throws -> MeetingSummary {
        guard !partials.isEmpty else {
            throw SummaryError.emptyTranscript
        }
        let merged = Self.mergeSummaries(partials)
        logger.info("Synthesizing from \(partials.count) partial summaries: \(merged.actionItems.count) action items, \(merged.decisions.count) decisions")
        if metadata.recordingContext == .trainingLecture {
            return try await refineLectureSummary(merged)
        }
        return merged
    }

    /// Re-derives topics, key points, and learning objectives for a training
    /// lecture summary by synthesizing them from the merged Review Notes.
    /// Clears fields that are irrelevant to lectures.
    private func refineLectureSummary(_ merged: MeetingSummary) async throws -> MeetingSummary {
        var refined = merged
        refined.tldr = ""
        refined.actionItems = []
        refined.decisions = []
        refined.followUps = []
        refined.lifeEvents = []
        refined.attendees = []

        guard let reviewNotes = merged.reviewNotes, !reviewNotes.isEmpty else {
            logger.info("Skipping lecture synthesis — no merged Review Notes")
            return refined
        }

        let instruction = """
        You extract a focused study outline from a lecture's prose study notes. \
        Produce concise, crux-level content — not story details or anecdotes.

        - title: A 2-5 word title capturing the central subject of the lecture, \
          in title case, with no trailing punctuation.
        - topics: 6 to 8 short tags (1-4 words each) describing the main subjects. \
          No duplicates.
        - learningObjectives: 5 to 8 single sentences stating what the lecture \
          was designed to teach. Skip minor points.
        - keyPoints: 8 to 12 single-sentence takeaways capturing the core \
          insights. Skip story details. Prefer ideas the listener should \
          remember over anecdotes used to illustrate them.

        Ground every item in the provided notes. Do not invent content. Use only \
        ASCII characters.
        """

        let prompt = "REVIEW NOTES:\n\(reviewNotes)\n\nProduce the focused study outline."

        do {
            let synthesis = try await AIService.shared.generateStructured(
                LectureSynthesis.self,
                prompt: prompt,
                systemInstruction: instruction,
                timeout: 45
            )
            refined.topics = synthesis.topics
            refined.learningObjectives = synthesis.learningObjectives
            refined.keyPoints = synthesis.keyPoints
            // Prefer the synthesis title — it was derived from the merged notes,
            // so it reflects the whole lecture instead of just the first chunk.
            if !synthesis.title.isEmpty {
                refined.title = synthesis.title
            }
            logger.info("Lecture synthesis: \(synthesis.topics.count) topics, \(synthesis.learningObjectives.count) objectives, \(synthesis.keyPoints.count) key points")
        } catch {
            logger.warning("Lecture synthesis pass failed, keeping merged fields: \(error.localizedDescription)")
        }

        return refined
    }

    /// Summarize a single chunk that fits within the context window.
    ///
    /// Uses Apple FoundationModels' constrained decoding via `@Generable` on
    /// `MeetingSummary` — the framework guarantees the returned value conforms
    /// to the schema, so there is no free-form JSON parsing step to fail.
    ///
    /// On context-window overflow, splits the chunk at a paragraph boundary
    /// and retries each half, merging the results. Recursion depth is capped
    /// by `maxOverflowRecoveryDepth`.
    private func summarizeSingleChunk(
        _ transcript: String,
        metadata: Metadata,
        depth: Int = 0
    ) async throws -> MeetingSummary {
        let systemInstruction = Self.systemInstruction(for: metadata.recordingContext)
        let prompt = Self.buildPrompt(transcript: transcript, metadata: metadata)

        do {
            return try await AIService.shared.generateStructured(
                MeetingSummary.self,
                prompt: prompt,
                systemInstruction: systemInstruction,
                timeout: 60
            )
        } catch {
            let overflow = Self.isContextWindowOverflow(error)
            let preview = Self.previewSnippet(transcript)

            // Loud failure log — level .error (severity 3). Captures everything
            // we need to reproduce and tune chunking.
            logger.error("""
            ❌ Summary chunk generation FAILED \
            depth=\(depth, privacy: .public) \
            overflow=\(overflow, privacy: .public) \
            chars=\(transcript.count, privacy: .public) \
            context=\(metadata.recordingContext.rawValue, privacy: .public) \
            error=\(error.localizedDescription, privacy: .public) \
            preview=\(preview, privacy: .public)
            """)

            // Recover from context-window overflow by halving and retrying.
            // Don't recurse forever and don't split sub-1k chunks — at that
            // point the prompt itself is probably the problem, not the input.
            if overflow,
               depth < Self.maxOverflowRecoveryDepth,
               transcript.count > 1_000,
               let (firstHalf, secondHalf) = Self.splitForRecovery(transcript) {
                logger.error("""
                🔁 Overflow recovery: splitting \(transcript.count) chars → \
                \(firstHalf.count) + \(secondHalf.count) (depth \(depth + 1))
                """)
                let first = try await summarizeSingleChunk(firstHalf, metadata: metadata, depth: depth + 1)
                let second = try await summarizeSingleChunk(secondHalf, metadata: metadata, depth: depth + 1)
                return Self.mergeSummaries([first, second])
            }

            throw error
        }
    }

    /// Identify FoundationModels context-window overflow errors by message.
    /// We match the error description (not a typed case) so this survives
    /// enum shape changes across iOS / macOS releases.
    private static func isContextWindowOverflow(_ error: any Error) -> Bool {
        let desc = error.localizedDescription.lowercased()
        return desc.contains("context window")
            || desc.contains("exceeded model context")
            || desc.contains("context size")
    }

    /// Split a chunk near its midpoint for overflow recovery. Prefers a
    /// paragraph boundary ("\n\n") so speaker turns stay intact; falls back
    /// to a raw character split only if no boundary exists.
    private static func splitForRecovery(_ text: String) -> (String, String)? {
        guard text.count > 1 else { return nil }
        let target = text.count / 2
        let targetIndex = text.index(text.startIndex, offsetBy: target)

        if let range = text.range(of: "\n\n", options: .backwards, range: text.startIndex..<targetIndex) {
            return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
        }
        if let range = text.range(of: "\n\n", range: targetIndex..<text.endIndex) {
            return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
        }
        // No paragraph boundary — raw split. Acceptable for recovery.
        return (String(text[..<targetIndex]), String(text[targetIndex...]))
    }

    /// Short redacted-friendly preview of a chunk for error logs. Strips
    /// newlines so the log line stays single-line-ish.
    private static func previewSnippet(_ text: String, limit: Int = 200) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    /// Merge multiple per-chunk summaries into one combined summary.
    /// Structured fields (action items, decisions, etc.) are concatenated
    /// and deduplicated. The TLDR is joined from per-chunk TLDRs.
    static func mergeSummaries(_ summaries: [MeetingSummary]) -> MeetingSummary {
        guard !summaries.isEmpty else { return .empty }
        if summaries.count == 1 { return summaries[0] }

        // Join TLDRs with a space — each chunk's TLDR covers a portion
        // of the meeting, and concatenation gives a natural multi-sentence
        // summary without needing another LLM pass.
        let combinedTldr = summaries
            .map(\.tldr)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // First non-empty title wins — chunk 1 has the most context on the
        // lecture's central subject. Lecture refinement will later overwrite
        // this with a title derived from the merged review notes.
        let mergedTitle = summaries
            .map(\.title)
            .first(where: { !$0.isEmpty }) ?? ""

        // Accumulate structured fields across all chunks.
        var allActionItems: [MeetingSummary.ActionItem] = []
        var allDecisions: [String] = []
        var allOpenQuestions: [String] = []
        var allFollowUps: [MeetingSummary.FollowUp] = []
        var allLifeEvents: [String] = []
        var allTopics: [String] = []
        var allComplianceFlags: [String] = []
        var allKeyPoints: [String] = []
        var allLearningObjectives: [String] = []
        var allReviewNotes: [String] = []
        var allAttendees: [String] = []
        var allAgendaItems: [MeetingSummary.AgendaItem] = []
        var allVotes: [MeetingSummary.VoteRecord] = []
        var sentiment: String?

        for summary in summaries {
            allActionItems.append(contentsOf: summary.actionItems)
            allDecisions.append(contentsOf: summary.decisions)
            allOpenQuestions.append(contentsOf: summary.openQuestions)
            allFollowUps.append(contentsOf: summary.followUps)
            allLifeEvents.append(contentsOf: summary.lifeEvents)
            allTopics.append(contentsOf: summary.topics)
            allComplianceFlags.append(contentsOf: summary.complianceFlags)
            allKeyPoints.append(contentsOf: summary.keyPoints)
            allLearningObjectives.append(contentsOf: summary.learningObjectives)
            if let rn = summary.reviewNotes, !rn.isEmpty { allReviewNotes.append(rn) }
            allAttendees.append(contentsOf: summary.attendees)
            allAgendaItems.append(contentsOf: summary.agendaItems)
            allVotes.append(contentsOf: summary.votes)
            if sentiment == nil, let s = summary.sentiment, !s.isEmpty {
                sentiment = s
            }
        }

        // Deduplicate simple string arrays (topics, decisions, etc.)
        // using case-insensitive comparison.
        func dedup(_ items: [String]) -> [String] {
            var seen = Set<String>()
            return items.filter { item in
                let key = item.lowercased()
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
        }

        // reviewNotes: join all non-empty chunk review notes into one prose block.
        let mergedReviewNotes = allReviewNotes.isEmpty ? nil : allReviewNotes.joined(separator: "\n\n")

        return MeetingSummary(
            title: mergedTitle,
            tldr: combinedTldr,
            decisions: dedup(allDecisions),
            actionItems: allActionItems,        // keep all — deduping tasks is risky
            openQuestions: dedup(allOpenQuestions),
            followUps: allFollowUps,            // keep all — different person/reason pairs
            lifeEvents: dedup(allLifeEvents),
            topics: dedup(allTopics),
            complianceFlags: dedup(allComplianceFlags),
            sentiment: sentiment,
            keyPoints: dedup(allKeyPoints),
            learningObjectives: dedup(allLearningObjectives),
            reviewNotes: mergedReviewNotes,
            attendees: dedup(allAttendees),
            agendaItems: allAgendaItems,        // keep all — order matters for minutes
            votes: allVotes                     // keep all — each vote is distinct
        )
    }

    // MARK: - Metadata

    struct Metadata: Sendable {
        var durationSeconds: TimeInterval = 0
        var speakerCount: Int = 0
        var detectedLanguage: String? = nil
        var recordedAt: Date? = nil
        var recordingContext: RecordingContext = .clientMeeting

        func promptLines() -> String {
            var lines: [String] = []
            if durationSeconds > 0 {
                let mins = Int(durationSeconds) / 60
                let secs = Int(durationSeconds) % 60
                lines.append("Duration: \(mins)m \(secs)s")
            }
            if speakerCount > 0 {
                lines.append("Speakers detected: \(speakerCount)")
            }
            if let lang = detectedLanguage, !lang.isEmpty {
                lines.append("Language: \(lang)")
            }
            if let recordedAt {
                lines.append("Recorded: \(recordedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            lines.append("Recording type: \(recordingContext.displayName)")
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Prompt

    /// Returns the system instruction appropriate for the given recording context.
    ///
    /// Internal so the test harness's stage cache can hash the active prompt
    /// into its cache key — edits to the prompt invalidate the summary cache
    /// automatically without needing a manual version bump.
    static func systemInstruction(for context: RecordingContext = .clientMeeting) -> String {
        switch context {
        case .clientMeeting:
            return clientMeetingInstruction()
        case .prospectingCall:
            let custom = UserDefaults.standard.string(forKey: "sam.ai.prospectingSummaryPrompt") ?? ""
            if !custom.isEmpty { return custom }
            return prospectingCallInstruction()
        case .recruitingInterview:
            let custom = UserDefaults.standard.string(forKey: "sam.ai.recruitingSummaryPrompt") ?? ""
            if !custom.isEmpty { return custom }
            return recruitingInterviewInstruction()
        case .annualReview:
            let custom = UserDefaults.standard.string(forKey: "sam.ai.annualReviewSummaryPrompt") ?? ""
            if !custom.isEmpty { return custom }
            return annualReviewInstruction()
        case .trainingLecture:
            let custom = UserDefaults.standard.string(forKey: "sam.ai.trainingSummaryPrompt") ?? ""
            if !custom.isEmpty { return custom }
            return trainingLectureInstruction()
        case .boardMeeting:
            let custom = UserDefaults.standard.string(forKey: "sam.ai.boardSummaryPrompt") ?? ""
            if !custom.isEmpty { return custom }
            return boardMeetingInstruction()
        }
    }

    // MARK: - Client Meeting Instruction

    private static func clientMeetingInstruction() -> String {
        // Allow user override via Settings
        let custom = UserDefaults.standard.string(forKey: "sam.ai.meetingSummaryPrompt") ?? ""
        if !custom.isEmpty { return custom }

        // Read practice type to determine persona and compliance rules
        let isFinancial: Bool
        if let data = UserDefaults.standard.data(forKey: "sam.businessProfile"),
           let profile = try? JSONDecoder().decode(BusinessProfile.self, from: data) {
            isFinancial = profile.isFinancial
        } else {
            isFinancial = true  // Default to financial for safety
        }

        let persona = isFinancial ? "a financial advisor" : "a professional"
        let complianceSection = isFinancial ? complianceSectionFinancialAdvisor : complianceSectionGeneral

        return """
        You summarize meeting transcripts for \(persona). Output \
        ONLY a JSON object matching the exact schema below. Every value you \
        emit must come from the transcript -- NEVER invent people, tasks, \
        topics, dates, or any other content.

        CRITICAL OUTPUT RULES
        - Respond with ONLY a raw JSON object starting with { and ending with }.
        - Do NOT wrap the JSON in markdown code blocks or prose.
        - Use ONLY ASCII characters (no smart quotes, no em-dashes).
        - If the transcript does not mention something for a field, use an \
          empty string or empty array for that field. NEVER fill fields with \
          invented content.
        - If the meeting is short, the summary should also be short.
        - If there is no decision, actionItems is still an array but may be empty.

        GROUNDING RULES
        - Every task, name, topic, date, and quote must be explicitly \
          present in the transcript. Do not paraphrase in ways that add \
          information.
        - Do not use any placeholder names. Use only names that literally \
          appear in the transcript.
        - When in doubt, leave fields empty.

        FIELD DEFINITIONS

        - title: 2-5 word title capturing the central subject of the meeting \
          (e.g. "Retirement Planning Review", "Policy Application Signing"). \
          Title case. No trailing punctuation.

        - tldr: 1-3 plain-language sentences summarizing what was actually \
          said. If two or more named individuals appear in the transcript \
          (other than the agent), mention them by name in the tldr. Always \
          include the most concrete commitment or decision if there is one. \
          Do not write a generic statement like "participants discussed \
          paperwork" -- name the people and the specific things they decided.

        - decisions: Concrete commitments or choices made during the \
          meeting. NOT plans to discuss or explore -- only commitments \
          that were made.

        - actionItems: Concrete tasks. Each has { task, owner, dueDate }. \
          owner is who will do it ("Agent", "Client", or a name from the \
          transcript). dueDate is free text -- "by Friday", "next week", \
          "before our next meeting on the 18th". Include EVERY task \
          assigned in the meeting, even if the same person owns several. \
          Omit owner/dueDate if not stated.

        - openQuestions: Things that still need answering.

        - followUps: Relationship-maintenance touches (checking in with \
          someone), NOT work tasks. Each has { person, reason }. Use this \
          for empathetic check-ins after life events, social courtesy \
          calls, or holiday outreach.

        - lifeEvents: Births, deaths, marriages, divorces, job changes, \
          retirements, moves, health events, college transitions, military \
          deployments. Include if explicitly mentioned in the transcript.

        - topics: Short topic tags (1-4 words each) describing what was \
          discussed. Include 2-6 topics for any meeting longer than a quick \
          reminder. This field should rarely be empty -- if anything \
          substantive was discussed, name the topics.

        \(complianceSection)

        - retentionSignals: Verbatim client quotes signaling retention risk — \
          considering another advisor, consulting outside the relationship, \
          surrendering a policy out of dissatisfaction, or "stewing". Preserve \
          specific days ("Saturday"), other advisor/firm names, and phrases \
          like "stewing" or "talked to someone else". Business-critical — the \
          advisor needs these anchors to act on retention risk. Empty array \
          if none.

        - numericalReframing: When the advisor revises a prior figure (return, \
          premium, timeline, amount), preserve BOTH the original number AND \
          the revised number verbatim in the same entry. Do not soften to \
          "the advisor clarified". Worked example: if the advisor said her \
          2022 messaging suggested 8-10% but a realistic long-term average is \
          5-6%, emit one entry containing both figures exactly as stated. \
          Empty array if none.

        - complianceStrengths: Compliance-positive behaviors as a counterweight \
          to complianceFlags — explicit commission disclosure, refusals to \
          guarantee returns, hedging that corrects inflated expectations, \
          no-pressure framing, explicit acknowledgment of prior messaging \
          errors. Empty array if none.

        - sentiment: Optional brief phrase describing the tone (e.g. "warm \
          and trusting", "cautious", "grieving").

        JSON SCHEMA (structure only)
        {
          "title": "<string>",
          "tldr": "<string>",
          "decisions": ["<string>", ...],
          "actionItems": [{"task": "<string>", "owner": "<string or null>", "dueDate": "<string or null>"}, ...],
          "openQuestions": ["<string>", ...],
          "followUps": [{"person": "<string>", "reason": "<string>"}, ...],
          "lifeEvents": ["<string>", ...],
          "topics": ["<string>", ...],
          "complianceFlags": ["<string>", ...],
          "retentionSignals": ["<string>", ...],
          "numericalReframing": ["<string>", ...],
          "complianceStrengths": ["<string>", ...],
          "sentiment": "<string or null>"
        }
        """
    }

    // MARK: - Prospecting Call Instruction

    private static func prospectingCallInstruction() -> String {
        """
        Summarize this prospecting call between a financial advisor and a prospective \
        client. The advisor will use this to remember who the prospect is, where they \
        came from, what they need, and what was committed to next. Every value must \
        come from the transcript -- never invent names, employers, dates, or content.

        FIELDS
        - title: 2-5 words, Title Case (e.g. "Warm Prospecting Call").
        - tldr: 1-3 sentences. Name the prospect and the referral source. State the \
          next meeting scheduled and the purpose of the call. Do not be generic.
        - decisions: commitments reached (next meeting scheduled, follow-up session \
          scheduled, no-obligation framing). Include the next session's date and time \
          using the wording the parties used ("Saturday the 7th at 9:30").
        - actionItems: {task, owner, dueDate}. Include EVERY artifact the advisor \
          promised to send (invite, intake form, follow-up email) and every commitment \
          the prospect made (complete form, bring spouse, return by deadline).
        - openQuestions: things the prospect raised that were not resolved.
        - followUps: {person, reason}. Use this for the referral chain — the person \
          who referred the prospect goes here with their relationship to the prospect.
        - lifeEvents: births, deaths, marriages, job changes, home purchases, moves, \
          new schooling — these often underlie why the prospect picked up the phone. \
          Include verbatim if mentioned.
        - topics: 2-6 short tags. Include the prospect's employer(s), existing plans \
          (401k, SEP, group benefits), and household composition as topics so this \
          profile isn't lost.
        - complianceFlags: any promises about returns, guarantees, definitive claims \
          about other advisors or products, or product-pitching on a first call. \
          Quote the offending phrase. Empty if none.
        - sentiment: brief tone phrase or null.

        ADDITIONAL FIELDS

        - retentionSignals: empty for a first-time prospecting call.
        - numericalReframing: only if the advisor revised a prior figure for the \
          prospect; usually empty.
        - complianceStrengths: compliance-positive behaviors — explicit commission \
          disclosure ("commissions will be shown"), no-obligation / no-pressure \
          framing, refusals to pitch product on a first call, hedging statements \
          like "I'd rather not sell you something wrong than sell you anything at \
          all". On a prospecting call the advisor's disclosure posture IS the \
          compliance record — capture it.

        GROUNDING
        Every name, employer, plan, and figure must literally appear in the \
        transcript. Preserve specific days-of-week, times, dollar amounts, and \
        employer names verbatim. Never synthesize a calendar date the transcript \
        does not state. Attribute concerns to the prospect and commitments to the \
        correct party.

        HOUSEHOLD PROFILE (critical)
        Prospecting calls establish who the prospect is — their household, their \
        partner's situation, their existing plans — and this profile must survive \
        into the summary so a future conversation can pick up without re-asking. \
        Capture these specific elements:
        - Spouse or partner name + profession/employer (verbatim): include in \
          tldr and as a topic tag. Example: "Teo (self-employed pediatric \
          dentist)" appears in both the tldr and topics.
        - Children's names and ages (verbatim): include as a topic tag. \
          Example: "Mia (6) and Kai (3)" is one tag, or "2 kids: Mia 6, Kai 3".
        - Prospect's employer + plan type (verbatim): include as a topic tag. \
          Example: "Genentech 401k".
        Do not paraphrase ages to "young children" or employers to "tech \
        company" — the names and specifics are the whole point of the profile. \
        If the transcript does not state one of these, omit it rather than \
        inventing.
        """
    }

    // MARK: - Recruiting Interview Instruction

    private static func recruitingInterviewInstruction() -> String {
        """
        Summarize this recruiting conversation between a financial advisor and a \
        prospective agent. The advisor will use this to recall the candidate's \
        situation, objections, and the next steps. Every value must come from the \
        transcript -- never invent names, income figures, or commitments.

        FIELDS
        - title: 2-5 words, Title Case (e.g. "Recruiting Conversation").
        - tldr: 1-3 sentences. Name the candidate and the referral source. State \
          the candidate's current situation briefly and the next step scheduled.
        - decisions: commitments reached (next meeting / BPM scheduled, candidate \
          bringing spouse, any topic explicitly deferred). Use the wording the \
          parties used for dates and times.
        - actionItems: {task, owner, dueDate}. Include EVERY artifact the advisor \
          promised (onboarding outline, compensation overview, BPM invite) and \
          every commitment the candidate made (bring spouse, contact coworker, \
          complete a step by a deadline). Every warm-market referral the \
          candidate offered is an action item for that introduction.
        - openQuestions: unresolved items, especially ones requiring a spouse or \
          family decision.
        - followUps: {person, reason}. Use this for the referral source who sent \
          the candidate and for any warm-market leads the candidate offered.
        - lifeEvents: births, deaths, diagnoses, marriages, job changes, moves, \
          new schooling. Candidates' motivations often trace to a recent life \
          event — include if mentioned.
        - topics: 2-6 short tags. Include the candidate's current employer/role, \
          licensing requirements discussed, compensation structure, onboarding \
          timeline, and specific objections raised (e.g. "MLM concern", "time \
          commitment", "year-one income"). These tags carry the recruiting \
          content that would otherwise be lost.
        - complianceFlags: any definitive income promises, guarantees of outcome, \
          or unhedged claims about how much the candidate will earn. Quote the \
          offending phrase. Empty if the advisor hedged appropriately.
        - sentiment: brief tone phrase or null.

        ADDITIONAL FIELDS

        - retentionSignals: empty for a recruiting interview.
        - numericalReframing: only if the advisor revised a prior figure \
          (compensation estimate, timeline). Preserve both numbers verbatim.
        - complianceStrengths: compliance-positive behaviors — explicit income \
          hedging ("most people earn nothing in year one", "this is not \
          guaranteed"), disclosure of licensing costs and time commitment, \
          acknowledgment of risk or failure rates, refusals to promise outcomes. \
          The advisor's hedging posture IS the compliance record for a \
          recruiting conversation — capture it.

        GROUNDING
        Every name, employer, dollar figure, and date must literally appear in \
        the transcript. Preserve specific days-of-week, times, and licensing \
        costs verbatim. Never synthesize a calendar date the transcript does \
        not state. Attribute concerns to the candidate and responses to the \
        advisor.

        CANDIDATE PROFILE (critical)
        Recruiting conversations establish the candidate's current baseline — \
        where they work, what they do, how long, and what they earn (if stated). \
        This profile must survive into the summary so the follow-up conversation \
        can start from the same footing. Capture:
        - Current employer + job title + tenure (verbatim): name these in the \
          tldr AND as a topic tag. Example: tldr says "Marcus, a nine-year \
          operations manager at Fremont Logistics"; topics include "operations \
          manager at Fremont Logistics" and "9 years".
        - Current compensation if stated (verbatim): include in topics as a tag. \
          Example: "$90k base + bonus".
        - Partner/spouse situation if raised (e.g., spouse's job, joint \
          decision-making): include as a topic tag.
        Do not paraphrase job titles to "manager" or tenure to "several years" — \
        the specifics are the baseline we need to build against.
        """
    }

    // MARK: - Annual Review Instruction

    private static func annualReviewInstruction() -> String {
        """
        Summarize this annual review meeting between a financial advisor and a \
        client. An annual review is a client meeting with a wider lens — prior \
        year's policies and decisions, updated life circumstances, progress \
        against stated goals, revised projections, and plans for the coming \
        year. Every value must come from the transcript -- never invent content.

        FIELDS
        - title: 2-5 words, Title Case (e.g. "Annual Review, 2026").
        - tldr: 1-3 sentences. Name the client and the most consequential \
          change year-over-year — a goal met or missed, a new policy added, \
          a life event that reshapes the plan, or a revised projection.
        - decisions: commitments reached — policy changes approved, beneficiary \
          updates, contribution changes, decisions to defer or continue. Use \
          verbatim language for dates and dollar amounts.
        - actionItems: {task, owner, dueDate}. Every task either party \
          committed to before the next review. Include illustrations, quotes, \
          applications, medical exam scheduling, beneficiary-update forms, \
          client document-gathering tasks.
        - openQuestions: items the client raised that need more information or \
          a partner/spouse decision.
        - followUps: {person, reason}. Relationship check-ins or referrals \
          from the client worth noting here.
        - lifeEvents: changes since the last review — births, deaths, \
          marriages, divorces, job changes, retirements, moves, health events, \
          college transitions. These drive much of the review's agenda.
        - topics: 3-8 short tags covering what was reviewed (e.g. "term life", \
          "college savings", "retirement projection", "estate beneficiaries").
        - complianceFlags: any guarantees, comparative-performance claims, or \
          definitive projections made by the advisor. Annual reviews often \
          revisit past projections — flag any that the advisor now states as \
          certainties. Quote the phrase. Empty if none.
        - sentiment: brief tone phrase or null.

        ADDITIONAL FIELDS

        - retentionSignals: verbatim client quotes about consulting another \
          advisor, considering surrendering a policy, "stewing" on a prior \
          recommendation, or shopping the relationship. Annual reviews are \
          prime retention-risk moments — capture these even if the client \
          ultimately committed to continue.
        - numericalReframing: when the advisor revises a prior-year figure \
          (last year's return expectation, a quoted premium, a timeline, a \
          projected account balance), preserve BOTH the original number AND \
          the revised number verbatim in one entry. Year-over-year reviews \
          produce these often — do not soften to "the advisor updated the \
          projection".
        - complianceStrengths: compliance-positive behaviors — explicit \
          commission disclosure on any new product discussed, refusals to \
          guarantee returns, hedging that corrects an inflated prior \
          expectation, acknowledgment that a previous year's messaging was \
          too optimistic, no-pressure framing around changes.

        GROUNDING
        Every name, dollar amount, carrier name, and date must literally \
        appear in the transcript. Preserve year-over-year figures exactly. \
        Never synthesize a calendar date. Attribute retention concerns to the \
        client and reframes to the advisor.

        YEAR-IN-REVIEW RECAP (critical)
        An annual review is a structured walk through each position the client \
        held a year ago and what has changed since. This historical recap is \
        the backbone of the meeting and must be captured in the summary — do \
        not let it get crowded out by decisions/reframes.
        - Every product, policy, or account in force at the prior review → \
          include it in topics as a short tag (e.g. "IUL", "term life", \
          "HELOC", "529 education", "Roth IRA"). This should be one of the \
          richest fields in an annual review.
        - Specific year-over-year changes per position → include each change \
          as its own entry in decisions (if action was taken this year) or \
          openQuestions (if deferred). Preserve the specific change verbatim: \
          "IUL credited 6% in year five", "HELOC paid off in August", "Maria's \
          education account distributed and closing in December as she \
          graduated", "premium adjusted from $X to $Y". Do not soften to \
          "various accounts reviewed" — each position gets its own entry.
        - tldr must name the single most consequential year-over-year change \
          (not just "annual review conducted"). "The Alvarez IUL hit its \
          fifth-year crediting at 6% and the HELOC cleared in August" is \
          correct; "The advisor reviewed the client's accounts" is not.
        Historical recap content (positions held + changes since) takes \
        priority over next-year planning when space is constrained. The \
        advisor needs to remember where things stood and how they moved \
        before talking about what comes next.
        """
    }

    // MARK: - Training / Lecture Instruction

    private static func trainingLectureInstruction() -> String {
        """
        Summarize this training session, lecture, or teaching transcript for a \
        financial advisor who attended. The advisor will use this summary to \
        review what was taught and act on the takeaways. Every value must come \
        from the transcript -- never invent content.

        FIELDS
        - title: 2-5 words, Title Case (e.g. "Needs-Based Selling Training").
        - tldr: 1-3 sentences. Name the instructor if stated and the session's \
          central thesis. State the single most important takeaway.
        - decisions: commitments the attendee(s) made during the session \
          (e.g. "commit to running two needs-based interviews this week"). \
          Empty if the session was purely informational.
        - actionItems: {task, owner, dueDate}. Any practice exercises, homework, \
          study assignments, or follow-up reading the instructor assigned, \
          including deadlines where stated.
        - openQuestions: questions raised by attendees that were not resolved.
        - followUps: {person, reason}. Mentors, coaches, or peers the instructor \
          suggested the attendee connect with. Empty if none.
        - lifeEvents: usually empty for training content.
        - topics: 3-8 short tags covering the session's core subjects (e.g. \
          "needs-based selling", "objection handling", "referral scripting"). \
          This should be one of the richest fields for a training session.
        - complianceFlags: any content that would be compliance-inappropriate to \
          repeat with a client (guaranteed-return claims, comparative performance \
          language, rebating suggestions). Quote the offending phrase. Empty if \
          the training was compliant.
        - sentiment: brief tone phrase or null.

        ADDITIONAL FIELDS

        - keyPoints: 5-10 verbatim or near-verbatim claims the instructor made. \
          This is the heart of the training summary. Every substantive idea the \
          instructor asserted (a technique, a rule, a statistic, a script \
          snippet) should appear here. Preserve specific numbers and named \
          techniques verbatim.
        - learningObjectives: 3-6 short sentences describing what attendees are \
          expected to be able to DO after the session — outcomes, not topics. \
          (e.g. "Run a needs-based interview without leading with product", "Use \
          the three-question referral ask at the close of a meeting".)
        - reviewNotes: A single prose paragraph (3-6 sentences) that a learner \
          could read to quickly review the core concepts covered. Write it as a \
          study aid, not a transcript summary. Connect the key ideas and explain \
          why they matter.
        - retentionSignals: empty for a training session.
        - numericalReframing: if the instructor corrected an earlier number \
          (e.g. a historical average or typical outcome), preserve both figures.
        - complianceStrengths: compliance-positive content the instructor \
          modeled — hedged income claims, proper disclosure framing, refusals \
          to promise outcomes. These are teaching moments; capture them.

        GROUNDING
        Every name, figure, technique, and statistic must literally appear in \
        the transcript. Preserve specific percentages, dollar amounts, and \
        named frameworks verbatim. Attribute statements to the instructor unless \
        the transcript clearly marks them as an attendee question or remark.
        """
    }

    // MARK: - Board Meeting Instruction

    private static func boardMeetingInstruction() -> String {
        """
        Summarize this board meeting or governance meeting transcript. The \
        output is a formal record -- verbatim motion language, named attendees, \
        agenda items with outcomes, votes with movers and seconders. Every \
        value must come from the transcript -- never invent content, names, or \
        motions.

        FIELDS
        - title: 2-5 words, Title Case, ideally naming the body (e.g. "Board \
          Meeting, April 2026", "Finance Committee").
        - tldr: 1-3 sentences. Name the chairperson if stated and the most \
          consequential decision or motion passed. State whether the meeting \
          concluded with quorum intact.
        - decisions: commitments and resolutions reached — name the motion if \
          tied to a vote, and any non-vote decisions (e.g. "deferred the budget \
          discussion to next session"). Empty only if the meeting adjourned \
          without any.
        - actionItems: {task, owner, dueDate}. Every assignment given to a \
          member or committee. Name the owner explicitly (use the person's \
          name, not "Board"). Include due dates and report-back deadlines.
        - openQuestions: matters tabled, deferred, or unresolved at adjournment.
        - followUps: {person, reason}. Members the chair asked to take \
          something offline, meet with a subcommittee, or connect with another \
          member. Empty if none.
        - lifeEvents: usually empty unless a member announced a life change \
          (retirement from the board, illness, death of a member).
        - topics: 3-8 short tags covering the agenda subjects discussed.
        - complianceFlags: governance issues — conflicts of interest not \
          disclosed, improper executive session usage, voting irregularities, \
          unauthorized commitments. Quote the phrase. Empty if the meeting \
          was procedurally clean.
        - sentiment: brief tone phrase or null.

        ADDITIONAL FIELDS

        - attendees: every named board member, officer, or staff member \
          recorded as present. Preserve first + last names exactly as spoken. \
          The chair and secretary should appear here.
        - agendaItems: {title, summary, outcome, notes}. One entry per agenda \
          item discussed. title is 2-4 words (e.g. "Q1 Budget Review"). \
          summary is 1-2 sentences on what was discussed. outcome is the \
          resolution ("approved", "tabled", "referred to committee", "no \
          action"). notes is optional discussion color. Include EVERY agenda \
          item the transcript addresses.
        - votes: {motion, movedBy, secondedBy, result, notes}. One entry per \
          formal motion voted on. motion is verbatim or near-verbatim motion \
          language ("Motion to approve the 2026 operating budget as \
          presented"). movedBy and secondedBy are the member names. result \
          is "passed", "failed", "tabled", or "withdrawn". notes captures \
          vote tallies ("7 in favor, 1 opposed, 1 abstained") if stated.
        - retentionSignals: empty for a board meeting.
        - numericalReframing: empty unless a budget or projection was revised \
          in-session — preserve both figures if so.
        - complianceStrengths: procedurally correct behavior worth noting — \
          explicit conflict-of-interest disclosures, proper recusal, call for \
          executive session handled by the bylaws.

        GROUNDING
        Every attendee, motion, mover, and seconder must literally appear in \
        the transcript. Do not infer movers from context. Preserve motion \
        language verbatim or very nearly so. If a vote tally was not stated, \
        leave notes empty — do not fabricate counts.

        FINANCIAL FIGURES (critical)
        Board meetings routinely include treasurer reports and budget \
        discussions that contain specific dollar amounts (quarterly revenue, \
        expenses, bank balance, budget line items, membership counts). These \
        figures are load-bearing governance content and MUST appear in the \
        summary. Route them as follows:
        - Treasurer-report numbers (Q1/Q2 revenue, expenses, net position, \
          bank balance) → agendaItems.notes for the treasurer item, verbatim. \
          Example: "Q1 revenue $48,200 vs budget $46,000; expenses $41,800 \
          vs budget $44,000; net favorable $4,400; bank balance $78,600 as \
          of April 1".
        - Budget line items tied to a vote → agendaItems.notes for that item, \
          verbatim. Example: "$42,500 total: venue $14,000, marketing $9,500, \
          admin/insurance $12,000, contingency $7,000".
        - Top-line quarter or meeting figures (total budget approved, bank \
          balance, membership count) → topics as short tags carrying the \
          number. Example: "Q2 budget $42,500", "bank balance $78,600".
        Preserve dollar amounts exactly as spoken — do not round, do not \
        paraphrase to "approximately", do not drop to a narrative like "the \
        treasurer reported favorable results". The numbers are the record.
        """
    }

    // MARK: - Compliance Profiles

    /// Financial Advisor compliance rules (WFG/insurance industry).
    /// Based on WFGIA Agent Insurance Guide (April 2025) — Trade Practices,
    /// Ethical Sales Practice Guidelines, and Quick Reference Do's and Don'ts.
    private static let complianceSectionFinancialAdvisor = """
        - complianceFlags: STATEMENTS that could trigger a regulatory \
          review. This is the MOST IMPORTANT field. The advisor's livelihood \
          depends on catching every potential violation. Be aggressive: if \
          you see any of the patterns below, you MUST add an entry. Empty \
          array is only correct if NONE of these patterns appear in the \
          transcript. NEVER invent a name to refer to "the advisor" -- use \
          only names that literally appear in the transcript.

           Patterns to flag (extract the offending phrase or close paraphrase):
           * GUARANTEES of investment performance: "guaranteed", \
             "risk-free", "zero risk", "can't lose", "principal protected", \
             "no downside"
           * COMPARATIVE PERFORMANCE claims: "outperformed the S&P", \
             "beats the market", "more reliable than bonds", "best in the \
             industry"
           * PROJECTED RETURNS with specific numbers: "8% annually", \
             "double your money in ten years", "averages 11% per year"
           * REBATING (illegal in most states): "agent rebate", "kickback", \
             "I'll cover your first premium", "cash back"
           * UNSUITABLE products mismatched to stated risk tolerance or \
             time horizon
           * PROHIBITED CLAIMS: "FDIC insured" on non-FDIC products, \
             "tax-free" on taxable products, "no fees" when fees exist
           * TWISTING: misrepresenting a policy to induce replacement \
             with another insurer's product
           * CHURNING: replacing a policy from the same insurer to earn \
             commission rather than benefit the client
           * MISREPRESENTATION: false statements about policy terms, \
             benefits, rates, advantages, or conditions
           * TAX OR LEGAL ADVICE: giving specific tax or legal advice \
             beyond commenting on product tax treatment
           * BORROWING/LENDING: offering to lend money to or borrow \
             from a client or client's family

           Worked example. Suppose the transcript contains:

               Agent: This product has guaranteed eight percent annual \
               returns through the income rider, and there is zero risk of \
               losing your principal. This fund has outperformed the S&P \
               500 every year since 2015. As a thank you, I can offer you \
               an agent rebate of two hundred dollars on the first year \
               premium.

           Then complianceFlags MUST be:

               [
                 "Claimed guaranteed 8% annual returns through the income rider",
                 "Claimed zero risk of losing principal",
                 "Claimed fund has outperformed the S&P 500 every year since 2015",
                 "Offered $200 agent rebate on first year premium (rebating)"
               ]

           Do NOT mention these things only in the tldr -- they must \
           appear in complianceFlags as well, even if you cover them in \
           the tldr.
        """

    /// General (non-regulated) compliance rules — minimal, universal ethics only.
    private static let complianceSectionGeneral = """
        - complianceFlags: This field is for noting any statements that \
          could be misleading, deceptive, or ethically problematic. For \
          most meetings this will be an empty array. Only flag clear \
          issues like false claims, deceptive promises, or discriminatory \
          language. Do not flag normal business discussion.
        """

    private static func buildPrompt(transcript: String, metadata: Metadata) -> String {
        let metaLines = metadata.promptLines()
        let metaBlock = metaLines.isEmpty ? "" : "METADATA:\n\(metaLines)\n\n"

        return """
        \(metaBlock)TRANSCRIPT:
        \(transcript)

        Summarize ONLY the transcript above. Every field in your JSON output \
        must be grounded in this transcript. If a field has no relevant \
        content, use an empty string or empty array. Do NOT invent content. \
        Do NOT reference any prior example. Return ONLY the JSON object.
        """
    }

    // MARK: - Errors

    enum SummaryError: Error, LocalizedError {
        case modelUnavailable
        case emptyTranscript
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .modelUnavailable: return "The on-device AI model is not available."
            case .emptyTranscript: return "The transcript is empty."
            case .invalidResponse: return "The AI returned an invalid response."
            }
        }
    }
}

// Persistence/wire helpers live on the shared `MeetingSummary` struct in
// SAMModels-Transcription.swift so both targets can use them.
