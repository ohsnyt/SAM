//
//  GoalEntryForm.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase X: Goal Setting & Decomposition
//
//  Sheet for creating or editing a BusinessGoal.
//

import SwiftUI

struct GoalEntryForm: View {

    enum Mode: Identifiable {
        case create
        case edit(BusinessGoal)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let goal): return goal.id.uuidString
            }
        }
    }

    let mode: Mode
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: GoalType = .newClients
    @State private var title: String = ""
    @State private var targetValueText: String = ""
    @State private var startDate: Date = .now
    @State private var endDate: Date = Calendar.current.date(byAdding: .month, value: 3, to: .now)!
    @State private var notes: String = ""
    @State private var hasAutoTitle = true
    @State private var isFinancial = true
    @State private var selectedRoleDefinitionID: UUID?
    @State private var availableRoles: [RoleDefinition] = []
    @State private var showingRoleEditor = false

    private var goalRepo: GoalRepository { GoalRepository.shared }

    private var availableGoalTypes: [GoalType] {
        GoalType.allCases.filter { isFinancial || !$0.requiresFinancialPractice }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Text(isEditing ? "Edit Goal" : "New Goal")
                    .samFont(.headline)

                Spacer()

                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetValue == nil || title.isEmpty)
            }
            .padding()

            Divider()

            Form {
                // Goal type picker (create mode only)
                if !isEditing {
                    Section("Goal Type") {
                        Picker("Type", selection: $selectedType) {
                            ForEach(availableGoalTypes, id: \.self) { type in
                                Label(type.displayName, systemImage: type.icon)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedType) {
                            if hasAutoTitle {
                                title = autoTitle
                            }
                        }
                    }
                } else {
                    Section("Goal Type") {
                        Label(selectedType.displayName, systemImage: selectedType.icon)
                            .foregroundStyle(selectedType.color)
                    }
                }

                // Title
                Section("Title") {
                    TextField("Goal title", text: $title)
                        .onChange(of: title) {
                            hasAutoTitle = false
                        }
                }

                // Target
                Section("Target") {
                    HStack {
                        if selectedType.isCurrency {
                            Text("$")
                                .foregroundStyle(.secondary)
                        }
                        TextField("Target value", text: $targetValueText)
                            .onChange(of: targetValueText) {
                                if hasAutoTitle {
                                    title = autoTitle
                                }
                            }
                    }

                    if !selectedType.isCurrency {
                        Text(selectedType.unit)
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Role definition picker (for roleFilling only)
                if selectedType == .roleFilling {
                    Section("Linked Role") {
                        Picker("Role", selection: $selectedRoleDefinitionID) {
                            Text("Select a role...").tag(nil as UUID?)
                            ForEach(availableRoles) { role in
                                Text(role.name).tag(Optional(role.id))
                            }
                        }
                        .pickerStyle(.menu)

                        Button("+ Create New Role") {
                            showingRoleEditor = true
                        }
                        .controlSize(.small)
                    }
                }

                // Date range
                Section("Period") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .date)
                    DatePicker("Deadline", selection: $endDate, displayedComponents: .date)
                }

                // Notes
                Section("Notes (Optional)") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 60)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 450, height: 520)
        .sheet(isPresented: $showingRoleEditor) {
            RoleDefinitionEditorSheet(mode: .create) {
                availableRoles = (try? RoleRecruitingRepository.shared.fetchActiveRoles()) ?? []
                selectedRoleDefinitionID = availableRoles.last?.id
            }
        }
        .task {
            isFinancial = await BusinessProfileService.shared.isFinancialPractice()
            availableRoles = (try? RoleRecruitingRepository.shared.fetchActiveRoles()) ?? []
        }
        .onAppear {
            FeatureAdoptionTracker.shared.recordUsage(.goalSetting)
            if case .edit(let goal) = mode {
                selectedType = goal.goalType
                title = goal.title
                targetValueText = goal.goalType.isCurrency
                    ? String(format: "%.0f", goal.targetValue)
                    : String(format: "%.0f", goal.targetValue)
                startDate = goal.startDate
                endDate = goal.endDate
                notes = goal.notes ?? ""
                selectedRoleDefinitionID = goal.roleDefinitionID
                hasAutoTitle = false
            } else {
                title = autoTitle
            }
        }
    }

    // MARK: - Helpers

    private var targetValue: Double? {
        Double(targetValueText.replacingOccurrences(of: ",", with: ""))
    }

    private var autoTitle: String {
        let valueStr = targetValueText.isEmpty ? "?" : targetValueText
        if selectedType.isCurrency {
            return "$\(valueStr) \(selectedType.displayName)"
        } else {
            return "\(valueStr) \(selectedType.displayName)"
        }
    }

    private func save() {
        guard let value = targetValue else { return }

        do {
            if case .edit(let goal) = mode {
                try goalRepo.update(
                    id: goal.id,
                    title: title,
                    targetValue: value,
                    startDate: startDate,
                    endDate: endDate,
                    notes: notes.isEmpty ? nil : notes
                )
                if selectedType == .roleFilling {
                    goal.roleDefinitionID = selectedRoleDefinitionID
                }
            } else {
                let goal = try goalRepo.create(
                    goalType: selectedType,
                    title: title,
                    targetValue: value,
                    startDate: startDate,
                    endDate: endDate,
                    notes: notes.isEmpty ? nil : notes
                )
                if selectedType == .roleFilling {
                    goal.roleDefinitionID = selectedRoleDefinitionID
                }
            }
            onSave()
            dismiss()
        } catch {
            // Best-effort — form stays open on error
        }
    }
}
