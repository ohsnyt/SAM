//
//  SAMModels-SphereLens.swift
//  SAM
//
//  Phase C of the multi-sphere classification work (May 2026).
//
//  Pure helpers for filtering evidence by a "sphere lens" — i.e., showing
//  only the interactions that belong to a specific sphere of the person's
//  life. Used by per-sphere relationship health, the lens picker, the
//  classification review batch, and any future consumer that needs a
//  sphere-scoped view of a person's history.
//
//  Filter rules (the "default fallback" semantics):
//    • `lens == nil`  → no lens active, evidence always matches.
//    • Evidence with explicit `contextSphere` → must equal lens.
//    • Evidence with nil `contextSphere`     → falls back to the person's
//      **default sphere** (lowest-order non-archived membership). This is
//      how single-sphere people work for free: every piece of evidence
//      implicitly belongs to their one sphere, no classifier needed.
//
//  The pure helpers take `defaultSphereID` as an explicit argument so hot
//  paths (computeHealth, briefing builders) can resolve the default sphere
//  once per person instead of round-tripping the repository per evidence
//  row.
//

import Foundation

public extension SamEvidenceItem {
    /// True if this evidence row belongs to the given sphere lens.
    ///
    /// - Parameters:
    ///   - lens: The sphere to filter against. `nil` disables filtering.
    ///   - defaultSphereID: ID of the person's default sphere (lowest-order
    ///     non-archived membership). Used as the fallback when this
    ///     evidence has no explicit `contextSphere`. Pass `nil` if the
    ///     person has no active memberships — in that case nil-context
    ///     evidence never matches a specific lens.
    func matches(lens: Sphere?, defaultSphereID: UUID?) -> Bool {
        guard let lens else { return true }
        if let evidenceSphereID = contextSphere?.id {
            return evidenceSphereID == lens.id
        }
        return defaultSphereID == lens.id
    }
}

/// Stateless utilities for evidence-by-sphere queries. Lives outside
/// SphereRepository so non-`@MainActor` callers (background classifier,
/// future actors) can reach it without touching the repo singleton.
public enum SphereLens {

    /// Filter a pre-fetched evidence collection by sphere lens. The caller
    /// is responsible for supplying the person's `defaultSphereID` — this
    /// keeps the helper pure and avoids repo lookups inside tight loops.
    ///
    /// When `lens` is nil, returns `evidence` unchanged.
    public static func filter(
        _ evidence: [SamEvidenceItem],
        lens: Sphere?,
        defaultSphereID: UUID?
    ) -> [SamEvidenceItem] {
        guard lens != nil else { return evidence }
        return evidence.filter { $0.matches(lens: lens, defaultSphereID: defaultSphereID) }
    }
}
