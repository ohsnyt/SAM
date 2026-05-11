//
//  PersonModeResolver.swift
//  SAM
//
//  Phase 2-3 of the relationship-model refactor (May 2026).
//
//  Resolves per-person context derived from the Sphere/Trajectory data
//  model: effective Mode (Phase 2) and trajectory-derived cadence (Phase 3).
//  Single resolver because both signals come from the same active-entry /
//  membership data; one cache rebuild populates both.
//
//  Mode resolution order:
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
//  Trajectory cadence resolution (Phase 3) — returns nil unless the user
//  has *explicitly* configured a cadence somewhere. Abstract Mode defaults
//  are NOT included so the bootstrap-created Funnel doesn't silently shrink
//  every Sarah-client's cadence from "personal baseline" to "14 days":
//    1. PersonTrajectoryEntry.cadenceDaysOverride (per-person on Trajectory)
//    2. TrajectoryStage.stageCadenceDaysOverride (per-stage)
//    3. Sphere.defaultCadenceDays when non-nil (per-Sphere user override)
//    4. nil — fall through to person.preferredCadenceDays / personal baseline.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PersonModeResolver")

@MainActor
enum PersonModeResolver {

    // MARK: - Session cache

    /// Mode keyed by personID. Lazily rebuilt from the repositories on first
    /// access (or after invalidation) using two bulk fetches instead of two
    /// per-person fetches — `computeHealth` runs once per person in briefings,
    /// OutcomeEngine, PersonDetailView, etc., so the unbatched cost is O(N²).
    private static var cache: [UUID: Mode] = [:]
    private static var cadenceCache: [UUID: Int] = [:]
    private static var cacheBuilt = false

    /// Drop the caches. Call after any mutation to Sphere / PersonSphereMembership /
    /// Trajectory / PersonTrajectoryEntry. The bootstrap calls this once it has
    /// finished seeding so the first real read sees populated state. Cheap —
    /// the next read rebuilds in two main-actor fetches.
    static func invalidateCache() {
        cache.removeAll(keepingCapacity: true)
        cadenceCache.removeAll(keepingCapacity: true)
        cacheBuilt = false
    }

    // MARK: - Resolution

    /// Resolve the effective Mode for a person. See file header for resolution order.
    /// Returns `.stewardship` as a safe default if any lookup throws or the person
    /// belongs to nothing — the caller treats this as "no special handling".
    static func effectiveMode(for personID: UUID) -> Mode {
        if !cacheBuilt { rebuildCache() }
        return cache[personID] ?? .stewardship
    }

    /// Convenience for the common case: "should cadence-decay alerts fire for this person?"
    static func generatesCadenceAlerts(for personID: UUID) -> Bool {
        effectiveMode(for: personID).generatesCadenceAlerts
    }

    /// Trajectory-derived cadence for the person, in days. Returns nil unless
    /// the user has *explicitly* configured one via an entry override, stage
    /// override, or Sphere defaultCadenceDays. See file header for resolution
    /// order. Abstract Mode defaults are deliberately excluded — they would
    /// regress Sarah's clients off their personal baseline rhythms.
    static func trajectoryCadenceDays(for personID: UUID) -> Int? {
        if !cacheBuilt { rebuildCache() }
        return cadenceCache[personID]
    }

    // MARK: - Cache build

    private static func rebuildCache() {
        cacheBuilt = true
        cache.removeAll(keepingCapacity: true)
        cadenceCache.removeAll(keepingCapacity: true)

        // 1. Active Trajectory entries: most-restrictive Mode wins per person.
        //    Cadence: most-specific (entry override > stage override) wins; if
        //    multiple entries override cadence, tightest cadence wins.
        if let entries = try? PersonTrajectoryRepository.shared.fetchAllActive() {
            for entry in entries {
                guard let pid = entry.person?.id,
                      let mode = entry.trajectory?.mode else { continue }
                if let existing = cache[pid] {
                    cache[pid] = moreRestrictive(existing, mode)
                } else {
                    cache[pid] = mode
                }
                let candidate = entry.cadenceDaysOverride
                    ?? entry.currentStage?.stageCadenceDaysOverride
                if let candidate, candidate > 0 {
                    if let existingCadence = cadenceCache[pid] {
                        cadenceCache[pid] = min(existingCadence, candidate)
                    } else {
                        cadenceCache[pid] = candidate
                    }
                }
            }
        }

        // 2. Sphere default fallback for persons with no active Trajectory entry.
        //    Cadence: Sphere.defaultCadenceDays applies only when explicitly set
        //    by the user (non-nil) — abstract Mode defaults intentionally skipped.
        if let memberships = try? SphereRepository.shared.fetchAllMemberships() {
            var primarySphereByPerson: [UUID: Sphere] = [:]
            for membership in memberships {
                guard let pid = membership.person?.id,
                      let sphere = membership.sphere,
                      !sphere.archived else { continue }
                if let current = primarySphereByPerson[pid] {
                    if sphere.sortOrder < current.sortOrder {
                        primarySphereByPerson[pid] = sphere
                    }
                } else {
                    primarySphereByPerson[pid] = sphere
                }
            }
            for (pid, sphere) in primarySphereByPerson where cache[pid] == nil {
                cache[pid] = sphere.defaultMode
            }
            for (pid, sphere) in primarySphereByPerson where cadenceCache[pid] == nil {
                if let explicit = sphere.defaultCadenceDays, explicit > 0 {
                    cadenceCache[pid] = explicit
                }
            }
        }
    }

    // MARK: - Mode restrictiveness

    /// Order in which Modes override each other when a person is on multiple
    /// Trajectories. Lower index = higher priority. Covenant first because the
    /// silence rule is the strongest user signal.
    private static let restrictivenessOrder: [Mode] = [
        .covenant, .service, .stewardship, .campaign, .funnel
    ]

    private static func moreRestrictive(_ a: Mode, _ b: Mode) -> Mode {
        let ai = restrictivenessOrder.firstIndex(of: a) ?? Int.max
        let bi = restrictivenessOrder.firstIndex(of: b) ?? Int.max
        return ai <= bi ? a : b
    }
}
