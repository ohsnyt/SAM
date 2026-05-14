//
//  DraftPersistenceServiceTests.swift
//  SAMTests
//
//  Phase 1 of the sheet-tear-down work loss fix.
//  Verifies CRUD on FormDraft via DraftPersistenceService, schema-tolerant
//  decode behavior, staleness queries, and DraftStore disk backing.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("DraftPersistenceService Tests", .serialized)
@MainActor
struct DraftPersistenceServiceTests {

    // MARK: - Test Payloads

    struct SamplePayload: Codable, Equatable {
        var title: String
        var actionItems: [String]
        var count: Int
    }

    /// Adds a new optional field to verify backwards-compat decode.
    struct SamplePayloadV2: Codable, Equatable {
        var title: String
        var actionItems: [String]
        var count: Int
        var addedLater: String?
    }

    /// Drops a required field to verify forward-incompatible decode fails soft.
    struct IncompatiblePayload: Codable, Equatable {
        var totallyDifferent: Bool
    }

    // MARK: - Setup

    private func makeService() throws -> DraftPersistenceService {
        let container = try makeTestContainer()
        let service = DraftPersistenceService.shared
        service.configure(container: container)
        // Wipe DraftStore's in-memory cache so its legacy-backed tests
        // start from a clean state every test (the shared singleton
        // otherwise leaks state across runs).
        DraftStore.shared.clearAll()
        return service
    }

    // MARK: - Typed CRUD

    @Test("Save then load returns equal payload")
    func saveThenLoadRoundTrips() throws {
        let service = try makeService()
        let subject = UUID()
        let payload = SamplePayload(title: "Coffee with Bob", actionItems: ["Send proposal", "Schedule follow-up"], count: 2)

        try service.save(kind: .postMeetingCapture, subjectID: subject, payload: payload)
        let loaded = service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subject)

        #expect(loaded == payload)
    }

    @Test("Load returns nil when no draft exists")
    func loadReturnsNilForMissingDraft() throws {
        let service = try makeService()
        let loaded = service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: UUID())
        #expect(loaded == nil)
    }

    @Test("Save twice for same subject upserts, not duplicates")
    func saveTwiceUpserts() throws {
        let service = try makeService()
        let subject = UUID()
        let v1 = SamplePayload(title: "First", actionItems: [], count: 0)
        let v2 = SamplePayload(title: "Second", actionItems: ["new"], count: 5)

        try service.save(kind: .postMeetingCapture, subjectID: subject, payload: v1)
        try service.save(kind: .postMeetingCapture, subjectID: subject, payload: v2)

        let loaded = service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subject)
        #expect(loaded == v2)

        // Verify only one row exists for the subject by checking allActive
        let active = service.allActive(olderThan: 60 * 60 * 24)
        let matching = active.filter { $0.subjectID == subject }
        #expect(matching.count == 1)
    }

    @Test("Different subjects do not collide")
    func differentSubjectsDoNotCollide() throws {
        let service = try makeService()
        let subjectA = UUID()
        let subjectB = UUID()
        let payloadA = SamplePayload(title: "A", actionItems: [], count: 1)
        let payloadB = SamplePayload(title: "B", actionItems: [], count: 2)

        try service.save(kind: .postMeetingCapture, subjectID: subjectA, payload: payloadA)
        try service.save(kind: .postMeetingCapture, subjectID: subjectB, payload: payloadB)

        #expect(service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subjectA) == payloadA)
        #expect(service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subjectB) == payloadB)
    }

    @Test("Different formKinds for same subject do not collide")
    func differentKindsDoNotCollide() throws {
        let service = try makeService()
        let subject = UUID()
        let postMeetingPayload = SamplePayload(title: "Capture", actionItems: [], count: 1)
        let contentPayload = SamplePayload(title: "Draft", actionItems: [], count: 2)

        try service.save(kind: .postMeetingCapture, subjectID: subject, payload: postMeetingPayload)
        try service.save(kind: .contentDraft, subjectID: subject, payload: contentPayload)

        #expect(service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subject) == postMeetingPayload)
        #expect(service.load(SamplePayload.self, kind: .contentDraft, subjectID: subject) == contentPayload)
    }

    @Test("Delete removes the draft")
    func deleteRemovesDraft() throws {
        let service = try makeService()
        let subject = UUID()
        let payload = SamplePayload(title: "Tmp", actionItems: [], count: 0)

        try service.save(kind: .postMeetingCapture, subjectID: subject, payload: payload)
        #expect(service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subject) != nil)

        service.delete(kind: .postMeetingCapture, subjectID: subject)
        #expect(service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subject) == nil)
    }

    // MARK: - Schema Tolerance

    @Test("Decoding into a payload with added optional fields succeeds")
    func decodingForwardCompatibleSucceeds() throws {
        let service = try makeService()
        let subject = UUID()
        let v1 = SamplePayload(title: "Old", actionItems: ["a"], count: 1)
        try service.save(kind: .postMeetingCapture, subjectID: subject, payload: v1)

        // Saved as V1; decode as V2 (which adds an optional field).
        let asV2 = service.load(SamplePayloadV2.self, kind: .postMeetingCapture, subjectID: subject)
        #expect(asV2?.title == "Old")
        #expect(asV2?.addedLater == nil)
    }

    @Test("Undecodable payload returns nil rather than throwing")
    func undecodablePayloadReturnsNil() throws {
        let service = try makeService()
        let subject = UUID()
        let v1 = SamplePayload(title: "Original", actionItems: [], count: 0)
        try service.save(kind: .postMeetingCapture, subjectID: subject, payload: v1)

        // Try to decode as an incompatible struct — should soft-fail.
        let asIncompatible = service.load(IncompatiblePayload.self, kind: .postMeetingCapture, subjectID: subject)
        #expect(asIncompatible == nil)

        // The row itself should still exist on disk (undecodable does not mean delete).
        let active = service.allActive(olderThan: 60 * 60 * 24)
        #expect(active.contains { $0.subjectID == subject })
    }

    // MARK: - Staleness

    @Test("allStale and allActive partition by updatedAt")
    func stalenessQueriesPartitionByAge() throws {
        let service = try makeService()
        let oldSubject = UUID()
        let newSubject = UUID()
        try service.save(kind: .postMeetingCapture, subjectID: oldSubject, payload: SamplePayload(title: "Old", actionItems: [], count: 0))
        try service.save(kind: .postMeetingCapture, subjectID: newSubject, payload: SamplePayload(title: "New", actionItems: [], count: 0))

        // Backdate the "old" row.
        let active = service.allActive(olderThan: 60 * 60 * 24 * 30)
        guard let oldRow = active.first(where: { $0.subjectID == oldSubject }) else {
            Issue.record("Expected oldSubject row to exist")
            return
        }
        oldRow.updatedAt = .now.addingTimeInterval(-60 * 60 * 24 * 10)  // 10 days ago

        let sevenDays: TimeInterval = 60 * 60 * 24 * 7
        let stale = service.allStale(olderThan: sevenDays)
        let activeSet = service.allActive(olderThan: sevenDays)

        #expect(stale.contains { $0.subjectID == oldSubject })
        #expect(!stale.contains { $0.subjectID == newSubject })
        #expect(activeSet.contains { $0.subjectID == newSubject })
        #expect(!activeSet.contains { $0.subjectID == oldSubject })
    }

    @Test("deleteAll removes matching rows")
    func deleteAllRemovesMatchingRows() throws {
        let service = try makeService()
        let subjectA = UUID()
        let subjectB = UUID()
        try service.save(kind: .postMeetingCapture, subjectID: subjectA, payload: SamplePayload(title: "A", actionItems: [], count: 0))
        try service.save(kind: .postMeetingCapture, subjectID: subjectB, payload: SamplePayload(title: "B", actionItems: [], count: 0))

        let rows = service.allActive(olderThan: 60 * 60 * 24)
        let deleted = service.deleteAll(matching: rows)
        #expect(deleted == 2)

        #expect(service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subjectA) == nil)
        #expect(service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subjectB) == nil)
    }

    // MARK: - Legacy Field-Map API (DraftStore backing)

    @Test("Legacy save/load round-trips field maps")
    func legacyRoundTrip() throws {
        let service = try makeService()
        let subject = UUID()
        let fields = ["title": "Meeting with Bob", "notes": "Discussed proposal"]

        try service.saveLegacy(legacyKind: "manual-task", subjectID: subject, fields: fields)
        let loaded = service.loadLegacy(legacyKind: "manual-task", subjectID: subject)
        #expect(loaded == fields)
    }

    @Test("Legacy and typed drafts coexist for same subject")
    func legacyAndTypedCoexist() throws {
        let service = try makeService()
        let subject = UUID()
        try service.saveLegacy(legacyKind: "note-edit", subjectID: subject, fields: ["content": "legacy text"])
        try service.save(kind: .postMeetingCapture, subjectID: subject, payload: SamplePayload(title: "typed", actionItems: [], count: 0))

        #expect(service.loadLegacy(legacyKind: "note-edit", subjectID: subject) == ["content": "legacy text"])
        #expect(service.load(SamplePayload.self, kind: .postMeetingCapture, subjectID: subject)?.title == "typed")
    }

    @Test("Two distinct legacy kinds for the same subject ID coexist")
    func twoLegacyKindsCoexist() throws {
        let service = try makeService()
        let subject = UUID()
        try service.saveLegacy(legacyKind: "compose-message", subjectID: subject, fields: ["body": "hello"])
        try service.saveLegacy(legacyKind: "note-edit", subjectID: subject, fields: ["content": "world"])

        #expect(service.loadLegacy(legacyKind: "compose-message", subjectID: subject) == ["body": "hello"])
        #expect(service.loadLegacy(legacyKind: "note-edit", subjectID: subject) == ["content": "world"])
    }

    // MARK: - DraftStore Disk Backing
    //
    // Kept in the same @Suite as the service tests so they run serialized
    // through the shared DraftPersistenceService and DraftStore singletons
    // without parallel container-stomping.

    @Test("deriveUUID returns same UUID for same input")
    func deriveUUIDStable() {
        let a = DraftStore.deriveUUID(from: "new")
        let b = DraftStore.deriveUUID(from: "new")
        #expect(a == b)
    }

    @Test("deriveUUID returns different UUIDs for different inputs")
    func deriveUUIDDistinct() {
        let a = DraftStore.deriveUUID(from: "new")
        let b = DraftStore.deriveUUID(from: "different")
        #expect(a != b)
    }

    @Test("deriveUUID parses valid UUID strings as-is")
    func deriveUUIDParsesValidUUIDStrings() {
        let original = UUID()
        let derived = DraftStore.deriveUUID(from: original.uuidString)
        #expect(original == derived)
    }

    @Test("DraftStore in-memory save/load works without disk")
    func memorySaveAndLoad() throws {
        _ = try makeService()
        DraftStore.shared.save(kind: "test", id: "new", fields: ["a": "1"])
        let loaded = DraftStore.shared.load(kind: "test", id: "new")
        #expect(loaded == ["a": "1"])
    }

    @Test("DraftStore flushAllPending writes pending edits to disk")
    func flushAllPendingPersistsToDisk() throws {
        let service = try makeService()
        DraftStore.shared.save(kind: "test", id: "new", fields: ["a": "1"])
        DraftStore.shared.flushAllPending()

        let subjectID = DraftStore.deriveUUID(from: "new")
        let onDisk = service.loadLegacy(legacyKind: "test", subjectID: subjectID)
        #expect(onDisk == ["a": "1"])
    }

    @Test("DraftStore clear removes from both memory and disk")
    func clearRemovesFromMemoryAndDisk() throws {
        let service = try makeService()
        DraftStore.shared.save(kind: "test", id: "new", fields: ["a": "1"])
        DraftStore.shared.flushAllPending()

        let subjectID = DraftStore.deriveUUID(from: "new")
        #expect(service.loadLegacy(legacyKind: "test", subjectID: subjectID) != nil)

        DraftStore.shared.clear(kind: "test", id: "new")
        #expect(DraftStore.shared.load(kind: "test", id: "new") == nil)
        #expect(service.loadLegacy(legacyKind: "test", subjectID: subjectID) == nil)
    }

    @Test("DraftStore cold-start hydrates from disk on first load")
    func coldStartHydratesFromDisk() throws {
        let service = try makeService()
        let subjectID = DraftStore.deriveUUID(from: "from-prior-run")
        try service.saveLegacy(legacyKind: "test", subjectID: subjectID, fields: ["restored": "yes"])

        // Force the memory cache to clear so we go through the disk-miss path.
        DraftStore.shared.clearAll()

        let loaded = DraftStore.shared.load(kind: "test", id: "from-prior-run")
        #expect(loaded == ["restored": "yes"])
    }
}
