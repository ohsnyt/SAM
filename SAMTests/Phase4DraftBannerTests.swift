//
//  Phase4DraftBannerTests.swift
//  SAMTests
//
//  Phase 4 of the sheet-tear-down work loss fix.
//
//  Verifies the Today restore banner's data sources: descriptor query,
//  7-day auto-discard pass, the UserDefaults-backed pending notice
//  counter, displayTitle round-trip from the coordinator into FormDraft,
//  and CapturePayloadSnapshot reconstruction of a CapturePayload from a
//  draft.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("Phase 4 Draft Banner Tests", .serialized)
@MainActor
struct Phase4DraftBannerTests {

    private func configureService() throws {
        let container = try makeTestContainer()
        DraftPersistenceService.shared.configure(container: container)
        DraftStore.shared.clearAll()
        // Reset the pending notice counter so each test starts clean.
        DraftPersistenceService.shared.acknowledgePendingAutoDiscardNotice()
    }

    private func makePayload(title: String = "Coffee with Bob") -> CapturePayload {
        CapturePayload(
            captureKind: .meeting,
            eventTitle: title,
            eventDate: Date(timeIntervalSince1970: 1_750_000_000),
            attendees: [],
            talkingPoints: ["Discuss pricing", "Timeline"],
            openActionItems: ["Send proposal"],
            evidenceID: UUID()
        )
    }

    // MARK: - Descriptors

    @Test("Descriptor surfaces displayTitle and subjectID")
    func descriptorCarriesDisplayMetadata() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload(title: "Quarterly review with Alice"))
        coord.mainOutcomeText = "Anything"
        coord.flushNow()

        let descriptors = DraftPersistenceService.shared.unfinishedDraftDescriptors()
        let descriptor = try #require(descriptors.first { $0.subjectID == coord.subjectID })
        #expect(descriptor.displayTitle == "Quarterly review with Alice")
        #expect(descriptor.formKind == .postMeetingCapture)
        #expect(descriptor.displaySubtitle != nil)
    }

    @Test("Descriptor list is empty after every draft is cleared")
    func descriptorListEmptiesAfterClear() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload())
        coord.mainOutcomeText = "Some content"
        coord.flushNow()
        #expect(DraftPersistenceService.shared.unfinishedDraftDescriptors().count == 1)

        coord.clearDraft()
        #expect(DraftPersistenceService.shared.unfinishedDraftDescriptors().count == 0)
    }

    // MARK: - Auto-discard

    @Test("Auto-discard purges drafts older than TTL and increments pending count")
    func autoDiscardPurgesAndCounts() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload())
        coord.mainOutcomeText = "Old content"
        coord.flushNow()

        // Backdate the draft so it qualifies as stale.
        let descriptor = try #require(DraftPersistenceService.shared.unfinishedDraftDescriptors().first)
        let row = try #require(DraftPersistenceService.shared.allActive(olderThan: .infinity)
            .first(where: { $0.id == descriptor.id }))
        row.updatedAt = .now.addingTimeInterval(-60 * 60 * 24 * 10)  // 10 days ago

        let purgedCount = DraftPersistenceService.shared.runAutoDiscardIfNeeded()
        #expect(purgedCount == 1)
        #expect(DraftPersistenceService.shared.unfinishedDraftDescriptors().count == 0)

        let (notice, when) = DraftPersistenceService.shared.pendingAutoDiscardNotice()
        #expect(notice == 1)
        #expect(when != nil)
    }

    @Test("Acknowledging the notice clears the pending count")
    func acknowledgeClearsNotice() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload())
        coord.mainOutcomeText = "Anything"
        coord.flushNow()

        let row = try #require(DraftPersistenceService.shared.allActive(olderThan: .infinity).first)
        row.updatedAt = .now.addingTimeInterval(-60 * 60 * 24 * 10)
        DraftPersistenceService.shared.runAutoDiscardIfNeeded()
        #expect(DraftPersistenceService.shared.pendingAutoDiscardNotice().count == 1)

        DraftPersistenceService.shared.acknowledgePendingAutoDiscardNotice()
        #expect(DraftPersistenceService.shared.pendingAutoDiscardNotice().count == 0)
    }

    @Test("Auto-discard accumulates across multiple passes until acknowledged")
    func autoDiscardAccumulates() throws {
        try configureService()
        let coordA = PostMeetingCaptureCoordinator(payload: makePayload(title: "A"))
        coordA.mainOutcomeText = "A"
        coordA.flushNow()
        let rowA = try #require(DraftPersistenceService.shared.allActive(olderThan: .infinity)
            .first(where: { $0.subjectID == coordA.subjectID }))
        rowA.updatedAt = .now.addingTimeInterval(-60 * 60 * 24 * 10)

        DraftPersistenceService.shared.runAutoDiscardIfNeeded()
        #expect(DraftPersistenceService.shared.pendingAutoDiscardNotice().count == 1)

        let coordB = PostMeetingCaptureCoordinator(payload: makePayload(title: "B"))
        coordB.mainOutcomeText = "B"
        coordB.flushNow()
        let rowB = try #require(DraftPersistenceService.shared.allActive(olderThan: .infinity)
            .first(where: { $0.subjectID == coordB.subjectID }))
        rowB.updatedAt = .now.addingTimeInterval(-60 * 60 * 24 * 14)

        DraftPersistenceService.shared.runAutoDiscardIfNeeded()
        // Accumulated: 1 + 1 = 2 until the user acknowledges.
        #expect(DraftPersistenceService.shared.pendingAutoDiscardNotice().count == 2)
    }

    @Test("Empty store: auto-discard reports zero purged and no notice")
    func autoDiscardEmptyStore() throws {
        try configureService()
        let purgedCount = DraftPersistenceService.shared.runAutoDiscardIfNeeded()
        #expect(purgedCount == 0)
        #expect(DraftPersistenceService.shared.pendingAutoDiscardNotice().count == 0)
    }

    // MARK: - Snapshot round-trip

    @Test("Saved coordinator round-trips through CapturePayloadSnapshot")
    func snapshotRoundTrip() throws {
        try configureService()
        let alice = CaptureAttendeeInfo(
            personID: UUID(),
            displayName: "Alice",
            roleBadges: ["Client"],
            pendingActionItems: ["Renew policy"],
            recentLifeEvents: ["Moved homes"]
        )
        let original = CapturePayload(
            captureKind: .meeting,
            eventTitle: "Client review",
            eventDate: Date(timeIntervalSince1970: 1_750_000_000),
            attendees: [alice],
            talkingPoints: ["Policy options"],
            openActionItems: ["Email Bob"],
            evidenceID: UUID()
        )
        let coord = PostMeetingCaptureCoordinator(payload: original)
        coord.mainOutcomeText = "Real content"
        coord.flushNow()

        // Load the StoredPayload back and reconstruct CapturePayload.
        let stored = try #require(DraftPersistenceService.shared.load(
            PostMeetingCaptureCoordinator.StoredPayload.self,
            kind: .postMeetingCapture,
            subjectID: coord.subjectID
        ))
        let snapshot = try #require(stored.payloadSnapshot)
        let restored = snapshot.toCapturePayload()

        #expect(restored.eventTitle == "Client review")
        #expect(restored.attendees.count == 1)
        #expect(restored.attendees.first?.displayName == "Alice")
        #expect(restored.attendees.first?.roleBadges == ["Client"])
        #expect(restored.talkingPoints == ["Policy options"])
        #expect(restored.openActionItems == ["Email Bob"])
        #expect(restored.evidenceID == original.evidenceID)
    }

    @Test("hasUnfinishedDraft probe matches the active draft state")
    func hasUnfinishedDraftProbe() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload())
        coord.mainOutcomeText = "Mid-flight content"
        coord.flushNow()

        #expect(DraftPersistenceService.shared.hasUnfinishedDraft(
            kind: .postMeetingCapture,
            subjectID: coord.subjectID
        ) == true)

        coord.clearDraft()
        #expect(DraftPersistenceService.shared.hasUnfinishedDraft(
            kind: .postMeetingCapture,
            subjectID: coord.subjectID
        ) == false)
    }
}
