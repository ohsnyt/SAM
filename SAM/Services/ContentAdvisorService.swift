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
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContentAdvisorService")

    private init() {}

    // MARK: - Analysis

    func analyze(data: String) async throws -> ContentAnalysis {
        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let businessContext = await BusinessProfileService.shared.fullContextBlock()

        let instructions = """
            You suggest educational content topics for an independent financial strategist. \
            Topics should be relevant to their client base, timely for the season, and compliant with \
            financial services regulations. Content is for social media posts, newsletters, or client education.

            \(businessContext)

            CRITICAL: You MUST respond with ONLY valid JSON.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            The JSON structure must be:
            {
              "topic_suggestions": [
                {
                  "topic": "Clear topic title",
                  "key_points": ["Point 1", "Point 2", "Point 3"],
                  "suggested_tone": "educational",
                  "compliance_notes": "Any regulatory considerations or null"
                }
              ]
            }

            Rules:
            - Suggest 3-5 topics, most relevant first
            - suggested_tone options: "educational", "motivational", "seasonal", "technical"
            - Include compliance_notes for topics touching investments, insurance, or guarantees
            - Topics should connect to recent client conversations when possible
            - Seasonal context matters (tax season, open enrollment, year-end planning, etc.)
            - Never suggest specific product recommendations or guarantees
            - Each topic must cite the specific recent meeting or discussion topic that inspired it (e.g., "Inspired by your meeting with John about retirement planning")
            - Include one copy-paste-ready opening sentence as a key_point (e.g., "Ever wonder how much you actually need to retire comfortably?")
            - Suggest the best platform + posting day for each topic (e.g., "Best on LinkedIn, post Tuesday morning")
            - At least 2 topics must connect to named meeting topics from the data — do not invent meetings that aren't in the data
            - If the user has a Substack publication, suggest content that extends existing article themes. \
            Reference specific past articles when suggesting new topics. \
            Maintain voice consistency with the user's established writing style.
            """

        let prompt = """
            Suggest educational content topics based on this context:

            \(data)
            """

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        return try parseResponse(responseText)
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
        guard case .available = await AIService.shared.checkAvailability() else {
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

        let complianceSection = complianceNotes.map { "Compliance considerations: \($0)" } ?? ""
        let keyPointsText = keyPoints.isEmpty ? "" : "Key points to cover: \(keyPoints.joined(separator: "; "))"
        let businessContext = await BusinessProfileService.shared.contextFragment()

        // For Substack, inject prominent voice/publication context
        let substackVoiceBlock: String
        if platform == .substack, let profile = await BusinessProfileService.shared.substackProfile() {
            var voiceLines: [String] = []
            voiceLines.append("WRITING VOICE — Match this style closely:")
            if !profile.writingVoiceSummary.isEmpty {
                voiceLines.append("Voice analysis: \(profile.writingVoiceSummary)")
            }
            if !profile.publicationName.isEmpty {
                voiceLines.append("Publication: \"\(profile.publicationName)\"")
            }
            if !profile.publicationDescription.isEmpty {
                voiceLines.append("Publication focus: \(profile.publicationDescription)")
            }
            if !profile.topicSummary.isEmpty {
                voiceLines.append("Core topics: \(profile.topicSummary.joined(separator: ", "))")
            }
            if !profile.recentPostTitles.isEmpty {
                let titles = profile.recentPostTitles.prefix(5).map { "\"\($0.title)\"" }
                voiceLines.append("Recent articles for style reference: \(titles.joined(separator: "; "))")
            }
            voiceLines.append("Write as if you ARE this author continuing their publication. The reader should not notice a change in voice.")
            substackVoiceBlock = voiceLines.joined(separator: "\n")
        } else {
            substackVoiceBlock = ""
        }

        let contentType = platform == .substack ? "newsletter articles" : "social media posts"
        let instructions = """
            You write \(contentType) for an independent financial strategist. \
            The content must be educational and compliant with financial services regulations.

            \(businessContext)

            \(substackVoiceBlock)

            STRICT COMPLIANCE RULES:
            - NEVER mention specific product names, company names, or fund names
            - NEVER promise returns, guarantees, or specific financial outcomes
            - NEVER make comparative claims against competitors
            - NEVER give specific financial advice (e.g., "You should invest in X")
            - Always use educational framing: "Consider...", "Many people find...", "A common strategy is..."
            - If the topic is sensitive, add a disclaimer

            \(platformGuidelines)

            Tone: \(tone)
            \(keyPointsText)
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

        let formatLabel = platform == .substack ? "a Substack newsletter article (800-1000 words)" : "a social media post"
        let prompt = "Write \(formatLabel) about: \(topic)"
        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        return try parseDraftResponse(responseText)
    }

    private func parseDraftResponse(_ jsonString: String) throws -> ContentDraft {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)
        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMContentDraft.self, from: data)
            return ContentDraft(
                draftText: llm.draftText ?? "",
                complianceFlags: llm.complianceFlags ?? []
            )
        } catch {
            // If JSON parsing fails, treat the entire response as the draft text
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty {
                logger.info("Draft generation returned plain text, using as draft body")
                return ContentDraft(draftText: String(plainText.prefix(2000)))
            }
            logger.error("Draft generation JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> ContentAnalysis {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)
        guard let data = cleaned.data(using: .utf8) else {
            throw AnalysisError.invalidResponse
        }

        do {
            let llm = try JSONDecoder().decode(LLMContentAnalysis.self, from: data)
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
        } catch {
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                logger.info("Content analysis returned plain text, using as single topic")
                return ContentAnalysis(
                    topicSuggestions: [ContentTopic(topic: String(plainText.prefix(200)))]
                )
            }
            logger.error("Content analysis JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }
}
