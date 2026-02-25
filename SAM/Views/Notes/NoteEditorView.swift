//
//  NoteEditorView.swift
//  SAM
//
//  Phase L-2: Simplified edit-only note editor (opened from note rows)
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "NoteEditorView")

/// Edit-only sheet for modifying an existing note's content.
/// Uses RichNoteEditor for inline image support.
struct NoteEditorView: View {

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Parameters

    let note: SamNote
    let onSave: () -> Void

    // MARK: - Dependencies

    @State private var repository = NotesRepository.shared
    @State private var coordinator = NoteAnalysisCoordinator.shared
    @State private var dictationService = DictationService.shared

    // MARK: - State

    @State private var content: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingDiscardConfirmation = false
    @State private var editorHandle = RichNoteEditorHandle()

    // Dictation state
    @State private var isDictating = false
    @State private var isPolishing = false
    @State private var rawDictationText: String?
    @State private var usedDictation = false
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0

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

            // Rich text editor with inline images
            RichNoteEditor(
                plainText: $content,
                existingImages: note.images
                    .sorted(by: { $0.displayOrder < $1.displayOrder })
                    .compactMap { img in
                        guard let data = img.imageData else { return nil }
                        return (data, img.mimeType, img.textInsertionPoint ?? Int.max)
                    },
                handle: editorHandle
            )
            .padding(4)

            // Toolbar: attach + mic
            HStack(spacing: 8) {
                Button {
                    attachImage()
                } label: {
                    Label("Attach Image", systemImage: "paperclip")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button {
                    if isDictating {
                        stopDictation()
                    } else {
                        startDictation()
                    }
                } label: {
                    Image(systemName: isDictating ? "mic.fill" : "mic")
                        .font(.caption)
                        .foregroundStyle(isDictating ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(isDictating ? "Stop dictation" : "Start dictation")
                .overlay {
                    if isDictating {
                        Circle()
                            .stroke(.red.opacity(0.5), lineWidth: 2)
                            .frame(width: 20, height: 20)
                            .scaleEffect(isDictating ? 1.3 : 1.0)
                            .opacity(isDictating ? 0 : 1)
                            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: false), value: isDictating)
                    }
                }

                Spacer()
            }
            .padding(.horizontal)

            // Polish status
            if isPolishing {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Polishing dictation...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            if let raw = rawDictationText, raw != content {
                Button {
                    content = raw
                    rawDictationText = nil
                } label: {
                    Label("Undo polish", systemImage: "arrow.uturn.backward")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            }

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

    private func attachImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let ext = url.pathExtension.lowercased()
            let mime: String
            switch ext {
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "tiff", "tif": mime = "image/tiff"
            default: mime = "image/png"
            }
            editorHandle.insertImage(data: data, mimeType: mime)
        }
    }

    // MARK: - Dictation

    private func startDictation() {
        let availability = dictationService.checkAvailability()

        switch availability {
        case .available:
            break
        case .notAuthorized:
            Task {
                let granted = await dictationService.requestAuthorization()
                guard granted else {
                    errorMessage = "Speech recognition permission not granted"
                    return
                }
                beginDictationStream()
            }
            return
        case .notAvailable:
            errorMessage = "Speech recognition is not available"
            return
        case .restricted:
            errorMessage = "Speech recognition is restricted"
            return
        }

        beginDictationStream()
    }

    private func beginDictationStream() {
        isDictating = true
        usedDictation = true
        errorMessage = nil
        accumulatedSegments = []
        lastSegmentPeakLength = 0

        // Preserve any existing text as the first segment
        let existingText = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingText.isEmpty {
            accumulatedSegments.append(existingText)
        }

        Task {
            do {
                let stream = try await dictationService.startRecognition()
                for await result in stream {
                    let currentText = result.text

                    if currentText.count < lastSegmentPeakLength / 2 && lastSegmentPeakLength > 5 {
                        let previousSegment = extractCurrentSegment()
                        if !previousSegment.isEmpty {
                            accumulatedSegments.append(previousSegment)
                        }
                        lastSegmentPeakLength = 0
                    }

                    lastSegmentPeakLength = max(lastSegmentPeakLength, currentText.count)

                    let prefix = accumulatedSegments.joined(separator: " ")
                    content = prefix.isEmpty ? currentText : "\(prefix) \(currentText)"

                    if result.isFinal {
                        isDictating = false
                    }
                }
                if isDictating {
                    isDictating = false
                    dictationService.stopRecognition()
                }
                if usedDictation && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await polishDictatedText()
                }
            } catch {
                errorMessage = error.localizedDescription
                isDictating = false
            }
        }
    }

    private func extractCurrentSegment() -> String {
        let prefix = accumulatedSegments.joined(separator: " ")
        if prefix.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let full = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }

    private func stopDictation() {
        dictationService.stopRecognition()
        isDictating = false

        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await polishDictatedText()
            }
        }
    }

    private func polishDictatedText() async {
        let rawText = content
        rawDictationText = rawText
        isPolishing = true

        do {
            let polished = try await NoteAnalysisService.shared.polishDictation(rawText: rawText)
            content = polished
        } catch {
            logger.debug("Dictation polish unavailable: \(error.localizedDescription)")
        }

        isPolishing = false
    }

    // MARK: - Save

    private func saveNote() {
        let (rawText, extractedImages) = editorHandle.extractContent()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSaving = true
        errorMessage = nil

        do {
            try repository.update(note: note, content: trimmed)

            // Replace existing images with current set
            // First remove old images
            let context = note.modelContext
            for oldImage in note.images {
                context?.delete(oldImage)
            }
            note.images.removeAll()
            try context?.save()

            // Save new images from editor
            if !extractedImages.isEmpty {
                try repository.addImages(to: note, images: extractedImages)
            }

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
