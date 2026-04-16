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

// MARK: - PracticeType

/// Controls which features SAM surfaces and how AI prompts describe the user's role.
public enum PracticeType: String, Codable, Sendable, CaseIterable {
    /// Full WFG financial advisor experience — production, recruiting, compliance.
    /// Compliance rules based on WFGIA Agent Insurance Guide (April 2025).
    case wfgFinancialAdvisor = "WFG Financial Advisor"
    /// Generic relationship coaching — no industry-specific compliance.
    /// User can optionally define custom compliance keywords.
    case general = "General"

    /// Display name for the Settings picker.
    public var displayName: String { rawValue }

    /// Whether this practice type has SAM-maintained compliance rules
    /// that cannot be turned off by the user.
    public var hasMandatoryCompliance: Bool {
        switch self {
        case .wfgFinancialAdvisor: return true
        case .general: return false
        }
    }

    // Legacy support: decode old "Financial Advisor" values as wfgFinancialAdvisor
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "WFG Financial Advisor": self = .wfgFinancialAdvisor
        case "Financial Advisor": self = .wfgFinancialAdvisor  // migrate old data
        case "General": self = .general
        default: self = .general
        }
    }
}

/// The user's business context profile — injected into all AI specialist system instructions.
/// Persisted as JSON in UserDefaults via `BusinessProfileService`.
nonisolated public struct BusinessProfile: Codable, Sendable, Equatable {

    // MARK: - Practice Type

    /// Controls feature visibility and AI persona. Default preserves existing behavior.
    public var practiceType: PracticeType

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

    /// The user's website URL (for inclusion in event invitations, email signatures, etc.).
    public var website: String

    // MARK: - Custom Context

    /// Free-form additional context the user wants all AI agents to know.
    /// E.g., "I specialize in serving military families" or "My warm market is exhausted."
    public var additionalContext: String

    // MARK: - Computed Helpers

    /// Whether this profile uses the financial advisor practice type.
    public var isFinancial: Bool { practiceType == .wfgFinancialAdvisor }

    /// A natural-language description of the user's role for AI system instructions.
    public var personaDescription: String {
        if isFinancial {
            return "an independent financial strategist"
        }
        // Build from available fields
        let role = roleTitle.isEmpty ? "a professional" : roleTitle
        if !organization.isEmpty {
            return "\(role) at \(organization)"
        }
        return role
    }

    // MARK: - Init

    public init(
        practiceType: PracticeType = .wfgFinancialAdvisor,
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
        website: String = "",
        additionalContext: String = ""
    ) {
        self.practiceType = practiceType
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
        self.website = website
        self.additionalContext = additionalContext
    }

    // MARK: - Codable (backwards-compatible)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.practiceType = try container.decodeIfPresent(PracticeType.self, forKey: .practiceType) ?? .wfgFinancialAdvisor
        self.isSoloPractitioner = try container.decodeIfPresent(Bool.self, forKey: .isSoloPractitioner) ?? true
        self.organization = try container.decodeIfPresent(String.self, forKey: .organization) ?? "World Financial Group"
        self.roleTitle = try container.decodeIfPresent(String.self, forKey: .roleTitle) ?? ""
        self.yearsExperience = try container.decodeIfPresent(Int.self, forKey: .yearsExperience) ?? 0
        self.marketFocus = try container.decodeIfPresent([String].self, forKey: .marketFocus) ?? []
        self.isActivelyRecruiting = try container.decodeIfPresent(Bool.self, forKey: .isActivelyRecruiting) ?? false
        self.geographicMarket = try container.decodeIfPresent(String.self, forKey: .geographicMarket) ?? ""
        self.samIsCRM = try container.decodeIfPresent(Bool.self, forKey: .samIsCRM) ?? true
        self.activeSocialPlatforms = try container.decodeIfPresent([String].self, forKey: .activeSocialPlatforms) ?? ["Facebook", "LinkedIn"]
        self.communicationChannels = try container.decodeIfPresent([String].self, forKey: .communicationChannels) ?? ["iMessage", "Email", "Phone"]
        self.website = try container.decodeIfPresent(String.self, forKey: .website) ?? ""
        self.additionalContext = try container.decodeIfPresent(String.self, forKey: .additionalContext) ?? ""
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

        if !organization.isEmpty {
            lines.append("• Organization: \(organization)")
        }

        if !roleTitle.isEmpty {
            lines.append("• Role: \(roleTitle)")
        }

        if yearsExperience > 0 {
            if isFinancial {
                lines.append("• Experience: \(yearsExperience) years in financial services")
            } else {
                lines.append("• Experience: \(yearsExperience) years")
            }
        }

        if !marketFocus.isEmpty {
            let label = isFinancial ? "Market focus" : "Focus areas"
            lines.append("• \(label): \(marketFocus.joined(separator: ", "))")
        }

        if isFinancial && isActivelyRecruiting {
            lines.append("• Actively recruiting new agents")
        }

        if !geographicMarket.isEmpty {
            lines.append("• Geographic market: \(geographicMarket)")
        }

        // SAM is always the user's CRM
        lines.append("• SAM IS the user's CRM — do NOT suggest researching, purchasing, or using other CRM tools or software")

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
