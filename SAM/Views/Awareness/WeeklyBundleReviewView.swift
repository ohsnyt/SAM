//
//  WeeklyBundleReviewView.swift
//  SAM
//
//  P9: Weekly rating loop. Lists every active and recently-closed
//  OutcomeBundle from the past 7 days and lets the user rate each one
//  1–5 stars. Ratings feed CalibrationService so future bundle priority
//  reflects which suggestions Sarah actually found useful.
//

import SwiftUI
import SwiftData

struct WeeklyBundleReviewView: View {

    @Query(sort: \OutcomeBundle.priorityScore, order: .reverse)
    private var allBundles: [OutcomeBundle]

    @Query(sort: \WeeklyBundleRating.createdAt, order: .reverse)
    private var allRatings: [WeeklyBundleRating]

    private var weekStart: Date {
        WeeklyBundleRatingRepository.weekStart(for: .now)
    }

    /// Active or closed this week, sorted by priority. Closed-this-week ones
    /// appear with their priority frozen at close time.
    private var ratableBundles: [OutcomeBundle] {
        allBundles.filter { bundle in
            if bundle.closedAt == nil { return true }
            if let closedAt = bundle.closedAt, closedAt >= weekStart { return true }
            return false
        }
    }

    private func existingRating(for bundle: OutcomeBundle) -> WeeklyBundleRating? {
        allRatings.first { $0.bundle?.id == bundle.id && $0.weekStartDate == weekStart }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Weekly bundle review")
                    .samFont(.title3)
                    .fontWeight(.bold)
                Spacer()
                Text(weekStart.formatted(date: .abbreviated, time: .omitted))
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            if ratableBundles.isEmpty {
                Text("No bundles to review this week.")
                    .samFont(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ratableBundles, id: \.id) { bundle in
                    BundleRatingRow(
                        bundle: bundle,
                        existing: existingRating(for: bundle),
                        weekStart: weekStart
                    )
                }
            }
        }
        .padding(16)
    }
}

private struct BundleRatingRow: View {
    let bundle: OutcomeBundle
    let existing: WeeklyBundleRating?
    let weekStart: Date

    @State private var stars: Int = 0
    @State private var comment: String = ""

    private var personName: String {
        bundle.person?.displayNameCache ?? bundle.person?.displayName ?? "Unknown"
    }

    private var seenKinds: [OutcomeSubItemKind] {
        Array(Set(bundle.subItems.map(\.kind)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(personName)
                    .samFont(.headline)
                Spacer()
                if bundle.closedAt != nil {
                    Label("closed", systemImage: "checkmark.seal")
                        .samFont(.caption)
                        .foregroundStyle(.green)
                }
            }

            if !seenKinds.isEmpty {
                Text(seenKinds.map(\.displayLabel).joined(separator: " • "))
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= stars ? "star.fill" : "star")
                        .samFont(.title3)
                        .foregroundStyle(star <= stars ? .yellow : .gray)
                        .onTapGesture {
                            stars = star
                            submit()
                        }
                }
                Spacer()
                Button("Skip") {
                    stars = 0
                    submit()
                }
                .buttonStyle(.borderless)
                .samFont(.caption)
            }

            TextField("Optional comment", text: $comment, onCommit: submit)
                .textFieldStyle(.roundedBorder)
                .samFont(.caption)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.secondary)
        )
        .onAppear {
            if let existing {
                stars = existing.stars
                comment = existing.comment ?? ""
            }
        }
    }

    private func submit() {
        do {
            let rating = try WeeklyBundleRatingRepository.shared.upsert(
                bundleID: bundle.id,
                weekStart: weekStart,
                stars: stars,
                comment: comment.isEmpty ? nil : comment,
                kindsSeen: seenKinds
            )
            Task {
                await WeeklyBundleRatingRepository.shared.feedCalibration(rating: rating)
            }
        } catch {
            // Silent — the user can re-tap.
        }
    }
}
