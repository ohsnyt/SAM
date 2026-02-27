//
//  BusinessProfileDTO.swift
//  SAM
//
//  Created on February 27, 2026.
//  Phase AB: Coaching Calibration — Business Context Profile
//
//  Stores core facts about the user's practice that are injected into
//  every AI agent's system instruction to prevent irrelevant suggestions.
//

import Foundation

/// The user's business context profile — injected into all AI specialist system instructions.
/// Persisted as JSON in UserDefaults via `BusinessProfileService`.
nonisolated public struct BusinessProfile: Codable, Sendable, Equatable {

    // MARK: - Practice Structure

    /// Whether this is a solo practice (true) or has a team (false).
    public var isSoloPractitioner: Bool

    /// The parent organization (e.g., "World Financial Group").
    public var organization: String

    /// The user's role title (e.g., "Senior Marketing Director", "Associate").
    public var roleTitle: String

    /// Years of experience in the financial services industry.
    public var yearsExperience: Int

    // MARK: - Practice Focus

    /// Primary market focus areas (e.g., ["Life Insurance", "Retirement Planning", "Mortgage Protection"]).
    public var marketFocus: [String]

    /// Whether the user is actively recruiting agents.
    public var isActivelyRecruiting: Bool

    /// Geographic market (e.g., "San Diego, CA" or "Southern California").
    public var geographicMarket: String

    // MARK: - Tools & Capabilities

    /// SAM is the user's CRM — they do not use external CRM software.
    /// This prevents suggestions to "research CRM tools", "purchase Salesforce", etc.
    public var samIsCRM: Bool

    /// Social media platforms the user actively uses (e.g., ["Facebook", "LinkedIn"]).
    public var activeSocialPlatforms: [String]

    /// Communication channels available (e.g., ["iMessage", "Email", "Phone"]).
    public var communicationChannels: [String]

    // MARK: - Custom Context

    /// Free-form additional context the user wants all AI agents to know.
    /// E.g., "I specialize in serving military families" or "My warm market is exhausted."
    public var additionalContext: String

    // MARK: - Init

    public init(
        isSoloPractitioner: Bool = true,
        organization: String = "World Financial Group",
        roleTitle: String = "",
        yearsExperience: Int = 0,
        marketFocus: [String] = [],
        isActivelyRecruiting: Bool = false,
        geographicMarket: String = "",
        samIsCRM: Bool = true,
        activeSocialPlatforms: [String] = ["Facebook", "LinkedIn"],
        communicationChannels: [String] = ["iMessage", "Email", "Phone"],
        additionalContext: String = ""
    ) {
        self.isSoloPractitioner = isSoloPractitioner
        self.organization = organization
        self.roleTitle = roleTitle
        self.yearsExperience = yearsExperience
        self.marketFocus = marketFocus
        self.isActivelyRecruiting = isActivelyRecruiting
        self.geographicMarket = geographicMarket
        self.samIsCRM = samIsCRM
        self.activeSocialPlatforms = activeSocialPlatforms
        self.communicationChannels = communicationChannels
        self.additionalContext = additionalContext
    }

    // MARK: - System Instruction Fragment

    /// Generates the context block to inject into AI system instructions.
    public func systemInstructionFragment() -> String {
        var lines: [String] = []

        lines.append("BUSINESS CONTEXT (about the user):")
        if isSoloPractitioner {
            lines.append("• This is a SOLO independent practice — there is no team, no sales team, no assistants, no employees.")
        } else {
            lines.append("• The user has a team-based practice.")
        }

        lines.append("• Organization: \(organization)")

        if !roleTitle.isEmpty {
            lines.append("• Role: \(roleTitle)")
        }

        if yearsExperience > 0 {
            lines.append("• Experience: \(yearsExperience) years in financial services")
        }

        if !marketFocus.isEmpty {
            lines.append("• Market focus: \(marketFocus.joined(separator: ", "))")
        }

        if isActivelyRecruiting {
            lines.append("• Actively recruiting new agents")
        }

        if !geographicMarket.isEmpty {
            lines.append("• Geographic market: \(geographicMarket)")
        }

        if samIsCRM {
            lines.append("• SAM IS the user's CRM — do NOT suggest researching, purchasing, or using other CRM tools or software")
        }

        if !activeSocialPlatforms.isEmpty {
            lines.append("• Active social platforms: \(activeSocialPlatforms.joined(separator: ", "))")
        }

        if !communicationChannels.isEmpty {
            lines.append("• Communication channels: \(communicationChannels.joined(separator: ", "))")
        }

        if !additionalContext.isEmpty {
            lines.append("• Additional context: \(additionalContext)")
        }

        return lines.joined(separator: "\n")
    }
}
