//
//  BusinessProfileService.swift
//  SAM
//
//  Created on February 27, 2026.
//  Phase AB: Coaching Calibration — Business Context Profile
//
//  Manages the user's business profile and universal blocklist.
//  Profile is persisted as JSON in UserDefaults.
//  The blocklist prevents all AI agents from suggesting irrelevant actions.
//

import Foundation
import os.log

/// Manages the business context profile and universal AI blocklist.
actor BusinessProfileService {

    static let shared = BusinessProfileService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "BusinessProfileService")
    private let profileKey = "sam.businessProfile"

    private var cachedProfile: BusinessProfile?

    private init() {}

    // MARK: - Profile Access

    /// Load the profile from UserDefaults (cached after first load).
    func profile() -> BusinessProfile {
        if let cached = cachedProfile {
            return cached
        }

        if let data = UserDefaults.standard.data(forKey: profileKey),
           let decoded = try? JSONDecoder().decode(BusinessProfile.self, from: data) {
            cachedProfile = decoded
            logger.info("Loaded business profile from UserDefaults")
            return decoded
        }

        // Return default profile
        let defaultProfile = BusinessProfile()
        cachedProfile = defaultProfile
        return defaultProfile
    }

    /// Save an updated profile.
    func save(_ profile: BusinessProfile) {
        cachedProfile = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
            logger.info("Saved business profile to UserDefaults")
        }
    }

    // MARK: - System Instruction Helpers

    /// Returns the business context fragment for injection into AI system instructions.
    func contextFragment() -> String {
        let p = profile()
        return p.systemInstructionFragment()
    }

    /// Returns the universal blocklist as a system instruction fragment.
    /// These are actions that NO AI agent should ever suggest.
    func blocklistFragment() -> String {
        let p = profile()
        var lines: [String] = []

        lines.append("UNIVERSAL CONSTRAINTS (never suggest these):")

        // Always-on blocklist items
        lines.append("• Do NOT suggest researching, purchasing, or subscribing to any software, tools, or SaaS products")
        lines.append("• Do NOT suggest hiring staff, assistants, consultants, or IT professionals")
        lines.append("• Do NOT suggest building websites, apps, landing pages, or technical systems")
        lines.append("• Do NOT suggest purchasing advertising, paid marketing, or media buys")
        lines.append("• Do NOT suggest actions that require tools or resources the user does not already have")

        // Solo practitioner constraints
        if p.isSoloPractitioner {
            lines.append("• Do NOT reference a \"sales team\", \"your team\", \"staff\", or \"employees\" — this is a solo practice")
            lines.append("• Do NOT suggest delegating tasks to others or creating team workflows")
            lines.append("• Do NOT suggest holding team meetings, standups, or group training sessions")
        }

        // SAM-is-CRM constraint
        if p.samIsCRM {
            lines.append("• Do NOT suggest CRM software, CRM research, or CRM alternatives — SAM is the CRM")
            lines.append("• Do NOT suggest spreadsheets or databases for contact tracking — SAM handles this")
        }

        return lines.joined(separator: "\n")
    }

    /// Returns the combined business context + blocklist + calibration for injection into system instructions.
    func fullContextBlock() async -> String {
        let context = contextFragment()
        let blocklist = blocklistFragment()
        let calibration = await CalibrationService.shared.calibrationFragment()
        if calibration.isEmpty {
            return "\(context)\n\n\(blocklist)"
        }
        return "\(context)\n\n\(blocklist)\n\n\(calibration)"
    }
}
