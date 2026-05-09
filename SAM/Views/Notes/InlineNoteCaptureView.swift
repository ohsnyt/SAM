//
//  InlineNoteCaptureView.swift
//  SAM
//
//  Phase L-2: Lightweight inline note capture for PersonDetailView and ContextDetailView
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TipKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "InlineNoteCaptureView")

/// Reusable inline note capture widget — always visible above note lists.
///
/// Shows a RichNoteEditor (inline images) with mic button and Save action.
/// After save: clears editor, fires background analysis, calls `onSaved`.
struct InlineNoteCaptureView: View {

    // MARK: - Parameters

    let linkedPerson: SamPerson?
    let linkedContext: SamContext?
    let onSaved: () -> Void
    /// Additional people IDs to link (for multi-attendee contexts like meeting follow-ups).
    /// When non-empty, overrides linkedPerson for note linking.
    var linkedPeopleIDs: [UUID] = []
    /// When true, the editor starts expanded (skips collapsed bar).
    var initiallyExpanded: Bool = false

    // MARK: - Dependencies

    @State private var repository = NotesRepository.shared
    @State private var coordinator = NoteAnalysisCoordinator.shared
    @State private var dictationService = DictationService.shared
    @State private var evidenceRepository = EvidenceRepository.shared

    // MARK: - State

    @State private var isEditing = false
    @State private var text = ""
    @State private var isDictating = false
    @State private var isPolishing = false
    @State private var rawDictationText: String?
    @State private var showSavedConfirmation = false
    @State private var autoLinkedTitle: String?
    @State private var errorMessage: String?
    @State private var usedDictation = false
    @State private var editorHandle = RichNoteEditorHandle()

    // Accumulate text across recognizer resets (on-device recognizer resets after pauses)
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0

    // LinkedIn PDF drop
    @State private var isPDFDropTargeted = false
    @State private var photoCoordinator = ContactPhotoCoordinator.shared

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TipView(AddNoteTip())
                .tipViewStyle(SAMTipViewStyle())

            if isEditing {
                expandedEditor
            } else {
                collapsedBar
            }

            // Status indicators (below both states)
            statusIndicators
        }
        .onAppear {
            if initiallyExpanded { isEditing = true }
        }
        .confirmationDialog(
            "Name Mismatch",
            isPresented: Binding(
                get: { photoCoordinator.pendingLinkedInImport != nil },
                set: { if !$0 { photoCoordinator.cancelPendingLinkedInImport() } }
            ),
            presenting: photoCoordinator.pendingLinkedInImport
        ) { pending in
            Button("Import Anyway") {
                Task {
                    await photoCoordinator.confirmPendingLinkedInImport()
                    onSaved()
                }
            }
            Button("Cancel", role: .cancel) {
                photoCoordinator.cancelPendingLinkedInImport()
            }
        } message: { pending in
            Text("This PDF is for \"\(pending.profileName)\" but you're viewing \"\(pending.personName)\". Import anyway?")
        }
        .dismissOnLock(isPresented: Binding(
            get: { photoCoordinator.pendingLinkedInImport != nil },
            set: { if !$0 { photoCoordinator.cancelPendingLinkedInImport() } }
        ))
    }

    // MARK: - Collapsed Bar

    private var collapsedBar: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                isEditing = true
            }
            // Focus the editor after SwiftUI inserts it
            Task { try? await Task.sleep(for: .milliseconds(250)); editorHandle.focus() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .samFont(.body)
                    .foregroundStyle(.secondary)
                Text("Add a note…")
                    .samFont(.body)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .overlay {
            if isPDFDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.fill")
                                .samFont(.body)
                            Text("Import LinkedIn Profile")
                                .samFont(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.blue)
                    }
            }
        }
        .overlay {
            if let msg = photoCoordinator.linkedInImportMessage {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.green.opacity(0.12))
                    .overlay {
                        Text(msg)
                            .samFont(.caption)
                            .foregroundStyle(.green)
                    }
            }
        }
        .animation(.default, value: isPDFDropTargeted)
        .animation(.default, value: photoCoordinator.linkedInImportMessage != nil)
        .onDrop(of: [.pdf], isTargeted: $isPDFDropTargeted) { providers in
            guard let person = linkedPerson,
                  let provider = providers.first,
                  provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
                Task { @MainActor in
                    if let data {
                        await photoCoordinator.handleLinkedInPDFDrop(data: data, for: person)
                        onSaved() // refresh notes list
                    }
                }
            }
            return true
        }
    }

    // MARK: - Expanded Editor

    private var expandedEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Editor area
            RichNoteEditor(plainText: $text, existingImages: [], handle: editorHandle)
                .frame(minHeight: 150, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && !isDictating {
                        Text("Type a note…")
                            .samFont(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }

            // Toolbar
            HStack(spacing: 8) {
                // Attach image button
                Button {
                    attachImage()
                } label: {
                    Image(systemName: "paperclip")
                        .samFont(.body)
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
                        FeatureAdoptionTracker.shared.recordUsage(.dictation)
                        startDictation()
                    }
                } label: {
                    Image(systemName: isDictating ? "mic.fill" : "mic")
                        .samFont(.body)
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

                // Cancel button
                Button("Cancel") {
                    cancelEditing()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Save button
                Button("Save") {
                    saveNote()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Status Indicators

    @ViewBuilder
    private var statusIndicators: some View {
        if isPolishing {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Polishing dictation...")
                    .samFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if let raw = rawDictationText, raw != text {
            Button {
                text = raw
                rawDictationText = nil
            } label: {
                Label("Undo polish", systemImage: "arrow.uturn.backward")
                    .samFont(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }

        if showSavedConfirmation {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .samFont(.caption)
                Text("Saved")
                    .samFont(.caption)
                    .foregroundStyle(.green)
                if let title = autoLinkedTitle {
                    Text("• Linked to: \(title)")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }

        if let error = errorMessage {
            Text(error)
                .samFont(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Cancel

    private func cancelEditing() {
        if isDictating {
            dictationService.stopRecognition()
            isDictating = false
        }
        text = ""
        editorHandle.clear()
        rawDictationText = nil
        usedDictation = false
        errorMessage = nil
        withAnimation(.easeIn(duration: 0.2)) {
            isEditing = false
        }
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
        let (rawText, extractedImages) = editorHandle.extractContent()
        let content = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        let sourceType: SamNote.SourceType = usedDictation ? .dictated : .typed

        do {
            let peopleIDs = linkedPeopleIDs.isEmpty
                ? (linkedPerson.map { [$0.id] } ?? [])
                : linkedPeopleIDs

            let note = try repository.create(
                content: content,
                sourceType: sourceType,
                linkedPeopleIDs: peopleIDs,
                linkedContextIDs: linkedContext.map { [$0.id] } ?? []
            )

            // Save extracted inline images
            if !extractedImages.isEmpty {
                try repository.addImages(to: note, images: extractedImages)
            }

            // Auto-link to recent meeting
            let autoLinkPersonID = linkedPerson?.id ?? linkedPeopleIDs.first
            if let personID = autoLinkPersonID {
                autoLinkToRecentMeeting(note: note, personID: personID)
            }

            // Reset state and collapse
            text = ""
            editorHandle.clear()
            rawDictationText = nil
            usedDictation = false
            errorMessage = nil
            withAnimation(.easeIn(duration: 0.2)) {
                isEditing = false
            }

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
