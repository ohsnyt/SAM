//
//  EngagementVelocitySection.swift
//  SAM
//
//  Created on February 24, 2026.
//  Engagement Velocity — surfaces people overdue based on their personal contact rhythm.
//

import SwiftUI
import SwiftData

struct EngagementVelocitySection: View {

    @Query(filter: #Predicate<SamPerson> { !$0.isMe && !$0.isArchived })
    private var people: [SamPerson]

    private var overduePeople: [OverdueEntry] {
        var entries: [OverdueEntry] = []

        for person in people {
            guard let entry = computeOverdue(for: person) else { continue }
            entries.append(entry)
        }

        return entries
            .sorted { $0.overdueRatio > $1.overdueRatio }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        let overdue = overduePeople
        if !overdue.isEmpty {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .foregroundStyle(.orange)
                    Text("Engagement Velocity")
                        .font(.headline)
                    Text("\(overdue.count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange)
                        .clipShape(Capsule())
                    Spacer()
                    Text("Based on contact rhythm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                VStack(spacing: 8) {
                    ForEach(overdue) { entry in
                        OverduePersonRow(entry: entry)
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Computation

    private func computeOverdue(for person: SamPerson) -> OverdueEntry? {
        let evidence = person.linkedEvidence
        guard evidence.count >= 3 else { return nil }

        let sorted = evidence.sorted { $0.occurredAt < $1.occurredAt }

        // Compute gaps between consecutive evidence items
        var gaps: [TimeInterval] = []
        for i in 1..<sorted.count {
            let gap = sorted[i].occurredAt.timeIntervalSince(sorted[i - 1].occurredAt)
            gaps.append(gap)
        }

        guard !gaps.isEmpty else { return nil }

        // Median gap
        let sortedGaps = gaps.sorted()
        let medianGap: TimeInterval
        let mid = sortedGaps.count / 2
        if sortedGaps.count.isMultiple(of: 2) {
            medianGap = (sortedGaps[mid - 1] + sortedGaps[mid]) / 2.0
        } else {
            medianGap = sortedGaps[mid]
        }

        // Cadence in days
        let cadenceDays = medianGap / 86400.0
        guard cadenceDays >= 1 else { return nil } // Ignore sub-day cadences

        // Current gap
        guard let mostRecent = sorted.last else { return nil }
        let currentGapSeconds = Date.now.timeIntervalSince(mostRecent.occurredAt)
        let currentGapDays = currentGapSeconds / 86400.0

        // Overdue ratio
        let ratio = currentGapDays / cadenceDays
        guard ratio >= 1.5 else { return nil }

        return OverdueEntry(
            personID: person.id,
            displayName: person.displayNameCache ?? person.displayName,
            roleBadges: person.roleBadges,
            cadenceDays: Int(round(cadenceDays)),
            currentGapDays: Int(round(currentGapDays)),
            overdueRatio: ratio
        )
    }
}

// MARK: - Data Types

private struct OverdueEntry: Identifiable {
    let personID: UUID
    let displayName: String
    let roleBadges: [String]
    let cadenceDays: Int
    let currentGapDays: Int
    let overdueRatio: Double

    var id: UUID { personID }

    var severityColor: Color {
        overdueRatio > 2.5 ? .red : .orange
    }

    var formattedRatio: String {
        let rounded = (overdueRatio * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))\u{00D7}"
        }
        return String(format: "%.1f\u{00D7}", rounded)
    }

    var cadenceLabel: String {
        if cadenceDays == 1 {
            return "~every day"
        } else if cadenceDays == 7 {
            return "~weekly"
        } else if cadenceDays >= 13 && cadenceDays <= 15 {
            return "~every 2 weeks"
        } else if cadenceDays >= 28 && cadenceDays <= 32 {
            return "~monthly"
        } else {
            return "~every \(cadenceDays) days"
        }
    }

    var gapLabel: String {
        if currentGapDays == 1 {
            return "1 day ago"
        } else if currentGapDays < 7 {
            return "\(currentGapDays) days ago"
        } else {
            let weeks = currentGapDays / 7
            let remainder = currentGapDays % 7
            if remainder == 0 {
                return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
            }
            return "\(currentGapDays) days ago"
        }
    }
}

// MARK: - Row View

private struct OverduePersonRow: View {

    let entry: OverdueEntry

    var body: some View {
        Button(action: navigateToPerson) {
            HStack(spacing: 12) {
                // Severity dot
                Circle()
                    .fill(entry.severityColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        ForEach(entry.roleBadges.prefix(2), id: \.self) { badge in
                            let style = RoleBadgeStyle.forBadge(badge)
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(style.color.opacity(0.15))
                                .foregroundStyle(style.color)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }

                    HStack(spacing: 8) {
                        Text(entry.cadenceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("·")
                            .foregroundStyle(.secondary)

                        Text(entry.gapLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Overdue ratio badge
                Text("\(entry.formattedRatio) longer than usual")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(entry.severityColor)
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func navigateToPerson() {
        NotificationCenter.default.post(
            name: .samNavigateToPerson,
            object: nil,
            userInfo: ["personID": entry.personID]
        )
    }
}
