//
//  SentMailDetectionService.swift
//  SAM
//
//  Created on March 23, 2026.
//  Watches for sent invitation emails when SAM regains focus after Mail.app handoff.
//  Scans the Envelope Index for recently sent messages matching event subjects,
//  then resolves TO/CC/BCC recipients with role-aware intelligence.
//

import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SentMailDetection")

/// Tracks a pending invitation handoff awaiting sent mail confirmation.
struct PendingInvitationWatch: Sendable {
    let eventID: UUID
    let subject: String
    let participationID: UUID
    let recipientEmail: String
    let handedOffAt: Date
}

/// Result of matching a sent email to pending invitation watches.
struct SentMailMatchResult: Sendable {
    let messageID: String
    let subject: String
    let sentDate: Date
    let toRecipients: [String]
    let ccRecipients: [String]
    let bccRecipients: [String]
    let matchedEventID: UUID
    let matchedParticipationIDs: [UUID]
}

/// Resolved recipient with role classification for the review sheet.
struct ResolvedRecipient: Sendable, Identifiable {
    let id: UUID
    let email: String
    let person: ResolvedPerson?
    let field: RecipientField
    let classification: RecipientClassification

    enum RecipientField: String, Sendable {
        case to, cc, bcc
    }

    enum RecipientClassification: Sendable {
        case invitee                    // TO recipient — treat as invited
        case informational              // CC/BCC with Agent/Vendor/Referral role
        case ambiguous(role: String)    // CC with Client/Lead/Applicant role — needs user input
        case newContact(email: String)  // Not in SAM contacts — offer to add
    }

    struct ResolvedPerson: Sendable {
        let id: UUID
        let name: String
        let roles: [String]
        let isExistingParticipant: Bool
    }
}

// MARK: - Service

@MainActor @Observable
final class SentMailDetectionService {

    static let shared = SentMailDetectionService()

    /// Pending handoffs awaiting sent mail confirmation.
    private(set) var pendingWatches: [PendingInvitationWatch] = []

    /// Results ready for user review (shown in InvitationRecipientReviewSheet).
    var pendingReviewResult: (SentMailMatchResult, [ResolvedRecipient])?

    private var focusObserver: NSObjectProtocol?

    private init() {
        startObservingFocus()
    }

    // MARK: - Watch Registration

    /// Register a pending invitation handoff for sent mail detection.
    func watchForSentInvitation(eventID: UUID, subject: String, participationID: UUID, recipientEmail: String) {
        let watch = PendingInvitationWatch(
            eventID: eventID,
            subject: subject,
            participationID: participationID,
            recipientEmail: recipientEmail,
            handedOffAt: .now
        )
        pendingWatches.append(watch)
        logger.debug("Watching for sent invitation: \(subject) to \(recipientEmail, privacy: .private)")
    }

    // MARK: - Focus Observation

    private func startObservingFocus() {
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }

            // SAM regained focus — check for pending watches
            Task { @MainActor in
                await self.checkForSentMail()
            }
        }
    }

    // MARK: - Sent Mail Scanning

    /// Scan for sent emails matching pending watches. Retries over ~30 seconds.
    private func checkForSentMail() async {
        guard !pendingWatches.isEmpty else { return }

        // Expire watches older than 1 hour
        pendingWatches.removeAll { watch in
            watch.handedOffAt.timeIntervalSinceNow < -3600
        }
        guard !pendingWatches.isEmpty else { return }

        logger.debug("SAM regained focus — checking \(self.pendingWatches.count) pending invitation watches")

        // Retry pattern: check at 1s, 3s, 8s, 15s, 30s
        let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(7), .seconds(15)]

        for delay in retryDelays {
            try? await Task.sleep(for: delay)

            let matches = await scanSentMailbox()
            if !matches.isEmpty {
                for match in matches {
                    await processMatch(match)
                }
                return
            }
        }

        logger.debug("No sent mail matches found after retries — watches remain pending")
    }

    /// Query the Mail Envelope Index for recently sent messages matching pending watch subjects.
    private func scanSentMailbox() async -> [SentMailMatchResult] {
        guard BookmarkManager.shared.hasMailDirAccess else { return [] }

        // Find the earliest handoff time among pending watches
        guard let earliest = pendingWatches.min(by: { $0.handedOffAt < $1.handedOffAt })?.handedOffAt else {
            return []
        }

        // Resolve the mail database URL
        guard let mailDirURL = BookmarkManager.shared.resolveMailDirURL() else { return [] }

        let mailDBService = MailDatabaseService.shared

        do {
            // Find the Envelope Index database
            guard let versionDir = await mailDBService.findMailDataDir(rootURL: mailDirURL),
                  let envURL = await mailDBService.findEnvelopeIndex(in: versionDir) else {
                return []
            }

            // Determine the user's email account addresses for filtering
            let accountEmails = MailImportCoordinator.shared.selectedAccountIDs

            // Fetch message metadata from the sent mailbox
            let sentMetas = try await mailDBService.fetchMetadata(
                dbURL: envURL,
                since: earliest,
                accountEmails: accountEmails,
                maxResults: 50,
                mailbox: .sent
            )

            guard !sentMetas.isEmpty else { return [] }

            // Get full EmailDTOs with recipients
            let sentEmails = try await mailDBService.fetchMetadataOnly(
                dbURL: envURL,
                metas: sentMetas,
                mailbox: .sent
            )

            var results: [SentMailMatchResult] = []

            for email in sentEmails {
                // Match against pending watches by subject
                let matchingWatches = pendingWatches.filter { watch in
                    email.subject.localizedCaseInsensitiveContains(watch.subject) &&
                    email.date >= watch.handedOffAt
                }

                guard let firstWatch = matchingWatches.first else { continue }

                results.append(SentMailMatchResult(
                    messageID: email.messageID,
                    subject: email.subject,
                    sentDate: email.date,
                    toRecipients: email.recipientEmails,
                    ccRecipients: email.ccEmails,
                    bccRecipients: email.bccEmails,
                    matchedEventID: firstWatch.eventID,
                    matchedParticipationIDs: matchingWatches.map { $0.participationID }
                ))

                // Remove matched watches
                let matchedIDs = Set(matchingWatches.map { $0.participationID })
                pendingWatches.removeAll { matchedIDs.contains($0.participationID) }
            }

            return results
        } catch {
            logger.error("Sent mail scan failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Match Processing

    /// Process a sent mail match: resolve recipients and update participations.
    private func processMatch(_ match: SentMailMatchResult) async {
        let resolved = resolveRecipients(match: match)

        // Auto-update matched participations that were in the TO field
        var hasAmbiguous = false
        var hasNewContacts = false

        for recipient in resolved {
            switch recipient.classification {
            case .invitee:
                if let person = recipient.person, person.isExistingParticipant {
                    // Auto-confirm: update participation to .invited
                    updateParticipationToInvited(personID: person.id, eventID: match.matchedEventID)
                } else if let person = recipient.person {
                    // Known person not yet a participant — auto-add
                    addAsParticipantAndMarkInvited(personID: person.id, eventID: match.matchedEventID)
                } else {
                    hasNewContacts = true
                }
            case .informational:
                // Log evidence only
                if let person = recipient.person {
                    logInformationalCC(personID: person.id, eventID: match.matchedEventID, email: recipient.email)
                }
            case .ambiguous:
                hasAmbiguous = true
            case .newContact:
                hasNewContacts = true
            }
        }

        // Also update the original handedOff participations
        for participationID in match.matchedParticipationIDs {
            markParticipationInvited(participationID: participationID)
        }

        // If there are ambiguous or new contacts, present the review sheet
        if hasAmbiguous || hasNewContacts {
            pendingReviewResult = (match, resolved)
        }
    }

    // MARK: - Recipient Resolution

    /// Resolve all recipients from a sent email against SAM contacts with role-aware classification.
    private func resolveRecipients(match: SentMailMatchResult) -> [ResolvedRecipient] {
        var resolved: [ResolvedRecipient] = []
        let existingParticipantEmails = existingParticipantEmails(for: match.matchedEventID)

        // Informational roles — CC/BCC with these roles are not invitees
        let informationalRoles: Set<String> = ["Agent", "External Agent", "Vendor", "Referral Partner", "Strategic Alliance"]

        for email in match.toRecipients {
            let person = lookupPerson(byEmail: email, existingParticipantEmails: existingParticipantEmails)
            resolved.append(ResolvedRecipient(
                id: UUID(),
                email: email,
                person: person,
                field: .to,
                classification: person != nil ? .invitee : .newContact(email: email)
            ))
        }

        for email in match.ccRecipients {
            let person = lookupPerson(byEmail: email, existingParticipantEmails: existingParticipantEmails)
            let classification: ResolvedRecipient.RecipientClassification
            if let person {
                let hasInformationalRole = person.roles.contains { informationalRoles.contains($0) }
                if hasInformationalRole {
                    classification = .informational
                } else if !person.roles.isEmpty {
                    classification = .ambiguous(role: person.roles.first ?? "Contact")
                } else {
                    classification = .ambiguous(role: "Contact")
                }
            } else {
                classification = .informational  // Unknown CC recipients are informational
            }
            resolved.append(ResolvedRecipient(
                id: UUID(),
                email: email,
                person: person,
                field: .cc,
                classification: classification
            ))
        }

        for email in match.bccRecipients {
            let person = lookupPerson(byEmail: email, existingParticipantEmails: existingParticipantEmails)
            resolved.append(ResolvedRecipient(
                id: UUID(),
                email: email,
                person: person,
                field: .bcc,
                classification: .informational  // BCC is always informational
            ))
        }

        return resolved
    }

    // MARK: - Helpers

    private func lookupPerson(
        byEmail email: String,
        existingParticipantEmails: Set<String>
    ) -> ResolvedRecipient.ResolvedPerson? {
        guard let allPeople = try? PeopleRepository.shared.fetchAll() else { return nil }
        let lowered = email.lowercased()

        for person in allPeople {
            let emails = ([person.emailCache].compactMap { $0 } + person.emailAliases).map { $0.lowercased() }
            if emails.contains(lowered) {
                return ResolvedRecipient.ResolvedPerson(
                    id: person.id,
                    name: person.displayNameCache ?? person.displayName,
                    roles: person.roleBadges,
                    isExistingParticipant: existingParticipantEmails.contains(lowered)
                )
            }
        }
        return nil
    }

    private func existingParticipantEmails(for eventID: UUID) -> Set<String> {
        guard let event = try? EventRepository.shared.fetch(id: eventID) else { return [] }
        let participations = EventRepository.shared.fetchParticipations(for: event)
        var emails: Set<String> = []
        for p in participations {
            if let email = p.person?.emailCache?.lowercased() {
                emails.insert(email)
            }
        }
        return emails
    }

    private func updateParticipationToInvited(personID: UUID, eventID: UUID) {
        guard let event = try? EventRepository.shared.fetch(id: eventID) else { return }
        let participations = EventRepository.shared.fetchParticipations(for: event)
        if let participation = participations.first(where: { $0.person?.id == personID }) {
            participation.inviteStatus = .invited
        }
    }

    func addAsParticipantAndMarkInvited(personID: UUID, eventID: UUID) {
        guard let event = try? EventRepository.shared.fetch(id: eventID),
              let person = try? PeopleRepository.shared.fetch(id: personID) else { return }
        if let participation = try? EventRepository.shared.addParticipant(
            event: event, person: person, priority: .standard, eventRole: "Attendee"
        ) {
            participation.inviteStatus = .invited
        }
    }

    private func markParticipationInvited(participationID: UUID) {
        // Look up the participation via its associated event from the match
        // Since we process one match at a time, search all pending watches
        for watch in pendingWatches where watch.participationID == participationID {
            guard let event = try? EventRepository.shared.fetch(id: watch.eventID) else { continue }
            let participations = EventRepository.shared.fetchParticipations(for: event)
            if let participation = participations.first(where: { $0.id == participationID }) {
                if participation.inviteStatus == .handedOff {
                    participation.inviteStatus = .invited
                }
            }
            return
        }
    }

    private func logInformationalCC(personID: UUID, eventID: UUID, email: String) {
        // Create a lightweight evidence item noting the CC
        logger.debug("CC'd \(email, privacy: .private) on event invitation — informational only")
    }
}
