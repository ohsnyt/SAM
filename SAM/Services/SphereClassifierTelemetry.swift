//
//  SphereClassifierTelemetry.swift
//  SAM
//
//  Phase D8 of the multi-sphere classification work (May 2026).
//
//  Per-sphere counters for accept / override / dismiss decisions on the
//  classifier's proposals. Backs the "What SAM Has Learned → Sphere
//  classifier" block in Settings, where the user sees:
//    • Which spheres the classifier nails (high accept rate).
//    • Which spheres it confuses (high override-out rate).
//    • Which spheres get ignored entirely (high dismiss rate).
//
//  Storage is UserDefaults-only — these counters are local, cheap, and
//  meaningless across reinstalls. No need for a SwiftData model.
//
//  Counters live in a single `[String: [String: Int]]` dictionary keyed
//  by sphereUUID-string → action-string ("accept" | "override" | "dismiss")
//  → count. Atomic enough; UserDefaults writes are batched by the system.
//

import Foundation

@MainActor
final class SphereClassifierTelemetry {

    static let shared = SphereClassifierTelemetry()

    private static let defaultsKey = "samSphereClassifierTelemetry.v1"
    private enum Action: String { case accept, override, dismiss }

    private init() {}

    // MARK: - Read

    /// Counters for one sphere. Zeros when nothing recorded yet.
    func counters(forSphere sphereID: UUID) -> SphereLearningCounters {
        let all = loadAll()
        let bucket = all[sphereID.uuidString] ?? [:]
        return SphereLearningCounters(
            sphereID: sphereID,
            accept: bucket[Action.accept.rawValue] ?? 0,
            override: bucket[Action.override.rawValue] ?? 0,
            dismiss: bucket[Action.dismiss.rawValue] ?? 0
        )
    }

    /// All recorded counters across every sphere — the data the Settings
    /// view walks. Spheres with zero counters are simply absent.
    func allCounters() -> [SphereLearningCounters] {
        loadAll().compactMap { (key, bucket) -> SphereLearningCounters? in
            guard let id = UUID(uuidString: key) else { return nil }
            return SphereLearningCounters(
                sphereID: id,
                accept: bucket[Action.accept.rawValue] ?? 0,
                override: bucket[Action.override.rawValue] ?? 0,
                dismiss: bucket[Action.dismiss.rawValue] ?? 0
            )
        }
    }

    // MARK: - Write

    func recordAccept(sphereID: UUID) { increment(sphereID: sphereID, action: .accept) }
    func recordOverride(sphereID: UUID) { increment(sphereID: sphereID, action: .override) }
    func recordDismiss(sphereID: UUID) { increment(sphereID: sphereID, action: .dismiss) }

    /// Reset all counters for a specific sphere. Used by the per-row
    /// "Reset" affordance in Settings.
    func reset(sphereID: UUID) {
        var all = loadAll()
        all[sphereID.uuidString] = nil
        UserDefaults.standard.set(all, forKey: Self.defaultsKey)
    }

    /// Reset every sphere's counters. Used by the "Reset all classifier
    /// learning" button.
    func resetAll() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: - Private

    private func increment(sphereID: UUID, action: Action) {
        var all = loadAll()
        var bucket = all[sphereID.uuidString] ?? [:]
        bucket[action.rawValue, default: 0] += 1
        all[sphereID.uuidString] = bucket
        UserDefaults.standard.set(all, forKey: Self.defaultsKey)
    }

    private func loadAll() -> [String: [String: Int]] {
        (UserDefaults.standard.object(forKey: Self.defaultsKey) as? [String: [String: Int]]) ?? [:]
    }
}

// MARK: - DTO

public struct SphereLearningCounters: Sendable {
    public let sphereID: UUID
    public let accept: Int
    public let override: Int
    public let dismiss: Int

    public var total: Int { accept + override + dismiss }

    /// Share of decisions where the user agreed with the classifier's pick.
    /// Returns nil when no decisions have been recorded yet (rendering
    /// callers can show an em-dash rather than a misleading 0%).
    public var acceptRate: Double? {
        guard total > 0 else { return nil }
        return Double(accept) / Double(total)
    }

    /// Share of decisions where the user picked a different sphere — the
    /// strongest "the classifier was wrong" signal.
    public var overrideRate: Double? {
        guard total > 0 else { return nil }
        return Double(`override`) / Double(total)
    }
}
