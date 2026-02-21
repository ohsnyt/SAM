//
//  NotesJournalView.swift
//  SAM
//
//  Phase L-2: Scrollable inline journal view for notes with in-place editing.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "NotesJournalView")

/// Scrollable journal view that shows all notes with metadata and inline editing.
///
/// Used by PersonDetailView and ContextDetailView to replace the
/// tap-to-open-sheet pattern with a unified scrollable notes panel.
struct NotesJournalView: View {

    // MARK: - Parameters

    let notes: [SamNote]
    let onUpdated: () -> Void

    // MARK: - Dependencies

    @State private var repository = NotesRepository.shared
    @State private var coordinator = NoteAnalysisCoordinator.shared

    // MARK: - State

    @State private var editingNoteID: UUID?
    @State private var editText = ""
    @State private var isSaving = false

    // MARK: - Body

    var body: some View {
        if notes.isEmpty {
            Text("No notes yet")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 {
                            Divider()
                                .padding(.vertical, 4)
                        }

                        noteCell(note)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 400)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Note Cell

    @ViewBuilder
    private func noteCell(_ note: SamNote) -> some View {
        let isEditing = editingNoteID == note.id

        VStack(alignment: .leading, spacing: 6) {
            // Metadata row
            HStack(spacing: 6) {
                Image(systemName: note.isAnalyzed ? "brain.head.profile" : "note.text")
                    .foregroundStyle(note.isAnalyzed ? .purple : .secondary)
                    .font(.caption)

                Text(note.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if note.sourceType == .dictated {
                    Image(systemName: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !note.extractedActionItems.isEmpty {
                    let pendingCount = note.extractedActionItems.filter { $0.status == .pending }.count
                    if pendingCount > 0 {
                        Text("\(pendingCount) action\(pendingCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }

                // Edit / Done button
                if isEditing {
                    Button("Done") {
                        saveEdit(note: note)
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .disabled(isSaving)
                } else {
                    Button {
                        beginEditing(note: note)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Content: read-only text or editable TextEditor
            if isEditing {
                TextEditor(text: $editText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 200)
                    .padding(4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    )

                // Cancel link
                HStack {
                    Button("Cancel") {
                        editingNoteID = nil
                        editText = ""
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()
                }
            } else {
                Text(note.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Summary (if different from content)
            if let summary = note.summary, summary != note.content {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }

            // Topics
            if !note.extractedTopics.isEmpty {
                HStack(spacing: 4) {
                    ForEach(note.extractedTopics.prefix(4), id: \.self) { topic in
                        Text(topic)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    if note.extractedTopics.count > 4 {
                        Text("+\(note.extractedTopics.count - 4)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    // MARK: - Editing

    private func beginEditing(note: SamNote) {
        editingNoteID = note.id
        editText = note.content
    }

    private func saveEdit(note: SamNote) {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != note.content else {
            editingNoteID = nil
            editText = ""
            return
        }

        isSaving = true

        do {
            try repository.update(note: note, content: trimmed)
            editingNoteID = nil
            editText = ""
            isSaving = false
            onUpdated()

            // Re-analyze in background
            Task {
                await coordinator.analyzeNote(note)
            }
        } catch {
            logger.error("Failed to save note edit: \(error)")
            isSaving = false
        }
    }
}
