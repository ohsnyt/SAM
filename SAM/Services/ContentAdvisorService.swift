//
//  ContentAdvisorService.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase V: Business Intelligence — Strategic Coordinator
//
//  Actor-isolated specialist that suggests educational content topics
//  for a WFG financial strategist based on recent interactions and seasonal context.
//

import Foundation
import os.log

actor ContentAdvisorService {

    // MARK: - Singleton

    static let shared = ContentAdvisorService()
    private let logger = Logger(
        subsystem: "com.matthewsessions.SAM",
        category: "ContentAdvisorService"
    )

    private init() {}

    // MARK: - Analysis

    func analyze(data: String) async throws -> ContentAnalysis {
        guard case .available = await AIService.shared.checkAvailability()
        else {
            throw AnalysisError.modelUnavailable
        }

        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logger.debug("Content advisor skipped — no interaction data available")
            return ContentAnalysis()
        }

        let businessContext = await BusinessProfileService.shared
            .fullContextBlock()

        let customPrompt = await MainActor.run {
            UserDefaults.standard.string(
                forKey: PromptSite.contentTopics.userDefaultsKey
            ) ?? ""
        }
        let jsonFormat = """

            CRITICAL: You MUST respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            The JSON structure must be:
            {
              "topic_suggestions": [
                {
                  "topic": "specific content idea",
                  "key_points": ["point 1", "point 2", "point 3"],
                  "suggested_tone": "educational",
                  "compliance_notes": "required disclaimers or null"
                }
              ]
            }
            """

        let instructions: String
        if !customPrompt.isEmpty {
            instructions = customPrompt + "\n\n" + businessContext + jsonFormat
        } else {
            instructions = """
                Suggest 5 social media post ideas based on the user's recent activities and interests.

                YOUR JOB is to suggest topics that will make the user's audience feel something — \
                curiosity, appreciation, inspiration, connection — not just learn something.

                TOPIC TITLE RULES:
                - Write titles as hooks, not headlines. Ask a question, make a bold claim, \
                or name an emotion. Bad: "Navigating Leadership Transitions: Best Practices." \
                Good: "The Leader Who Built Something That Will Outlast Him."
                - Titles should sound like something a real person would say to a friend, \
                not a consulting firm's report title.
                - No colons followed by subtitles. No "Lessons from..." or "Strategies for..." \
                or "Best Practices in..." patterns.
                - Each title should make someone stop scrolling and want to read more.

                KEY POINTS RULES:
                - The first key point should be a specific, concrete detail from the context data — \
                not a generic observation.
                - Include one ready-to-use opening sentence that the user could copy directly \
                into a post.
                - The last key point should be an engagement hook: a question to ask readers, \
                an invitation to connect, or a call to share their own experience.
                - Write from the user's perspective ("I" / "my") not about the user ("the professional").

                TONE:
                - suggested_tone should vary across topics. Use: "personal" (sharing from experience), \
                "inspirational" (calling to action), "reflective" (honest observation), \
                "celebratory" (highlighting wins), "curious" (asking genuine questions).
                - Do NOT default everything to "educational."

                GOAL ALIGNMENT:
                - If ACTIVE BUSINESS GOALS are provided, 2-3 topics should support those goals — \
                but frame them as genuine stories or reflections, not marketing tactics.

                \(jsonFormat)
                """
        }

        let prompt = """
            Suggest social media post ideas based on this context about my work and interests:

            \(data)
            """

        // Use generateNarrative to prefer MLX (Qwen) — FoundationModels ignores
        // style instructions and produces generic "Title: Subtitle" topics regardless of prompt.
        let responseText = try await AIService.shared.generateNarrative(
            prompt: prompt,
            systemInstruction: instructions
        )
        logger.debug("📝 Content advisor raw response (\(responseText.count) chars): \(String(responseText.prefix(500)))")
        let analysis = try parseResponse(responseText)
        logger.debug("📝 Content advisor parsed \(analysis.topicSuggestions.count) topics")
        for (i, topic) in analysis.topicSuggestions.enumerated() {
            logger.debug("📝  Topic \(i+1): \(topic.topic)")
        }
        return analysis
    }

    // MARK: - Draft Generation (Phase W)

    /// Generate a platform-aware social media draft from a topic.
    func generateDraft(
        topic: String,
        keyPoints: [String],
        platform: ContentPlatform,
        tone: String,
        complianceNotes: String?
    ) async throws -> ContentDraft {
        guard case .available = await AIService.shared.checkAvailability()
        else {
            throw AnalysisError.modelUnavailable
        }

        let platformGuidelines: String
        switch platform {
        case .linkedin:
            platformGuidelines = """
                Platform: LinkedIn
                - Professional, educational tone
                - 150-250 words
                - Open with a hook question or bold statement
                - Include 1-3 relevant hashtags at the end
                - End with a call-to-action or thought-provoking question
                """
        case .facebook:
            platformGuidelines = """
                Platform: Facebook
                - Conversational, relatable tone
                - 100-150 words
                - Make it personal — share a lesson or observation
                - End with an engagement question
                - No hashtags (or 1-2 at most)
                """
        case .instagram:
            platformGuidelines = """
                Platform: Instagram
                - Brief, hook-focused
                - 50-100 words for caption
                - Start with a strong hook line
                - Include 5-10 relevant hashtags
                - Use line breaks for readability
                """
        case .substack:
            platformGuidelines = """
                Platform: Substack (long-form newsletter article)
                THIS IS A NEWSLETTER ARTICLE, NOT A SOCIAL MEDIA POST. It must be substantially longer than other platforms.
                - MINIMUM 600 words, TARGET 800-1000 words. This is critical — short posts are unacceptable for Substack.
                - Educational, in-depth tone matching the author's established voice
                - Structure with an introduction (2-3 paragraphs), 2-4 sections with subheadings (## format), and a conclusion
                - Open with a compelling hook, personal anecdote, or relatable scenario
                - Each section should develop a distinct point with examples, stories, or practical advice
                - End with a clear takeaway, reflection, or call-to-action
                - Reference previous articles when building on past topics
                - Do NOT include hashtags — this is a newsletter, not social media
                """
        case .other:
            platformGuidelines = """
                Platform: General
                - Clear, educational tone
                - 100-200 words
                - Focus on providing value
                """
        }

        let complianceSection =
            complianceNotes.map { "Compliance considerations: \($0)" } ?? ""
        let businessContext = await BusinessProfileService.shared
            .contextFragment()

        let voiceBlock = await buildVoiceBlock(for: platform)

        let persona = await BusinessProfileService.shared.personaFragment()
        let isFinancial = await BusinessProfileService.shared.isFinancialPractice()
        let complianceNote = await BusinessProfileService.shared.complianceNote()

        // Use Prompt Lab deployed variant if available
        let customDraftPrompt = await MainActor.run { UserDefaults.standard.string(forKey: PromptSite.contentDraft.userDefaultsKey) ?? "" }

        let contentType =
            platform == .substack ? "newsletter articles" : "social media posts"
        let complianceLine = complianceNote.isEmpty ? "" : " \(complianceNote)"

        let financialComplianceBlock = isFinancial ? """

            FINANCIAL COMPLIANCE RULES (apply only to financial/investment topics):
            - NEVER mention specific product names, company names, or fund names
            - NEVER promise returns, guarantees, or specific financial outcomes
            - NEVER make comparative claims against competitors
            - NEVER give specific financial advice (e.g., "You should invest in X")
            - Always use educational framing: "Consider...", "Many people find...", "A common strategy is..."
            """ : ""

        let instructions: String
        if !customDraftPrompt.isEmpty {
            instructions = customDraftPrompt
        } else {
        instructions = """
            You write \(contentType) for \(persona).\(complianceLine)

            \(businessContext)

            \(voiceBlock)

            CONTENT SCOPE:
            The user may request posts on ANY topic — professional, personal, nonprofit, \
            ministry, faith-based, charitable, community, or any other subject. \
            All user-supplied topics are appropriate and should be fulfilled enthusiastically.

            WRITING STYLE:
            - Write in a warm, personal voice — as if the author is sharing something they care about
            - Lead with emotion, values, or a compelling question — not dry facts
            - Use short paragraphs and line breaks for readability
            - Share just enough detail to spark curiosity and engagement
            - End with a clear invitation: ask a question, invite comments, or suggest a next step
            - The goal is to make readers feel something — appreciation, curiosity, inspiration — \
            not just inform them
            - Avoid writing like a report or press release; write like a person talking to friends \
            who share their values
            \(financialComplianceBlock)

            \(platformGuidelines)

            Tone: \(tone)
            \(complianceSection)

            CRITICAL: Respond with ONLY valid JSON (no markdown code blocks).
            The draft_text field must contain YOUR COMPLETE ORIGINAL DRAFT about the requested topic.
            Do NOT echo these instructions or example values — write real content.
            {
              "draft_text": "Your complete draft goes here. Write the actual article or post content about the topic.",
              "compliance_flags": ["List any compliance concerns, or leave as empty array"]
            }

            If there are no compliance concerns, return an empty array for compliance_flags.
            """
        }

        let formatLabel =
            platform == .substack
            ? "a Substack newsletter article (800-1000 words)"
            : "a social media post"

        var prompt = "Write \(formatLabel) about: \(topic)"
        if !keyPoints.isEmpty {
            let numbered = keyPoints.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            prompt += """


                The post MUST cover these specific points — do not omit or generalize them:
                \(numbered)

                Weave all of these points naturally into the post. Each point should be clearly addressed.
                """
        }

        // Use generateNarrative to prefer MLX (Qwen) for content drafting —
        // better prose quality and no overly cautious Apple safety filters.
        var responseText = try await AIService.shared.generateNarrative(
            prompt: prompt,
            systemInstruction: instructions
        )

        // Detect model refusal and retry with softened framing
        if Self.isRefusal(responseText) {
            logger.warning("Draft generation refused, retrying with softened prompt")
            let softenedPrompt = "Write \(formatLabel) about: \(topic). " +
                "This is a personal post by the author about their own life and community involvement. " +
                "Focus on the positive, human-interest angle."
            responseText = try await AIService.shared.generateNarrative(
                prompt: softenedPrompt,
                systemInstruction: instructions
            )
        }
        return try parseDraftResponse(responseText)
    }

    private func parseDraftResponse(_ jsonString: String) throws -> ContentDraft
    {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)

        // Attempt 1: direct JSON decode
        if let data = cleaned.data(using: .utf8),
            let llm = try? JSONDecoder().decode(
                LLMContentDraft.self,
                from: data
            ),
            let text = llm.draftText, !text.isEmpty
        {
            return ContentDraft(
                draftText: text,
                complianceFlags: llm.complianceFlags ?? []
            )
        }

        // Attempt 2: sanitize literal newlines inside JSON string values and retry
        let sanitized = Self.sanitizeJSONNewlines(cleaned)
        if let data = sanitized.data(using: .utf8),
            let llm = try? JSONDecoder().decode(
                LLMContentDraft.self,
                from: data
            ),
            let text = llm.draftText, !text.isEmpty
        {
            logger.debug("Draft parsed after newline sanitization")
            return ContentDraft(
                draftText: text,
                complianceFlags: llm.complianceFlags ?? []
            )
        }

        // Attempt 3: regex extract draft_text value between quotes
        if let extracted = Self.extractDraftText(from: cleaned) {
            logger.debug("Draft extracted via regex fallback")
            return ContentDraft(draftText: extracted)
        }

        // Attempt 4: plain text fallback — the model returned prose instead of JSON.
        // Strip residual JSON artifacts (keys, braces, brackets) and use as-is.
        var plainText = cleaned
        // Remove JSON structural artifacts
        for artifact in ["\"draft_text\"", "\"compliance_flags\"", "\"compliance_flags\": []", "\"compliance_flags\":[]"] {
            plainText = plainText.replacingOccurrences(of: artifact, with: "")
        }
        // Remove leading/trailing braces and brackets
        plainText = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if plainText.hasPrefix("{") { plainText = String(plainText.dropFirst()) }
        if plainText.hasSuffix("}") { plainText = String(plainText.dropLast()) }
        // Remove leading colon/comma left from key-value stripping
        plainText = plainText.trimmingCharacters(in: CharacterSet(charactersIn: ":,\" \t\n"))
        if !plainText.isEmpty {
            logger.debug(
                "Draft generation returned plain text, using as draft body"
            )
            return ContentDraft(draftText: String(plainText.prefix(5000)))
        }

        logger.error("Draft generation parsing failed completely")
        throw AnalysisError.invalidResponse
    }

    /// Detect on-device model refusal responses (safety filter rejections).
    private static func isRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let refusalPhrases = [
            "i cannot write",
            "i can't write",
            "i'm unable to",
            "i am unable to",
            "safeguards prevent",
            "against my guidelines",
            "controversial",
            "i cannot create",
            "i can't create",
            "i cannot generate",
            "i can't generate",
            "not appropriate for me",
        ]
        return refusalPhrases.contains { lower.contains($0) }
    }

    /// Escape literal newlines inside JSON string values so JSONDecoder can parse them.
    /// Walks the string tracking quote boundaries to only escape newlines within strings.
    private static func sanitizeJSONNewlines(_ json: String) -> String {
        var result = ""
        result.reserveCapacity(json.count)
        var inString = false
        var escaped = false
        for char in json {
            if escaped {
                result.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                result.append(char)
                continue
            }
            if char == "\"" {
                inString.toggle()
                result.append(char)
                continue
            }
            if inString && char == "\n" {
                result.append("\\")
                result.append("n")
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// Regex fallback: extract the value of "draft_text" from a JSON-like string.
    private static func extractDraftText(from text: String) -> String? {
        // Find "draft_text" : "..." — greedy match up to the last plausible closing pattern
        guard
            let keyRange = text.range(
                of: "\"draft_text\"",
                options: .caseInsensitive
            )
        else { return nil }
        let afterKey = text[keyRange.upperBound...]
        // Skip whitespace, colon, whitespace, opening quote
        guard let colonIdx = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colonIdx)...].drop(
            while: { $0.isWhitespace })
        guard afterColon.first == "\"" else { return nil }
        let contentStart = afterColon.index(after: afterColon.startIndex)

        // Walk forward to find the closing quote (not preceded by backslash)
        // But also handle the common case where the AI uses literal newlines
        // Look for `", ` or `"\n` followed by `"compliance` as end markers
        if let endPattern = text.range(
            of: "\",\\s*\"compliance_flags\"",
            options: .regularExpression,
            range: contentStart..<text.endIndex
        ) {
            let draft = String(text[contentStart..<endPattern.lowerBound])
            return draft.isEmpty ? nil : draft
        }

        // Simpler: find last `"` before `compliance_flags` or end of object
        if let endPattern = text.range(
            of: "\"compliance_flags\"",
            range: contentStart..<text.endIndex
        ) {
            // Walk backward from the match to find the preceding quote
            var idx = endPattern.lowerBound
            while idx > contentStart {
                idx = text.index(before: idx)
                if text[idx] == "\"" {
                    let draft = String(text[contentStart..<idx])
                    return draft.isEmpty ? nil : draft
                }
            }
        }

        return nil
    }

    // MARK: - Voice Block

    /// Build a platform-appropriate writing voice block for draft generation prompts.
    /// Uses the target platform's voice data when available, falls back to cross-platform data.
    private func buildVoiceBlock(for platform: ContentPlatform) async -> String
    {
        let bps = BusinessProfileService.shared
        let substackProfile = await bps.substackProfile()
        let linkedInProfile = await bps.linkedInProfile()
        let facebookProfile = await bps.facebookProfile()

        var voiceLines: [String] = []

        switch platform {
        case .substack:
            guard let profile = substackProfile else { break }
            voiceLines.append("WRITING VOICE — Match this style closely:")
            if !profile.writingVoiceSummary.isEmpty {
                voiceLines.append(
                    "Voice analysis: \(profile.writingVoiceSummary)"
                )
            }
            if !profile.publicationName.isEmpty {
                voiceLines.append("Publication: \"\(profile.publicationName)\"")
            }
            if !profile.publicationDescription.isEmpty {
                voiceLines.append(
                    "Publication focus: \(profile.publicationDescription)"
                )
            }
            if !profile.topicSummary.isEmpty {
                voiceLines.append(
                    "Core topics: \(profile.topicSummary.joined(separator: ", "))"
                )
            }
            if !profile.recentPostTitles.isEmpty {
                let titles = profile.recentPostTitles.prefix(5).map {
                    "\"\($0.title)\""
                }
                voiceLines.append(
                    "Recent articles for style reference: \(titles.joined(separator: "; "))"
                )
            }
            voiceLines.append(
                "Write as if you ARE this author continuing their publication. The reader should not notice a change in voice."
            )

        case .linkedin:
            if let profile = linkedInProfile,
                !profile.writingVoiceSummary.isEmpty
            {
                voiceLines.append("WRITING VOICE — Match this style closely:")
                voiceLines.append(
                    "Voice analysis: \(profile.writingVoiceSummary)"
                )
                if !profile.headline.isEmpty {
                    voiceLines.append(
                        "Professional headline: \(profile.headline)"
                    )
                }
                if !profile.recentShareSnippets.isEmpty {
                    let snippets = profile.recentShareSnippets.prefix(3).map {
                        "\"\($0.prefix(100))\""
                    }
                    voiceLines.append(
                        "Recent post samples: \(snippets.joined(separator: "; "))"
                    )
                }
                voiceLines.append(
                    "Write as if you ARE this professional on LinkedIn. The reader should not notice a change in voice."
                )
            } else {
                // Cross-platform fallback
                let fallbackVoice = bestAvailableVoice(
                    substack: substackProfile,
                    facebook: facebookProfile
                )
                if !fallbackVoice.isEmpty {
                    voiceLines.append(
                        "WRITING VOICE — Adapt this style for LinkedIn (professional, educational):"
                    )
                    voiceLines.append(
                        "Voice analysis (from other platform): \(fallbackVoice)"
                    )
                    voiceLines.append(
                        "Adjust tone to be professional and authoritative for a LinkedIn audience."
                    )
                }
            }

        case .facebook:
            if let profile = facebookProfile,
                !profile.writingVoiceSummary.isEmpty
            {
                voiceLines.append("WRITING VOICE — Match this style closely:")
                voiceLines.append(
                    "Voice analysis: \(profile.writingVoiceSummary)"
                )
                if !profile.recentPostSnippets.isEmpty {
                    let snippets = profile.recentPostSnippets.prefix(3).map {
                        "\"\($0.prefix(100))\""
                    }
                    voiceLines.append(
                        "Recent post samples: \(snippets.joined(separator: "; "))"
                    )
                }
                voiceLines.append(
                    "Write as if you ARE this person on Facebook. Keep the tone personal and authentic. The reader should not notice a change in voice."
                )
            } else {
                // Cross-platform fallback
                let fallbackVoice = bestAvailableVoice(
                    substack: substackProfile,
                    linkedIn: linkedInProfile
                )
                if !fallbackVoice.isEmpty {
                    voiceLines.append(
                        "WRITING VOICE — Adapt this style for Facebook (conversational, personal):"
                    )
                    voiceLines.append(
                        "Voice analysis (from other platform): \(fallbackVoice)"
                    )
                    voiceLines.append(
                        "Adjust tone to be casual, personal, and authentic for a Facebook audience."
                    )
                }
            }

        case .instagram, .other:
            // Cross-reference best available voice data
            let fallbackVoice = bestAvailableVoice(
                substack: substackProfile,
                linkedIn: linkedInProfile,
                facebook: facebookProfile
            )
            if !fallbackVoice.isEmpty {
                let platformLabel =
                    platform == .instagram
                    ? "Instagram" : "general social media"
                voiceLines.append(
                    "WRITING VOICE — Adapt this style for \(platformLabel):"
                )
                voiceLines.append(
                    "Voice analysis (from other platform): \(fallbackVoice)"
                )
                if platform == .instagram {
                    voiceLines.append(
                        "Adjust tone to be concise, visual, and hook-focused for Instagram."
                    )
                }
            }
        }

        return voiceLines.joined(separator: "\n")
    }

    /// Returns the best available voice summary from any connected platform, preferring richer sources.
    private func bestAvailableVoice(
        substack: UserSubstackProfileDTO? = nil,
        linkedIn: UserLinkedInProfileDTO? = nil,
        facebook: UserFacebookProfileDTO? = nil
    ) -> String {
        // Prefer Substack (richest content), then LinkedIn, then Facebook
        if let voice = substack?.writingVoiceSummary, !voice.isEmpty {
            return voice
        }
        if let voice = linkedIn?.writingVoiceSummary, !voice.isEmpty {
            return voice
        }
        if let voice = facebook?.writingVoiceSummary, !voice.isEmpty {
            return voice
        }
        return ""
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> ContentAnalysis {
        var cleaned = JSONExtraction.extractJSON(from: jsonString)

        // Sanitize common MLX JSON errors:
        // 1. Unquoted keys like `clam:` → remove the offending line
        // 2. Trailing commas before closing brackets
        cleaned = Self.sanitizeMLXJSON(cleaned)

        logger.debug("📝 Content parseResponse — cleaned JSON (\(cleaned.count) chars): \(String(cleaned.prefix(300)))")
        guard let data = cleaned.data(using: .utf8) else {
            logger.error("📝 Content parseResponse — failed to convert cleaned JSON to UTF-8 data")
            throw AnalysisError.invalidResponse
        }

        do {
            // Primary: expect {"topic_suggestions": [...]}
            let llm = try JSONDecoder().decode(
                LLMContentAnalysis.self,
                from: data
            )
            return ContentAnalysis(
                topicSuggestions: (llm.topicSuggestions ?? []).compactMap { t in
                    guard let topic = t.topic else { return nil }
                    return ContentTopic(
                        topic: topic,
                        keyPoints: t.keyPoints ?? [],
                        suggestedTone: t.suggestedTone ?? "educational",
                        complianceNotes: t.complianceNotes
                    )
                }
            )
        } catch DecodingError.typeMismatch {
            // Fallback: LLM returned a bare array instead of an object
            logger.debug("📝 Content parseResponse — retrying as bare array")
            let topics = try JSONDecoder().decode(
                [LLMContentTopic].self,
                from: data
            )
            return ContentAnalysis(
                topicSuggestions: topics.compactMap { t in
                    guard let topic = t.topic else { return nil }
                    return ContentTopic(
                        topic: topic,
                        keyPoints: t.keyPoints ?? [],
                        suggestedTone: t.suggestedTone ?? "educational",
                        complianceNotes: t.complianceNotes
                    )
                }
            )
        } catch {
            let plainText = jsonString.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.debug(
                    "Content analysis returned plain text, using as single topic"
                )
                return ContentAnalysis(
                    topicSuggestions: [
                        ContentTopic(topic: String(plainText.prefix(200)))
                    ]
                )
            }
            logger.error(
                "Content analysis JSON parsing failed: \(error.localizedDescription)"
            )
            throw error
        }
    }

    /// Fix common MLX/Qwen JSON hallucinations that break parsing.
    /// - Removes lines with unquoted keys (e.g., `clam: "reflective"`)
    /// - Fixes trailing commas before `]` or `}`
    static func sanitizeMLXJSON(_ json: String) -> String {
        var lines = json.components(separatedBy: .newlines)

        // Remove lines with unquoted keys (word followed by colon, not inside quotes)
        // Valid JSON keys are always "quoted": value
        // Hallucinated keys look like: clam: "reflective"
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match pattern: starts with a bare word (no quote) followed by colon
            if let colonIdx = trimmed.firstIndex(of: ":"),
               !trimmed.hasPrefix("\""),
               !trimmed.hasPrefix("{"),
               !trimmed.hasPrefix("["),
               !trimmed.hasPrefix("}"),
               !trimmed.hasPrefix("]"),
               !trimmed.isEmpty {
                let beforeColon = trimmed[trimmed.startIndex..<colonIdx]
                    .trimmingCharacters(in: .whitespaces)
                // If it's a bare word (no quotes), it's a hallucinated key
                if !beforeColon.isEmpty && !beforeColon.hasPrefix("\"") &&
                   beforeColon.allSatisfy({ $0.isLetter || $0 == "_" }) {
                    return false
                }
            }
            return true
        }

        var result = lines.joined(separator: "\n")

        // Fix trailing commas: `,` followed by whitespace/newlines then `]` or `}`
        let trailingCommaPattern = #",\s*([\]\}])"#
        if let regex = try? NSRegularExpression(pattern: trailingCommaPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: "$1"
            )
        }

        return result
    }
}
