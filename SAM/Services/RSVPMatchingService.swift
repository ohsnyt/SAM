//
//  RSVPMatchingService.swift
//  SAM
//
//  Created on March 11, 2026.
//  Matches RSVP detections from evidence analysis to active event participations.
//

import Foundation
import os.log

/// Bridges RSVP detections from the evidence analysis pipeline to EventCoordinator.
/// When a message/email analysis detects an RSVP-like response, this service checks
/// whether the sender is on the invite list of any upcoming event and routes the
/// signal to EventCoordinator for status updates and auto-acknowledgment.
@MainActor
final class RSVPMatchingService {

    static let shared = RSVPMatchingService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "RSVPMatching")

    private init() {}

    /// Process RSVP detections extracted from a message or email.
    /// Matches the sender to active event participations and updates RSVP status.
    /// If the sender is not yet a participant on any upcoming event, auto-adds them
    /// to the nearest upcoming event and flags for user review.
    func processDetections(
        _ detections: [RSVPDetectionDTO],
        fromEvidence evidence: SamEvidenceItem
    ) {
        guard !detections.isEmpty else { return }

        let linkedPeople = evidence.linkedPeople
        guard !linkedPeople.isEmpty else {
            logger.debug("RSVP detections found but no linked people on evidence \(evidence.id)")
            return
        }

        for person in linkedPeople {
            // Skip the "Me" contact
            if person.isMe { continue }

            do {
                let activeParticipations = try EventRepository.shared.activeEventParticipations(for: person.id)

                // Use the highest-confidence detection
                guard let bestDetection = detections.max(by: { $0.confidence < $1.confidence }) else { continue }
                let rsvpStatus = mapToRSVPStatus(bestDetection.detectedStatus)

                if activeParticipations.isEmpty {
                    // Person is not on any event — try to auto-add to nearest upcoming event
                    tryAutoAddToEvent(
                        person: person,
                        rsvpStatus: rsvpStatus,
                        detection: bestDetection
                    )
                    continue
                }

                for participation in activeParticipations {
                    // Skip if already has a confirmed RSVP
                    if participation.rsvpUserConfirmed &&
                       (participation.rsvpStatus == .accepted || participation.rsvpStatus == .declined) {
                        continue
                    }

                    do {
                        try EventCoordinator.shared.processRSVPSignal(
                            participationID: participation.id,
                            detectedStatus: rsvpStatus,
                            responseQuote: bestDetection.responseText,
                            confidence: bestDetection.confidence
                        )
                        logger.info("RSVP matched: \(person.displayNameCache ?? "unknown") → \(rsvpStatus.displayName) for event \(participation.event?.title ?? "unknown")")
                    } catch {
                        logger.error("Failed to process RSVP for \(person.displayNameCache ?? "unknown"): \(error.localizedDescription)")
                    }
                }
            } catch {
                logger.error("Failed to fetch active participations for \(person.id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Auto-Add to Event

    /// When an RSVP is detected from someone not on any event's participant list,
    /// add them to the best-matching upcoming event and flag for user confirmation.
    private func tryAutoAddToEvent(
        person: SamPerson,
        rsvpStatus: RSVPStatus,
        detection: RSVPDetectionDTO
    ) {
        let personName = person.displayNameCache ?? "Unknown"

        do {
            let upcoming = try EventRepository.shared.fetchUpcoming()
            let candidates = upcoming.filter { $0.status == .inviting || $0.status == .confirmed || $0.status == .draft }

            guard !candidates.isEmpty else {
                logger.debug("RSVP from \(personName) but no active upcoming events to add them to")
                return
            }

            // Only auto-add for accepted or tentative RSVPs
            guard rsvpStatus == .accepted || rsvpStatus == .tentative else {
                logger.debug("RSVP from \(personName) was \(rsvpStatus.displayName) — skipping auto-add")
                return
            }

            // Match to the best event using event_reference if available
            let targetEvent = matchEvent(from: candidates, detection: detection)

            // Add the sender
            let participation = try autoAddParticipant(
                person: person,
                event: targetEvent,
                rsvpStatus: rsvpStatus,
                detection: detection
            )

            logger.info("Auto-added \(personName) to event '\(targetEvent.title)' with RSVP: \(rsvpStatus.displayName)")

            NotificationCenter.default.post(
                name: .samRSVPAutoAdded,
                object: nil,
                userInfo: [
                    "personName": personName,
                    "eventTitle": targetEvent.title,
                    "rsvpStatus": rsvpStatus.displayName,
                    "eventID": targetEvent.id.uuidString,
                    "participationID": participation.id.uuidString
                ]
            )

            // Handle additional guests ("I'll bring Mike and Lisa")
            processAdditionalGuests(detection: detection, event: targetEvent)

        } catch {
            logger.error("Failed to auto-add \(personName) to event: \(error.localizedDescription)")
        }
    }

    /// Add a person as a participant with RSVP, always flagged for user confirmation.
    @discardableResult
    private func autoAddParticipant(
        person: SamPerson,
        event: SamEvent,
        rsvpStatus: RSVPStatus,
        detection: RSVPDetectionDTO
    ) throws -> EventParticipation {
        let participation = try EventRepository.shared.addParticipant(
            event: event,
            person: person,
            priority: .standard,
            eventRole: "Attendee"
        )

        try EventRepository.shared.updateRSVP(
            participationID: participation.id,
            status: rsvpStatus,
            responseQuote: detection.responseText,
            detectionConfidence: detection.confidence,
            userConfirmed: false
        )

        return participation
    }

    // MARK: - Multi-Event Matching

    /// Match a detection to the best event. Uses event_reference for title/date matching,
    /// falls back to the nearest upcoming event.
    private func matchEvent(from candidates: [SamEvent], detection: RSVPDetectionDTO) -> SamEvent {
        guard let reference = detection.eventReference, !reference.isEmpty else {
            return candidates.first! // Already guaranteed non-empty by caller
        }

        let refLower = reference.lowercased()

        // Score each candidate by how well the reference matches
        var bestScore = 0
        var bestEvent = candidates.first!

        for event in candidates {
            var score = 0

            // Title match (fuzzy — check if reference words appear in title)
            let titleLower = event.title.lowercased()
            let refWords = refLower.split(separator: " ").map(String.init)
            let titleWords = titleLower.split(separator: " ").map(String.init)
            let matchingWords = refWords.filter { word in titleWords.contains(where: { $0.contains(word) || word.contains($0) }) }
            score += matchingWords.count * 10

            // Direct substring match
            if titleLower.contains(refLower) || refLower.contains(titleLower) {
                score += 50
            }

            // Day-of-week match ("Thursday", "Friday")
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEEE"
            let eventDay = dayFormatter.string(from: event.startDate).lowercased()
            if refLower.contains(eventDay) {
                score += 20
            }

            // Date match ("March 20", "3/20")
            let dateFormatter = DateFormatter()
            for format in ["MMMM d", "M/d", "MMM d"] {
                dateFormatter.dateFormat = format
                let dateStr = dateFormatter.string(from: event.startDate).lowercased()
                if refLower.contains(dateStr) {
                    score += 30
                    break
                }
            }

            if score > bestScore {
                bestScore = score
                bestEvent = event
            }
        }

        if bestScore > 0 {
            logger.debug("Matched event reference '\(reference)' to '\(bestEvent.title)' (score: \(bestScore))")
        }

        return bestEvent
    }

    // MARK: - Additional Guest Handling

    /// Process "bringing others" — look up named guests in contacts, create placeholder
    /// notifications for unnamed guests.
    private func processAdditionalGuests(detection: RSVPDetectionDTO, event: SamEvent) {
        guard detection.additionalGuestCount > 0 || !detection.additionalGuestNames.isEmpty else { return }

        // Try to match named guests to existing contacts
        for guestName in detection.additionalGuestNames {
            let trimmed = guestName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            do {
                let matches = try PeopleRepository.shared.search(query: trimmed)
                if let matched = matches.first(where: { $0.lifecycleStatus == .active && !($0.isMe) }) {
                    // Found a matching contact — auto-add them too
                    let existing = event.participations.first { $0.person?.id == matched.id }
                    if existing == nil {
                        try autoAddParticipant(
                            person: matched,
                            event: event,
                            rsvpStatus: .accepted,
                            detection: RSVPDetectionDTO(
                                responseText: "Mentioned by \(detection.senderName ?? "another attendee") as also attending",
                                detectedStatus: .accepted,
                                confidence: detection.confidence * 0.7, // Lower confidence for second-hand
                                additionalGuestCount: 0,
                                additionalGuestNames: []
                            )
                        )
                        logger.info("Auto-added guest '\(trimmed)' (matched to \(matched.displayNameCache ?? "unknown")) to '\(event.title)'")

                        NotificationCenter.default.post(
                            name: .samRSVPAutoAdded,
                            object: nil,
                            userInfo: [
                                "personName": matched.displayNameCache ?? trimmed,
                                "eventTitle": event.title,
                                "rsvpStatus": "Accepted (via referral)",
                                "eventID": event.id.uuidString,
                                "participationID": UUID().uuidString
                            ]
                        )
                    }
                } else {
                    // No matching contact — log for awareness
                    logger.info("Guest '\(trimmed)' mentioned for '\(event.title)' but no matching contact found")
                }
            } catch {
                logger.error("Failed to search for guest '\(trimmed)': \(error.localizedDescription)")
            }
        }

        // Log unnamed additional guests for awareness
        let unnamedCount = detection.additionalGuestCount - detection.additionalGuestNames.count
        if unnamedCount > 0 {
            logger.info("\(unnamedCount) unnamed additional guest(s) expected for '\(event.title)'")
        }
    }

    // MARK: - Mapping

    private func mapToRSVPStatus(_ detected: RSVPDetectionDTO.RSVPResponse) -> RSVPStatus {
        switch detected {
        case .accepted:  return .accepted
        case .declined:  return .declined
        case .tentative: return .tentative
        case .question:  return .tentative // Questions treated as tentative
        }
    }
}
