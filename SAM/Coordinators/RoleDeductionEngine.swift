//
//  RoleDeductionEngine.swift
//  SAM
//
//  Created on March 4, 2026.
//
//  Deterministic role deduction from imported data (calendar titles, communication patterns,
//  contact metadata). Suggests roles for contacts with empty roleBadges, persisted to UserDefaults.
//

import Foundation
import os
import SwiftData

// MARK: - Types

struct RoleSignal: Codable, Sendable {
    let category: String   // "calendar", "communication", "contact", "email"
    let description: String
    let weight: Double
}

struct RoleSuggestion: Codable, Identifiable, Sendable {
    let personID: UUID
    let displayName: String
    var suggestedRole: String
    let confidence: Double
    let signals: [RoleSignal]

    var id: UUID { personID }
}

// MARK: - Engine

@MainActor
@Observable
final class RoleDeductionEngine {
    static let shared = RoleDeductionEngine()

    enum DeductionStatus: String, Sendable {
        case idle, running, complete, failed
    }

    var deductionStatus: DeductionStatus = .idle
    var pendingSuggestions: [RoleSuggestion] = []

    private var currentBatchIndex: Int = 0
    private var batches: [[RoleSuggestion]] = []

    private let peopleRepo = PeopleRepository.shared
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RoleDeductionEngine")

    // MARK: - UserDefaults Keys

    private static let suggestionsKey = "sam.roleDeduction.suggestions"
    private static let lastRunDateKey = "sam.roleDeduction.lastRunDate"

    // MARK: - Init

    private init() {
        loadSuggestions()
    }

    // MARK: - Computed Properties

    var currentBatch: [RoleSuggestion] {
        guard !batches.isEmpty, currentBatchIndex < batches.count else { return [] }
        return batches[currentBatchIndex]
    }

    var currentBatchRole: String? {
        currentBatch.first?.suggestedRole
    }

    var totalBatchCount: Int {
        batches.count
    }

    var currentBatchNumber: Int {
        currentBatchIndex + 1
    }

    // MARK: - Batch Navigation

    func advanceBatch() {
        guard currentBatchIndex < batches.count - 1 else { return }
        currentBatchIndex += 1
    }

    func previousBatch() {
        guard currentBatchIndex > 0 else { return }
        currentBatchIndex -= 1
    }

    // MARK: - Actions

    func confirmRole(personID: UUID, role: String) {
        guard let person = try? peopleRepo.fetch(id: personID) else { return }
        if !person.roleBadges.contains(role) {
            person.roleBadges.append(role)
            try? peopleRepo.save()
        }
        removeSuggestion(personID: personID)
    }

    func confirmBatch(personIDs: Set<UUID>) {
        for suggestion in currentBatch where personIDs.contains(suggestion.personID) {
            confirmRole(personID: suggestion.personID, role: suggestion.suggestedRole)
        }
        removeEmptyBatches()
    }

    func changeSuggestedRole(personID: UUID, newRole: String) {
        guard let idx = pendingSuggestions.firstIndex(where: { $0.personID == personID }) else { return }
        var updated = pendingSuggestions[idx]
        updated = RoleSuggestion(
            personID: updated.personID,
            displayName: updated.displayName,
            suggestedRole: newRole,
            confidence: updated.confidence,
            signals: updated.signals
        )
        pendingSuggestions[idx] = updated
        rebuildBatches()
        saveSuggestions()
    }

    func dismissSuggestion(personID: UUID) {
        removeSuggestion(personID: personID)
    }

    func dismissBatch(personIDs: Set<UUID>) {
        pendingSuggestions.removeAll { personIDs.contains($0.personID) }
        rebuildBatches()
        saveSuggestions()
    }

    /// Look up a pending suggestion for a specific person.
    func suggestion(for personID: UUID) -> RoleSuggestion? {
        pendingSuggestions.first { $0.personID == personID }
    }

    /// All person IDs with pending suggestions.
    var pendingPersonIDs: Set<UUID> {
        Set(pendingSuggestions.map(\.personID))
    }

    /// Remaining suggestion count after the current batch.
    var remainingAfterCurrentBatch: Int {
        max(0, pendingSuggestions.count - currentBatch.count)
    }

    // MARK: - Deduction

    /// Set `force` to bypass the 10-minute throttle (e.g., after a fresh data import).
    func deduceRoles(force: Bool = false) async {
        guard deductionStatus != .running else { return }

        // Throttle: skip if last run was within 10 minutes (unless forced)
        if !force,
           let lastRun = UserDefaults.standard.object(forKey: Self.lastRunDateKey) as? Date,
           Date.now.timeIntervalSince(lastRun) < 600 {
            logger.debug("Role deduction throttled — last run \(Int(Date.now.timeIntervalSince(lastRun)))s ago")
            return
        }

        deductionStatus = .running
        logger.debug("Starting role deduction...")

        do {
            let allPeople = try peopleRepo.fetchAll()
            let candidates = allPeople.filter { person in
                guard person.roleBadges.isEmpty, !person.isMe, !person.isArchived else { return false }
                // Skip dead-weight contacts (raw social-graph connections,
                // stale Apple Contacts) that carry no real signal. See
                // `SamPerson.hasMeaningfulSignal`.
                return person.hasMeaningfulSignal
            }

            logger.debug("Found \(candidates.count) candidates for role deduction")

            var suggestions: [RoleSuggestion] = []

            for person in candidates {
                guard !person.isDeleted else { continue }
                let contactDTO: ContactDTO? = await fetchContactDTO(for: person)
                // Re-check after await — person may have been deleted during contact fetch
                guard !person.isDeleted else { continue }
                let evidence = person.linkedEvidence

                let scored = scoreAllRoles(person: person, contact: contactDTO, evidence: evidence)

                // Pick top role if score ≥ 40
                if let best = scored.first, best.score >= 40 {
                    let confidence = min(1.0, best.score / 100.0)
                    let suggestion = RoleSuggestion(
                        personID: person.id,
                        displayName: person.displayName,
                        suggestedRole: best.role,
                        confidence: confidence,
                        signals: best.signals
                    )
                    suggestions.append(suggestion)
                }
            }

            // Sort by confidence descending
            suggestions.sort { $0.confidence > $1.confidence }

            // Merge: update existing suggestions with fresh evaluation,
            // add new ones, remove stale ones for people who no longer qualify
            let freshIDs = Set(suggestions.map(\.personID))
            // Keep existing suggestions only if the person still qualifies
            // (they might have gotten a role badge since last run)
            pendingSuggestions = pendingSuggestions.filter { freshIDs.contains($0.personID) }
            // Now replace/add from fresh evaluation
            for suggestion in suggestions {
                if let idx = pendingSuggestions.firstIndex(where: { $0.personID == suggestion.personID }) {
                    pendingSuggestions[idx] = suggestion
                } else {
                    pendingSuggestions.append(suggestion)
                }
            }

            rebuildBatches()
            saveSuggestions()
            UserDefaults.standard.set(Date(), forKey: Self.lastRunDateKey)

            deductionStatus = .complete
            let pendingCount = pendingSuggestions.count
            logger.info("Role deduction complete: \(suggestions.count) suggestions (\(pendingCount) pending total)")
        } catch {
            deductionStatus = .failed
            logger.error("Role deduction failed: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func fetchContactDTO(for person: SamPerson) async -> ContactDTO? {
        guard let identifier = person.contactIdentifier, !identifier.isEmpty else { return nil }
        return await ContactsService.shared.fetchContact(identifier: identifier, keys: .detail)
    }

    private func removeSuggestion(personID: UUID) {
        pendingSuggestions.removeAll { $0.personID == personID }
        rebuildBatches()
        saveSuggestions()
    }

    private func removeEmptyBatches() {
        let currentBatchIDs = Set(currentBatch.map(\.personID))
        pendingSuggestions.removeAll { currentBatchIDs.contains($0.personID) && false }
        // Current batch was already processed by confirmBatch/dismissBatch
        rebuildBatches()
        saveSuggestions()
    }

    private func rebuildBatches() {
        // Group by role in predefined order, then chunk into batches of 12
        let roleOrder = ["Client", "Applicant", "Lead", "Agent", "External Agent", "Vendor", "Referral Partner"]
        var ordered: [RoleSuggestion] = []

        for role in roleOrder {
            let group = pendingSuggestions.filter { $0.suggestedRole == role }
            ordered.append(contentsOf: group)
        }
        // Any remaining roles not in the predefined set
        let knownRoles = Set(roleOrder)
        let remaining = pendingSuggestions.filter { !knownRoles.contains($0.suggestedRole) }
        ordered.append(contentsOf: remaining)

        // Chunk into batches of 12, keeping same-role items together
        batches = []
        var current: [RoleSuggestion] = []
        var currentRole: String?

        for suggestion in ordered {
            if suggestion.suggestedRole != currentRole {
                if !current.isEmpty {
                    batches.append(current)
                    current = []
                }
                currentRole = suggestion.suggestedRole
            }
            current.append(suggestion)
            if current.count >= 10 {
                batches.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            batches.append(current)
        }

        // Clamp batch index
        if currentBatchIndex >= batches.count {
            currentBatchIndex = max(0, batches.count - 1)
        }
    }

    // MARK: - Persistence

    private func saveSuggestions() {
        guard let data = try? JSONEncoder().encode(pendingSuggestions) else { return }
        UserDefaults.standard.set(data, forKey: Self.suggestionsKey)
    }

    private func loadSuggestions() {
        guard let data = UserDefaults.standard.data(forKey: Self.suggestionsKey),
              let loaded = try? JSONDecoder().decode([RoleSuggestion].self, from: data) else { return }
        pendingSuggestions = loaded
        rebuildBatches()
    }

    // MARK: - Scoring

    private struct RoleScore {
        let role: String
        var score: Double
        var signals: [RoleSignal]
    }

    private func scoreAllRoles(person: SamPerson, contact: ContactDTO?, evidence: [SamEvidenceItem]) -> [RoleScore] {
        let roles = ["Client", "Applicant", "Lead", "Agent", "External Agent", "Vendor", "Referral Partner"]

        var scores = roles.map { RoleScore(role: $0, score: 0, signals: []) }

        let calendarEvidence = evidence.filter { $0.source == .calendar }
        let interactionEvidence = evidence.filter { $0.source != .calendar }

        for i in scores.indices {
            let role = scores[i].role

            // Category 1: Calendar Title Keywords (max 40)
            let (titleScore, titleSignals) = scoreCalendarTitles(role: role, calendarEvidence: calendarEvidence)
            scores[i].score += titleScore
            scores[i].signals.append(contentsOf: titleSignals)

            // Category 2: Calendar Frequency Pattern (max 25)
            let (freqScore, freqSignals) = scoreCalendarFrequency(role: role, calendarEvidence: calendarEvidence)
            scores[i].score += freqScore
            scores[i].signals.append(contentsOf: freqSignals)

            // Category 3: Communication Volume & Direction (max 20)
            let (commScore, commSignals) = scoreCommunicationVolume(role: role, interactions: interactionEvidence)
            scores[i].score += commScore
            scores[i].signals.append(contentsOf: commSignals)

            // Category 4: Contact Metadata (max 15)
            if let contact = contact {
                let (metaScore, metaSignals) = scoreContactMetadata(role: role, contact: contact)
                scores[i].score += metaScore
                scores[i].signals.append(contentsOf: metaSignals)
            }
        }

        // Apply tiebreaker rules
        scores = applyTiebreakers(scores: scores, calendarEvidence: calendarEvidence)

        // If no role scored ≥ 40 but the person is a known contact, suggest Lead as default
        let topScore = scores.max(by: { $0.score < $1.score })?.score ?? 0
        if topScore < 40 {
            let hasSocialPresence = person.linkedInConnectedOn != nil
                || person.facebookFriendedOn != nil
                || person.facebookMessageCount > 0
            let hasAppleContact = person.contactIdentifier != nil

            if hasSocialPresence || hasAppleContact {
                if let leadIdx = scores.firstIndex(where: { $0.role == "Lead" }) {
                    let reason = hasSocialPresence
                        ? "Connected on social media, no other role signals"
                        : "In your Contacts, no other role signals"
                    let socialSignal = RoleSignal(
                        category: hasSocialPresence ? "social" : "contact",
                        description: reason,
                        weight: 40
                    )
                    scores[leadIdx].score = max(scores[leadIdx].score, 40)
                    scores[leadIdx].signals.append(socialSignal)
                }
            }
        }

        return scores.sorted { $0.score > $1.score }
    }

    // MARK: - Category 1: Calendar Title Keywords

    private func scoreCalendarTitles(role: String, calendarEvidence: [SamEvidenceItem]) -> (Double, [RoleSignal]) {
        let keywords: [(pattern: String, points: Double)]

        switch role {
        case "Client":
            keywords = [
                ("annual review", 10), ("policy review", 10), ("financial review", 10),
                ("retirement review", 10), ("portfolio review", 10), ("benefits review", 10)
            ]
        case "Applicant":
            keywords = [
                ("application", 10), ("signing", 10), ("underwriting", 10),
                ("exam", 10), ("paramed", 10), ("submission", 10)
            ]
        case "Lead":
            keywords = [
                ("introduction", 8), ("30 minutes with", 8), ("discovery", 8),
                ("initial meeting", 8), ("coffee with", 8), ("lunch with", 8),
                ("intro call", 8), ("get to know", 8)
            ]
        case "Agent":
            keywords = [
                ("training", 8), ("coaching", 8), ("team meeting", 8),
                ("field training", 8), ("joint work", 8), ("ride along", 8),
                ("business overview", 8)
            ]
        case "External Agent":
            keywords = [
                ("co-write", 10), ("split case", 10), ("joint appointment", 10)
            ]
        case "Vendor":
            keywords = [
                ("product update", 8), ("carrier", 8), ("wholesaler", 8),
                ("underwriting call", 8)
            ]
        case "Referral Partner":
            keywords = []
        default:
            keywords = []
        }

        var totalScore: Double = 0
        var signals: [RoleSignal] = []
        var matchCount = 0

        for event in calendarEvidence {
            let titleLower = event.title.lowercased()
            for kw in keywords {
                if titleLower.contains(kw.pattern) {
                    matchCount += 1
                    let addition = min(kw.points, 40 - totalScore)
                    if addition > 0 {
                        totalScore += addition
                    }
                }
            }
        }

        if matchCount > 0 {
            let matchedPatterns = keywords.filter { kw in
                calendarEvidence.contains { $0.title.lowercased().contains(kw.pattern) }
            }.map(\.pattern)
            signals.append(RoleSignal(
                category: "calendar",
                description: "\(matchCount) meeting\(matchCount == 1 ? "" : "s") with keywords: \(matchedPatterns.joined(separator: ", "))",
                weight: totalScore
            ))
        }

        return (min(totalScore, 40), signals)
    }

    // MARK: - Category 2: Calendar Frequency Pattern

    private func scoreCalendarFrequency(role: String, calendarEvidence: [SamEvidenceItem]) -> (Double, [RoleSignal]) {
        let count = calendarEvidence.count
        guard count > 0 else { return (0, []) }

        let sorted = calendarEvidence.sorted { $0.occurredAt < $1.occurredAt }
        let now = Date()

        // Compute average gap between meetings
        var avgGap: TimeInterval = 0
        if count >= 2 {
            let totalSpan = sorted.last!.occurredAt.timeIntervalSince(sorted.first!.occurredAt)
            avgGap = totalSpan / Double(count - 1)
        }
        let avgGapDays = avgGap / 86400

        // Check for burst pattern (meetings clustered in last 60 days)
        let sixtyDaysAgo = Calendar.current.date(byAdding: .day, value: -60, to: now)!
        let recentCount = sorted.filter { $0.occurredAt >= sixtyDaysAgo }.count
        let isBurst = count >= 2 && recentCount == count && avgGapDays < 60

        var score: Double = 0
        var signals: [RoleSignal] = []

        switch role {
        case "Client":
            // 2+ meetings, avg gap 90-365 days (annual/semi-annual)
            if count >= 2 && avgGapDays >= 90 && avgGapDays <= 365 {
                score = avgGapDays >= 180 ? 25 : 15
                signals.append(RoleSignal(category: "calendar", description: "\(count) meetings with \(Int(avgGapDays))-day avg gap (annual/semi-annual pattern)", weight: score))
            }

        case "Applicant":
            // 2+ meetings, all within last 60 days (burst)
            if count >= 2 && isBurst {
                score = 20
                signals.append(RoleSignal(category: "calendar", description: "\(count) meetings clustered in last 60 days (application burst)", weight: score))
            }

        case "Lead":
            // Exactly 1 meeting
            if count == 1 {
                score = 15
                signals.append(RoleSignal(category: "calendar", description: "Single meeting (discovery/intro pattern)", weight: score))
            }

        case "Agent":
            // 4+ meetings, avg gap 7-21 days (weekly/biweekly cadence)
            if count >= 4 && avgGapDays >= 7 && avgGapDays <= 21 {
                score = avgGapDays <= 10 ? 25 : 20
                signals.append(RoleSignal(category: "calendar", description: "\(count) meetings with \(Int(avgGapDays))-day cadence (training pattern)", weight: score))
            }

        case "External Agent":
            // 1-3 meetings, avg gap > 30 days
            if count >= 1 && count <= 3 && (count == 1 || avgGapDays > 30) {
                score = 10
                signals.append(RoleSignal(category: "calendar", description: "\(count) sporadic meeting\(count == 1 ? "" : "s") (external collaboration)", weight: score))
            }

        case "Vendor":
            // 1-3 meetings, sporadic
            if count >= 1 && count <= 3 {
                score = 10
                signals.append(RoleSignal(category: "calendar", description: "\(count) meeting\(count == 1 ? "" : "s") (vendor interaction)", weight: score))
            }

        case "Referral Partner":
            // 1-3 meetings, irregular
            if count >= 1 && count <= 3 {
                score = 10
                signals.append(RoleSignal(category: "calendar", description: "\(count) meeting\(count == 1 ? "" : "s") (referral partner pattern)", weight: score))
            }

        default:
            break
        }

        return (min(score, 25), signals)
    }

    // MARK: - Category 3: Communication Volume & Direction

    private func scoreCommunicationVolume(role: String, interactions: [SamEvidenceItem]) -> (Double, [RoleSignal]) {
        let count = interactions.count
        guard count > 0 else {
            // Low interaction count is a signal for Lead
            if role == "Lead" {
                return (5, [RoleSignal(category: "communication", description: "No communications (cold contact)", weight: 5)])
            }
            return (0, [])
        }

        let now = Date()
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let recentCount = interactions.filter { $0.occurredAt >= thirtyDaysAgo }.count
        let olderCount = count - recentCount
        let isBurst = recentCount >= 3 && (olderCount == 0 || Double(recentCount) > Double(olderCount) * 2)

        var score: Double = 0
        var signals: [RoleSignal] = []

        switch role {
        case "Client":
            // Sustained moderate (3-15 interactions)
            if count >= 3 && count <= 15 && !isBurst {
                score = count >= 8 ? 15 : 10
                signals.append(RoleSignal(category: "communication", description: "\(count) sustained interactions (client service pattern)", weight: score))
            }

        case "Applicant":
            // Burst (recent > 2× older, recent ≥ 3)
            if isBurst {
                score = recentCount >= 5 ? 20 : 15
                signals.append(RoleSignal(category: "communication", description: "\(recentCount) recent interactions (application burst)", weight: score))
            }

        case "Lead":
            // Low (0-2 interactions)
            if count <= 2 {
                score = count == 0 ? 5 : 10
                signals.append(RoleSignal(category: "communication", description: "\(count) interaction\(count == 1 ? "" : "s") (minimal contact)", weight: score))
            }

        case "Agent":
            // Very high sustained (>15, not burst)
            if count > 15 && !isBurst {
                score = count > 25 ? 20 : 15
                signals.append(RoleSignal(category: "communication", description: "\(count) sustained interactions (team member pattern)", weight: score))
            }

        case "External Agent":
            // Low sporadic (2-8, not sustained)
            if count >= 2 && count <= 8 {
                score = 10
                signals.append(RoleSignal(category: "communication", description: "\(count) sporadic interactions (peer collaboration)", weight: score))
            }

        case "Vendor":
            // Primarily inbound, sporadic
            if count >= 1 && count <= 10 {
                score = count >= 5 ? 15 : 10
                signals.append(RoleSignal(category: "communication", description: "\(count) interaction\(count == 1 ? "" : "s") (vendor pattern)", weight: score))
            }

        case "Referral Partner":
            // Moderate (3-10)
            if count >= 3 && count <= 10 {
                score = 10
                signals.append(RoleSignal(category: "communication", description: "\(count) interactions (referral partner pattern)", weight: score))
            }

        default:
            break
        }

        return (min(score, 20), signals)
    }

    // MARK: - Category 4: Contact Metadata

    private static let knownCarriers: Set<String> = [
        "transamerica", "nationwide", "pacific life", "aegon", "aig",
        "prudential", "metlife", "lincoln financial", "john hancock",
        "principal", "voya", "athene", "global atlantic", "north american",
        "protective", "securian", "american general", "allianz"
    ]

    private func scoreContactMetadata(role: String, contact: ContactDTO) -> (Double, [RoleSignal]) {
        let jobTitle = contact.jobTitle.lowercased()
        let org = contact.organizationName.lowercased()
        let emails = contact.emailAddresses.map { $0.lowercased() }

        var score: Double = 0
        var signals: [RoleSignal] = []

        switch role {
        case "Agent":
            if org.contains("wfg") || org.contains("world financial") {
                score = 15
                signals.append(RoleSignal(category: "contact", description: "Organization contains WFG/World Financial", weight: 15))
            }
            // Email domain bonus
            let wfgEmail = emails.contains { $0.contains("wfg") || $0.contains("worldfinancial") }
            if wfgEmail && score < 15 {
                let bonus = min(5.0, 15 - score)
                score += bonus
                signals.append(RoleSignal(category: "email", description: "WFG email domain", weight: bonus))
            }

        case "External Agent":
            if (org.contains("wfg") || org.contains("world financial")) {
                score = 12
                signals.append(RoleSignal(category: "contact", description: "Organization contains WFG (external peer)", weight: 12))
            }
            let wfgEmail = emails.contains { $0.contains("wfg") || $0.contains("worldfinancial") }
            if wfgEmail && score < 12 {
                let bonus = min(5.0, 12 - score)
                score += bonus
                signals.append(RoleSignal(category: "email", description: "WFG email domain", weight: bonus))
            }

        case "Vendor":
            let vendorTitles = ["wholesaler", "underwriter", "carrier", "regional"]
            if vendorTitles.contains(where: { jobTitle.contains($0) }) {
                score = 15
                signals.append(RoleSignal(category: "contact", description: "Job title indicates vendor role (\(contact.jobTitle))", weight: 15))
            }
            if Self.knownCarriers.contains(where: { org.contains($0) }) {
                let addition = min(15.0, 15 - score)
                if addition > 0 {
                    score += addition
                    signals.append(RoleSignal(category: "contact", description: "Organization matches known carrier (\(contact.organizationName))", weight: addition))
                }
            }
            // Email domain bonus for carrier domains
            let carrierEmail = emails.contains { email in
                Self.knownCarriers.contains { email.contains($0.replacingOccurrences(of: " ", with: "")) }
            }
            if carrierEmail && score < 15 {
                let bonus = min(5.0, 15 - score)
                score += bonus
                signals.append(RoleSignal(category: "email", description: "Carrier email domain", weight: bonus))
            }

        case "Referral Partner":
            let referralTitles = ["realtor", "real estate", "cpa", "accountant", "attorney",
                                  "lawyer", "mortgage", "banker", "lender"]
            if referralTitles.contains(where: { jobTitle.contains($0) }) {
                score = 12
                signals.append(RoleSignal(category: "contact", description: "Job title indicates referral partner (\(contact.jobTitle))", weight: 12))
            }

        default:
            break
        }

        return (min(score, 15), signals)
    }

    // MARK: - Tiebreakers

    private func applyTiebreakers(scores: [RoleScore], calendarEvidence: [SamEvidenceItem]) -> [RoleScore] {
        var result = scores

        guard let agentIdx = result.firstIndex(where: { $0.role == "Agent" }),
              let extAgentIdx = result.firstIndex(where: { $0.role == "External Agent" }) else {
            return result
        }

        // Agent vs External Agent: training cadence decides
        if result[agentIdx].score > 0 && result[extAgentIdx].score > 0 &&
           abs(result[agentIdx].score - result[extAgentIdx].score) < 15 {
            let trainingKeywords = ["training", "coaching", "team meeting", "field training"]
            let trainingEvents = calendarEvidence.filter { event in
                trainingKeywords.contains(where: { event.title.lowercased().contains($0) })
            }.sorted { $0.occurredAt < $1.occurredAt }

            if trainingEvents.count >= 2 {
                let totalSpan = trainingEvents.last!.occurredAt.timeIntervalSince(trainingEvents.first!.occurredAt)
                let avgGap = totalSpan / Double(trainingEvents.count - 1) / 86400
                if avgGap <= 14 {
                    // Frequent training → Agent
                    result[agentIdx].score += 10
                } else {
                    // Infrequent → External Agent
                    result[extAgentIdx].score += 5
                }
            }
        }

        // Client vs Applicant: all process-titled meetings in last 60 days → Applicant
        guard let clientIdx = result.firstIndex(where: { $0.role == "Client" }),
              let applicantIdx = result.firstIndex(where: { $0.role == "Applicant" }) else {
            return result
        }

        if result[clientIdx].score > 0 && result[applicantIdx].score > 0 &&
           abs(result[clientIdx].score - result[applicantIdx].score) < 15 {
            let processKeywords = ["application", "signing", "underwriting", "exam", "paramed", "submission"]
            let processEvents = calendarEvidence.filter { event in
                processKeywords.contains(where: { event.title.lowercased().contains($0) })
            }
            let sixtyDaysAgo = Calendar.current.date(byAdding: .day, value: -60, to: .now)!
            let allRecent = !processEvents.isEmpty && processEvents.allSatisfy { $0.occurredAt >= sixtyDaysAgo }
            if allRecent {
                result[applicantIdx].score += 10
            } else if !processEvents.isEmpty {
                result[clientIdx].score += 5
            }
        }

        return result
    }
}
