//
//  HealthLevelShadowReportService.swift
//  SAM
//
//  Phase 3f of the relationship-model refactor (May 2026).
//
//  Compares the legacy decayRisk-only HealthLevel derivation against the
//  Phase 3e vector-aware derivation across every non-archived person.
//  Run from Settings → Diagnostics before flipping the
//  `sam.feature.healthLevelVector` flag on for real.
//
//  The report counts agreements and surfaces every divergence so the user
//  can spot-check whether the new math makes sense for her contacts (per
//  `relationship-model/relationship_model_implementation_plan.md` §3 Sarah-regression check).
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "HealthLevelShadowReport")

// MARK: - Report shape

struct HealthLevelShadowReport: Sendable {

    /// One row per person whose legacy and vector HealthLevels disagree.
    struct Divergence: Sendable, Identifiable {
        let id: UUID
        let personName: String
        let mode: Mode
        let legacy: GraphNode.HealthLevel
        let vector: GraphNode.HealthLevel
        let dominantSignal: HealthSignal
        let decayRisk: DecayRisk
        let driftRatio: Double?
        let initiationRatio: Double?
        let pnRatio: Double?
    }

    let generatedAt: Date
    let totalPeople: Int
    let agreementCount: Int
    let divergenceCount: Int
    /// Bucketed count of vector-side HealthLevel for every divergence —
    /// quick read on "is the new engine running hotter or cooler?"
    let vectorBucketCounts: [GraphNode.HealthLevel: Int]
    let divergences: [Divergence]

    var agreementPercent: Double {
        guard totalPeople > 0 else { return 0 }
        return Double(agreementCount) / Double(totalPeople) * 100.0
    }
}

// MARK: - Service

@MainActor
enum HealthLevelShadowReportService {

    /// Build a fresh report. Cheap-ish — one computeHealth per non-archived
    /// person, then two dict lookups per person. ~200ms for 50 people on
    /// Sarah's machine; runs on the main actor with periodic yields so the
    /// UI stays responsive on larger lists.
    static func runReport() async throws -> HealthLevelShadowReport {
        let people = try PeopleRepository.shared.fetchAll()
            .filter { !$0.isArchived && !$0.isMe }

        let graph = RelationshipGraphCoordinator.shared
        let prep  = MeetingPrepCoordinator.shared

        var divergences: [HealthLevelShadowReport.Divergence] = []
        var agreementCount = 0
        var vectorBuckets: [GraphNode.HealthLevel: Int] = [:]

        for (idx, person) in people.enumerated() {
            let health = prep.computeHealth(for: person)
            let mode = PersonModeResolver.effectiveMode(for: person.id)

            let legacy = graph.legacyHealthLevelForShadow(health)
            let vector = graph.vectorHealthLevelForShadow(health, mode: mode)

            if legacy == vector {
                agreementCount += 1
            } else {
                vectorBuckets[vector, default: 0] += 1
                divergences.append(HealthLevelShadowReport.Divergence(
                    id: person.id,
                    personName: person.displayNameCache ?? person.displayName,
                    mode: mode,
                    legacy: legacy,
                    vector: vector,
                    dominantSignal: health.dominantSignal,
                    decayRisk: health.decayRisk,
                    driftRatio: health.driftRatio,
                    initiationRatio: health.initiationRatio,
                    pnRatio: health.pnRatio
                ))
            }

            if (idx + 1) % 20 == 0 { await Task.yield() }
        }

        let report = HealthLevelShadowReport(
            generatedAt: .now,
            totalPeople: people.count,
            agreementCount: agreementCount,
            divergenceCount: divergences.count,
            vectorBucketCounts: vectorBuckets,
            divergences: divergences.sorted { lhs, rhs in
                // Cold/atRisk first so the user reads the most-significant
                // disagreements at the top of the list.
                if lhs.vector != rhs.vector {
                    return vectorSeverity(lhs.vector) > vectorSeverity(rhs.vector)
                }
                return lhs.personName < rhs.personName
            }
        )

        logger.notice(
            "Shadow report: \(report.agreementCount)/\(report.totalPeople) agree (\(String(format: "%.1f", report.agreementPercent))%), \(report.divergenceCount) divergences"
        )
        return report
    }

    /// Severity ordering used to sort the divergence list.
    private static func vectorSeverity(_ level: GraphNode.HealthLevel) -> Int {
        switch level {
        case .cold:    return 4
        case .atRisk:  return 3
        case .cooling: return 2
        case .healthy: return 1
        case .unknown: return 0
        }
    }
}
