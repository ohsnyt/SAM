//
//  CalendarImportCoordinator.swift
//  SAM_crm
//
//  Created by David Snyder on 2/2/26.
//

import Foundation
import EventKit
@preconcurrency import Contacts
import SwiftUI

@MainActor
final class CalendarImportCoordinator {

    static let shared = CalendarImportCoordinator()

    /// The single, process-lifetime EKEventStore.  On macOS the
    /// authorization cache is per-instance: the instance that calls
    /// requestFullAccessToEvents() is the one whose
    /// authorizationStatus() reflects the grant.  Every other part of
    /// the app (Settings, coordinator) must use this same instance.
    static let eventStore = EKEventStore()

    private let evidenceStore = EvidenceRepository.shared

    @AppStorage("sam.calendar.import.enabled") private var importEnabled: Bool = true
    @AppStorage("sam.calendar.selectedCalendarID") private var selectedCalendarID: String = ""
    @AppStorage("sam.calendar.import.windowPastDays") private var pastDays: Int = 60
    @AppStorage("sam.calendar.import.windowFutureDays") private var futureDays: Int = 30
    @AppStorage("sam.calendar.import.lastRunAt") private var lastRunAt: Double = 0

    private var debounceTask: Task<Void, Never>?

    // Normal throttling (launch / app-activate) can be conservative,
    // but calendar-change events should prune quickly.
    private let minimumIntervalNormal: TimeInterval = 300   // 5 minutes
    private let minimumIntervalChanged: TimeInterval = 10    // 10 seconds

    func kick(reason: String) {
        debounceTask?.cancel()

        debounceTask = Task {
            // Debounce bursts of EKEventStoreChanged / app activation.
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
            await importIfNeeded(reason: reason)
        }
    }

    func importNow() async {
        await importCalendarEvidence()
    }

    private func importIfNeeded(reason: String) async {
        guard importEnabled else { return }
        guard !selectedCalendarID.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        // Only the normal periodic triggers (app launch / app became active)
        // get the conservative 5-minute throttle.  Anything event-driven
        // (calendar changed, permission granted, selection changed) should
        // run as soon as the 10-second guard clears.
        let isPeriodicTrigger = reason == "app launch" || reason == "app became active"
        let minInterval = isPeriodicTrigger ? minimumIntervalNormal : minimumIntervalChanged

        guard now - lastRunAt > minInterval else { return }

        await importCalendarEvidence()
    }

    private func importCalendarEvidence() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { return }

        // Ensure *this* EKEventStore instance has been granted access.
        // requestFullAccessToEvents() is idempotent when permission is
        // already granted — it just resolves immediately.  Without this
        // the instance's internal calendar cache may be stale if it was
        // created before the user granted permission (which is the normal
        // flow: the coordinator's singleton is created at app launch,
        // permission is granted later in Settings on a different instance).
        do {
            try await Self.eventStore.requestFullAccessToEvents()
        } catch {
            return
        }

        guard let calendar = Self.eventStore.calendars(for: .event)
            .first(where: { $0.calendarIdentifier == selectedCalendarID }) else { return }

        let start = Calendar.current.date(byAdding: .day, value: -pastDays, to: Date())!
        let end = Calendar.current.date(byAdding: .day, value: futureDays, to: Date())!

        let predicate = Self.eventStore.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let events = Self.eventStore.events(matching: predicate)

        // Track what currently exists in the observed calendar for this window.
        let currentUIDs: Set<String> = Set(events.map { "eventkit:\($0.calendarItemIdentifier)" })

        // Prune calendar evidence that no longer exists in the observed calendar (moved/deleted).
        evidenceStore.pruneCalendarEvidenceNotIn(
            currentUIDs,
            windowStart: start,
            windowEnd: end
        )

        for event in events {
            let sourceUID = "eventkit:\(event.calendarItemIdentifier)"

            let hints = await ContactsResolver.resolve(event: event)

            let item = SamEvidenceItem(
                id: UUID(),
                state: EvidenceTriageState.needsReview,
                sourceUID: sourceUID,
                source: EvidenceSource.calendar,
                occurredAt: event.startDate,
                title: (event.title?.isEmpty == false ? event.title! : "Untitled Event"),
                snippet: event.location ?? event.notes ?? "",
                bodyText: event.notes,
                participantHints: hints,
                signals: [],
                proposedLinks: [],
                linkedPeople: [],
                linkedContexts: []
            )

            try? evidenceStore.upsert(item)
        }

        lastRunAt = Date().timeIntervalSince1970
    }
}
// MARK: - Contacts Resolution

/// Resolves EKEvent attendees against CNContactStore to produce
/// `ParticipantHint` values with display-friendly names and an organiser flag.
///
/// Lookup strategy (first match wins):
///   1. `EKParticipant.contactIdentifier` → `CNContactStore.unifiedContact(withIdentifier:…)`
///   2. `mailto:` URL → email address → `CNContact.predicateForContacts(matchingEmailAddress:…)`
///   3. Fall back to the raw email or the URL string.
///
/// Read-only; never writes to Contacts.  Degrades gracefully when Contacts
/// access has not been granted.
enum ContactsResolver {

    // Single shared instance.  CNContactStore is thread-safe and
    // relatively expensive to initialise (it negotiates a change-history
    // anchor with the local database).  Creating one per event produces
    // the "Full Sync Required / Invalid Change History Anchor" console
    // noise; a singleton silences that after the first use.
    private static let contactStore = CNContactStore()

    /// Returns resolved participant hints for the given event.
    /// The organiser (if identifiable) is tagged with `isOrganizer: true`.
    static func resolve(event: EKEvent) async -> [ParticipantHint] {
        await Task.yield()

        let participants: [EKParticipant] = event.attendees ?? []
        let organizerURL: URL? = event.organizer?.url

        let hasContacts = CNContactStore.authorizationStatus(for: .contacts) == .authorized

        var hints: [ParticipantHint] = []
        // Resolve each participant on a lower priority task to avoid priority inversions.
        await withTaskGroup(of: ParticipantHint?.self) { group in
            for participant in participants {
                group.addTask(priority: .utility) {
                    let isOrganizer = participantIsOrganizer(participant, organizerURL: organizerURL)
                    let (displayName, isVerified, rawEmail) = await resolveDisplayName(
                        for: participant,
                        contactStore: hasContacts ? contactStore : nil
                    )
                    return await ParticipantHint(
                        displayName: displayName,
                        isOrganizer: isOrganizer,
                        isVerified: isVerified,
                        rawEmail: rawEmail
                    )
                }
            }
            for await maybe in group { if let hint = maybe { hints.append(hint) } }
        }
        return hints
    }

    // MARK: - Private helpers

    /// Full resolution chain for a single participant.
    /// Returns (displayName, isVerified, rawEmail).
    private static func resolveDisplayName(for participant: EKParticipant, contactStore: CNContactStore?) async -> (String, Bool, String?) {
        // Note: EKParticipant does not expose a Contacts identifier. We cannot
        // resolve directly via CNContact identifier; fall back to email/URL.

        // 2. Fall back to email extraction + predicate-based lookup.
        if let email = emailFromParticipant(participant) {
            if let contactStore {
                let resolved = resolveByEmail(email, contactStore: contactStore)
                if let resolved {
                    // Successfully matched a CNContact — verified.
                    return (resolved, true, email)
                }
            }
            // 3a. Contacts lookup failed but we have an email — unverified.
            return (email, false, email)
        }

        // 3b. No mailto: URL at all — use whatever URL we have, or a placeholder.
        let url = participant.url
        if (url.scheme?.lowercased() ?? "") != "mailto" {
            return (url.absoluteString, false, nil)
        } else {
            return ("Unknown Participant", false, nil)
        }
    }

    /// Returns true when *participant* matches the event's organiser.
    /// Comparison is by URL because `contactIdentifier` may be nil on one side.
    nonisolated private static func participantIsOrganizer(_ participant: EKParticipant, organizerURL: URL?) -> Bool {
        guard let organizerURL else { return false }
        return participant.url.absoluteString.lowercased() == organizerURL.absoluteString.lowercased()
    }

    /// Extracts an email address from an EKParticipant's mailto: URL.
    private static func emailFromParticipant(_ participant: EKParticipant) -> String? {
        let url = participant.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }

        var s = url.absoluteString
        if s.lowercased().hasPrefix("mailto:") {
            s.removeFirst("mailto:".count)
        }
        let email = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
    }

    /// Looks up a contact by its CNContact identifier (direct hit).
    /// Returns "Full Name <email>" if found, nil otherwise.
    ///
    /// Marked `nonisolated` for the same reason as `resolveByEmail`: the
    /// caller is already a `.utility` task-group child, so there is no need
    /// for an inner detached task.
    nonisolated private static func resolveByIdentifier(_ identifier: String, contactStore: CNContactStore) -> String? {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        guard let contact = try? contactStore.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch) else {
            return nil
        }
        let name = fullName(contact)
        guard !name.isEmpty else { return nil }
        let email = contact.emailAddresses.first.map { String($0.value) } ?? ""
        return email.isEmpty ? name : "\(name) <\(email)>"
    }

    /// Looks up a contact by email address using a predicate query.
    /// Returns "Full Name <email>" if a match is found, nil otherwise.
    ///
    /// All work—including the synchronous CNContactStore I/O—runs inside the
    /// caller's `.utility` task group child so there is no inner detached task
    /// whose `.value` could block a higher-QoS thread and trigger a priority
    /// inversion warning.  The method is marked `nonisolated` so it never
    /// implicitly hops to MainActor.
    nonisolated private static func resolveByEmail(_ email: String, contactStore: CNContactStore) -> String? {
        let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        guard let contact = try? contactStore.unifiedContacts(matching: predicate, keysToFetch: keysToFetch).first else {
            return nil
        }
        let name = fullName(contact)
        return name.isEmpty ? nil : "\(name) <\(email)>"
    }

    /// Combines given + family name, skipping empty components.
    nonisolated private static func fullName(_ contact: CNContact) -> String {
        [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

