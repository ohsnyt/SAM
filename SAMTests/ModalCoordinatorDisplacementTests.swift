//
//  ModalCoordinatorDisplacementTests.swift
//  SAMTests
//
//  Phase 3 of the sheet-tear-down work loss fix.
//
//  Verifies the soft-displacement guard, stale-queue dequeue, and the
//  PostMeetingCaptureCoordinator's idle-decay behavior. These are the
//  behavioral changes that prevent a sheet Sarah is actively typing in
//  from being yanked away by autonomous coaching prompts — and prevent
//  the queue from spitting out a backlog of stale prompts the moment
//  she finishes typing.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("ModalCoordinator Displacement Tests", .serialized)
@MainActor
struct ModalCoordinatorDisplacementTests {

    // MARK: - Test scaffolding

    /// Resets the singleton coordinator between tests.
    private func resetCoordinator() {
        ModalCoordinator.shared.resetForTesting()
    }

    private final class FakePresentation {
        var presented = false
        var dismissed = false
        func present() { presented = true }
        func dismiss() { presented = false; dismissed = true }
    }

    // MARK: - Soft-displacement guard

    @Test("Active sheet with user content blocks replaceLowerPriority displacement")
    func softDisplacementBlocksLowerThanCritical() async throws {
        resetCoordinator()
        let active = FakePresentation()
        let incoming = FakePresentation()

        // Active opportunistic sheet declares it has user content.
        let activeToken = ModalCoordinator.shared.requestPresentation(
            identifier: "active.capture",
            priority: .opportunistic,
            policy: .queue,
            present: { active.present() },
            dismissActive: { active.dismiss() },
            hasUserContentProvider: { true }
        )
        #expect(active.presented == true)

        // userInitiated request with replaceLowerPriority would normally
        // bump the active opportunistic — but the user-content guard
        // should queue it instead.
        _ = ModalCoordinator.shared.requestPresentation(
            identifier: "incoming.user",
            priority: .userInitiated,
            policy: .replaceLowerPriority,
            present: { incoming.present() },
            dismissActive: { incoming.dismiss() }
        )

        #expect(active.presented == true, "Active sheet should NOT have been dismissed")
        #expect(incoming.presented == false, "Incoming should be queued, not presented")

        // Once the active sheet releases, the queued one should advance.
        activeToken.dismissed()
        try await Task.sleep(for: .milliseconds(50))
        #expect(incoming.presented == true)
    }

    @Test("Critical priority still displaces even with user content")
    func criticalOverridesUserContentGuard() throws {
        resetCoordinator()
        let active = FakePresentation()
        let incoming = FakePresentation()

        _ = ModalCoordinator.shared.requestPresentation(
            identifier: "active.capture",
            priority: .opportunistic,
            policy: .queue,
            present: { active.present() },
            dismissActive: { active.dismiss() },
            hasUserContentProvider: { true }
        )
        #expect(active.presented == true)

        _ = ModalCoordinator.shared.requestPresentation(
            identifier: "incoming.critical",
            priority: .critical,
            policy: .replaceLowerPriority,
            present: { incoming.present() },
            dismissActive: { incoming.dismiss() }
        )

        #expect(active.dismissed == true, "Critical priority must override user-content guard")
        #expect(incoming.presented == true)
    }

    @Test("Active sheet without user content is displaced normally")
    func noUserContentAllowsDisplacement() throws {
        resetCoordinator()
        let active = FakePresentation()
        let incoming = FakePresentation()

        _ = ModalCoordinator.shared.requestPresentation(
            identifier: "active.capture",
            priority: .opportunistic,
            policy: .queue,
            present: { active.present() },
            dismissActive: { active.dismiss() },
            hasUserContentProvider: { false }
        )
        _ = ModalCoordinator.shared.requestPresentation(
            identifier: "incoming",
            priority: .userInitiated,
            policy: .replaceLowerPriority,
            present: { incoming.present() },
            dismissActive: { incoming.dismiss() }
        )

        #expect(active.dismissed == true)
        #expect(incoming.presented == true)
    }

    // MARK: - Stale-queue dequeue

    @Test("Stale queued entry is dropped at dequeue time")
    func staleQueuedEntryDropped() async throws {
        resetCoordinator()
        let active = FakePresentation()
        let stale = FakePresentation()
        let fresh = FakePresentation()

        let activeToken = ModalCoordinator.shared.requestPresentation(
            identifier: "active",
            priority: .userInitiated,
            policy: .queue,
            present: { active.present() },
            dismissActive: { active.dismiss() }
        )
        // Queue a stale entry behind it.
        _ = ModalCoordinator.shared.requestPresentation(
            identifier: "stale.prompt",
            priority: .opportunistic,
            policy: .queue,
            present: { stale.present() },
            dismissActive: { stale.dismiss() },
            isStillRelevant: { false }
        )
        // Queue a fresh entry behind both.
        _ = ModalCoordinator.shared.requestPresentation(
            identifier: "fresh.prompt",
            priority: .opportunistic,
            policy: .queue,
            present: { fresh.present() },
            dismissActive: { fresh.dismiss() },
            isStillRelevant: { true }
        )

        activeToken.dismissed()
        try await Task.sleep(for: .milliseconds(50))

        #expect(stale.presented == false, "Stale entry should be skipped")
        #expect(fresh.presented == true, "Fresh entry should advance past the stale one")
    }

    @Test("Queued entry without relevance gate is always considered relevant")
    func defaultRelevanceIsTrue() async throws {
        resetCoordinator()
        let active = FakePresentation()
        let queued = FakePresentation()

        let activeToken = ModalCoordinator.shared.requestPresentation(
            identifier: "active",
            priority: .userInitiated,
            policy: .queue,
            present: { active.present() },
            dismissActive: { active.dismiss() }
        )
        _ = ModalCoordinator.shared.requestPresentation(
            identifier: "queued",
            priority: .opportunistic,
            policy: .queue,
            present: { queued.present() },
            dismissActive: { queued.dismiss() }
            // no isStillRelevant — should default to "always relevant"
        )

        activeToken.dismissed()
        try await Task.sleep(for: .milliseconds(50))
        #expect(queued.presented == true)
    }
}

// MARK: - PostMeetingCaptureCoordinator idle decay

@Suite("PostMeetingCaptureCoordinator Idle Decay Tests", .serialized)
@MainActor
struct PostMeetingCaptureCoordinatorIdleDecayTests {

    private func configureService() throws {
        let container = try makeTestContainer()
        DraftPersistenceService.shared.configure(container: container)
        DraftStore.shared.clearAll()
    }

    private func makePayload() -> CapturePayload {
        CapturePayload(
            captureKind: .meeting,
            eventTitle: "Idle Decay Test",
            eventDate: Date(),
            attendees: [],
            talkingPoints: [],
            openActionItems: [],
            evidenceID: UUID()
        )
    }

    @Test("Fresh coordinator with no edits reports no displacement block")
    func freshCoordinatorAllowsDisplacement() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload())
        // hasUserContent is false on a blank form, and lastEditAt is nil
        // — so hasUserContentForDisplacement must be false.
        #expect(coord.hasUserContentForDisplacement == false)
    }

    @Test("Recent edit blocks displacement")
    func recentEditBlocksDisplacement() throws {
        try configureService()
        let coord = PostMeetingCaptureCoordinator(payload: makePayload())
        coord.mainOutcomeText = "Just typed"
        #expect(coord.hasUserContentForDisplacement == true)
    }

    @Test("Init seeding does not look like a user edit")
    func initSeedingIsNotUserActivity() throws {
        try configureService()
        let attendee = CaptureAttendeeInfo(
            personID: UUID(),
            displayName: "Bob",
            roleBadges: [],
            pendingActionItems: [],
            recentLifeEvents: []
        )
        let payload = CapturePayload(
            captureKind: .meeting,
            eventTitle: "Has Attendees",
            eventDate: Date(),
            attendees: [attendee],
            talkingPoints: [],
            openActionItems: [],
            evidenceID: UUID()
        )
        let coord = PostMeetingCaptureCoordinator(payload: payload)
        // Coordinator seeded attendancePresent during init; that should
        // NOT count as user activity for displacement purposes.
        #expect(coord.lastEditAt == nil)
        #expect(coord.hasUserContentForDisplacement == false)
    }

    @Test("Restored draft does not count as recent user activity")
    func restoreDoesNotResetIdleClock() throws {
        try configureService()
        let payload = makePayload()

        let first = PostMeetingCaptureCoordinator(payload: payload)
        first.mainOutcomeText = "Typed some content"
        first.flushNow()

        // Simulate a fresh instance being built later (e.g., AppShellView
        // re-creating after eviction or a process restart). The restored
        // content shouldn't reset the displacement-block clock — Sarah
        // hasn't actually touched the form in this session.
        let second = PostMeetingCaptureCoordinator(payload: payload)
        #expect(second.mainOutcomeText == "Typed some content")
        #expect(second.lastEditAt == nil)
        #expect(second.hasUserContentForDisplacement == false)
    }
}
