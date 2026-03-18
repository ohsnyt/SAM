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
                Section("Role") {
                    TextField("Name (e.g. ABT Board Member)", text: $name)
                    TextField("Description — what will this person do?", text: $roleDescription, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Target") {
                    Stepper("Need \(targetCount) \(targetCount == 1 ? "person" : "people")", value: $targetCount, in: 1...100)
                    TextField("Time commitment (optional)", text: $timeCommitment)
                }

                Section("Ideal Candidate Profile") {
                    TextField("Describe who's a good fit (free-form)", text: $idealCandidateProfile, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Criteria") {
                    ForEach(criteria.indices, id: \.self) { index in
                        HStack {
                            TextField("Criterion", text: $criteria[index])
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
                            .onSubmit { addCriterion() }

                        Button {
                            addCriterion()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newCriterion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    ForEach(exclusionCriteria.indices, id: \.self) { index in
                        HStack {
                            TextField("Exclusion", text: $exclusionCriteria[index])
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
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 600)
        .onAppear {
            if case .edit(let role) = mode {
                name = role.name
                roleDescription = role.roleDescription
                idealCandidateProfile = role.idealCandidateProfile
                criteria = role.criteria
                exclusionCriteria = role.exclusionCriteria
                timeCommitment = role.timeCommitment ?? ""
                targetCount = role.targetCount
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
                try repo.saveRoleDefinition(role)
            } else {
                let role = RoleDefinition(
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    roleDescription: roleDescription,
                    idealCandidateProfile: idealCandidateProfile,
                    criteria: cleanCriteria,
                    exclusionCriteria: cleanExclusions,
                    timeCommitment: timeCommitment.isEmpty ? nil : timeCommitment,
                    targetCount: targetCount
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
