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
        case .trainingLecture:
            // Allow user override via Settings
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
          "sentiment": "<string or null>"
        }
        """
    }

    // MARK: - Training / Lecture Instruction

    private static func trainingLectureInstruction() -> String {
        """
        You extract learning content from training session or lecture transcripts. \
        Output ONLY a JSON object matching the exact schema below. Every value you \
        emit must come from the transcript -- NEVER invent content.

        CRITICAL OUTPUT RULES
        - Respond with ONLY a raw JSON object starting with { and ending with }.
        - Do NOT wrap the JSON in markdown code blocks or prose.
        - Use ONLY ASCII characters (no smart quotes, no em-dashes).
        - If the transcript does not contain something for a field, use an \
          empty string or empty array. NEVER fill fields with invented content.

        GROUNDING RULES
        - Every point, objective, topic, and quote must be explicitly \
          present in the transcript. Do not paraphrase in ways that add information.
        - When in doubt, leave fields empty.

        FIELD DEFINITIONS

        - title: 2-5 word title capturing the central subject of the lecture \
          (e.g. "Intro to IUL", "Client Objection Handling"). Title case. \
          No trailing punctuation.

        - tldr: 2-3 sentences summarizing what this training or lecture covered \
          and the central lesson or skill it aimed to develop.

        - keyPoints: The most important takeaways from the session. Each entry \
          is one complete sentence capturing a single insight, concept, or fact \
          the listener should remember. Aim for 4-8 entries for a full session.

        - learningObjectives: What this training or lecture explicitly aimed to \
          teach. If the presenter stated goals or outcomes, use those. Otherwise \
          infer from the content. Each entry is one sentence.

        - reviewNotes: A single prose paragraph (3-6 sentences) that a learner \
          could read to quickly review the core concepts covered. Write it as a \
          study aid, not a transcript summary. Connect the key ideas and explain \
          why they matter.

        - topics: Short topic tags (1-4 words each) describing subjects covered. \
          Include 2-8 tags for a full session.

        - actionItems: Follow-up study or practice tasks the presenter assigned \
          or that naturally follow from the content. Each has { task, owner, dueDate }. \
          owner is null (self-directed). dueDate is free text if mentioned. \
          If no tasks were assigned, return an empty array.

        JSON SCHEMA (structure only)
        {
          "title": "<string>",
          "tldr": "<string>",
          "keyPoints": ["<string>", ...],
          "learningObjectives": ["<string>", ...],
          "reviewNotes": "<string>",
          "topics": ["<string>", ...],
          "actionItems": [{"task": "<string>", "owner": null, "dueDate": "<string or null>"}, ...]
        }
        """
    }

    // MARK: - Board Meeting Instruction

    private static func boardMeetingInstruction() -> String {
        """
        You extract structured governance records from board meeting transcripts. \
        Output ONLY a JSON object matching the exact schema below. Every value you \
        emit must come from the transcript -- NEVER invent people, motions, \
        outcomes, or any other content.

        CRITICAL OUTPUT RULES
        - Respond with ONLY a raw JSON object starting with { and ending with }.
        - Do NOT wrap the JSON in markdown code blocks or prose.
        - Use ONLY ASCII characters (no smart quotes, no em-dashes).
        - If the transcript does not contain something for a field, use an \
          empty string or empty array. NEVER fill fields with invented content.
        - Use names exactly as they appear in the transcript.

        GROUNDING RULES
        - Every name, motion, decision, vote result, and date must be \
          explicitly present in the transcript.
        - Do not infer votes not stated. If a vote outcome is unclear, use \
          result: "Unclear" and add a note.
        - When in doubt, leave fields empty.

        FIELD DEFINITIONS

        - title: 2-5 word title for the meeting, typically the organization and \
          meeting type (e.g. "Q1 Board Meeting", "Audit Committee Session"). \
          Title case. No trailing punctuation.

        - tldr: 2-3 sentences summarizing the meeting: who attended, the \
          main business conducted, and any significant decisions made.

        - attendees: Names of all people identified as present. Use names \
          exactly as they appear. If a quorum call or roll call is present, \
          use those names.

        - agendaItems: Each formal topic brought before the board. Each has:
            title: The agenda item name or topic heading (1-8 words).
            summary: 1-2 sentences describing what was discussed under \
              this item and any key points raised.
            outcome: "Approved", "Rejected", "Tabled", "Deferred", \
              "Discussed" (no formal action), or null if not stated.
            notes: Optional additional context (motion text, conditions, \
              dissenting views). null if none.

        - votes: Each formal vote taken, even if already captured in \
          agendaItems. Each has:
            motion: The exact text of the motion or a close paraphrase \
              from the transcript.
            movedBy: Name of who moved the motion. null if not stated.
            secondedBy: Name of who seconded. null if not stated.
            result: "Passed", "Failed", "Tabled", "Withdrawn", \
              "No vote taken", or "Unclear".
            notes: Optional (e.g. vote count, conditions). null if none.

        - decisions: Formal decisions or resolutions adopted, as short \
          declarative statements. Draws from approved agenda items and \
          passed votes. May overlap with agendaItems -- include both.

        - actionItems: Tasks assigned during the meeting. Each has \
          { task, owner, dueDate }. owner is the name from the transcript \
          or null. dueDate is free text or null.

        - openQuestions: Items raised but not resolved or deferred for \
          future meetings.

        - topics: Short topic tags (1-4 words) for search and filing. \
          Include 2-8 tags.

        JSON SCHEMA (structure only)
        {
          "title": "<string>",
          "tldr": "<string>",
          "attendees": ["<string>", ...],
          "agendaItems": [
            {
              "title": "<string>",
              "summary": "<string or null>",
              "outcome": "<string or null>",
              "notes": "<string or null>"
            }, ...
          ],
          "votes": [
            {
              "motion": "<string>",
              "movedBy": "<string or null>",
              "secondedBy": "<string or null>",
              "result": "<string>",
              "notes": "<string or null>"
            }, ...
          ],
          "decisions": ["<string>", ...],
          "actionItems": [{"task": "<string>", "owner": "<string or null>", "dueDate": "<string or null>"}, ...],
          "openQuestions": ["<string>", ...],
          "topics": ["<string>", ...]
        }
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
