//
//  RolesSettingsPane.swift
//  SAM
//
//  Settings pane for role definitions (create/edit/delete).
//

import SwiftUI

struct RolesSettingsPane: View {

    @State private var coordinator = RoleRecruitingCoordinator.shared
    @State private var showingEditor = false
    @State private var editingRole: RoleDefinition?
    @State private var showDeleteConfirmation = false
    @State private var roleToDelete: RoleDefinition?
    @State private var isFinancial = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Define roles you want to fill. SAM will scan your contacts and suggest candidates who match your criteria.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    if coordinator.roleDefinitions.isEmpty {
                        ContentUnavailableView {
                            Label("No Roles Defined", systemImage: "person.badge.key")
                        } description: {
                            Text("Create a role to discover candidates in your network.")
                        } actions: {
                            VStack(spacing: 8) {
                                Button("Create Role") {
                                    editingRole = nil
                                    showingEditor = true
                                }
                                .buttonStyle(.borderedProminent)

                                if isFinancial {
                                    Button("Add Financial Advisor Roles") {
                                        seedFinancialAdvisorRoles()
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .frame(minHeight: 200)
                    } else {
                        ForEach(coordinator.roleDefinitions) { role in
                            roleRow(role)
                        }

                        HStack {
                            Button {
                                editingRole = nil
                                showingEditor = true
                            } label: {
                                Label("New Role", systemImage: "plus")
                            }
                            .controlSize(.small)

                            if isFinancial {
                                Spacer()
                                Button("Add Financial Advisor Roles") {
                                    seedFinancialAdvisorRoles()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            coordinator.loadRoles()
        }
        .task {
            isFinancial = await BusinessProfileService.shared.isFinancialPractice()
        }
        .sheet(isPresented: $showingEditor) {
            RoleDefinitionEditorSheet(
                mode: editingRole.map { .edit($0) } ?? .create,
                onSave: {
                    coordinator.loadRoles()
                    StrategicCoordinator.shared.invalidateContentCache()
                }
            )
        }
        .alert("Delete Role?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let role = roleToDelete {
                    try? RoleRecruitingRepository.shared.deleteRoleDefinition(role)
                    coordinator.loadRoles()
                }
            }
        } message: {
            if let role = roleToDelete {
                Text("Delete \"\(role.name)\" and all its candidate matches? This cannot be undone.")
            }
        }
    }

    // MARK: - Seed Financial Advisor Roles

    private func seedFinancialAdvisorRoles() {
        let repo = RoleRecruitingRepository.shared
        let existingNames = Set(coordinator.roleDefinitions.map { $0.name.lowercased() })

        for seed in Self.financialAdvisorSeedRoles {
            guard !existingNames.contains(seed.name.lowercased()) else { continue }
            let role = RoleDefinition(
                name: seed.name,
                roleDescription: seed.description,
                idealCandidateProfile: seed.idealProfile,
                criteria: seed.criteria,
                exclusionCriteria: seed.exclusions,
                targetCount: seed.targetCount
            )
            try? repo.saveRoleDefinition(role)
        }
        coordinator.loadRoles()
        StrategicCoordinator.shared.invalidateContentCache()
    }

    private struct SeedRole {
        let name: String
        let description: String
        let idealProfile: String
        let criteria: [String]
        let exclusions: [String]
        let targetCount: Int
    }

    private static let financialAdvisorSeedRoles: [SeedRole] = [
        SeedRole(
            name: "Referral Partner",
            description: "A professional who regularly refers potential clients — accountants, attorneys, real estate agents, or other centers of influence.",
            idealProfile: "Established professional with an active client base in a complementary field. Already trusts you or has seen your work.",
            criteria: ["Works in a complementary profession", "Has an active client base", "Existing relationship or mutual connection"],
            exclusions: ["Competing financial advisor", "No active practice"],
            targetCount: 5
        ),
        SeedRole(
            name: "WFG Agent Recruit",
            description: "A candidate for joining the WFG team — someone entrepreneurial who could thrive in financial services.",
            idealProfile: "Self-motivated, coachable, interested in financial services. Ideally has sales, teaching, or leadership experience.",
            criteria: ["Entrepreneurial mindset", "Coachable and willing to learn", "Strong interpersonal skills"],
            exclusions: ["Already licensed with a competing firm", "Not legally eligible to obtain a license"],
            targetCount: 3
        ),
        SeedRole(
            name: "Client Advocate",
            description: "An existing client who could become a champion — providing testimonials, referrals, and introductions to their network.",
            idealProfile: "Satisfied client with a strong relationship. Active in their community or professional network.",
            criteria: ["Existing client in good standing", "Active social or professional network", "Has expressed satisfaction"],
            exclusions: ["New client with no established track record"],
            targetCount: 3
        ),
        SeedRole(
            name: "Strategic Alliance",
            description: "A business owner or professional for joint ventures — co-hosted workshops, shared client events, or cross-promotional content.",
            idealProfile: "Local business owner or professional serving a similar demographic without competing on financial products.",
            criteria: ["Serves a similar client demographic", "Open to collaboration", "Active in the local community"],
            exclusions: ["Direct competitor"],
            targetCount: 2
        )
    ]

    // MARK: - Role Row

    private func roleRow(_ role: RoleDefinition) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.name)
                    .samFont(.body)
                    .fontWeight(.medium)

                if !role.roleDescription.isEmpty {
                    Text(role.roleDescription)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                let candidateCount = coordinator.candidatesByRole[role.id]?.count ?? 0
                if candidateCount > 0 {
                    Text("\(candidateCount) candidate\(candidateCount == 1 ? "" : "s")")
                        .samFont(.caption2)
                        .foregroundStyle(.teal)
                }
            }

            Spacer()

            Button {
                editingRole = role
                showingEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit role")

            Button(role: .destructive) {
                roleToDelete = role
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete role")
        }
        .padding(.vertical, 4)
    }
}
