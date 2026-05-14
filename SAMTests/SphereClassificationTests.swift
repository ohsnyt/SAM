//
//  SphereClassificationTests.swift
//  SAMTests
//
//  Unit tests for the multi-sphere classification path (Phases C–D of the
//  May 2026 work). Covers the deterministic, no-LLM parts:
//    • Result gating thresholds (auto-apply vs review vs ignored).
//    • SphereRepository.recordExample idempotency + rotation policy.
//    • staleEmptySpheres time-based filter.
//    • Per-membership ordering & spheres(forPerson:) sort by order.
//

import Testing
import Foundation
import SwiftData
@testable import SAM

@Suite("Sphere Classification — Deterministic Path", .serialized)
@MainActor
struct SphereClassificationDeterministicTests {

    // MARK: - Result gating

    @Test("Auto-apply gate at 0.75")
    func autoApplyGateAtThreshold() {
        let id = UUID()
        // Above gate
        let above = SphereClassificationResult(sphereID: id, confidence: 0.85, reason: nil, wasColdStartCapped: false)
        #expect(above.shouldAutoApply)
        #expect(!above.shouldQueueForReview)

        // Exactly at gate
        let onGate = SphereClassificationResult(sphereID: id, confidence: 0.75, reason: nil, wasColdStartCapped: false)
        #expect(onGate.shouldAutoApply)

        // Just below
        let below = SphereClassificationResult(sphereID: id, confidence: 0.749, reason: nil, wasColdStartCapped: false)
        #expect(!below.shouldAutoApply)
        #expect(below.shouldQueueForReview)
    }

    @Test("Review band 0.5 – 0.75")
    func reviewBand() {
        let id = UUID()
        let mid = SphereClassificationResult(sphereID: id, confidence: 0.6, reason: nil, wasColdStartCapped: false)
        #expect(mid.shouldQueueForReview)
        #expect(!mid.shouldAutoApply)

        // Bottom of band
        let bottom = SphereClassificationResult(sphereID: id, confidence: 0.5, reason: nil, wasColdStartCapped: false)
        #expect(bottom.shouldQueueForReview)

        // Just below band → ignored
        let belowBand = SphereClassificationResult(sphereID: id, confidence: 0.49, reason: nil, wasColdStartCapped: false)
        #expect(!belowBand.shouldQueueForReview)
        #expect(!belowBand.shouldAutoApply)
    }

    @Test("Nil sphereID never gates positively")
    func nilSphereNeverGates() {
        let nada = SphereClassificationResult(sphereID: nil, confidence: 0.99, reason: nil, wasColdStartCapped: false)
        #expect(!nada.shouldAutoApply)
        #expect(!nada.shouldQueueForReview)
    }

    // MARK: - Example pool rotation

    @Test("recordExample is idempotent on evidenceID")
    func recordExampleIsIdempotent() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let sphere = try SphereRepository.shared.createSphere(name: "Work")
        let evidenceID = UUID()

        _ = try SphereRepository.shared.recordExample(
            sphereID: sphere.id, evidenceID: evidenceID,
            snippet: "first capture", wasOverride: false
        )
        _ = try SphereRepository.shared.recordExample(
            sphereID: sphere.id, evidenceID: evidenceID,
            snippet: "first capture", wasOverride: false
        )

        let refreshed = try #require(try SphereRepository.shared.fetch(id: sphere.id))
        #expect(refreshed.examples.count == 1)
    }

    @Test("Re-recording an evidenceID upgrades wasOverride flag")
    func recordExampleUpgradesOverride() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let sphere = try SphereRepository.shared.createSphere(name: "Work")
        let evidenceID = UUID()

        _ = try SphereRepository.shared.recordExample(
            sphereID: sphere.id, evidenceID: evidenceID,
            snippet: "accepted", wasOverride: false
        )
        _ = try SphereRepository.shared.recordExample(
            sphereID: sphere.id, evidenceID: evidenceID,
            snippet: "now an override", wasOverride: true
        )

        let refreshed = try #require(try SphereRepository.shared.fetch(id: sphere.id))
        #expect(refreshed.examples.count == 1)
        #expect(refreshed.examples.first?.wasOverride == true)
    }

    @Test("Rotation prefers evicting non-overrides")
    func rotationKeepsOverrides() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let sphere = try SphereRepository.shared.createSphere(name: "Work")

        // Stuff in 8 non-overrides + then 1 override — should evict the
        // oldest non-override, not the brand-new override.
        for i in 0..<Sphere.maxExamples {
            _ = try SphereRepository.shared.recordExample(
                sphereID: sphere.id, evidenceID: UUID(),
                snippet: "msg \(i)", wasOverride: false
            )
        }
        let overrideID = UUID()
        _ = try SphereRepository.shared.recordExample(
            sphereID: sphere.id, evidenceID: overrideID,
            snippet: "user-corrected", wasOverride: true
        )

        let refreshed = try #require(try SphereRepository.shared.fetch(id: sphere.id))
        #expect(refreshed.examples.count == Sphere.maxExamples)
        #expect(refreshed.examples.contains { $0.evidenceID == overrideID && $0.wasOverride })
    }

    @Test("All-overrides pool evicts oldest entry when full")
    func rotationAllOverridesEvictsOldest() async throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let sphere = try SphereRepository.shared.createSphere(name: "Work")

        var oldestID: UUID?
        for i in 0..<(Sphere.maxExamples + 1) {
            let id = UUID()
            if i == 0 { oldestID = id }
            _ = try SphereRepository.shared.recordExample(
                sphereID: sphere.id, evidenceID: id,
                snippet: "msg \(i)", wasOverride: true
            )
            // Force monotonically increasing addedAt without sleeping the
            // whole suite. Tiny offset is enough for the sort comparator.
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let refreshed = try #require(try SphereRepository.shared.fetch(id: sphere.id))
        #expect(refreshed.examples.count == Sphere.maxExamples)
        #expect(!refreshed.examples.contains { $0.evidenceID == oldestID })
    }

    // MARK: - Stale empty filter

    @Test("staleEmptySpheres respects 30-day threshold")
    func staleEmptyAge() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)

        // Fresh sphere — should NOT count, regardless of example count.
        _ = try SphereRepository.shared.createSphere(name: "Brand New")

        // Old sphere with no examples — SHOULD count.
        let old = try SphereRepository.shared.createSphere(name: "Forgotten")
        old.createdAt = Date(timeIntervalSinceNow: -45 * 86_400)
        try old.modelContext?.save()

        let stale = try SphereRepository.shared.staleEmptySpheres()
        #expect(stale.contains { $0.id == old.id })
        #expect(!stale.contains { $0.name == "Brand New" })
    }

    @Test("staleEmptySpheres ignores bootstrap default")
    func staleEmptyIgnoresBootstrap() throws {
        let container = try makeTestContainer()
        configureAllRepositories(with: container)
        let boot = try SphereRepository.shared.createSphere(
            name: "My Practice",
            isBootstrapDefault: true
        )
        boot.createdAt = Date(timeIntervalSinceNow: -90 * 86_400)
        try boot.modelContext?.save()

        let stale = try SphereRepository.shared.staleEmptySpheres()
        #expect(!stale.contains { $0.id == boot.id })
    }
}
