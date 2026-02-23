//
//  QuickNoteWindowView.swift
//  SAM
//
//  Floating auxiliary window for quick note capture from outcome cards.
//  Supports typing and dictation with auto-polish, then saves a linked note
//  and marks the originating outcome as completed.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "QuickNoteWindowView")

struct QuickNoteWindowView: View {

    let payload: QuickNotePayload

    // MARK: - Dependencies

    @State private var repository = NotesRepository.shared
    @State private var outcomeRepo = OutcomeRepository.shared
    @State private var coordinator = NoteAnalysisCoordinator.shared
    @State private var dictationService = DictationService.shared
    @State private var evidenceRepository = EvidenceRepository.shared

    // MARK: - State

    @State private var text = ""
    @State private var isDictating = false
    @State private var isPolishing = false
    @State private var isSaving = false
    @State private var rawDictationText: String?
    @State private var errorMessage: String?
    @State private var usedDictation = false

    // Segment accumulation for dictation (recognizer resets after pauses)
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title bar context
            Text(payload.contextTitle)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // Text editor
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 200)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && !isDictating {
                        Text("Type or dictate your note...")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
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

            if let raw = rawDictationText, raw != text {
                Button {
                    text = raw
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

            Divider()

            // Bottom bar: mic on left, cancel + save on right
            HStack {
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

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

                Button("Save & Complete") {
                    saveAndComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 420, idealWidth: 500, minHeight: 250, idealHeight: 300)
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

        // Preserve any existing typed text as the first segment
        let existingText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingText.isEmpty {
            accumulatedSegments.append(existingText)
        }

        Task {
            do {
                let stream = try await dictationService.startRecognition()
                for await result in stream {
                    let currentText = result.text

                    // Detect recognizer reset: if new text is much shorter than
                    // what we've seen in this segment, the recognizer restarted
                    if currentText.count < lastSegmentPeakLength / 2 && lastSegmentPeakLength > 5 {
                        let previousSegment = extractCurrentSegment()
                        if !previousSegment.isEmpty {
                            accumulatedSegments.append(previousSegment)
                        }
                        lastSegmentPeakLength = 0
                    }

                    lastSegmentPeakLength = max(lastSegmentPeakLength, currentText.count)

                    // Build full display text: accumulated segments + current partial
                    let prefix = accumulatedSegments.joined(separator: " ")
                    text = prefix.isEmpty ? currentText : "\(prefix) \(currentText)"

                    if result.isFinal {
                        isDictating = false
                    }
                }
                // Stream ended naturally
                if isDictating {
                    isDictating = false
                    dictationService.stopRecognition()
                }
                // Polish after dictation ends
                if usedDictation && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }

    private func stopDictation() {
        dictationService.stopRecognition()
        isDictating = false

        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await polishDictatedText()
            }
        }
    }

    private func polishDictatedText() async {
        let rawText = text
        rawDictationText = rawText
        isPolishing = true

        do {
            let polished = try await NoteAnalysisService.shared.polishDictation(rawText: rawText)
            text = polished
        } catch {
            logger.debug("Dictation polish unavailable: \(error.localizedDescription)")
        }

        isPolishing = false
    }

    // MARK: - Save

    private func saveAndComplete() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSaving = true

        let sourceType: SamNote.SourceType = usedDictation ? .dictated : .typed
        var linkedPeopleIDs: [UUID] = []
        if let pid = payload.personID {
            linkedPeopleIDs.append(pid)
        }
        var linkedEvidenceIDs: [UUID] = []
        if let eid = payload.evidenceID {
            linkedEvidenceIDs.append(eid)
        }

        do {
            let note = try repository.create(
                content: content,
                sourceType: sourceType,
                linkedPeopleIDs: linkedPeopleIDs,
                linkedEvidenceIDs: linkedEvidenceIDs
            )

            // Auto-link to recent meeting if no explicit evidence
            if payload.evidenceID == nil, let personID = payload.personID {
                if let meeting = evidenceRepository.findRecentMeeting(forPersonID: personID) {
                    try? repository.updateLinks(note: note, evidenceIDs: [meeting.id])
                }
            }

            // Mark the outcome as completed
            try? outcomeRepo.markCompleted(id: payload.outcomeID)

            logger.info("Quick note saved and outcome \(payload.outcomeID) completed")

            // Background analysis
            Task {
                await coordinator.analyzeNote(note)
            }

            dismiss()

        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            logger.error("Quick note save failed: \(error)")
            isSaving = false
        }
    }
}
