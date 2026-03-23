//
//  OutgoingEventMatcher.swift
//  SAM
//
//  Created on March 23, 2026.
//  Scans recent outgoing messages for references to upcoming events,
//  and generates outcomes suggesting the recipient be added as a participant.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "OutgoingEventMatcher")

@MainActor
@Observable
final class OutgoingEventMatcher {

    static let shared = OutgoingEventMatcher()

    /// How far back to scan outgoing evidence (messages sent since last scan).
    private var lastScanDate: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "sam.outgoingEventMatcher.lastScan")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "sam.outgoingEventMatcher.lastScan") }
    }

    private let evidenceRepo = EvidenceRepository.shared
    private let eventRepo = EventRepository.shared
    private let outcomeRepo = OutcomeRepository.shared

    private init() {}

    // MARK: - Public API

    /// Scan recent outgoing messages for event-related content and generate outcomes.
    /// Called by PostImportOrchestrator after mail/comms imports.
    func scanRecentOutgoing() {
        let scanSince = lastScanDate
        let now = Date.now

        // Avoid scanning if we just scanned < 30 seconds ago
        guard now.timeIntervalSince(scanSince) > 30 else { return }

        do {
            let upcomingEvents = try eventRepo.fetchUpcoming()
            guard !upcomingEvents.isEmpty else {
                lastScanDate = now
                return
            }

            let allEvidence = try evidenceRepo.fetchAll()

            // Filter to outgoing messages since last scan
            let outgoingSources: Set<EvidenceSource> = [.mail, .iMessage, .whatsApp]
            let recentOutgoing = allEvidence.filter { ev in
                ev.isFromMe
                && outgoingSources.contains(ev.source)
                && ev.occurredAt > scanSince
            }

            guard !recentOutgoing.isEmpty else {
                lastScanDate = now
                return
            }

            logger.debug("Scanning \(recentOutgoing.count) outgoing messages against \(upcomingEvents.count) upcoming events")

            var matchCount = 0

            for evidence in recentOutgoing {
                let searchText = "\(evidence.title) \(evidence.snippet)".lowercased()

                for event in upcomingEvents {
                    // Check if the message content references this event
                    guard messageReferencesEvent(searchText: searchText, event: event) else { continue }

                    // Check each linked person — are they already a participant?
                    for person in evidence.linkedPeople {
                        let isParticipant = event.participations.contains { $0.person?.id == person.id }
                        guard !isParticipant else { continue }

                        // Generate an outcome suggesting adding this person
                        try? generateAddParticipantOutcome(
                            person: person,
                            event: event,
                            evidence: evidence
                        )
                        matchCount += 1
                    }
                }
            }

            lastScanDate = now

            if matchCount > 0 {
                logger.info("Generated \(matchCount) event-participant suggestion(s)")
            }

        } catch {
            logger.error("OutgoingEventMatcher scan failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Event Matching

    /// Check if message text references a given event by title keywords, date, or venue.
    private func messageReferencesEvent(searchText: String, event: SamEvent) -> Bool {
        // Match on event title keywords (at least 2 significant words)
        let titleWords = event.title
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 3 } // Skip short words like "the", "and", "for"

        let titleMatchCount = titleWords.filter { searchText.contains($0) }.count
        if titleWords.count >= 2 && titleMatchCount >= 2 {
            return true
        }
        // For short titles (1 significant word), require exact match
        if titleWords.count == 1 && titleMatchCount == 1 {
            return true
        }

        // Match on venue name
        if let venue = event.venue?.lowercased(), venue.count > 3, searchText.contains(venue) {
            return true
        }

        // Match on formatted date (e.g., "March 28" or "3/28")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d"
        let longDate = dateFormatter.string(from: event.startDate).lowercased()
        if searchText.contains(longDate) {
            return true
        }

        dateFormatter.dateFormat = "M/d"
        let shortDate = dateFormatter.string(from: event.startDate)
        if searchText.contains(shortDate) {
            return true
        }

        return false
    }

    // MARK: - Outcome Generation

    /// Generate an outcome suggesting the user add this person as a participant to the event.
    private func generateAddParticipantOutcome(
        person: SamPerson,
        event: SamEvent,
        evidence: SamEvidenceItem
    ) throws {
        let personName = person.displayNameCache ?? person.displayName

        // Dedup: check if we already have a similar outcome for this person + event
        let active = (try? outcomeRepo.fetchActive()) ?? []
        let alreadyExists = active.contains { outcome in
            outcome.linkedPerson?.id == person.id
            && outcome.sourceInsightSummary.contains(event.id.uuidString)
        }
        guard !alreadyExists else { return }

        let channelName = evidence.source.displayName
        let eventDate = event.startDate.formatted(date: .abbreviated, time: .omitted)

        let outcome = SamOutcome(
            title: "Add \(personName) to \(event.title)",
            rationale: "You sent a \(channelName) message to \(personName) that appears to reference your \(eventDate) event \"\(event.title)\". They may be attending — would you like to add them as a participant?",
            outcomeKind: .preparation,
            priorityScore: 0.65,
            deadlineDate: event.startDate,
            sourceInsightSummary: "eventID:\(event.id.uuidString)",
            suggestedNextStep: "Open \(event.title) and add \(personName) as a participant."
        )
        outcome.linkedPerson = person
        outcome.actionLaneRawValue = ActionLane.schedule.rawValue

        try outcomeRepo.upsert(outcome: outcome)
        logger.debug("Suggested adding \(personName, privacy: .private) to event \(event.title)")
    }
}
