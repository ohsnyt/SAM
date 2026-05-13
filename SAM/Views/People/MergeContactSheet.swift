//
//  MergeContactSheet.swift
//  SAM
//
//  Created by Assistant on 3/27/26.
//  UI for merging two contacts — transfers all relationships from source to target.
//

import SwiftUI
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MergeContact")

struct MergeContactSheet: View {

    /// The person being merged away (source — will be deleted after merge)
    let sourcePerson: SamPerson

    // MARK: - State

    @State private var searchText = ""
    @State private var selectedTargetID: UUID?
    @State private var isMerging = false
    @State private var errorMessage: String?
    @State private var showingConfirmation = false

    @Query(filter: #Predicate<SamPerson> { $0.lifecycleStatusRawValue == "active" },
           sort: \SamPerson.displayNameCache)
    private var allPeople: [SamPerson]

    @Environment(\.dismiss) private var dismiss

    // MARK: - Computed

    private var filteredPeople: [SamPerson] {
        let candidates = allPeople.filter { $0.id != sourcePerson.id }
        let search = searchText.lowercased().trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return candidates }
        return candidates.filter { person in
            let name = (person.displayNameCache ?? person.displayName).lowercased()
            return name.contains(search)
        }
    }

    private var targetPerson: SamPerson? {
        guard let id = selectedTargetID else { return nil }
        return allPeople.first { $0.id == id }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Merge Contact")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // Source person info
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sourcePerson.displayNameCache ?? sourcePerson.displayName)
                                .samFont(.body)
                                .fontWeight(.medium)
                            HStack(spacing: 8) {
                                Label("\(sourcePerson.linkedEvidence.count) evidence", systemImage: "doc.text")
                                Label("\(sourcePerson.linkedNotes.count) notes", systemImage: "note.text")
                            }
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                            if !sourcePerson.roleBadges.isEmpty {
                                Text(sourcePerson.roleBadges.joined(separator: ", "))
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Merge from")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                // Target person picker
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if let target = targetPerson {
                            HStack {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.displayNameCache ?? target.displayName)
                                        .samFont(.body)
                                        .fontWeight(.medium)
                                    HStack(spacing: 8) {
                                        Label("\(target.linkedEvidence.count) evidence", systemImage: "doc.text")
                                        Label("\(target.linkedNotes.count) notes", systemImage: "note.text")
                                    }
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    selectedTargetID = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            TextField("Search for target contact...", text: $searchText)
                                .textFieldStyle(.roundedBorder)

                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(filteredPeople.prefix(10)) { person in
                                        Button {
                                            selectedTargetID = person.id
                                            searchText = ""
                                        } label: {
                                            HStack {
                                                Text(person.displayNameCache ?? person.displayName)
                                                    .samFont(.body)
                                                Spacer()
                                                if !person.roleBadges.isEmpty {
                                                    Text(person.roleBadges.first ?? "")
                                                        .samFont(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 4)
                                            .padding(.horizontal, 6)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                } label: {
                    Text("Merge into")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                // What will happen
                if targetPerson != nil {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            mergePreviewRow("Evidence items", count: sourcePerson.linkedEvidence.count)
                            mergePreviewRow("Notes", count: sourcePerson.linkedNotes.count)
                            mergePreviewRow("Insights", count: sourcePerson.insights.count)
                            mergePreviewRow("Stage transitions", count: sourcePerson.stageTransitions.count)
                            mergePreviewRow("Production records", count: sourcePerson.productionRecords.count)
                        }
                    } label: {
                        Text("Will be transferred")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .samFont(.caption)
                }
            }
            .padding()

            Spacer()

            Divider()

            // Footer
            HStack {
                Text("The source contact will be deleted after merge.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Merge", role: .destructive) {
                    showingConfirmation = true
                }
                .disabled(selectedTargetID == nil || isMerging)
            }
            .padding()
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 480, idealHeight: 560)
        .alert("Confirm Merge", isPresented: $showingConfirmation) {
            Button("Merge", role: .destructive) { performMerge() }
            Button("Cancel", role: .cancel) { }
        } message: {
            if targetPerson != nil {
                Text("Merge these contacts? This will transfer all data and delete the source contact.")
            }
        }
        .dismissOnLock(isPresented: $showingConfirmation)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func mergePreviewRow(_ label: String, count: Int) -> some View {
        if count > 0 {
            HStack {
                Text(label)
                    .samFont(.caption)
                Spacer()
                Text("\(count)")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func performMerge() {
        guard let targetID = selectedTargetID else { return }
        isMerging = true
        errorMessage = nil

        do {
            let snapshot = try PeopleRepository.shared.mergePerson(
                sourceID: sourcePerson.id,
                targetID: targetID
            )
            // Create undo entry
            if let entry = try? UndoRepository.shared.capture(
                operation: .merged,
                entityType: .person,
                entityID: sourcePerson.id,
                entityDisplayName: sourcePerson.displayNameCache ?? sourcePerson.displayName,
                snapshot: snapshot
            ) {
                UndoCoordinator.shared.showToast(for: entry)
            }
            logger.info("Merged \(sourcePerson.displayNameCache ?? "person", privacy: .private) into target")

            // Engine output (outcomes, bundles, insights, role candidates) for
            // both source and target was deleted by mergePerson — kick the
            // outcome engine so the queue refills from the merged data instead
            // of waiting for the next scheduled tick.
            OutcomeEngine.shared.startGeneration()

            // Navigate sidebar selection to the target BEFORE dismissing.
            // Without this, when the sheet was launched from PersonDetailView
            // the parent re-renders bound to the now-deleted source SamPerson
            // and crashes faulting a property like `familyReferences`. Switching
            // selection forces PeopleDetailContainer's `.id(personID)` to
            // rebuild PersonDetailView against the surviving target.
            NotificationCenter.default.post(
                name: .samNavigateToPerson,
                object: nil,
                userInfo: ["personID": targetID]
            )
            dismiss()
        } catch {
            errorMessage = "Merge failed: \(error.localizedDescription)"
            logger.error("Merge failed: \(error.localizedDescription)")
            isMerging = false
        }
    }
}
