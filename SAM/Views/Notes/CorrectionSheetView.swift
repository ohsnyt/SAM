//
//  CorrectionSheetView.swift
//  SAM
//
//  Correction-Through-Enrichment: lets the user explain what's actually true
//  about a person when the AI relationship summary is wrong.
//  Saves as a regular note and triggers re-analysis.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CorrectionSheetView")

struct CorrectionSheetView: View {

    let person: SamPerson
    let currentSummary: String

    @Environment(\.dismiss) private var dismiss

    @State private var correctionText = ""
    @State private var isSaving = false

    // Dictation state
    @State private var isDictating = false
    @State private var isPolishing = false
    @State private var rawDictationText: String?
    @State private var usedDictation = false
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0
    @State private var errorMessage: String?
    @State private var editorHandle = RichNoteEditorHandle()

    // Dependencies
    private let notesRepository = NotesRepository.shared
    private let analysisCoordinator = NoteAnalysisCoordinator.shared
    @State private var dictationService = DictationService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Correct AI Summary")
                        .font(.headline)
                    Text(person.displayNameCache ?? person.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Current AI summary (read-only, scrollable)
            VStack(alignment: .leading, spacing: 4) {
                Text("What the AI thinks:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView {
                    Text(currentSummary)
                        .font(.callout)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // User correction input
            VStack(alignment: .leading, spacing: 4) {
                Text("What's actually true:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .bottom, spacing: 8) {
                    RichNoteEditor(plainText: $correctionText, existingImages: [], handle: editorHandle)
                        .frame(minHeight: 60, idealHeight: 80, maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.secondary.opacity(0.2))
                        )
                        .overlay(alignment: .topLeading) {
                            if correctionText.isEmpty && !isDictating {
                                Text("Type or dictate a correction...")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .allowsHitTesting(false)
                            }
                        }

                    // Attach image button
                    Button {
                        attachImage()
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Attach image from file")

                    // Mic button
                    Button {
                        if isDictating {
                            stopDictation()
                        } else {
                            startDictation()
                        }
                    } label: {
                        Image(systemName: isDictating ? "mic.fill" : "mic")
                            .font(.body)
                            .foregroundStyle(isDictating ? .red : .secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(isDictating ? "Stop dictation" : "Start dictation")
                    .overlay {
                        if isDictating {
                            Circle()
                                .stroke(.red.opacity(0.5), lineWidth: 2)
                                .frame(width: 28, height: 28)
                                .scaleEffect(isDictating ? 1.3 : 1.0)
                                .opacity(isDictating ? 0 : 1)
                                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: false), value: isDictating)
                        }
                    }
                }

                // Status indicators
                if isPolishing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Polishing dictation...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let raw = rawDictationText, raw != correctionText {
                    Button {
                        correctionText = raw
                        rawDictationText = nil
                    } label: {
                        Label("Undo polish", systemImage: "arrow.uturn.backward")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            // Footer buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await saveCorrection() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    }
                    Text("Save & Re-analyze")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    // MARK: - Image Attach

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

        let existingText = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    correctionText = prefix.isEmpty ? currentText : "\(prefix) \(currentText)"

                    if result.isFinal {
                        isDictating = false
                    }
                }
                if isDictating {
                    isDictating = false
                    dictationService.stopRecognition()
                }
                if usedDictation && !correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            return correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let full = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }

    private func stopDictation() {
        dictationService.stopRecognition()
        isDictating = false

        if !correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await polishDictatedText()
            }
        }
    }

    private func polishDictatedText() async {
        let rawText = correctionText
        rawDictationText = rawText
        isPolishing = true

        do {
            let polished = try await NoteAnalysisService.shared.polishDictation(rawText: rawText)
            correctionText = polished
        } catch {
            logger.debug("Dictation polish unavailable: \(error.localizedDescription)")
        }

        isPolishing = false
    }

    // MARK: - Save

    private func saveCorrection() async {
        let (rawText, extractedImages) = editorHandle.extractContent()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSaving = true

        let personName = person.displayNameCache ?? person.displayName

        // Truncate summary excerpt for the note
        let excerpt = currentSummary.count > 200
            ? String(currentSummary.prefix(200)) + "..."
            : currentSummary

        let content = """
        Correction: The current AI summary for \(personName) states: "\(excerpt)"

        This is inaccurate. \(trimmed)
        """

        let sourceType: SamNote.SourceType = usedDictation ? .dictated : .typed

        do {
            let note = try notesRepository.create(
                content: content,
                sourceType: sourceType,
                linkedPeopleIDs: [person.id]
            )

            // Save extracted inline images
            if !extractedImages.isEmpty {
                try notesRepository.addImages(to: note, images: extractedImages)
            }

            logger.info("Created correction note for \(personName)")

            // Fire analysis (will also refresh relationship summary)
            Task {
                await analysisCoordinator.analyzeNote(note)
            }

            dismiss()
        } catch {
            logger.error("Failed to save correction note: \(error)")
            isSaving = false
        }
    }
}
