//
//  GoHighLevelRegistrationService.swift
//  SAM
//
//  Detects GoHighLevel event registration notification emails and creates
//  EventParticipation records on the matching SamEvent.
//
//  Email pattern:
//    From: sarah.snyder@nofamilyleftbehind.co   (user-configurable via UserDefaults)
//    Subject: Registered: {name} has registered for [the] {event title}
//
//  Name and event title are matched to SamPerson / SamEvent using FoundationModels
//  for fuzzy matching (handles nicknames, title variations, etc.).
//

import Foundation
import os.log

actor GoHighLevelRegistrationService {

    static let shared = GoHighLevelRegistrationService()
    private init() {}

    nonisolated let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "GoHighLevelRegistration")

    /// UserDefaults key for the GoHighLevel sender address.
    /// Defaults to sarah.snyder@nofamilyleftbehind.co; can be overridden in Settings.
    nonisolated static let kSenderKey = "sam.goHighLevel.registrationSenderEmail"

    // MARK: - Public API

    /// Process a batch of email metadata structs that matched the GoHighLevel filter.
    /// Called from MailImportCoordinator step 1d. Runs at utility priority.
    func processRegistrations(_ metas: [MessageMeta]) async {
        for meta in metas {
            await processOne(meta)
        }
    }

    // MARK: - Per-email Processing

    private func processOne(_ meta: MessageMeta) async {
        guard let parsed = parseSubject(meta.subject) else {
            logger.debug("GoHighLevel: couldn't parse subject '\(meta.subject, privacy: .private)'")
            return
        }

        logger.debug("GoHighLevel: parsed — name='\(parsed.registrantName, privacy: .private)' event='\(parsed.eventHint, privacy: .private)'")

        // Fetch candidates on the main actor
        let (personCandidates, eventCandidates) = await MainActor.run {
            let people = (try? PeopleRepository.shared.fetchAll()) ?? []
            let events = (try? EventRepository.shared.fetchAll()) ?? []
            // Only consider future/active events
            let relevantEvents = events.filter { $0.status != .cancelled && $0.status != .completed }
            return (
                people.compactMap { $0.displayNameCache }.filter { !$0.isEmpty },
                relevantEvents.map { ($0.id, $0.title) }
            )
        }

        guard !eventCandidates.isEmpty else {
            logger.debug("GoHighLevel: no active SamEvents to match against")
            return
        }

        // Fuzzy match with FoundationModels
        async let matchedEventID = matchEvent(hint: parsed.eventHint, candidates: eventCandidates)
        async let matchedPersonName = matchPerson(name: parsed.registrantName, candidates: personCandidates)

        let (eventID, personName) = await (matchedEventID, matchedPersonName)

        guard let eventID else {
            logger.info("GoHighLevel: no event matched '\(parsed.eventHint, privacy: .private)' — skipping")
            return
        }

        // Create participation on the main actor
        await MainActor.run {
            do {
                let eventRepo = EventRepository.shared
                guard let event = try eventRepo.fetch(id: eventID) else { return }

                let person: SamPerson
                if let personName,
                   let existing = (try? PeopleRepository.shared.fetchAll())?.first(where: { $0.displayNameCache == personName }) {
                    person = existing
                    logger.info("GoHighLevel: matched '\(parsed.registrantName, privacy: .private)' → '\(personName, privacy: .private)'")
                } else {
                    // Create standalone person
                    person = try PeopleRepository.shared.insertStandalone(
                        displayName: parsed.registrantName
                    )
                    logger.info("GoHighLevel: created new person '\(parsed.registrantName, privacy: .private)'")
                }

                let participation = try eventRepo.addParticipant(
                    event: event,
                    person: person,
                    priority: .standard,
                    eventRole: "Attendee"
                )
                try eventRepo.updateRSVP(
                    participationID: participation.id,
                    status: .accepted,
                    responseQuote: "Registered via GoHighLevel: \(meta.subject)",
                    detectionConfidence: 1.0,
                    userConfirmed: true
                )
                logger.info("GoHighLevel: added \(parsed.registrantName, privacy: .private) to '\(event.title, privacy: .private)'")
            } catch {
                logger.error("GoHighLevel: failed to create participation: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Subject Parsing

    struct ParsedRegistration: Sendable {
        let registrantName: String
        let eventHint: String
    }

    /// Deterministically extract name and event hint from a GoHighLevel registration subject.
    /// Expected format: "Registered: {name} has registered for [the] {event title}"
    func parseSubject(_ subject: String) -> ParsedRegistration? {
        let prefix = "Registered:"
        guard subject.hasPrefix(prefix) else { return nil }

        let afterColon = subject.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)

        // Extract name: everything before " has registered"
        let hasRegisteredMarker = " has registered"
        guard let markerRange = afterColon.range(of: hasRegisteredMarker, options: .caseInsensitive) else {
            // Fallback: if GoHighLevel format varies, use everything before " for "
            if let forRange = afterColon.range(of: " for ", options: .caseInsensitive) {
                let name = String(afterColon[..<forRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let eventHint = String(afterColon[forRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !eventHint.isEmpty else { return nil }
                return ParsedRegistration(registrantName: name, eventHint: stripLeadingThe(eventHint))
            }
            return nil
        }

        let name = String(afterColon[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespaces)

        // Extract event hint: everything after "has registered for [the] "
        let afterMarker = String(afterColon[markerRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let eventHint: String
        if afterMarker.lowercased().hasPrefix("for ") {
            let afterFor = afterMarker.dropFirst(4).trimmingCharacters(in: .whitespaces)
            eventHint = stripLeadingThe(afterFor)
        } else {
            eventHint = stripLeadingThe(afterMarker)
        }

        guard !name.isEmpty, !eventHint.isEmpty else { return nil }
        return ParsedRegistration(registrantName: name, eventHint: eventHint)
    }

    private func stripLeadingThe(_ s: String) -> String {
        let lower = s.lowercased()
        if lower.hasPrefix("the ") { return String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        return s
    }

    // MARK: - FoundationModels Fuzzy Matching

    /// Returns the SamEvent ID that best matches the hint, or nil if no reasonable match.
    private func matchEvent(hint: String, candidates: [(id: UUID, title: String)]) async -> UUID? {
        guard !candidates.isEmpty else { return nil }

        // Build a compact candidate list for the model
        let numbered = candidates.enumerated().map { "\($0.offset + 1). \($0.element.title)" }.joined(separator: "\n")
        let prompt = """
Event hint extracted from a registration email: "\(hint)"

Active events (numbered):
\(numbered)

Which event number best matches the hint? Consider partial titles, word order variations, and abbreviations. Reply with just the number, or "0" if nothing is a reasonable match.
"""
        do {
            let response = try await AIService.shared.generate(
                prompt: prompt,
                systemInstruction: "You match event registration emails to event names. Be conservative: reply 0 if there is no reasonable match.",
                maxTokens: 4
            )
            let digits = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = Int(digits), index > 0, index <= candidates.count {
                return candidates[index - 1].id
            }
        } catch {
            logger.warning("GoHighLevel event match failed: \(error.localizedDescription)")
            // Fallback: simple contains check
            let hintLower = hint.lowercased()
            for candidate in candidates {
                if candidate.title.lowercased().contains(hintLower) || hintLower.contains(candidate.title.lowercased()) {
                    return candidate.id
                }
            }
        }
        return nil
    }

    /// Returns the candidate name that best matches the registrant name, or nil if no match.
    private func matchPerson(name: String, candidates: [String]) async -> String? {
        guard !candidates.isEmpty else { return nil }

        let numbered = candidates.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let prompt = """
Registrant name from a registration email: "\(name)"

Existing contacts (numbered):
\(numbered)

Which contact number best matches the registrant? Consider nicknames, middle names, and name order variations. Reply with just the number, or "0" if nothing is a reasonable match.
"""
        do {
            let response = try await AIService.shared.generate(
                prompt: prompt,
                systemInstruction: "You match registration names to contact names. Be conservative: reply 0 if there is genuine ambiguity or no reasonable match.",
                maxTokens: 4
            )
            let digits = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = Int(digits), index > 0, index <= candidates.count {
                return candidates[index - 1]
            }
        } catch {
            logger.warning("GoHighLevel person match failed: \(error.localizedDescription)")
            // Fallback: case-insensitive exact match
            let nameLower = name.lowercased()
            return candidates.first { $0.lowercased() == nameLower }
        }
        return nil
    }

    // MARK: - Sender Configuration

    /// The configured GoHighLevel registration sender email address.
    static var registrationSenderEmail: String {
        UserDefaults.standard.string(forKey: kSenderKey) ?? "sarah.snyder@nofamilyleftbehind.co"
    }

    /// Returns true if this email metadata matches the GoHighLevel registration pattern.
    static func isRegistrationEmail(_ meta: MessageMeta) -> Bool {
        meta.senderEmail.lowercased() == registrationSenderEmail.lowercased()
        && meta.subject.hasPrefix("Registered:")
    }
}
