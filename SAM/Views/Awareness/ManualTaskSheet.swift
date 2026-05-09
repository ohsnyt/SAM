//
//  ManualTaskSheet.swift
//  SAM
//
//  Created by Assistant on 3/27/26.
//  User-created manual tasks and follow-up reminders.
//

import SwiftUI
import SwiftData

struct ManualTaskSheet: View {

    // MARK: - Parameters

    /// Pre-filled person (when launched from PersonDetailView)
    var prefilledPerson: SamPerson?

    /// Dismiss callback
    var onSave: () -> Void = {}

    // MARK: - Draft persistence

    private static let draftKind = "manual-task"

    private var draftID: String { prefilledPerson?.id.uuidString ?? "new" }

    // MARK: - State

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDeadline = false
    @State private var deadlineDate = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var selectedPersonID: UUID?
    @State private var personSearchText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    @Query(filter: #Predicate<SamPerson> { $0.lifecycleStatusRawValue == "active" },
           sort: \SamPerson.displayNameCache)
    private var allPeople: [SamPerson]

    @Environment(\.dismiss) private var dismiss

    // MARK: - Computed

    private var filteredPeople: [SamPerson] {
        let search = personSearchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return allPeople }
        return allPeople.filter { person in
            let name = (person.displayNameCache ?? person.displayName).lowercased()
            return name.contains(search)
        }
    }

    private var selectedPerson: SamPerson? {
        guard let id = selectedPersonID else { return nil }
        return allPeople.first { $0.id == id }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Task")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Form
            Form {
                Section("What do you need to do?") {
                    TextField("e.g., Call Ricky about the IUL quote", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Notes (optional)") {
                    TextField("Additional context or details", text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Person (optional)") {
                    if let person = selectedPerson {
                        HStack {
                            Text(person.displayNameCache ?? person.displayName)
                                .samFont(.body)
                            Spacer()
                            Button {
                                selectedPersonID = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        TextField("Search contacts...", text: $personSearchText)
                            .textFieldStyle(.roundedBorder)

                        if !personSearchText.isEmpty {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(filteredPeople.prefix(8)) { person in
                                        Button {
                                            selectedPersonID = person.id
                                            personSearchText = ""
                                        } label: {
                                            Text(person.displayNameCache ?? person.displayName)
                                                .samFont(.body)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 4)
                                                .padding(.horizontal, 6)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 160)
                        }
                    }
                }

                Section("Deadline (optional)") {
                    Toggle("Set a deadline", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Due", selection: $deadlineDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .samFont(.caption)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Create Task") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 400, idealHeight: 500)
        .onAppear {
            if let person = prefilledPerson {
                selectedPersonID = person.id
            }
            if let stored = DraftStore.shared.load(kind: Self.draftKind, id: draftID) {
                if let v = stored["title"] { title = v }
                if let v = stored["notes"] { notes = v }
            }
        }
        .onChange(of: title) { saveDraft() }
        .onChange(of: notes) { saveDraft() }
    }

    private func saveDraft() {
        DraftStore.shared.save(
            kind: Self.draftKind,
            id: draftID,
            fields: ["title": title, "notes": notes]
        )
    }

    // MARK: - Save

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        errorMessage = nil

        let outcome = SamOutcome(
            title: trimmedTitle,
            rationale: notes.trimmingCharacters(in: .whitespaces).isEmpty
                ? "User-created task"
                : notes.trimmingCharacters(in: .whitespaces),
            outcomeKind: .userTask,
            priorityScore: 0.8,
            deadlineDate: hasDeadline ? deadlineDate : nil,
            sourceInsightSummary: "Created manually by user",
            linkedPerson: selectedPerson
        )
        outcome.actionLaneRawValue = ActionLane.record.rawValue

        do {
            try OutcomeRepository.shared.upsert(outcome: outcome)
            DraftStore.shared.clear(kind: Self.draftKind, id: draftID)
            onSave()
            dismiss()
        } catch {
            errorMessage = "Failed to create task: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
