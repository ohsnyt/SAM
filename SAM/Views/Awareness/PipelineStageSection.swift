//
//  PipelineStageSection.swift
//  SAM
//
//  Created on February 24, 2026.
//
//  Pipeline visualization for the Awareness dashboard showing
//  Lead → Applicant → Client progression with "stuck" indicators.
//

import SwiftUI
import SwiftData

struct PipelineStageSection: View {

    @Query private var allPeople: [SamPerson]

    // MARK: - Computed pipeline data

    private var leads: [SamPerson] {
        allPeople.filter { $0.roleBadges.contains("Lead") && !$0.isArchived }
    }

    private var applicants: [SamPerson] {
        allPeople.filter { $0.roleBadges.contains("Applicant") && !$0.isArchived }
    }

    private var clients: [SamPerson] {
        allPeople.filter { $0.roleBadges.contains("Client") && !$0.isArchived }
    }

    private var totalCount: Int {
        leads.count + applicants.count + clients.count
    }

    private var stuckPeople: [StuckPerson] {
        let now = Date.now
        var result: [StuckPerson] = []

        let leadThreshold: TimeInterval = 30 * 24 * 60 * 60
        for person in leads {
            let lastEvidence = person.linkedEvidence
                .map(\.occurredAt)
                .max()
            if let last = lastEvidence {
                let gap = now.timeIntervalSince(last)
                if gap >= leadThreshold {
                    result.append(StuckPerson(
                        person: person,
                        stage: "Lead",
                        daysStuck: Int(gap / (24 * 60 * 60))
                    ))
                }
            } else {
                // No evidence at all — consider stuck from sync date or creation
                if let synced = person.lastSyncedAt {
                    let gap = now.timeIntervalSince(synced)
                    if gap >= leadThreshold {
                        result.append(StuckPerson(
                            person: person,
                            stage: "Lead",
                            daysStuck: Int(gap / (24 * 60 * 60))
                        ))
                    }
                }
            }
        }

        let applicantThreshold: TimeInterval = 14 * 24 * 60 * 60
        for person in applicants {
            let lastEvidence = person.linkedEvidence
                .map(\.occurredAt)
                .max()
            if let last = lastEvidence {
                let gap = now.timeIntervalSince(last)
                if gap >= applicantThreshold {
                    result.append(StuckPerson(
                        person: person,
                        stage: "Applicant",
                        daysStuck: Int(gap / (24 * 60 * 60))
                    ))
                }
            } else {
                if let synced = person.lastSyncedAt {
                    let gap = now.timeIntervalSince(synced)
                    if gap >= applicantThreshold {
                        result.append(StuckPerson(
                            person: person,
                            stage: "Applicant",
                            daysStuck: Int(gap / (24 * 60 * 60))
                        ))
                    }
                }
            }
        }

        return result.sorted { $0.daysStuck > $1.daysStuck }
    }

    // MARK: - Body

    var body: some View {
        if totalCount > 0 {
            VStack(spacing: 0) {
                // Section header
                HStack {
                    Image(systemName: "chart.bar.horizontal.page")
                        .foregroundStyle(.blue)
                    Text("Pipeline")
                        .font(.headline)
                    Text("\(totalCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue)
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                VStack(spacing: 12) {
                    // Stage cards row
                    stageCardsRow

                    // Stuck people
                    if !stuckPeople.isEmpty {
                        stuckSection
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    // MARK: - Stage Cards

    private var stageCardsRow: some View {
        HStack(spacing: 0) {
            StageCard(
                stage: "Lead",
                count: leads.count,
                color: RoleBadgeStyle.forBadge("Lead").color
            )

            arrowSeparator

            StageCard(
                stage: "Applicant",
                count: applicants.count,
                color: RoleBadgeStyle.forBadge("Applicant").color
            )

            arrowSeparator

            StageCard(
                stage: "Client",
                count: clients.count,
                color: RoleBadgeStyle.forBadge("Client").color
            )
        }
    }

    private var arrowSeparator: some View {
        Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
    }

    // MARK: - Stuck Section

    private var stuckSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Needs Attention")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }

            ForEach(stuckPeople) { item in
                Button(action: {
                    NotificationCenter.default.post(
                        name: .samNavigateToPerson,
                        object: nil,
                        userInfo: ["personID": item.person.id]
                    )
                }) {
                    HStack(spacing: 8) {
                        let style = RoleBadgeStyle.forBadge(item.stage)
                        Image(systemName: style.icon)
                            .font(.caption)
                            .foregroundStyle(style.color)

                        Text(item.person.displayNameCache ?? item.person.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer()

                        Text("stuck for \(item.daysStuck) days")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Stage Card

private struct StageCard: View {

    let stage: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(stage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Stuck Person

private struct StuckPerson: Identifiable {
    let person: SamPerson
    let stage: String
    let daysStuck: Int

    var id: UUID { person.id }
}
