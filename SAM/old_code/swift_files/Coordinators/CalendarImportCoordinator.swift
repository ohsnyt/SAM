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

// MARK: - Shared debounced insight runner

/// Actor-based insight runner with automatic debouncing.
/// Replaces manual locking with Swift 6 actor isolation.
actor DebouncedInsightRunner {
    static let shared = DebouncedInsightRunner()
    
    private var runningTask: Task<Void, Never>?
    
    func run() {
        // Cancel any existing task to debounce
        runningTask?.cancel()
        
        DevLogger.info("🧠 [InsightRunner] Scheduled insight generation (debounce: 1.0s)")
        
        // Start new debounced task
        runningTask = Task {
            // Debounce: wait briefly to coalesce bursts of imports
            try? await Task.sleep(for: .seconds(1.0))
            
            // Check for cancellation after sleep
            guard !Task.isCancelled else {
                DevLogger.info("⏭️ [InsightRunner] Cancelled during debounce")
                return
            }
            
            DevLogger.info("🧠 [InsightRunner] Starting insight generation...")
            let ctx = SAMModelContainer.newContext()
            let generator = InsightGenerator(context: ctx)
            await generator.generatePendingInsights()
            await generator.deduplicateInsights()
            DevLogger.info("✅ [InsightGenerator] Insight generation complete")
            
            // Clear running task (no await needed - actor-isolated)
            clearRunningTask()
        }
    }
    
    private func clearRunningTask() {
        runningTask = nil
    }
}

@MainActor
final class CalendarImportCoordinator {

    static let shared = CalendarImportCoordinator()

    // Store references - can be safely captured in Task closures
    // because they're immutable references to singletons
    private let evidenceStore = EvidenceRepository.shared
    private let permissions = PermissionsManager.shared

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

        // Capture 'self' explicitly - Swift 6 allows this because the Task
        // is marked @MainActor in, ensuring safe access to MainActor-isolated state
        debounceTask = Task { @MainActor [self] in
            // Debounce bursts of EKEventStoreChanged / app activation.
            try? await Task.sleep(for: .seconds(1.5))
            await self.importIfNeeded(reason: reason)
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
        // Check permissions WITHOUT requesting (no dialogs from background tasks)
        guard permissions.hasFullCalendarAccess else { return }

        let eventStore = permissions.eventStore

        guard let calendar = eventStore.calendars(for: .event)
            .first(where: { $0.calendarIdentifier == selectedCalendarID }) else { return }

        let start = Calendar.current.date(byAdding: .day, value: -pastDays, to: Date())!
        let end = Calendar.current.date(byAdding: .day, value: futureDays, to: Date())!

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let events = eventStore.events(matching: predicate)

        // Track what currently exists in the observed calendar for this window.
        let currentUIDs: Set<String> = Set(events.map { "eventkit:\($0.calendarItemIdentifier)" })

        // Prune calendar evidence that no longer exists in the observed calendar (moved/deleted).
        evidenceStore.pruneCalendarEvidenceNotIn(
            currentUIDs,
            windowStart: start,
            windowEnd: end
        )
        
        DevLogger.info("Calendar import processed \(events.count) events for window [\(start) – \(end)]")

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
                proposedLinks: []
            )

            try? evidenceStore.upsert(item)
        }

        // Trigger Phase 2 insight generation after import completes (Option A)
        Task { @MainActor in
            await DebouncedInsightRunner.shared.run()
        }

        lastRunAt = Date().timeIntervalSince1970
    }
    
    @MainActor
    static func kickOnStartup() {
        // Generate insights at startup as a safety net
        Task { @MainActor in
            await DebouncedInsightRunner.shared.run()
        }
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

    /// Returns resolved participant hints for the given event.
    /// The organiser (if identifiable) is tagged with `isOrganizer: true`.
    static func resolve(event: EKEvent) async -> [ParticipantHint] {
        await Task.yield()

        let participants: [EKParticipant] = event.attendees ?? []
        let organizerURL: URL? = event.organizer?.url

        // Extract contact store reference outside of task group to avoid capturing
        // main-actor-isolated PermissionsManager inside concurrent tasks
        let hasContacts = PermissionsManager.shared.hasContactsAccess
        let contactStore: CNContactStore? = if hasContacts {
            PermissionsManager.shared.contactStore
        } else {
            nil
        }

        // Precompute Sendable copies to avoid capturing class references in concurrent tasks
        let organizerString = organizerURL?.absoluteString.lowercased()
        
        // Pre-resolve unique emails to avoid concurrent CNContactStore access
        var resolvedByEmail: [String: String] = [:]
        if let store = contactStore {
            // Collect unique emails from participants
            let uniqueEmails: Set<String> = Set((event.attendees ?? []).compactMap { participant in
                ContactsResolver.emailFromParticipant(participant)?.lowercased()
            })
            // Resolve each email once, serially
            for email in uniqueEmails {
                if let resolved = resolveByEmail(email, contactStore: store) {
                    resolvedByEmail[email] = resolved
                }
            }
        }

        /*
        // Snapshot for concurrent capture in @Sendable closures.
        // Child tasks created below use @Sendable closures and may execute concurrently.
        // Capturing a mutable var (like `resolvedByEmail`) by reference would violate
        // Swift 6 concurrency rules and trigger: "reference to captured var in concurrently-executing code".
        // Take an immutable copy so each task captures a value that is safe to read concurrently.
        */
        // Snapshot for concurrent capture in @Sendable closures.
        // Child tasks created below use @Sendable closures and may execute concurrently.
        // Capturing a mutable var (like `resolvedByEmail`) by reference would violate
        // Swift 6 concurrency rules and trigger: "reference to captured var in concurrently-executing code".
        // Take an immutable copy so each task captures a value that is safe to read concurrently.
        let resolvedByEmailSnapshot = resolvedByEmail

        // Build parallel arrays of all participant data we need
        var participantData: [(email: String?, urlString: String)] = []
        for participant in participants {
            let email = emailFromParticipant(participant)
            let urlString = participant.url.absoluteString
            participantData.append((email, urlString))
        }
        
        let participantCount = participantData.count

        let interim: [(displayName: String, isOrganizer: Bool, isVerified: Bool, rawEmail: String?)] = await withTaskGroup(of: (Int, String, Bool, Bool, String?).self) { group in
            for index in 0..<participantCount {
                let org = organizerString
                let data = participantData[index]

                group.addTask(priority: .utility) { @Sendable in
                    // Organizer flag via Sendable strings
                    let isOrganizer: Bool = {
                        guard let org, !data.urlString.isEmpty else { return false }
                        return data.urlString.lowercased() == org
                    }()

                    // Resolve display name using pre-resolved email map; no CNContactStore in child tasks
                    let (displayName, isVerified, rawEmail): (String, Bool, String?) = {
                        if let email = data.email, !email.isEmpty {
                            let lower = email.lowercased()
                            if let resolved = resolvedByEmailSnapshot[lower] {
                                return (resolved, true, email)
                            } else {
                                return (email, false, email)
                            }
                        }
                        // No email; use URL string as fallback
                        let lowerScheme = (URL(string: data.urlString)?.scheme ?? "").lowercased()
                        if lowerScheme != "mailto" {
                            let display = data.urlString.isEmpty ? "Unknown Participant" : data.urlString
                            return (display, false, nil)
                        } else {
                            return ("Unknown Participant", false, nil)
                        }
                    }()

                    return (index, displayName, isOrganizer, isVerified, rawEmail)
                }
            }
            
            // Collect results and sort by index to maintain order
            var collected: [(Int, String, Bool, Bool, String?)] = []
            for await value in group { collected.append(value) }
            collected.sort { $0.0 < $1.0 }
            
            // Strip the index and return
            return collected.map { ($0.1, $0.2, $0.3, $0.4) }
        }

        // Map to ParticipantHint
        return interim.map { t in
            ParticipantHint(
                displayName: t.displayName,
                isOrganizer: t.isOrganizer,
                isVerified: t.isVerified,
                rawEmail: t.rawEmail
            )
        }
    }

    // MARK: - Private helpers

    /// Full resolution chain for a single participant.
    /// Returns (displayName, isVerified, rawEmail).
    nonisolated private static func resolveDisplayName(for participant: EKParticipant, contactStore: CNContactStore?) async -> (String, Bool, String?) {
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
        let scheme = (url.scheme ?? "").lowercased()
        if scheme != "mailto" {
            return (url.absoluteString, false, nil)
        } else {
            return ("Unknown Participant", false, nil)
        }
    }

    nonisolated private static func resolveDisplayName(email: String?, urlString: String, contactStore: CNContactStore?) -> (String, Bool, String?) {
        if let email, !email.isEmpty {
            if let store = contactStore, let resolved = resolveByEmail(email, contactStore: store) {
                return (resolved, true, email)
            }
            return (email, false, email)
        }
        // No email; use URL string as fallback
        let lower = (URL(string: urlString)?.scheme ?? "").lowercased()
        if lower != "mailto" {
            return (urlString, false, nil)
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
    nonisolated private static func emailFromParticipant(_ participant: EKParticipant) -> String? {
        let url = participant.url
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "mailto" else { return nil }

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

