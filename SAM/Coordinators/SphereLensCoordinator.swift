//
//  SphereLensCoordinator.swift
//  SAM
//
//  Phase C6 of the multi-sphere classification work (May 2026).
//
//  App-wide observable state for the "sphere lens" — the currently-active
//  filter that scopes relationship health, briefings, and lists to one
//  sphere of the user's life.
//
//  Two states the coordinator owns:
//    • `currentLens` — the Sphere the user has selected, or `nil` for
//      "all spheres" (the unfiltered default).
//    • `isPickerAvailable` — true once at least one person has 2+ active
//      sphere memberships. We hide the picker entirely until then so
//      single-sphere users (the majority) never see UI they don't need.
//
//  Persistence: the picker selection is stored in UserDefaults so it
//  survives launches. Picker availability is recomputed on launch and
//  whenever a `samPersonDidChange` / `samSphereDidChange` notification
//  fires — both are already used by membership-mutating call sites.
//

import Foundation
import SwiftData
import os.log

@MainActor
@Observable
final class SphereLensCoordinator {

    static let shared = SphereLensCoordinator()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SphereLensCoordinator")

    // MARK: - Published state

    /// The currently active lens. `nil` = "all spheres" (unfiltered).
    private(set) var currentLens: Sphere?

    /// True once at least one person has ≥2 active sphere memberships.
    /// Views check this to decide whether to render the picker at all.
    private(set) var isPickerAvailable: Bool = false

    // MARK: - Persistence

    private static let storageKey = "sam.sphereLens.currentSphereID.v1"

    // MARK: - Init

    private init() {
        observeChanges()
    }

    // MARK: - Public API

    /// Re-evaluate `isPickerAvailable` and restore the persisted lens.
    /// Call once from app launch after SAMModelContainer is configured.
    func refresh() {
        recomputeAvailability()
        restoreSelectionIfNeeded()
    }

    /// Set the active lens (`nil` = clear). Persists across launches.
    func setLens(_ sphere: Sphere?) {
        currentLens = sphere
        UserDefaults.standard.set(sphere?.id.uuidString, forKey: Self.storageKey)
        logger.debug("Lens set to \(sphere?.name ?? "All spheres", privacy: .public)")
    }

    /// Convenience: cycle through all+spheres, used by ⌘L / sidebar tap.
    func clearLens() { setLens(nil) }

    // MARK: - Availability

    private func recomputeAvailability() {
        let context = SAMModelContainer.shared.mainContext
        let descriptor = FetchDescriptor<PersonSphereMembership>()
        guard let all = try? context.fetch(descriptor) else {
            isPickerAvailable = false
            return
        }
        // Count active memberships per person; gate on any person ≥2.
        var perPerson: [UUID: Int] = [:]
        for m in all {
            guard let pid = m.person?.id, m.sphere?.archived == false else { continue }
            perPerson[pid, default: 0] += 1
        }
        let nowAvailable = perPerson.values.contains { $0 >= 2 }
        if nowAvailable != isPickerAvailable {
            isPickerAvailable = nowAvailable
            logger.debug("Lens picker availability → \(nowAvailable)")
        }
        // If the picker just went away and a lens was selected, clear it
        // so health math stops surprising the user with stale filters.
        if !nowAvailable && currentLens != nil {
            setLens(nil)
        }
    }

    private func restoreSelectionIfNeeded() {
        guard isPickerAvailable else {
            currentLens = nil
            return
        }
        guard let raw = UserDefaults.standard.string(forKey: Self.storageKey),
              let id = UUID(uuidString: raw) else {
            currentLens = nil
            return
        }
        currentLens = try? SphereRepository.shared.fetch(id: id)
        // If the saved sphere was archived/deleted, fall back to "All".
        if currentLens?.archived == true { currentLens = nil }
    }

    // MARK: - Change observers

    private func observeChanges() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: .samPersonDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recomputeAvailability() }
        }
        center.addObserver(
            forName: .samSphereDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recomputeAvailability()
                self?.restoreSelectionIfNeeded()
            }
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted whenever a Sphere is created, renamed, archived, or has its
    /// membership set changed. Used by the lens coordinator and the
    /// classification coordinator to invalidate caches.
    static let samSphereDidChange = Notification.Name("samSphereDidChange")
}
