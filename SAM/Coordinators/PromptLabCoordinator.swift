//
//  PromptLabCoordinator.swift
//  SAM
//
//  Created on March 9, 2026.
//  Prompt Lab — Manages prompt variants, runs tests, stores results.
//

import Foundation
import os.log

@MainActor @Observable
final class PromptLabCoordinator {

    // MARK: - Singleton

    static let shared = PromptLabCoordinator()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PromptLab")

    private init() {
        loadStore()
    }

    // MARK: - State

    var store = PromptLabStore()
    var isRunning = false
    var runningVariantIDs: Set<UUID> = []
    var lastError: String?

    // MARK: - Persistence

    private var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let samDir = appSupport.appendingPathComponent("SAM", isDirectory: true)
        try? FileManager.default.createDirectory(at: samDir, withIntermediateDirectories: true)
        return samDir.appendingPathComponent("PromptLabStore.json")
    }

    private func loadStore() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            store = try JSONDecoder().decode(PromptLabStore.self, from: data)
            logger.debug("Loaded prompt lab store: \(self.store.variants.values.flatMap { $0 }.count) variants, \(self.store.testRuns.count) runs")
        } catch {
            logger.error("Failed to load prompt lab store: \(error.localizedDescription)")
        }
    }

    func saveStore() {
        do {
            let data = try JSONEncoder().encode(store)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            logger.error("Failed to save prompt lab store: \(error.localizedDescription)")
        }
    }

    // MARK: - Variant Management

    func variants(for site: PromptSite) -> [PromptVariant] {
        store.variants[site] ?? []
    }

    /// Ensures the default variant exists for a site. Creates it from the service's default prompt if missing.
    func ensureDefaultVariant(for site: PromptSite) async {
        var siteVariants = store.variants[site] ?? []
        if !siteVariants.contains(where: { $0.isDefault }) {
            let defaultVariant = PromptVariant(
                name: "Default",
                systemInstruction: await defaultPrompt(for: site),
                isDefault: true
            )
            siteVariants.insert(defaultVariant, at: 0)
            store.variants[site] = siteVariants
            saveStore()
        }
    }

    func addVariant(for site: PromptSite, name: String, systemInstruction: String) {
        var siteVariants = store.variants[site] ?? []
        let variant = PromptVariant(name: name, systemInstruction: systemInstruction)
        siteVariants.append(variant)
        store.variants[site] = siteVariants
        saveStore()
    }

    func duplicateVariant(_ variant: PromptVariant, for site: PromptSite) {
        var siteVariants = store.variants[site] ?? []
        let copy = PromptVariant(
            name: "\(variant.name) (copy)",
            systemInstruction: variant.systemInstruction
        )
        siteVariants.append(copy)
        store.variants[site] = siteVariants
        saveStore()
    }

    func updateVariant(_ variant: PromptVariant, for site: PromptSite) {
        guard var siteVariants = store.variants[site] else { return }
        if let idx = siteVariants.firstIndex(where: { $0.id == variant.id }) {
            siteVariants[idx] = variant
            store.variants[site] = siteVariants
            saveStore()
        }
    }

    func deleteVariant(_ variant: PromptVariant, for site: PromptSite) {
        guard !variant.isDefault else { return }
        guard var siteVariants = store.variants[site] else { return }
        siteVariants.removeAll { $0.id == variant.id }
        store.variants[site] = siteVariants
        // Remove associated test runs
        store.testRuns.removeAll { $0.variantID == variant.id }
        saveStore()
    }

    func rateVariant(_ variant: PromptVariant, rating: VariantRating, for site: PromptSite) {
        var updated = variant
        updated.rating = rating
        updateVariant(updated, for: site)
    }

    /// Deploy a variant as the active prompt for its site.
    func deployVariant(_ variant: PromptVariant, for site: PromptSite) {
        if variant.isDefault {
            // Revert to default — remove custom override
            UserDefaults.standard.removeObject(forKey: site.userDefaultsKey)
            logger.debug("Reverted \(site.rawValue) to default prompt")
        } else {
            UserDefaults.standard.set(variant.systemInstruction, forKey: site.userDefaultsKey)
            logger.debug("Deployed variant '\(variant.name)' for \(site.rawValue)")
        }
    }

    /// Returns the currently deployed prompt for a site (custom override or default).
    func deployedPrompt(for site: PromptSite) async -> String {
        let custom = UserDefaults.standard.string(forKey: site.userDefaultsKey) ?? ""
        if !custom.isEmpty { return custom }
        return await defaultPrompt(for: site)
    }

    /// Check if a non-default variant is currently deployed.
    func isDeployed(_ variant: PromptVariant, for site: PromptSite) -> Bool {
        if variant.isDefault {
            let custom = UserDefaults.standard.string(forKey: site.userDefaultsKey) ?? ""
            return custom.isEmpty
        }
        let deployed = UserDefaults.standard.string(forKey: site.userDefaultsKey) ?? ""
        return deployed == variant.systemInstruction
    }

    // MARK: - Test Runs

    func testRuns(for variantID: UUID) -> [PromptTestRun] {
        store.testRuns.filter { $0.variantID == variantID }
    }

    func latestRun(for variantID: UUID) -> PromptTestRun? {
        store.testRuns
            .filter { $0.variantID == variantID }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    /// Run all variants for a site against the given input.
    func runAll(site: PromptSite, input: String) async {
        let siteVariants = variants(for: site)
        guard !siteVariants.isEmpty else { return }

        isRunning = true
        lastError = nil

        // Run each variant sequentially to avoid overloading the LLM
        for variant in siteVariants {
            await runSingle(variant: variant, site: site, input: input)
        }

        isRunning = false
    }

    /// Run a single variant against the given input.
    func runSingle(variant: PromptVariant, site: PromptSite, input: String) async {
        runningVariantIDs.insert(variant.id)
        defer { runningVariantIDs.remove(variant.id) }

        let start = Date()
        let backendName = await AIService.shared.activeBackend().rawValue

        do {
            let prompt = buildUserPrompt(for: site, input: input)
            let output = try await AIService.shared.generateNarrative(
                prompt: prompt,
                systemInstruction: variant.systemInstruction,
                maxTokens: 4096
            )

            let duration = Date().timeIntervalSince(start)
            let run = PromptTestRun(
                variantID: variant.id,
                site: site,
                input: input,
                output: output,
                durationSeconds: duration,
                backend: backendName
            )
            store.testRuns.append(run)
            saveStore()
            logger.debug("Test run complete for '\(variant.name)' on \(site.rawValue) — \(String(format: "%.1f", duration))s")
        } catch {
            lastError = "Failed to run '\(variant.name)': \(error.localizedDescription)"
            logger.error("Test run failed for '\(variant.name)': \(error.localizedDescription)")
        }
    }

    /// Clear all test runs for a site.
    func clearRuns(for site: PromptSite) {
        store.testRuns.removeAll { $0.site == site }
        saveStore()
    }

    // MARK: - Registry Import

    /// Import optimized prompt variants from a sam-prompt-research registry JSON file.
    /// Skips variants whose name already exists for that site to avoid duplicates.
    func importFromRegistry(at url: URL) async throws -> RegistryImportResult {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let registry = try decoder.decode(PromptRegistry.self, from: data)

        var imported = 0
        var skipped = 0
        var unrecognizedSites: [String] = []

        for prompt in registry.prompts {
            guard let site = PromptSite.fromRegistryKey(prompt.site) else {
                if !unrecognizedSites.contains(prompt.site) {
                    unrecognizedSites.append(prompt.site)
                }
                logger.warning("Skipping unrecognized registry site: \(prompt.site)")
                continue
            }

            // Ensure the default variant exists before adding research variants
            await ensureDefaultVariant(for: site)

            let existingVariants = store.variants[site] ?? []
            let variantName = "Research: \(prompt.name) (v\(registry.metadata.version))"

            // Skip if a variant with this name already exists
            if existingVariants.contains(where: { $0.name == variantName }) {
                skipped += 1
                logger.debug("Skipped duplicate: \(variantName) for \(site.rawValue)")
                continue
            }

            let variant = PromptVariant(
                name: variantName,
                systemInstruction: prompt.systemInstruction
            )
            var siteVariants = store.variants[site] ?? []
            siteVariants.append(variant)
            store.variants[site] = siteVariants
            imported += 1
            logger.debug("Imported \(variantName) for \(site.rawValue) (avg score: \(String(format: "%.1f", prompt.avgScore)))")
        }

        saveStore()
        logger.debug("Registry v\(registry.metadata.version) import complete: \(imported) imported, \(skipped) skipped, \(unrecognizedSites.count) unrecognized sites")

        return RegistryImportResult(
            imported: imported,
            skipped: skipped,
            unrecognizedSites: unrecognizedSites,
            registryVersion: registry.metadata.version
        )
    }

    // MARK: - Default Prompts

    /// Returns the built-in default system instruction for each prompt site.
    func defaultPrompt(for site: PromptSite) async -> String {
        switch site {
        case .noteAnalysis:
            return NoteAnalysisService.defaultNotePrompt(persona: "an independent professional")

        case .emailAnalysis:
            return await EmailAnalysisService.defaultEmailPrompt()

        case .messageAnalysis:
            return await MessageAnalysisService.defaultPrompt()

        case .pipelineAnalyst:
            return Self.defaultPipelinePrompt

        case .timeAnalyst:
            return Self.defaultTimePrompt

        case .patternDetector:
            return Self.defaultPatternPrompt

        case .contentTopics:
            return Self.defaultContentTopicsPrompt

        case .contentDraft:
            return Self.defaultContentDraftPrompt

        case .morningBriefing:
            return Self.defaultMorningBriefingPrompt

        case .eveningBriefing:
            return Self.defaultEveningBriefingPrompt

        case .eventTopics:
            return Self.defaultEventTopicsPrompt
        }
    }

    /// Build the user-facing prompt (the "question") for a given site and input.
    private func buildUserPrompt(for site: PromptSite, input: String) -> String {
        switch site {
        case .noteAnalysis:
            return "Analyze this note and extract structured data:\n\n\(input)"

        case .emailAnalysis:
            return "Extract intelligence from this email:\n\n\(input)"

        case .messageAnalysis:
            return "Analyze this conversation thread:\n\n\(input)"

        case .pipelineAnalyst:
            let plPersona = BusinessProfileService.shared.personaFragmentSync()
            return "Analyze this pipeline data for \(plPersona):\n\n\(input)"

        case .timeAnalyst:
            let taPersona = BusinessProfileService.shared.personaFragmentSync()
            return "Analyze this time allocation data for \(taPersona):\n\n\(input)"

        case .patternDetector:
            return "Identify patterns in this business relationship data:\n\n\(input)"

        case .contentTopics:
            return "Suggest educational content topics based on this context:\n\n\(input)"

        case .contentDraft:
            return "Write a social media post based on this brief:\n\n\(input)"

        case .morningBriefing:
            return input  // The full data block is the prompt

        case .eveningBriefing:
            return input

        case .eventTopics:
            return "Suggest workshop/event topics based on this context:\n\n\(input)"
        }
    }

    // MARK: - Static Default Prompts (for services without static accessors)

    static var defaultPipelinePrompt: String {
        let persona = BusinessProfileService.shared.personaFragmentSync()
        return """
        You are a pipeline analyst for \(persona)'s practice. \
        Analyze the pipeline data provided and generate strategic recommendations. \
        Focus on conversion bottlenecks, stuck prospects, production gaps, and recruiting health.

        CRITICAL: You MUST respond with ONLY valid JSON.
        - Do NOT wrap the JSON in markdown code blocks
        - Return ONLY the raw JSON object starting with { and ending with }

        The JSON structure must be:
        {
          "health_summary": "1-2 sentence overall pipeline health assessment",
          "recommendations": [
            {
              "title": "Short actionable title",
              "rationale": "Why this matters and what to do",
              "priority": 0.8,
              "category": "pipeline",
              "approaches": [
                {
                  "title": "Short approach name",
                  "summary": "2-3 sentence description of this approach",
                  "steps": ["Step 1", "Step 2", "Step 3"],
                  "effort": "moderate"
                }
              ]
            }
          ],
          "risk_alerts": ["Urgent issue description"]
        }

        Rules:
        - health_summary should be specific to the numbers provided, not generic
        - Include 2-3 recommendations maximum, focused on highest impact
        - priority is 0.0 to 1.0 (1.0 = most urgent)
        - risk_alerts only for truly urgent issues (stuck people, zero conversion, etc.)
        - If data is sparse, keep recommendations brief rather than speculating
        - Each recommendation should include 2-3 approaches (alternative ways to implement it)
        - effort is "quick" (< 30 min), "moderate" (1-2 hours), or "substantial" (half-day+)
        - Name specific stuck people and explain what to do for each
        - Each rationale must include 2-3 concrete next steps that reference people by name
        - For pending production, name the person + product type + specific next step
        - risk_alerts must name the people involved
        - The top 3 stuck prospects each get an individual action plan in the approaches
        """
    }

    static var defaultTimePrompt: String {
        let persona = BusinessProfileService.shared.personaFragmentSync()
        return """
        You analyze how \(persona) allocates their work time. \
        Identify imbalances, suggest improvements, and highlight trends. \
        Common categories: Prospecting, Client Meeting, Policy Review, Recruiting, \
        Training/Mentoring, Admin, Deep Work, Personal Development, Travel, Other.

        CRITICAL: You MUST respond with ONLY valid JSON.
        - Do NOT wrap the JSON in markdown code blocks
        - Return ONLY the raw JSON object starting with { and ending with }

        The JSON structure must be:
        {
          "balance_summary": "1-2 sentence assessment of time allocation health",
          "recommendations": [
            {
              "title": "Short actionable title",
              "rationale": "Why this matters and what to change",
              "priority": 0.7,
              "category": "time",
              "approaches": [
                {
                  "title": "Short approach name",
                  "summary": "2-3 sentence description of this approach",
                  "steps": ["Step 1", "Step 2", "Step 3"],
                  "effort": "moderate"
                }
              ]
            }
          ],
          "imbalances": ["Specific imbalance description"]
        }

        Rules:
        - balance_summary should reference specific percentages from the data
        - Include 2-3 recommendations maximum
        - priority is 0.0 to 1.0 (1.0 = most urgent)
        - imbalances should be specific observations (e.g., "Only 15% client-facing time")
        - Aim for 40-60% of time on client-facing activities
        - If data is sparse, note that and keep recommendations conservative
        - Each recommendation should include 2-3 approaches (alternative ways to implement it)
        - effort is "quick" (< 30 min), "moderate" (1-2 hours), or "substantial" (half-day+)
        - Steps must suggest specific time blocks (e.g., "Block Tuesday 9-11 AM for prospecting calls")
        - Connect recommendations to the contact distribution data
        - Compare 7-day vs 30-day data to surface week-over-week trends
        - Flag categories at 0% this week but non-zero for the month
        """
    }

    static var defaultPatternPrompt: String {
        let persona = BusinessProfileService.shared.personaFragmentSync()
        return """
        You identify behavioral patterns and correlations in business relationship data \
        for \(persona). \
        Look for patterns in engagement, referral networks, meeting quality, and role transitions.

        CRITICAL: You MUST respond with ONLY valid JSON.
        - Do NOT wrap the JSON in markdown code blocks
        - Return ONLY the raw JSON object starting with { and ending with }

        The JSON structure must be:
        {
          "patterns": [
            {
              "description": "Clear description of the pattern observed",
              "confidence": "high",
              "data_points": 5
            }
          ],
          "recommendations": [
            {
              "title": "Short actionable title",
              "rationale": "Why this pattern matters and what to do about it",
              "priority": 0.6,
              "category": "pattern",
              "approaches": [
                {
                  "title": "Short approach name",
                  "summary": "2-3 sentence description of this approach",
                  "steps": ["Step 1", "Step 2", "Step 3"],
                  "effort": "moderate"
                }
              ]
            }
          ]
        }

        Rules:
        - Only report patterns supported by multiple data points
        - confidence is "high" (5+ data points), "medium" (3-4), or "low" (2)
        - Include 2-3 patterns maximum, most significant first
        - Include 1-2 recommendations based on patterns found
        - priority is 0.0 to 1.0 (1.0 = most actionable)
        - Do not fabricate patterns — if data is sparse, report fewer patterns
        - Each recommendation should include 2-3 approaches
        - effort is "quick" (< 30 min), "moderate" (1-2 hours), or "substantial" (half-day+)
        - Each pattern must reference the specific role group driving it with numbers
        - Name the count of cold/inactive people and their primary roles
        - Reference the actual referral partner count and interaction rate from the data
        - Explain causal relationships, not just correlations
        """
    }

    static var defaultContentTopicsPrompt: String {
        let persona = BusinessProfileService.shared.personaFragmentSync()
        let complianceNote = BusinessProfileService.shared.complianceNoteSync()
        let complianceClause = complianceNote.isEmpty ? "" : "\nNote: for financial topics, ensure compliance with industry regulations."
        return """
        Suggest 5 social media post ideas for \(persona) based on their recent activities.

        YOUR JOB is to suggest topics that make readers feel something — curiosity, \
        appreciation, inspiration, connection — not just learn something.

        TOPIC TITLE RULES:
        - Write titles as hooks. Ask a question, make a bold claim, or name an emotion.
        - Bad: "Navigating Leadership Transitions: Best Practices."
        - Good: "The Leader Who Built Something That Will Outlast Him."
        - No colons with subtitles. No "Lessons from..." or "Strategies for..." patterns.
        - Each title should make someone stop scrolling.

        KEY POINTS RULES:
        - First key point: a specific, concrete detail from the context data.
        - Include one ready-to-use opening sentence the user could copy into a post.
        - Last key point: an engagement hook — a question, invitation, or call to share.
        - Write from the user's perspective ("I" / "my"), not about the user.

        TONE VARIETY:
        - Vary suggested_tone across topics. Options: "personal", "inspirational", \
        "reflective", "celebratory", "curious". Do NOT default everything to "educational."

        CRITICAL: You MUST respond with ONLY valid JSON.
        - Do NOT wrap the JSON in markdown code blocks
        - Return ONLY the raw JSON object starting with { and ending with }

        The JSON structure must be:
        {
          "topic_suggestions": [
            {
              "topic": "Hook-style topic title",
              "key_points": ["Specific detail from data", "Copy-paste opening sentence", "Engagement question"],
              "suggested_tone": "personal",
              "compliance_notes": null
            }
          ]
        }
        \(complianceClause)
        """
    }

    static var defaultContentDraftPrompt: String {
        let persona = BusinessProfileService.shared.personaFragmentSync()
        let isFinancial = BusinessProfileService.shared.isFinancialPracticeSync()

        let complianceBlock: String
        if isFinancial {
            complianceBlock = """

            FINANCIAL COMPLIANCE (apply only to financial/investment topics):
            - Never promise specific returns or performance
            - Never mention specific product names, company names, or fund names
            - Include disclaimers for investment-related content
            - Use educational framing for financial topics
            """
        } else {
            complianceBlock = ""
        }

        return """
        You are an expert social media content writer for \(persona).

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
        - The goal is to make readers feel something — appreciation, curiosity, inspiration — not just inform them
        - Avoid writing like a report or press release; write like a person talking to friends who share their values
        - Weave the user's specific key points naturally into the narrative — each point should be clearly addressed

        HIGH-PERFORMING PATTERNS:
        - Open with a hook: a bold statement, a personal reflection, or a surprising fact
        - Use concrete details and specific examples rather than abstract descriptions
        - Create emotional resonance — connect facts to human impact and shared values
        - Keep paragraphs to 1-3 sentences for social media readability
        - Close with engagement: a question, a call to connect, or an invitation to learn more
        \(complianceBlock)
        """
    }

    static var defaultMorningBriefingPrompt: String {
        let persona = BusinessProfileService.shared.personaFragmentSync()
        return """
        You are a warm, professional executive assistant for \(persona).
        Write a concise morning briefing (4-6 sentences) based ONLY on the data below.

        CRITICAL: Only reference people, meetings, times, and goals that appear in the data.
        Never invent names, events, or details. If a section is missing, skip it.

        Structure:
        1. First 1-2 sentences: overview of the day based ONLY on data present. If TODAY'S CALENDAR is empty, say the calendar is open — NEVER invent meetings or times.
        2. Next 2-3 sentences: a suggested plan for the next 4 hours based on priority actions and follow-ups.
        3. If there are business goals, mention the most relevant one and what would move it forward today.

        Include exact times, full names, and specific details from the data. Be data-dense but readable.
        NEVER fabricate meetings, times, or events that do not appear in the data.
        Use a confident, forward-looking tone. No greetings or sign-offs.

        Respond with ONLY the narrative paragraph. No headers, bullets, or formatting.
        """
    }

    static var defaultEveningBriefingPrompt: String {
        let persona = BusinessProfileService.shared.personaFragmentSync()
        return """
        You are a warm, professional executive assistant summarizing the day for \(persona).
        Write a concise end-of-day summary (3-5 sentences) based ONLY on the data below.

        CRITICAL: Only reference accomplishments, metrics, and events that appear in the data.
        Never invent names or details. If a section is missing, skip it.

        Celebrate accomplishments. Note key metrics. Preview tomorrow. Be encouraging but honest.

        Respond with ONLY the narrative paragraph. No headers, bullets, or formatting.
        """
    }

    static var defaultEventTopicsPrompt: String {
        let persona = BusinessProfileService.shared.personaFragmentSync()
        let complianceNote = BusinessProfileService.shared.complianceNoteSync()
        let complianceClause = complianceNote.isEmpty ? "" : ", compliant with industry regulations"
        return """
        You suggest workshop and event topics for \(persona) \
        to host for their clients, leads, and professional network. Topics should be \
        educational\(complianceClause), timely, and grounded \
        in actual recent interactions.

        Suggest 3-5 topics. Every rationale MUST reference specific people or meeting topics \
        from the data. Do NOT invent interactions or people. Topics should be educational \
        workshops, not sales pitches. Never suggest specific product recommendations.

        Return valid JSON with a "suggestions" array.
        """
    }
}
