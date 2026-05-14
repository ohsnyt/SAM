//
//  PostMeetingCaptureCoordinatorTests.swift
//  SAMTests
//
//  Phase 2 of the sheet-tear-down work loss fix.
//
//  Verifies the form-state coordinator: identity resolution, defensive
//  restore filtering, submit-success-clears / submit-failure-preserves,
//  and the sheet-flip recovery path that motivates the whole refactor —
//  if a coordinator is displaced and recreated for the same meeting, the
//  form should come back exactly as the user left it.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("PostMeetingCaptureCoordinator Tests", .serialized)
@MainActor
struct PostMeetingCaptureCoordinatorTests {

    // MARK: - Fixtures

    private func makePayload(
        evidenceID: UUID? = UUID(),
        attendees: [CaptureAttendeeInfo] = [],
        talkingPoints: [String] = [],
        openActionItems: [String] = []
    ) -> CapturePayload {
        CapturePayload(
            captureKind: .meeting,
            eventTitle: "Coffee with Bob",
            eventDate: Date(timeIntervalSince1970: 1_750_000_000),
            attendees: attendees,
            talkingPoints: talkingPoints,
            openActionItems: openActionItems,
            evidenceID: evidenceID
        )
    }

    private func makeAttendee(name: String = "Bob") -> CaptureAttendeeInfo {
        CaptureAttendeeInfo(
            personID: UUID(),
            displayName: name,
            roleBadges: [],
            pendingActionItems: [],
            recentLifeEvents: []
        )
    }

    private func configureService() throws {
        let container = try makeTestContainer()
        DraftPersistenceService.shared.configure(container: container)
        DraftStore.shared.clearAll()
    }

    // MARK: - Identity

    @Test("resolveSubjectID prefers evidenceID")
    func subjectIDFromEvidence() throws {
        let evidenceID = UUID()
        let payload = makePayload(evidenceID: evidenceID)
        #expect(PostMeetingCaptureCoordinator.resolveSubjectID(for: payload) == evidenceID)
    }

    @Test("resolveSubjectID is stable for impromptu captures")
    func subjectIDForImpromptu() throws {
        let p1 = makePayload(evidenceID: nil)
        let p2 = makePayload(evidenceID: nil)
        // Two payloads with identical title + date but different `id`s should
        // still resolve to the same subject UUID for coordinator lookup.
        #expect(PostMeetingCaptureCoordinator.resolveSubjectID(for: p1)
                == PostMeetingCaptureCoordinator.resolveSubjectID(for: p2))
    }

    // MARK: - Seeding from payload

    @Test("Init pre-checks all attendees")
    func initPreChecksAttendees() throws {
        try configureService()
        let alice = makeAttendee(name: "Alice")
        let bob = makeAttendee(name: "Bob")
        let payload = makePayload(attendees: [alice, bob])

        let coord = PostMeetingCaptureCoordinator(payload: payload)
        #expect(coord.attendancePresent == Set([alice.personID, bob.personID]))
    }

    @Test("Init copies unknown attendee names")
    func initCopiesUnknownNames() throws {
        try configureService()
        var payload = makePayload()
        payload.unknownAttendeeNames = ["Stranger A", "Stranger B"]
        let coord = PostMeetingCaptureCoordinator(payload: payload)
        #expect(coord.extraAttendeeNames == ["Stranger A", "Stranger B"])
    }

    // MARK: - Sheet-flip recovery (the headline use case)

    @Test("New coordinator built for same subject restores typed content")
    func reCreatingCoordinatorRestoresContent() throws {
        try configureService()
        let payload = makePayload()

        // First coordinator: user types something.
        let first = PostMeetingCaptureCoordinator(payload: payload)
        first.mainOutcomeText = "We agreed on next steps."
        first.guidedActionItemsText = "Send proposal\nSchedule follow-up"
        first.flushNow()

        // Simulate the view being torn down by displacement, then re-created.
        // AppShellView would normally reuse the same instance, but if it has
        // been evicted from the dictionary the restore path must still work.
        let second = PostMeetingCaptureCoordinator(payload: payload)
        #expect(second.mainOutcomeText == "We agreed on next steps.")
        #expect(second.guidedActionItemsText == "Send proposal\nSchedule follow-up")
    }

    @Test("Drafts for different meetings do not cross-contaminate")
    func separateMeetingsAreIsolated() throws {
        try configureService()
        let payloadA = makePayload(evidenceID: UUID())
        let payloadB = makePayload(evidenceID: UUID())

        let a = PostMeetingCaptureCoordinator(payload: payloadA)
        a.mainOutcomeText = "Meeting A content"
        a.flushNow()

        let b = PostMeetingCaptureCoordinator(payload: payloadB)
        b.mainOutcomeText = "Meeting B content"
        b.flushNow()

        let aReopened = PostMeetingCaptureCoordinator(payload: payloadA)
        let bReopened = PostMeetingCaptureCoordinator(payload: payloadB)
        #expect(aReopened.mainOutcomeText == "Meeting A content")
        #expect(bReopened.mainOutcomeText == "Meeting B content")
    }

    // MARK: - Defensive restore

    @Test("Restore drops attendee UUIDs that are no longer in the payload")
    func restoreFiltersDanglingAttendees() throws {
        try configureService()
        let alice = makeAttendee(name: "Alice")
        let bob = makeAttendee(name: "Bob")
        let payload1 = makePayload(attendees: [alice, bob])

        let coord1 = PostMeetingCaptureCoordinator(payload: payload1)
        coord1.attendancePresent = Set([alice.personID, bob.personID])
        coord1.flushNow()

        // Same meeting (same evidenceID), but Bob has been removed.
        let payload2 = CapturePayload(
            captureKind: .meeting,
            eventTitle: payload1.eventTitle,
            eventDate: payload1.eventDate,
            attendees: [alice],
            talkingPoints: [],
            openActionItems: [],
            evidenceID: payload1.evidenceID
        )

        let coord2 = PostMeetingCaptureCoordinator(payload: payload2)
        #expect(coord2.attendancePresent == Set([alice.personID]))
    }

    @Test("updatePayload refresh filters dangling references in-place")
    func updatePayloadFiltersInPlace() throws {
        try configureService()
        let alice = makeAttendee(name: "Alice")
        let bob = makeAttendee(name: "Bob")
        let payload1 = makePayload(attendees: [alice, bob])

        let coord = PostMeetingCaptureCoordinator(payload: payload1)
        #expect(coord.attendancePresent.contains(bob.personID))

        // Re-presented with bob gone.
        let payload2 = CapturePayload(
            captureKind: .meeting,
            eventTitle: payload1.eventTitle,
            eventDate: payload1.eventDate,
            attendees: [alice],
            talkingPoints: [],
            openActionItems: [],
            evidenceID: payload1.evidenceID
        )
        coord.updatePayload(payload2)
        #expect(coord.attendancePresent == Set([alice.personID]))
    }

    // MARK: - hasUserContent

    @Test("hasUserContent is false on a freshly seeded coordinator")
    func hasUserContentInitiallyFalse() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload(attendees: [makeAttendee()]))
        #expect(coord.hasUserContent == false)
    }

    @Test("hasUserContent flips true once outcome text is non-empty")
    func hasUserContentDetectsTyping() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload())
        coord.mainOutcomeText = "Real content"
        #expect(coord.hasUserContent == true)
    }

    @Test("hasUserContent works in freeform mode")
    func hasUserContentFreeform() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload())
        coord.mode = .freeform
        #expect(coord.hasUserContent == false)
        coord.discussionText = "Discussion"
        #expect(coord.hasUserContent == true)
    }

    // MARK: - Clear lifecycle

    @Test("clearDraft removes draft from disk")
    func clearDraftRemovesFromDisk() throws {
        try configureService()
        let payload = makePayload()
        let coord = PostMeetingCaptureCoordinator(payload: payload)
        coord.mainOutcomeText = "Soon to be cleared"
        coord.flushNow()

        coord.clearDraft()

        let fresh = PostMeetingCaptureCoordinator(payload: payload)
        #expect(fresh.mainOutcomeText == "")
    }

    // MARK: - Submit semantics

    @Test("submitAndClear deletes draft on successful submit")
    func submitAndClearOnSuccess() throws {
        try configureService()
        let payload = makePayload()
        let coord = PostMeetingCaptureCoordinator(payload: payload)
        coord.mainOutcomeText = "Will be submitted"
        coord.flushNow()

        try coord.submitAndClear {
            // Successful submit closure.
        }

        let fresh = PostMeetingCaptureCoordinator(payload: payload)
        #expect(fresh.mainOutcomeText == "")
    }

    @Test("submitAndClear preserves draft when submit throws")
    func submitAndClearPreservesOnFailure() throws {
        try configureService()
        let payload = makePayload()
        let coord = PostMeetingCaptureCoordinator(payload: payload)
        coord.mainOutcomeText = "Must survive failure"
        coord.flushNow()

        struct TestError: Error {}
        #expect(throws: TestError.self) {
            try coord.submitAndClear {
                throw TestError()
            }
        }

        // Draft should still be there for retry.
        let fresh = PostMeetingCaptureCoordinator(payload: payload)
        #expect(fresh.mainOutcomeText == "Must survive failure")
    }
}
