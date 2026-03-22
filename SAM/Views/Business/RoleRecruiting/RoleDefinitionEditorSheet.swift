//
//  RoleDefinitionEditorSheet.swift
//  SAM
//
//  Created on March 17, 2026.
//  Role Recruiting: Create/edit role definitions with criteria entry.
//

import SwiftUI

struct RoleDefinitionEditorSheet: View {

    enum Mode {
        case create
        case edit(RoleDefinition)
    }

    let mode: Mode
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var roleDescription: String = ""
    @State private var idealCandidateProfile: String = ""
    @State private var criteria: [String] = []
    @State private var newCriterion: String = ""
    @State private var exclusionCriteria: [String] = []
    @State private var newExclusion: String = ""
    @State private var timeCommitment: String = ""
    @State private var targetCount: Int = 1
    @State private var contentGenerationEnabled: Bool = false
    @State private var contentBrief: String = ""

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Text(isEditing ? "Edit Role" : "New Role")
                    .samFont(.headline)

                Spacer()

                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("What will this person do?", text: $roleDescription, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Role")
                } footer: {
                    Text("E.g. \"ABT Board Member\", \"Referral Partner\", \"WFG Agent\"")
                }

                Section {
                    Stepper("Need \(targetCount) \(targetCount == 1 ? "person" : "people")", value: $targetCount, in: 1...100)
                    TextField("Time commitment (optional)", text: $timeCommitment)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Target")
                }

                Section {
                    TextField("Describe who would be a good fit for this role...", text: $idealCandidateProfile, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("Ideal Candidate Profile")
                } footer: {
                    Text("Free-form description that helps SAM identify matching contacts.")
                }

                Section {
                    ForEach(criteria.indices, id: \.self) { index in
                        HStack {
                            TextField("Criterion", text: $criteria[index])
                                .textFieldStyle(.roundedBorder)
                            Button {
                                criteria.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("Add criterion...", text: $newCriterion)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addCriterion() }

                        Button {
                            addCriterion()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newCriterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Matching Criteria")
                } footer: {
                    Text("Specific traits SAM uses to score candidates. E.g. \"Connected to our community\", \"Has leadership experience\".")
                }

                Section {
                    ForEach(exclusionCriteria.indices, id: \.self) { index in
                        HStack {
                            TextField("Exclusion", text: $exclusionCriteria[index])
                                .textFieldStyle(.roundedBorder)
                            Button {
                                exclusionCriteria.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("Add exclusion...", text: $newExclusion)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addExclusion() }

                        Button {
                            addExclusion()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newExclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Disqualifying Conditions")
                } footer: {
                    Text("People matching these conditions will be excluded. E.g. \"Employees of ABT\", \"Anyone compensated by the organization\".")
                }

                Section {
                    Toggle("Generate content topics for this role", isOn: $contentGenerationEnabled)

                    if contentGenerationEnabled {
                        TextField(
                            "Why should people know about this group? What do they do? What impact do they have?",
                            text: $contentBrief,
                            axis: .vertical
                        )
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                    }
                } header: {
                    Text("Content Generation")
                } footer: {
                    Text("When enabled, SAM will suggest social media topics inspired by your interactions with people in this role.")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            if case .edit(let role) = mode {
                name = role.name
                roleDescription = role.roleDescription
                idealCandidateProfile = role.idealCandidateProfile
                criteria = role.criteria
                exclusionCriteria = role.exclusionCriteria
                timeCommitment = role.timeCommitment ?? ""
                targetCount = role.targetCount
                contentGenerationEnabled = role.contentGenerationEnabled
                contentBrief = role.contentBrief
            }
        }
    }

    // MARK: - Helpers

    private func addCriterion() {
        let trimmed = newCriterion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        criteria.append(trimmed)
        newCriterion = ""
    }

    private func addExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        exclusionCriteria.append(trimmed)
        newExclusion = ""
    }

    private func save() {
        let repo = RoleRecruitingRepository.shared

        do {
            let cleanCriteria = criteria.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let cleanExclusions = exclusionCriteria.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            if case .edit(let role) = mode {
                role.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                role.roleDescription = roleDescription
                role.idealCandidateProfile = idealCandidateProfile
                role.criteria = cleanCriteria
                role.exclusionCriteria = cleanExclusions
                role.timeCommitment = timeCommitment.isEmpty ? nil : timeCommitment
                role.targetCount = targetCount
                role.contentGenerationEnabled = contentGenerationEnabled
                role.contentBrief = contentBrief
                try repo.saveRoleDefinition(role)
            } else {
                let role = RoleDefinition(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    roleDescription: roleDescription,
                    idealCandidateProfile: idealCandidateProfile,
                    criteria: cleanCriteria,
                    exclusionCriteria: cleanExclusions,
                    timeCommitment: timeCommitment.isEmpty ? nil : timeCommitment,
                    targetCount: targetCount,
                    contentGenerationEnabled: contentGenerationEnabled,
                    contentBrief: contentBrief
                )
                try repo.saveRoleDefinition(role)
            }

            onSave()
            dismiss()
        } catch {
            // Best-effort — form stays open on error
        }
    }
}
