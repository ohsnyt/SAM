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
    private let linkedInProfileKey = "sam.userLinkedInProfile"
    private let facebookProfileKey = "sam.userFacebookProfile"
    private let substackProfileKey = "sam.userSubstackProfile"
    /// Legacy single-item key — migrated to `profileAnalysesKey` on first access.
    private let profileAnalysisKey = "sam.profileAnalysis"
    /// Array of per-platform analyses (one entry per platform).
    private let profileAnalysesKey = "sam.profileAnalyses"
    private let profileSnapshotKey = "sam.profileAnalysisSnapshot"
    private let facebookSnapshotKey = "sam.facebookAnalysisSnapshot"

    private var cachedProfile: BusinessProfile?
    private var cachedLinkedInProfile: UserLinkedInProfileDTO?
    private var cachedFacebookProfile: UserFacebookProfileDTO?
    private var cachedSubstackProfile: UserSubstackProfileDTO?
    private var cachedAnalyses: [ProfileAnalysisDTO]?
    private var cachedSnapshot: ProfileAnalysisSnapshot?
    private var cachedFacebookSnapshot: FacebookAnalysisSnapshot?

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
            logger.debug("Loaded business profile from UserDefaults")
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
            logger.debug("Saved business profile to UserDefaults")
        }
    }

    // MARK: - LinkedIn Profile Storage

    /// Save the user's parsed LinkedIn profile.
    func saveLinkedInProfile(_ profile: UserLinkedInProfileDTO) {
        cachedLinkedInProfile = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: linkedInProfileKey)
            logger.debug("Saved user LinkedIn profile to UserDefaults")
        }
    }

    /// Load the user's LinkedIn profile (cached after first load). Returns nil if not yet imported.
    func linkedInProfile() -> UserLinkedInProfileDTO? {
        if let cached = cachedLinkedInProfile { return cached }
        guard let data = UserDefaults.standard.data(forKey: linkedInProfileKey),
              let decoded = try? JSONDecoder().decode(UserLinkedInProfileDTO.self, from: data) else { return nil }
        cachedLinkedInProfile = decoded
        return decoded
    }

    // MARK: - Facebook Profile Storage

    /// Save the user's parsed Facebook profile (full JSON).
    func saveFacebookProfile(_ profile: UserFacebookProfileDTO) {
        cachedFacebookProfile = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: facebookProfileKey)
            logger.debug("Saved user Facebook profile to UserDefaults")
        }
    }

    /// Load the user's Facebook profile (cached after first load). Returns nil if not yet imported.
    func facebookProfile() -> UserFacebookProfileDTO? {
        if let cached = cachedFacebookProfile { return cached }
        // Try full JSON decode first (new format)
        if let data = UserDefaults.standard.data(forKey: facebookProfileKey),
           let decoded = try? JSONDecoder().decode(UserFacebookProfileDTO.self, from: data) {
            cachedFacebookProfile = decoded
            return decoded
        }
        return nil
    }

    /// Load the user's Facebook profile coaching fragment. Returns nil if not yet imported.
    func facebookProfileFragment() -> String? {
        if let profile = facebookProfile() { return profile.coachingContextFragment }
        // Legacy fallback: stored as plain string before Codable upgrade
        guard let fragment = UserDefaults.standard.string(forKey: facebookProfileKey),
              !fragment.isEmpty else { return nil }
        return fragment
    }

    // MARK: - Substack Profile Storage

    /// Save the user's parsed Substack publication profile.
    func saveSubstackProfile(_ profile: UserSubstackProfileDTO) {
        cachedSubstackProfile = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: substackProfileKey)
            logger.debug("Saved user Substack profile to UserDefaults")
        }
    }

    /// Load the user's Substack profile (cached after first load). Returns nil if not yet imported.
    func substackProfile() -> UserSubstackProfileDTO? {
        if let cached = cachedSubstackProfile { return cached }
        guard let data = UserDefaults.standard.data(forKey: substackProfileKey),
              let decoded = try? JSONDecoder().decode(UserSubstackProfileDTO.self, from: data) else { return nil }
        cachedSubstackProfile = decoded
        return decoded
    }

    // MARK: - Facebook Analysis Snapshot

    /// Save the Facebook analysis snapshot (import-time activity data for on-demand re-analysis).
    func saveFacebookSnapshot(_ snapshot: FacebookAnalysisSnapshot) {
        cachedFacebookSnapshot = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: facebookSnapshotKey)
            logger.debug("Saved Facebook analysis snapshot to UserDefaults")
        }
    }

    /// Load the Facebook analysis snapshot. Returns nil if no import has been processed yet.
    func facebookSnapshot() -> FacebookAnalysisSnapshot? {
        if let cached = cachedFacebookSnapshot { return cached }
        guard let data = UserDefaults.standard.data(forKey: facebookSnapshotKey),
              let decoded = try? JSONDecoder().decode(FacebookAnalysisSnapshot.self, from: data) else { return nil }
        cachedFacebookSnapshot = decoded
        return decoded
    }

    // MARK: - Profile Analysis Storage (multi-platform)

    /// Save or update a profile analysis for its platform.
    /// Replaces any existing entry for the same platform; adds a new entry otherwise.
    func saveProfileAnalysis(_ analysis: ProfileAnalysisDTO) {
        var analyses = loadProfileAnalyses()
        if let idx = analyses.firstIndex(where: { $0.platform == analysis.platform }) {
            analyses[idx] = analysis
        } else {
            analyses.append(analysis)
        }
        cachedAnalyses = analyses
        if let data = try? JSONEncoder().encode(analyses) {
            UserDefaults.standard.set(data, forKey: profileAnalysesKey)
            // Remove legacy single-item key once migrated
            UserDefaults.standard.removeObject(forKey: profileAnalysisKey)
            logger.debug("Saved profile analyses (\(analyses.count) platforms) to UserDefaults")
            Task { @MainActor in
                NotificationCenter.default.post(name: .samProfileAnalysisDidUpdate, object: nil)
            }
        }
    }

    /// All stored platform analyses, sorted by most recently analyzed.
    func profileAnalyses() -> [ProfileAnalysisDTO] {
        if let cached = cachedAnalyses { return cached }
        let analyses = loadProfileAnalyses()
        cachedAnalyses = analyses
        return analyses
    }

    /// Convenience — returns the analysis for a specific platform, or nil.
    func profileAnalysis(for platform: String = "linkedIn") -> ProfileAnalysisDTO? {
        profileAnalyses().first(where: { $0.platform == platform })
    }

    /// Internal loader — reads from the array key, migrating from the legacy single-item key if needed.
    private func loadProfileAnalyses() -> [ProfileAnalysisDTO] {
        // Prefer the new array key
        if let data = UserDefaults.standard.data(forKey: profileAnalysesKey),
           let decoded = try? JSONDecoder().decode([ProfileAnalysisDTO].self, from: data) {
            return decoded.sorted { $0.analysisDate > $1.analysisDate }
        }
        // Migrate legacy single-item entry
        if let data = UserDefaults.standard.data(forKey: profileAnalysisKey),
           let legacy = try? JSONDecoder().decode(ProfileAnalysisDTO.self, from: data) {
            logger.debug("Migrating legacy profileAnalysis to array store")
            return [legacy]
        }
        return []
    }

    /// Save the profile analysis snapshot (import-time endorsement/recommendation/share data).
    func saveAnalysisSnapshot(_ snapshot: ProfileAnalysisSnapshot) {
        cachedSnapshot = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: profileSnapshotKey)
            logger.debug("Saved profile analysis snapshot to UserDefaults")
        }
    }

    /// Load the profile analysis snapshot. Returns nil if no import has been processed yet.
    func analysisSnapshot() -> ProfileAnalysisSnapshot? {
        if let cached = cachedSnapshot { return cached }
        guard let data = UserDefaults.standard.data(forKey: profileSnapshotKey),
              let decoded = try? JSONDecoder().decode(ProfileAnalysisSnapshot.self, from: data) else { return nil }
        cachedSnapshot = decoded
        return decoded
    }

    // MARK: - Practice Type Helpers

    /// Returns the persona description for the current profile (e.g., "an independent financial strategist").
    func personaFragment() -> String {
        profile().personaDescription
    }

    /// Whether the current profile uses the financial advisor practice type.
    func isFinancialPractice() -> Bool {
        profile().isFinancial
    }

    /// Returns a compliance note for financial practice, or empty string for general.
    func complianceNote() -> String {
        if profile().isFinancial {
            return "Ensure all content is compliant with financial services regulations."
        }
        return ""
    }

    // MARK: - Nonisolated Synchronous Accessors

    /// Thread-safe synchronous persona fragment, reads directly from UserDefaults.
    /// Use this from synchronous contexts (e.g., static computed properties) where `await` is unavailable.
    nonisolated func personaFragmentSync() -> String {
        Self.loadProfile().personaDescription
    }

    /// Thread-safe synchronous financial practice check.
    nonisolated func isFinancialPracticeSync() -> Bool {
        Self.loadProfile().isFinancial
    }

    /// Thread-safe synchronous compliance note.
    nonisolated func complianceNoteSync() -> String {
        let p = Self.loadProfile()
        if p.isFinancial {
            return "Ensure all content is compliant with financial services regulations."
        }
        return ""
    }

    /// Load the profile directly from UserDefaults without actor isolation.
    private nonisolated static func loadProfile() -> BusinessProfile {
        if let data = UserDefaults.standard.data(forKey: "sam.businessProfile"),
           let decoded = try? JSONDecoder().decode(BusinessProfile.self, from: data) {
            return decoded
        }
        return BusinessProfile()
    }

    // MARK: - System Instruction Helpers

    /// Returns the business context fragment for injection into AI system instructions.
    func contextFragment() -> String {
        let p = profile()
        var fragment = p.systemInstructionFragment()

        // Append LinkedIn profile context if available
        if let li = linkedInProfile(), !li.coachingContextFragment.isEmpty {
            fragment += "\n\n## LinkedIn Profile\n" + li.coachingContextFragment
        }

        // Append Facebook profile context if available
        if let fbFragment = facebookProfileFragment() {
            fragment += "\n\n" + fbFragment
        }

        // Append Substack publication context if available
        if let substack = substackProfile(), !substack.coachingContextFragment.isEmpty {
            fragment += "\n\n## Substack Publication\n" + substack.coachingContextFragment
        }

        return fragment
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

        // Financial-specific constraints
        if p.isFinancial {
            lines.append("• Never make specific financial product recommendations or promises about returns")
            lines.append("• Never fabricate data points — if data is insufficient for analysis, say so")
        }

        return lines.joined(separator: "\n")
    }

    /// Returns a compact context block with just the business profile and blocklist — no social platform
    /// fragments, no calibration. Use this for profile analyst prompts where the platform data is already
    /// provided as input and context budget is tight.
    func compactContextBlock() -> String {
        let p = profile()
        return "\(p.systemInstructionFragment())\n\n\(blocklistFragment())"
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
