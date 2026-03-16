// CrossPlatformConsistencyService.swift
// SAM
//
// Phase FB-4: Cross-Platform Profile Consistency (Spec §9)
//
// Compares the user's LinkedIn and Facebook profiles for inconsistencies,
// identifies contacts who appear on both platforms, and merges touch scores
// for cross-platform contacts.
//
// This service unlocks LinkedIn §11 — which was deferred until a second
// platform became available.

import Foundation
import os.log

actor CrossPlatformConsistencyService {

    // MARK: - Singleton

    static let shared = CrossPlatformConsistencyService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CrossPlatformConsistency")

    private init() {}

    // MARK: - Profile Comparison

    /// Compares the user's LinkedIn and Facebook profiles for inconsistencies.
    /// Returns a structured result with field-by-field comparison.
    func compareProfiles(
        linkedIn: UserLinkedInProfileDTO,
        facebook: UserFacebookProfileDTO
    ) -> CrossPlatformProfileComparison {

        var fields: [CrossPlatformFieldComparison] = []

        // Name comparison
        let linkedInName = "\(linkedIn.firstName) \(linkedIn.lastName)".trimmingCharacters(in: .whitespaces)
        let facebookName = facebook.fullName
        fields.append(CrossPlatformFieldComparison(
            field: "Name",
            linkedInValue: linkedInName,
            facebookValue: facebookName,
            status: normalizedMatch(linkedInName, facebookName) ? .consistent : .inconsistent,
            note: normalizedMatch(linkedInName, facebookName) ? nil : "Names differ — may use different formality levels"
        ))

        // Current employer
        let liEmployer = linkedIn.currentPosition?.companyName ?? ""
        let fbEmployer = facebook.workExperiences.first?.employer ?? ""
        if !liEmployer.isEmpty || !fbEmployer.isEmpty {
            let match = normalizedMatch(liEmployer, fbEmployer)
            fields.append(CrossPlatformFieldComparison(
                field: "Current Employer",
                linkedInValue: liEmployer.isEmpty ? "(not set)" : liEmployer,
                facebookValue: fbEmployer.isEmpty ? "(not set)" : fbEmployer,
                status: match ? .consistent : (liEmployer.isEmpty || fbEmployer.isEmpty ? .missingOnOnePlatform : .inconsistent),
                note: match ? nil : "Employer should be identical on both platforms"
            ))
        }

        // Current title
        let liTitle = linkedIn.currentPosition?.title ?? ""
        let fbTitle = facebook.workExperiences.first?.title ?? ""
        if !liTitle.isEmpty || !fbTitle.isEmpty {
            let match = normalizedMatch(liTitle, fbTitle)
            fields.append(CrossPlatformFieldComparison(
                field: "Current Title",
                linkedInValue: liTitle.isEmpty ? "(not set)" : liTitle,
                facebookValue: fbTitle.isEmpty ? "(not set)" : fbTitle,
                status: match ? .consistent : (liTitle.isEmpty || fbTitle.isEmpty ? .missingOnOnePlatform : .inconsistent),
                note: nil
            ))
        }

        // Location
        let liLocation = linkedIn.geoLocation
        let fbLocation = facebook.currentCity ?? ""
        if !liLocation.isEmpty || !fbLocation.isEmpty {
            // Fuzzy match — LinkedIn might say "St. Louis, Missouri" while Facebook says "St. Louis, MO"
            let match = fuzzyLocationMatch(liLocation, fbLocation)
            fields.append(CrossPlatformFieldComparison(
                field: "Location",
                linkedInValue: liLocation.isEmpty ? "(not set)" : liLocation,
                facebookValue: fbLocation.isEmpty ? "(not set)" : fbLocation,
                status: match ? .consistent : (liLocation.isEmpty || fbLocation.isEmpty ? .missingOnOnePlatform : .inconsistent),
                note: match ? nil : "Location descriptions differ — verify both are current"
            ))
        }

        // Education (compare school names)
        let liSchools = Set(linkedIn.education.map { normalize($0.schoolName) })
        let fbSchools = Set(facebook.educationExperiences.map { normalize($0.name) })
        if !liSchools.isEmpty || !fbSchools.isEmpty {
            let overlap = liSchools.intersection(fbSchools)
            let liOnly = liSchools.subtracting(fbSchools)
            let fbOnly = fbSchools.subtracting(liSchools)

            let status: CrossPlatformFieldStatus
            if liSchools == fbSchools || (!overlap.isEmpty && liOnly.isEmpty && fbOnly.isEmpty) {
                status = .consistent
            } else if !overlap.isEmpty {
                status = .partialMatch
            } else if liSchools.isEmpty || fbSchools.isEmpty {
                status = .missingOnOnePlatform
            } else {
                status = .inconsistent
            }

            fields.append(CrossPlatformFieldComparison(
                field: "Education",
                linkedInValue: linkedIn.education.map(\.schoolName).joined(separator: ", "),
                facebookValue: facebook.educationExperiences.map(\.name).joined(separator: ", "),
                status: status,
                note: liOnly.isEmpty && fbOnly.isEmpty ? nil : "Some schools appear on only one platform"
            ))
        }

        // Websites
        // LinkedIn profile may have a website in the profile; Facebook has explicit websites array
        if !facebook.websites.isEmpty {
            fields.append(CrossPlatformFieldComparison(
                field: "Websites",
                linkedInValue: "(check LinkedIn profile manually)",
                facebookValue: facebook.websites.joined(separator: ", "),
                status: .needsManualCheck,
                note: "Verify website links are consistent across platforms"
            ))
        }

        // Compute overall score
        let totalFields = fields.count
        let consistentFields = fields.filter { $0.status == .consistent }.count
        let overallScore = totalFields > 0 ? Int(Double(consistentFields) / Double(totalFields) * 100) : 100

        return CrossPlatformProfileComparison(
            comparisonDate: .now,
            fields: fields,
            overallConsistencyScore: overallScore,
            linkedInProfileAvailable: true,
            facebookProfileAvailable: true
        )
    }

    // MARK: - Friend Overlap Detection

    /// Identifies people who appear as both LinkedIn connections and Facebook friends.
    /// Uses fuzzy name matching since Facebook exports don't include profile URLs.
    ///
    /// - Parameters:
    ///   - facebookFriends: Parsed Facebook friend list
    ///   - linkedInConnections: Names of LinkedIn connections (from existing SamPerson records with LinkedIn URLs)
    /// - Returns: Array of cross-platform contact matches
    func findCrossPlatformContacts(
        facebookFriends: [(name: String, friendedOn: Date)],
        linkedInConnections: [(name: String, profileURL: String)]
    ) -> [CrossPlatformContactMatch] {

        var matches: [CrossPlatformContactMatch] = []
        let normalizer = FacebookService.shared

        // Build a normalized name → LinkedIn data lookup
        var linkedInByNormalizedName: [String: (name: String, profileURL: String)] = [:]
        for connection in linkedInConnections {
            let norm = normalizer.normalizeNameForMatching(connection.name)
            linkedInByNormalizedName[norm] = connection
        }

        for friend in facebookFriends {
            let norm = normalizer.normalizeNameForMatching(friend.name)
            if let liMatch = linkedInByNormalizedName[norm] {
                matches.append(CrossPlatformContactMatch(
                    facebookName: friend.name,
                    linkedInName: liMatch.name,
                    linkedInProfileURL: liMatch.profileURL,
                    facebookFriendedOn: friend.friendedOn,
                    matchConfidence: .high  // Exact normalized name match
                ))
            }
        }

        logger.debug("Cross-platform overlap: \(matches.count) contacts on both LinkedIn and Facebook")
        return matches
    }

    // MARK: - AI Analysis

    /// Runs an AI analysis of cross-platform consistency, using both profile comparison
    /// and friend overlap data.
    func analyzeConsistency(
        profileComparison: CrossPlatformProfileComparison,
        overlapCount: Int,
        totalLinkedInConnections: Int,
        totalFacebookFriends: Int
    ) async throws -> ProfileAnalysisDTO {

        guard case .available = await AIService.shared.checkAvailability() else {
            throw AnalysisError.modelUnavailable
        }

        let businessContext = await BusinessProfileService.shared.compactContextBlock()

        let persona = await BusinessProfileService.shared.personaFragment()

        let instructions = """
            You are a cross-platform profile consistency advisor for \(persona). \
            This person maintains both a LinkedIn profile (professional networking) and a Facebook profile (personal/community connections). \
            Your job is to identify inconsistencies between the two profiles and suggest corrections.

            \(businessContext)

            IMPORTANT PRINCIPLES:
            - LinkedIn is the PROFESSIONAL platform: optimize for discoverability, credibility, and business
            - Facebook is the PERSONAL platform: optimize for authenticity, community trust, and approachability
            - The two should be consistent in FACTS (name, employer, education, location) but may differ in TONE
            - Never suggest making Facebook more professional or LinkedIn more personal
            - Focus on factual inconsistencies that could confuse contacts or undermine credibility

            Analyze the cross-platform data and provide:
            1. PRAISE — What's consistent and well-maintained across platforms
            2. IMPROVEMENTS — For EVERY inconsistency, provide platform-specific copy-paste text in example_or_prompt. \
            Format: "Paste this on LinkedIn: '[exact text]'. Paste this on Facebook: '[exact text]'." \
            Every improvement MUST include example_or_prompt with ready-to-paste text for the relevant platform(s).
            3. CONTENT STRATEGY — How the two platforms should complement each other
            4. NETWORK HEALTH — Cross-platform contact overlap assessment
            5. EXTERNAL PROMPT — A prompt for deeper cross-platform optimization

            CRITICAL: respond with ONLY valid JSON matching the ProfileAnalysisDTO schema.
            - Do NOT wrap the JSON in markdown code blocks
            - Return ONLY the raw JSON object starting with { and ending with }

            JSON schema:
            {
              "overall_score": 72,
              "praise": [{ "category": "...", "message": "...", "metric": "..." }],
              "improvements": [{ "category": "...", "priority": "high|medium|low", "suggestion": "...", "rationale": "...", "example_or_prompt": "..." }],
              "content_strategy": { "summary": "...", "posting_frequency": "...", "content_mix": "...", "engagement_assessment": "...", "topic_suggestions": ["..."] },
              "network_health": { "summary": "...", "growth_trend": "...", "endorsement_insight": "...", "recommendation_reciprocity": "..." },
              "changes_since_last": null,
              "external_prompt": { "context": "...", "prompt": "...", "copy_button_label": "Copy Cross-Platform Optimization Prompt" }
            }
            """

        var dataLines: [String] = []
        dataLines.append("Cross-Platform Profile Comparison")
        dataLines.append("Overall consistency: \(profileComparison.overallConsistencyScore)%\n")

        for field in profileComparison.fields {
            dataLines.append("\(field.field):")
            dataLines.append("  LinkedIn: \(field.linkedInValue)")
            dataLines.append("  Facebook: \(field.facebookValue)")
            dataLines.append("  Status: \(field.status.rawValue)")
            if let note = field.note { dataLines.append("  Note: \(note)") }
            dataLines.append("")
        }

        dataLines.append("Network Overlap:")
        dataLines.append("  LinkedIn connections: \(totalLinkedInConnections)")
        dataLines.append("  Facebook friends: \(totalFacebookFriends)")
        dataLines.append("  Appear on both: \(overlapCount)")
        if totalLinkedInConnections > 0 && totalFacebookFriends > 0 {
            let overlapPct = Double(overlapCount) / Double(min(totalLinkedInConnections, totalFacebookFriends)) * 100
            dataLines.append("  Overlap rate: \(String(format: "%.1f%%", overlapPct))")
        }

        let prompt = """
            Analyze this cross-platform profile comparison:

            \(dataLines.joined(separator: "\n"))
            """

        let systemSize = instructions.count
        let promptSize = prompt.count
        logger.debug("📏 CrossPlatformConsistency prompt — system: \(systemSize)ch, user: \(promptSize)ch, total: \((systemSize+promptSize)/4)t")

        let responseText = try await AIService.shared.generate(prompt: prompt, systemInstruction: instructions)
        logger.debug("📏 CrossPlatformConsistency response — \(responseText.count)ch")

        return try parseResponse(responseText)
    }

    // MARK: - Parsing

    private func parseResponse(_ jsonString: String) throws -> ProfileAnalysisDTO {
        let cleaned = JSONExtraction.extractJSON(from: jsonString)
        do {
            return try parseProfileAnalysisJSON(cleaned, platform: "crossPlatform")
        } catch {
            let plainText = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !plainText.isEmpty && !plainText.contains("{") {
                return ProfileAnalysisDTO(
                    analysisDate: .now,
                    platform: "crossPlatform",
                    overallScore: 50,
                    praise: [],
                    improvements: [],
                    contentStrategy: nil,
                    networkHealth: NetworkHealthAssessmentDTO(
                        summary: String(plainText.prefix(500)),
                        growthTrend: nil,
                        endorsementInsight: nil,
                        recommendationReciprocity: nil
                    ),
                    changesSinceLastAnalysis: nil,
                    externalPrompt: nil
                )
            }
            logger.error("CrossPlatformConsistency JSON parsing failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - String Matching Helpers

    private func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func normalizedMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty && !b.isEmpty else { return false }
        return normalize(a) == normalize(b)
    }

    private func fuzzyLocationMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty && !b.isEmpty else { return false }
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        // Check if one contains the other (e.g., "St. Louis" contains "st louis")
        if na.contains(nb) || nb.contains(na) { return true }
        // Check if they share a significant word (city name)
        let wordsA = Set(na.components(separatedBy: " ").filter { $0.count > 3 })
        let wordsB = Set(nb.components(separatedBy: " ").filter { $0.count > 3 })
        return !wordsA.intersection(wordsB).isEmpty
    }
}

// MARK: - DTOs

/// Result of comparing the user's profiles across LinkedIn and Facebook.
public struct CrossPlatformProfileComparison: Codable, Sendable {
    public var comparisonDate: Date
    public var fields: [CrossPlatformFieldComparison]
    public var overallConsistencyScore: Int  // 0–100
    public var linkedInProfileAvailable: Bool
    public var facebookProfileAvailable: Bool
}

/// A single field comparison between LinkedIn and Facebook.
public struct CrossPlatformFieldComparison: Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var field: String
    public var linkedInValue: String
    public var facebookValue: String
    public var status: CrossPlatformFieldStatus
    public var note: String?
}

/// Status of a cross-platform field comparison.
public enum CrossPlatformFieldStatus: String, Codable, Sendable {
    case consistent = "Consistent"
    case inconsistent = "Inconsistent"
    case partialMatch = "Partial Match"
    case missingOnOnePlatform = "Missing on One Platform"
    case needsManualCheck = "Needs Manual Check"
}

/// A contact identified on both LinkedIn and Facebook.
public struct CrossPlatformContactMatch: Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var facebookName: String
    public var linkedInName: String
    public var linkedInProfileURL: String
    public var facebookFriendedOn: Date
    public var matchConfidence: MatchConfidence

    public enum MatchConfidence: String, Codable, Sendable {
        case high = "High"      // Exact normalized name match
        case medium = "Medium"  // Fuzzy name match
        case low = "Low"        // Partial name match
    }
}
