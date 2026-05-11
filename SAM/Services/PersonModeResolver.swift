//
//  PersonModeResolver.swift
//  SAM
//
//  Phase 2 of the relationship-model refactor (May 2026).
//
//  Resolves the effective Mode for a person. No PersonModeOverride field
//  exists yet (deferred to Phase 5 per the implementation plan); the
//  resolution order is:
//
//    1. Most-restrictive Mode across all active PersonTrajectoryEntry rows
//       for the person. "Most restrictive" = Covenant wins over everything,
//       then Service, Stewardship, Campaign, Funnel. Rationale: if a person
//       is on multiple Trajectories and one of them is Covenant, the user
//       has signaled "don't nag me about this person" — that wins.
//    2. Fallback to the defaultMode of the person's first (primary) Sphere
//       membership when no active Trajectory entries exist.
//    3. .stewardship if the person has no memberships at all (defensive —
//       shouldn't happen post-bootstrap).
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PersonModeResolver")

@MainActor
enum PersonModeResolver {

    /// Resolve the effective Mode for a person. See file header for resolution order.
    /// Returns `.stewardship` as a safe default if any lookup throws or the person
    /// belongs to nothing — the caller treats this as "no special handling".
    static func effectiveMode(for personID: UUID) -> Mode {
        // 1. Active Trajectory entries — pick the most restrictive Mode.
        if let active = try? PersonTrajectoryRepository.shared.activeEntries(forPerson: personID),
           !active.isEmpty {
            let modes = active.compactMap { $0.trajectory?.mode }
            if let resolved = mostRestrictive(modes) {
                return resolved
            }
        }

        // 2. Primary Sphere defaultMode.
        if let spheres = try? SphereRepository.shared.spheres(forPerson: personID),
           let primary = spheres.first {
            return primary.defaultMode
        }

        // 3. Defensive default.
        return .stewardship
    }

    /// Convenience for the common case: "should cadence-decay alerts fire for this person?"
    static func generatesCadenceAlerts(for personID: UUID) -> Bool {
        effectiveMode(for: personID).generatesCadenceAlerts
    }

    /// Order in which Modes override each other when a person is on multiple
    /// Trajectories. Lower index = higher priority. Covenant first because the
    /// silence rule is the strongest user signal.
    private static let restrictivenessOrder: [Mode] = [
        .covenant, .service, .stewardship, .campaign, .funnel
    ]

    private static func mostRestrictive(_ modes: [Mode]) -> Mode? {
        guard !modes.isEmpty else { return nil }
        for candidate in restrictivenessOrder where modes.contains(candidate) {
            return candidate
        }
        return modes.first
    }
}
