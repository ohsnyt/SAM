//
//  RoleRecruitingDashboardView.swift
//  SAM
//
//  Created on March 17, 2026.
//  Role Recruiting: Main dashboard tab for role-based candidate management.
//

import SwiftUI
import TipKit

struct RoleRecruitingDashboardView: View {

    @State private var coordinator = RoleRecruitingCoordinator.shared
    @State private var selectedRoleID: UUID?
    @State private var showingEditor = false
    @State private var editingRole: RoleDefinition?
    @State private var showingReviewSheet = false
    private let tip = RoleRecruitingTip()

    private var selectedRole: RoleDefinition? {
        coordinator.roleDefinitions.first { $0.id == selectedRoleID }
    }

    private var candidates: [RoleCandidate] {
        guard let id = selectedRoleID else { return [] }
        return coordinator.candidatesByRole[id] ?? []
    }

    private var pendingCount: Int {
        guard let id = selectedRoleID else { return 0 }
        return coordinator.pendingResults[id]?.count ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            TipView(tip, arrowEdge: .bottom) { action in
                SAMTipActionHandler.handleAction(action, for: tip)
            }
            .tipViewStyle(SAMTipViewStyle())
            .padding(.horizontal)

            if coordinator.roleDefinitions.isEmpty {
                emptyState
            } else {
                rolePicker
                Divider()

                if let role = selectedRole {
                    funnelStrip(role: role)
                    Divider()

                    actionBar

                    candidateList
                } else {
                    ContentUnavailableView("Select a Role", systemImage: "person.badge.key")
                }
            }
        }
        .onAppear {
            coordinator.loadRoles()
            if selectedRoleID == nil {
                selectedRoleID = coordinator.roleDefinitions.first?.id
            }
        }
        .sheet(isPresented: $showingEditor) {
            RoleDefinitionEditorSheet(
                mode: editingRole.map { .edit($0) } ?? .create,
                onSave: {
                    coordinator.loadRoles()
                    if selectedRoleID == nil {
                        selectedRoleID = coordinator.roleDefinitions.first?.id
                    }
                    StrategicCoordinator.shared.invalidateContentCache()
                }
            )
        }
        .sheet(isPresented: $showingReviewSheet) {
            if let roleID = selectedRoleID,
               let results = coordinator.pendingResults[roleID] {
                RoleCandidateReviewSheet(
                    results: results,
                    roleID: roleID,
                    roleName: selectedRole?.name ?? "Role",
                    coordinator: coordinator
                )
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Roles Defined", systemImage: "person.badge.key")
        } description: {
            Text("Create a role to discover candidates in your network.")
        } actions: {
            Button("Create Role") {
                editingRole = nil
                showingEditor = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Role Picker

    private var rolePicker: some View {
        HStack {
            if coordinator.roleDefinitions.count <= 3 {
                Picker("Role", selection: $selectedRoleID) {
                    ForEach(coordinator.roleDefinitions) { role in
                        Text(role.name).tag(Optional(role.id))
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Picker("Role", selection: $selectedRoleID) {
                    ForEach(coordinator.roleDefinitions) { role in
                        Text(role.name).tag(Optional(role.id))
                    }
                }
                .pickerStyle(.menu)
            }

            Spacer()

            Button {
                editingRole = nil
                showingEditor = true
            } label: {
                Label("New Role", systemImage: "plus")
            }
            .controlSize(.small)

            if selectedRole != nil {
                Button {
                    editingRole = selectedRole
                    showingEditor = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .controlSize(.small)
            }
        }
        .padding()
    }

    // MARK: - Funnel Strip

    private func funnelStrip(role: RoleDefinition) -> some View {
        let allCandidates = coordinator.candidatesByRole[role.id] ?? []
        let byCounts = Dictionary(grouping: allCandidates, by: { $0.stage })

        return HStack(spacing: 12) {
            ForEach(RoleCandidateStage.allCases.filter { !$0.isTerminal }, id: \.self) { stage in
                let count = byCounts[stage]?.count ?? 0
                VStack(spacing: 2) {
                    Text("\(count)")
                        .samFont(.title3, weight: .bold)
                        .foregroundStyle(stage.color)
                    Text(stage.rawValue)
                        .samFont(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            Divider().frame(height: 30)

            VStack(spacing: 2) {
                Text("\(role.filledCount)/\(role.targetCount)")
                    .samFont(.title3, weight: .bold)
                    .foregroundStyle(role.filledCount >= role.targetCount ? .green : .orange)
                Text("Filled")
                    .samFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Button {
                guard let roleID = selectedRoleID else { return }
                Task { await coordinator.scoreCandidates(for: roleID) }
            } label: {
                Label("Scan Contacts", systemImage: "magnifyingglass.circle")
            }
            .disabled(isScoringInProgress)

            if pendingCount > 0 {
                Button {
                    showingReviewSheet = true
                } label: {
                    Label("Review \(pendingCount) Suggestions", systemImage: "star.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Spacer()

            scoringStatusLabel

            GuideButton(articleID: "business.role-recruiting")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var isScoringInProgress: Bool {
        switch coordinator.scoringStatus {
        case .preparing, .scoring: return true
        default: return false
        }
    }

    @ViewBuilder
    private var scoringStatusLabel: some View {
        switch coordinator.scoringStatus {
        case .idle:
            EmptyView()
        case .preparing(let name):
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Preparing scan for \(name)...")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        case .scoring(_, let current, let total):
            HStack(spacing: 6) {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("Scanning \(current) of \(total)")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .complete:
            if pendingCount == 0 {
                Text("Scan complete — no new matches")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .samFont(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Candidate List

    private var candidateList: some View {
        List {
            ForEach(nonTerminalStages, id: \.self) { stage in
                let stageCandidates = candidates
                    .filter { $0.stage == stage }
                    .sorted { $0.matchScore > $1.matchScore }
                if !stageCandidates.isEmpty {
                    Section(stage.rawValue) {
                        ForEach(stageCandidates) { candidate in
                            RoleCandidateRow(candidate: candidate)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var nonTerminalStages: [RoleCandidateStage] {
        RoleCandidateStage.allCases.filter { !$0.isTerminal }
    }
}

// MARK: - Candidate Row

private struct RoleCandidateRow: View {
    let candidate: RoleCandidate

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.person?.displayNameCache ?? candidate.person?.displayName ?? "Unknown")
                        .samFont(.body, weight: .medium)

                    ForEach(candidate.person?.roleBadges ?? [], id: \.self) { badge in
                        Text(badge)
                            .samFont(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }

                if !candidate.matchRationale.isEmpty {
                    Text(candidate.matchRationale)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Score indicator
            scoreIndicator(candidate.matchScore)

            // Last contacted
            if let date = candidate.lastContactedAt {
                Text(date, style: .relative)
                    .samFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func scoreIndicator(_ score: Double) -> some View {
        let color: Color = score >= 0.7 ? .green : score >= 0.5 ? .orange : .gray
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help("Match score: \(Int(score * 100))%")
    }
}
