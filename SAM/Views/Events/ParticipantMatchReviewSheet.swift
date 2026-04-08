//
//  ParticipantMatchReviewSheet.swift
//  SAM
//
//  Created on April 7, 2026.
//  Review sheet for unmatched chat participants after import.
//  Allows the user to match, create, or skip each unmatched name.
//

import SwiftUI
import SwiftData

struct ParticipantMatchReviewSheet: View {

    let event: SamEvent
    @Binding var pendingReviews: [ChatParticipantAnalysis]

    @State private var searchText = ""
    @Query(sort: \SamPerson.displayNameCache) private var allPeople: [SamPerson]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Match Participants")
                        .samFont(.title2, weight: .semibold)
                    Text("\(pendingReviews.count) unmatched participant\(pendingReviews.count == 1 ? "" : "s")")
                        .samFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            if pendingReviews.isEmpty {
                ContentUnavailableView(
                    "All Matched",
                    systemImage: "checkmark.circle",
                    description: Text("Every participant has been matched or skipped.")
                )
            } else {
                List {
                    ForEach(pendingReviews) { analysis in
                        reviewRow(analysis: analysis)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 500, height: 450)
    }

    // MARK: - Review Row

    private func reviewRow(analysis: ChatParticipantAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.questionmark")
                    .foregroundStyle(.orange)
                Text(analysis.displayName)
                    .samFont(.headline)
                Spacer()
                Text("\(analysis.messageCount) msg, \(analysis.reactionCount) reactions")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            // Questions they asked (context for matching)
            if !analysis.questionsAsked.isEmpty {
                Text("Asked: \(analysis.questionsAsked.first ?? "")")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                // Search existing contacts
                Menu {
                    let filtered = filteredPeople(for: analysis.displayName)
                    if filtered.isEmpty {
                        Text("No matches found")
                    } else {
                        ForEach(filtered.prefix(10), id: \.id) { person in
                            Button {
                                PostEventEvaluationCoordinator.shared.resolveParticipant(
                                    analysisID: analysis.id,
                                    matchedPersonID: person.id
                                )
                            } label: {
                                Text(person.displayNameCache ?? "Unknown")
                            }
                        }
                    }
                } label: {
                    Label("Match to Contact", systemImage: "person.crop.circle.badge.checkmark")
                        .samFont(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    PostEventEvaluationCoordinator.shared.resolveParticipant(
                        analysisID: analysis.id,
                        matchedPersonID: nil,
                        createNew: true
                    )
                } label: {
                    Label("Create New", systemImage: "person.badge.plus")
                        .samFont(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    PostEventEvaluationCoordinator.shared.resolveParticipant(
                        analysisID: analysis.id,
                        matchedPersonID: nil
                    )
                } label: {
                    Text("Skip")
                        .samFont(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func filteredPeople(for name: String) -> [SamPerson] {
        let parts = name.lowercased().split(separator: " ")
        guard let firstName = parts.first else { return [] }

        return allPeople.filter { person in
            guard let display = person.displayNameCache?.lowercased() else { return false }
            return display.contains(String(firstName))
        }
    }
}
