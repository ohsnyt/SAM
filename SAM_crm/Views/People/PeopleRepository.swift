import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class PeopleRepository {
    static let shared = PeopleRepository()

    private var container: ModelContainer
    private var isBatching = false
    private var pendingChangesCount = 0

    init(container: ModelContainer? = nil) {
        // Fallback container for tests; production calls configure(container:)
        self.container = container ?? (try! ModelContainer(for: SamPerson.self))
    }

    func configure(container: ModelContainer) {
        self.container = container
    }

    // Begin a batched write session; saves are deferred until endImportSession().
    func beginImportSession() {
        isBatching = true
        pendingChangesCount = 0
    }

    // End the batched write session and commit pending changes with a single save.
    func endImportSession() throws {
        defer {
            isBatching = false
            pendingChangesCount = 0
        }
        if pendingChangesCount > 0 {
            try container.mainContext.save()
        }
    }

    // Upsert a person anchored to a CNContact.identifier. If a person with
    // the same contactIdentifier exists, update displayName and email (if present).
    // Otherwise, insert a new SamPerson.
    func upsertFromContacts(contactIdentifier: String, displayName: String, email: String?) throws {
        let ctx = container.mainContext
        let fetch = FetchDescriptor<SamPerson>(
            predicate: #Predicate { $0.contactIdentifier == contactIdentifier }
        )
        if let existing = try ctx.fetch(fetch).first {
            existing.displayName = displayName
            if let email, !email.isEmpty {
                existing.email = email
            }
            if isBatching {
                pendingChangesCount += 1
            } else {
                try ctx.save()
            }
            return
        }

        let person = SamPerson(
            id: UUID(),
            displayName: displayName,
            roleBadges: [],
            contactIdentifier: contactIdentifier,
            email: email,
            consentAlertsCount: 0,
            reviewAlertsCount: 0
        )
        ctx.insert(person)
        if isBatching {
            pendingChangesCount += 1
        } else {
            try ctx.save()
        }
    }

    // Bulk upsert a collection of contacts with a single save at the end.
    // Per-item failures are collected and logged; the session still commits
    // so that successfully-upserted contacts are not lost.  The caller can
    // inspect the returned array to decide whether to surface a warning.
    @discardableResult
    func bulkUpsertFromContacts(_ items: [(contactIdentifier: String, displayName: String, email: String?)]) throws -> [Error] {
        beginImportSession()
        var failures: [Error] = []
        for item in items {
            do {
                try upsertFromContacts(contactIdentifier: item.contactIdentifier, displayName: item.displayName, email: item.email)
            } catch {
                failures.append(error)
                NSLog("PeopleRepository.bulkUpsert: failed for '%@' — %@",
                      item.displayName, error.localizedDescription)
            }
        }
        // endImportSession commits; if *that* throws we propagate it —
        // nothing was persisted.
        try endImportSession()
        return failures
    }
}
