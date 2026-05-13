//
//  MembershipOrderBackfillCoordinator.swift
//  SAM
//
//  Phase A5 of the multi-sphere classification work (May 2026).
//
//  PersonSphereMembership gained an `order` field so the lowest-order
//  membership becomes a person's default sphere. Memberships created
//  before this field existed all carry the model default (1_000), which
//  loses determinism for users who already have multi-sphere people.
//  This migration rewrites `order` per person to a 0-based index sorted
//  by `addedAt`, so the **oldest** membership wins the default slot.
//
//  Rationale: the user's typical pattern is to add the "primary" sphere
//  first (Work / Family) and tack on a secondary later (the same person
//  also turns up at church). Ordering by addedAt mirrors that intent
//  without making the user reorder anything by hand. Users who disagree
//  drag-to-reorder in the Spheres panel after the migration runs.
//
//  Idempotent: gated by UserDefaults; reruns are safe because the
//  rewrite is deterministic and no-ops on a person with one membership.
//

import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MembershipOrderBackfill")

@MainActor
enum MembershipOrderBackfillCoordinator {

    private static let migrationDoneKey = "sam.migration.membershipOrderBackfillDone"

    static func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: migrationDoneKey) else { return }

        do {
            let context = ModelContext(SAMModelContainer.shared)
            let all = try context.fetch(FetchDescriptor<PersonSphereMembership>())
            let grouped = Dictionary(grouping: all) { $0.person?.id ?? UUID() }

            var rewritten = 0
            for (_, memberships) in grouped {
                let sorted = memberships.sorted { $0.addedAt < $1.addedAt }
                for (idx, membership) in sorted.enumerated() {
                    if membership.order != idx {
                        membership.order = idx
                        rewritten += 1
                    }
                }
            }
            try context.save()

            UserDefaults.standard.set(true, forKey: migrationDoneKey)
            logger.notice("Membership order backfill complete — rewrote \(rewritten) of \(all.count) memberships across \(grouped.count) people")
        } catch {
            logger.error("Membership order backfill failed: \(error.localizedDescription)")
            // Do NOT set the done flag — retry next launch.
        }
    }
}
