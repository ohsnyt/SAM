//
//  RoleCandidateDetailView.swift
//  SAM
//
//  Created on March 17, 2026.
//  Role Recruiting: Inspector panel for a selected candidate.
//

import SwiftUI

struct RoleCandidateDetailView: View {

    let candidate: RoleCandidate
    @State var coordinator: RoleRecruitingCoordinator

    @State private var userNotes: String = ""
    @State private var showingPassReason = false
    @State private var passReason: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Person header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.person?.displayNameCache ?? candidate.person?.displayName ?? "Unknown")
                            .font(.title3.bold())

                        if let role = candidate.roleDefinition {
                            Text("Candidate for \(role.name)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()

                    // Score
                    ZStack {
                        Circle()
                            .stroke(scoreColor, lineWidth: 4)
                            .frame(width: 44, height: 44)
                        Text("\(Int(candidate.matchScore * 100))%")
                            .font(.caption.bold())
                    }
                }
                .padding(.bottom, 4)

                Divider()

                // Match rationale
                if !candidate.matchRationale.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Match Rationale")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(candidate.matchRationale)
                            .font(.body)
                    }
                }

                // Strength signals
                if !candidate.strengthSignals.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Strengths")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(candidate.strengthSignals, id: \.self) { signal in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text(signal)
                                    .font(.callout)
                            }
                        }
                    }
                }

                // Gap signals
                if !candidate.gapSignals.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gaps")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(candidate.gapSignals, id: \.self) { signal in
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                Text(signal)
                                    .font(.callout)
                            }
                        }
                    }
                }

                Divider()

                // Stage progression
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stage")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(RoleCandidateStage.allCases.filter { !$0.isTerminal }, id: \.self) { stage in
                            let isCurrent = candidate.stage == stage
                            let isPast = stage.order < candidate.stage.order

                            VStack(spacing: 2) {
                                Image(systemName: stage.icon)
                                    .font(.caption)
                                    .foregroundStyle(isCurrent ? stage.color : isPast ? .green : .gray)
                                Text(stage.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(isCurrent ? stage.color.opacity(0.1) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    // Advance button
                    if let nextStage = candidate.stage.next {
                        Button {
                            coordinator.advanceStage(candidateID: candidate.id, to: nextStage)
                        } label: {
                            Label("Move to \(nextStage.rawValue)", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                Divider()

                // User notes
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextEditor(text: $userNotes)
                        .frame(minHeight: 60)
                        .font(.body)
                }

                // Pass button
                if !candidate.stage.isTerminal {
                    Divider()

                    if showingPassReason {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Why not? (helps SAM learn)", text: $passReason)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Confirm Pass") {
                                    if let roleID = candidate.roleDefinition?.id, !passReason.isEmpty {
                                        try? RoleRecruitingRepository.shared.addRefinementNote(roleID: roleID, note: passReason)
                                    }
                                    coordinator.advanceStage(candidateID: candidate.id, to: .passed, notes: passReason)
                                    showingPassReason = false
                                }
                                .foregroundStyle(.red)
                                Button("Cancel") { showingPassReason = false }
                            }
                        }
                    } else {
                        Button("Pass on this candidate") {
                            showingPassReason = true
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .padding()
        }
        .onAppear {
            userNotes = candidate.userNotes ?? ""
        }
    }

    private var scoreColor: Color {
        candidate.matchScore >= 0.7 ? .green : candidate.matchScore >= 0.5 ? .orange : .gray
    }
}
