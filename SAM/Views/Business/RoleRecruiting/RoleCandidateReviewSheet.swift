//
//  RoleCandidateReviewSheet.swift
//  SAM
//
//  Created on March 17, 2026.
//  Role Recruiting: Review AI-scored candidates with approve/pass actions.
//

import SwiftUI

struct RoleCandidateReviewSheet: View {

    let results: [RoleCandidateScoringResult]
    let roleID: UUID
    let roleName: String
    @State var coordinator: RoleRecruitingCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var passReasons: [UUID: String] = [:]
    @State private var showingPassField: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Candidate Suggestions for \(roleName)")
                    .samFont(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if results.isEmpty {
                ContentUnavailableView("No Matches", systemImage: "person.badge.key",
                    description: Text("SAM didn't find any strong matches. Try refining your criteria."))
                    .padding()
            } else {
                List {
                    ForEach(results, id: \.personID) { result in
                        candidateRow(result)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 550, height: 500)
    }

    @ViewBuilder
    private func candidateRow(_ result: RoleCandidateScoringResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Score indicator
                ZStack {
                    Circle()
                        .stroke(scoreColor(result.matchScore), lineWidth: 3)
                        .frame(width: 32, height: 32)
                    Text("\(Int(result.matchScore * 100))")
                        .samFont(.caption2, weight: .bold)
                        .foregroundStyle(scoreColor(result.matchScore))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(personName(for: result.personID))
                        .samFont(.body, weight: .medium)

                    Text(result.matchRationale)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                Spacer()
            }

            // Strength signals
            if !result.strengthSignals.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .samFont(.caption)
                    Text(result.strengthSignals.prefix(2).joined(separator: " · "))
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Gap signals
            if !result.gapSignals.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .samFont(.caption)
                    Text(result.gapSignals.first ?? "")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Actions
            HStack {
                Button("Add to Pipeline") {
                    coordinator.approveCandidate(result: result, roleID: roleID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if showingPassField == result.personID {
                    TextField("Why not? (helps SAM learn)", text: Binding(
                        get: { passReasons[result.personID] ?? "" },
                        set: { passReasons[result.personID] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                    Button("Confirm") {
                        coordinator.dismissCandidate(
                            result: result,
                            roleID: roleID,
                            reason: passReasons[result.personID]
                        )
                        showingPassField = nil
                    }
                    .controlSize(.small)
                } else {
                    Button("Pass") {
                        showingPassField = result.personID
                    }
                    .controlSize(.small)
                }

                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    private func personName(for id: UUID) -> String {
        guard let people = try? PeopleRepository.shared.fetchAll() else { return "Unknown" }
        return people.first { $0.id == id }?.displayNameCache ?? people.first { $0.id == id }?.displayName ?? "Unknown"
    }

    private func scoreColor(_ score: Double) -> Color {
        score >= 0.7 ? .green : score >= 0.5 ? .orange : .gray
    }
}
