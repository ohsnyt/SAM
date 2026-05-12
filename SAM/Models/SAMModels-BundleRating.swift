//
//  SAMModels-BundleRating.swift
//  SAM
//
//  Weekly user rating of an OutcomeBundle's coaching quality. Captured once
//  per (week, bundle) so the user grades the suggestions SAM made for each
//  person over the past 7 days. Feeds CalibrationService strategic weights.
//

import SwiftData
import Foundation

@Model
public final class WeeklyBundleRating {
    @Attribute(.unique) public var id: UUID

    /// Bundle this rating applies to. Nullify so closing a bundle doesn't
    /// destroy historical signal.
    @Relationship(deleteRule: .nullify)
    public var bundle: OutcomeBundle?

    /// Cached personID — keeps the rating queryable after the bundle is gone.
    public var personID: UUID

    /// Monday-of-week the rating covers (start of ISO week).
    public var weekStartDate: Date

    /// 1–5 stars. 0 means "skipped — not rated yet".
    public var stars: Int

    /// Optional free-text note ("too pushy", "perfect timing", etc.).
    public var comment: String?

    /// Sub-item kinds that were open during this week (newline-joined
    /// rawValues). Used to attribute the rating across kinds.
    public var kindsSeenRaw: String

    public var createdAt: Date

    public init(
        bundle: OutcomeBundle?,
        personID: UUID,
        weekStartDate: Date,
        stars: Int,
        comment: String? = nil,
        kindsSeenRaw: String = ""
    ) {
        self.id = UUID()
        self.bundle = bundle
        self.personID = personID
        self.weekStartDate = weekStartDate
        self.stars = max(0, min(5, stars))
        self.comment = comment
        self.kindsSeenRaw = kindsSeenRaw
        self.createdAt = .now
    }

    @Transient
    public var kindsSeen: [OutcomeSubItemKind] {
        kindsSeenRaw
            .split(separator: "\n")
            .compactMap { OutcomeSubItemKind(rawValue: String($0)) }
    }
}
