//
//  InlineNoteCaptureView.swift
//  SAM
//
//  Phase L-2: Lightweight inline note capture for PersonDetailView and ContextDetailView
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "InlineNoteCaptureView")

/// Reusable inline note capture widget — always visible above note lists.
///
/// Shows a compact TextEditor with mic button and Save action.
/// After save: clears text, fires background analysis, calls `onSaved`.
struct InlineNoteCaptureView: View {

    // MARK: - Parameters

    let linkedPerson: SamPerson?
    let linkedContext: SamContext?
    let onSaved: () -> Void

    // MARK: - Dependencies

    @State private var repository = NotesRepository.shared
    @State private var coordinator = NoteAnalysisCoordinator.shared
    @State private var dictationService = DictationService.shared
    @State private var evidenceRepository = EvidenceRepository.shared

    // MARK: - State

    @State private var text = ""
    @State private var isDictating = false
    @State private var isPolishing = false
    @State private var rawDictationText: String?
    @State private var showSavedConfirmation = false
    @State private var autoLinkedTitle: String?
    @State private var errorMessage: String?
    @State private var usedDictation = false

    // Accumulate text across recognizer resets (on-device recognizer resets after pauses)
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                // Text editor
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 36, maxHeight: 80)
                    .padding(6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty && !isDictating {
                            Text("Type a note...")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }

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

                // Save button
                Button("Save") {
                    saveNote()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

            if showSavedConfirmation {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.green)
                    if let title = autoLinkedTitle {
                        Text("• Linked to: \(title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
                        // Save the previous segment's peak text (already in `text`)
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

    /// Extract the current segment text (everything after accumulated prefix)
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

        // Polish after stop
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
            // Keep raw text — graceful degradation
            logger.debug("Dictation polish unavailable: \(error.localizedDescription)")
        }

        isPolishing = false
    }

    // MARK: - Save

    private func saveNote() {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        let sourceType: SamNote.SourceType = usedDictation ? .dictated : .typed

        do {
            let note = try repository.create(
                content: content,
                sourceType: sourceType,
                linkedPeopleIDs: linkedPerson.map { [$0.id] } ?? [],
                linkedContextIDs: linkedContext.map { [$0.id] } ?? []
            )

            // Auto-link to recent meeting
            if let person = linkedPerson {
                autoLinkToRecentMeeting(note: note, personID: person.id)
            }

            // Reset state
            text = ""
            rawDictationText = nil
            usedDictation = false
            errorMessage = nil

            // Show confirmation
            withAnimation {
                showSavedConfirmation = true
            }

            // Hide confirmation after 3 seconds
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation {
                    showSavedConfirmation = false
                    autoLinkedTitle = nil
                }
            }

            onSaved()

            // Background analysis
            Task {
                await coordinator.analyzeNote(note)
            }

        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            logger.error("Note save failed: \(error)")
        }
    }

    private func autoLinkToRecentMeeting(note: SamNote, personID: UUID) {
        if let meeting = evidenceRepository.findRecentMeeting(forPersonID: personID) {
            do {
                try repository.updateLinks(
                    note: note,
                    evidenceIDs: [meeting.id]
                )
                autoLinkedTitle = meeting.title
            } catch {
                logger.debug("Auto-link failed: \(error.localizedDescription)")
            }
        }
    }
}
