//
//  NoteEditorView.swift
//  SAM
//
//  Phase L-2: Simplified edit-only note editor (opened from note rows)
//

import SwiftUI
import SwiftData

/// Edit-only sheet for modifying an existing note's content.
/// New note creation is handled by InlineNoteCaptureView.
struct NoteEditorView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Parameters

    let note: SamNote
    let onSave: () -> Void

    // MARK: - Dependencies

    @State private var repository = NotesRepository.shared
    @State private var coordinator = NoteAnalysisCoordinator.shared

    // MARK: - State

    @State private var content: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingDiscardConfirmation = false

    // MARK: - Initialization

    init(note: SamNote, onSave: @escaping () -> Void) {
        self.note = note
        self.onSave = onSave
        _content = State(initialValue: note.content)
    }

    // MARK: - Computed

    private var hasChanges: Bool {
        content != note.content
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Note")
                    .font(.headline)

                Spacer()

                if note.isAnalyzed {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.secondary)
                        .help("AI analysis complete")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Divider()

            // Text editor
            TextEditor(text: $content)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding()

            // Error
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            // Footer: Cancel / Save
            HStack {
                Button("Cancel") {
                    if hasChanges {
                        showingDiscardConfirmation = true
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    saveNote()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 500, minHeight: 350)
        .alert("Discard Changes?", isPresented: $showingDiscardConfirmation) {
            Button("Discard", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved changes that will be lost.")
        }
    }

    // MARK: - Actions

    private func saveNote() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSaving = true
        errorMessage = nil

        do {
            try repository.update(note: note, content: trimmed)
            onSave()
            dismiss()

            // Re-analyze in background
            Task {
                await coordinator.analyzeNote(note)
            }
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Preview

#Preview("Edit Note") {
    @Previewable @State var note = SamNote(
        content: "Met with John about retirement planning. He wants to review the whole portfolio before Q3.",
        summary: "Discussed retirement planning and portfolio review",
        isAnalyzed: true
    )

    NoteEditorView(note: note, onSave: {})
        .modelContainer(SAMModelContainer.shared)
        .frame(width: 600, height: 400)
}
