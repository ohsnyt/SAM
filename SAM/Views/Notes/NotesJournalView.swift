//
//  NotesJournalView.swift
//  SAM
//
//  Phase L-2: Scrollable inline journal view for notes with in-place editing.
//

import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
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
    @State private var dictationService = DictationService.shared

    // MARK: - State

    @State private var editingNoteID: UUID?
    @State private var editText = ""
    @State private var isSaving = false
    @State private var expandedNoteIDs: Set<UUID> = []
    @State private var editHandle = RichNoteEditorHandle()

    // Dictation state
    @State private var isDictating = false
    @State private var isPolishing = false
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0

    // Unsaved changes warning
    @State private var showUnsavedAlert = false
    @State private var pendingNoteToSave: SamNote?

    // MARK: - Body

    var body: some View {
        if notes.isEmpty {
            Text("No notes yet")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            if index > 0 {
                                Divider()
                                    .padding(.vertical, 4)
                            }

                            noteCell(note)
                                .id(note.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: editingNoteID) { _, newID in
                    // Scroll editing note into view after layout settles
                    if let id = newID {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: notes.map(\.id)) { _, _ in
                    // Clear stale expanded state when notes change (e.g. switching people)
                    expandedNoteIDs.removeAll()
                    if editingNoteID != nil {
                        // Warn user about unsaved changes before clearing edit
                        if let noteID = editingNoteID,
                           let note = notes.first(where: { $0.id == noteID }) {
                            pendingNoteToSave = note
                            showUnsavedAlert = true
                        } else {
                            editingNoteID = nil
                        }
                    }
                }
                .alert("Unsaved Changes", isPresented: $showUnsavedAlert) {
                    Button("Save") {
                        if let note = pendingNoteToSave {
                            saveEdit(note: note)
                        }
                        pendingNoteToSave = nil
                    }
                    Button("Discard", role: .destructive) {
                        editingNoteID = nil
                        editText = ""
                        pendingNoteToSave = nil
                    }
                    Button("Cancel", role: .cancel) {
                        pendingNoteToSave = nil
                    }
                } message: {
                    Text("You have unsaved changes to this note. Would you like to save them?")
                }
            }
        }
    }

    // MARK: - Note Cell

    @ViewBuilder
    private func noteCell(_ note: SamNote) -> some View {
        let isEditing = editingNoteID == note.id
        let imageCount = note.images.count

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

                if imageCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "photo")
                            .font(.caption2)
                        Text("\(imageCount)")
                            .font(.caption2)
                    }
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

                // Edit button (hidden during editing — click outside to save)
                if !isEditing {
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

            // Content: rich text editor with inline images
            if isEditing {
                RichNoteEditor(
                    plainText: $editText,
                    existingImages: note.images
                        .sorted(by: { $0.displayOrder < $1.displayOrder })
                        .compactMap { img in
                            guard let data = img.imageData else { return nil }
                            return (data, img.mimeType, img.textInsertionPoint ?? Int.max)
                        },
                    handle: editHandle,
                    onSave: { saveEdit(note: note) },
                    onCancel: { cancelEdit() }
                )
                .frame(minHeight: 200, maxHeight: 500)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )

                // Toolbar: attach + dictate + hints
                HStack(spacing: 8) {
                    // Attach image
                    Button {
                        attachImage()
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Attach image from file")

                    // Mic button
                    Button {
                        if isDictating {
                            stopDictation(for: note)
                        } else {
                            startDictation(for: note)
                        }
                    } label: {
                        Image(systemName: isDictating ? "mic.fill" : "mic")
                            .font(.body)
                            .foregroundStyle(isDictating ? .red : .secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(isDictating ? "Stop dictation" : "Start dictation")
                    .overlay {
                        if isDictating {
                            Circle()
                                .stroke(.red.opacity(0.5), lineWidth: 2)
                                .frame(width: 24, height: 24)
                                .scaleEffect(isDictating ? 1.3 : 1.0)
                                .opacity(isDictating ? 0 : 1)
                                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: false), value: isDictating)
                        }
                    }

                    if isPolishing {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Polishing...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Cancel") {
                        cancelEdit()
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Button("Save") {
                        saveEdit(note: note)
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                }
            } else {
                let isExpanded = expandedNoteIDs.contains(note.id)

                // Collapsed: 2-line preview (click to expand, double-click to edit)
                if !isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.content)
                            .lineLimit(2)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if note.content.count > 100 || imageCount > 0 {
                            Text(imageCount == 0 ? "Show more" : "Show more (\(imageCount) image\(imageCount == 1 ? "" : "s"))")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        ExclusiveGesture(
                            TapGesture(count: 2),
                            TapGesture(count: 1)
                        )
                        .onEnded { gesture in
                            switch gesture {
                            case .first:
                                // Double-click: expand + edit
                                _ = expandedNoteIDs.insert(note.id)
                                beginEditing(note: note)
                            case .second:
                                // Single click: expand
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    _ = expandedNoteIDs.insert(note.id)
                                }
                            }
                        }
                    )
                }

                // Expanded: inline content with images interleaved
                if isExpanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            _ = expandedNoteIDs.remove(note.id)
                        }
                    } label: {
                        Text("Show less")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)

                    inlineContent(note)

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

                // Follow-up draft card
                followUpDraftCard(note)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .task(id: note.id) {
            // Diagnostic logging — runs async, not during layout
            if imageCount > 0 {
                let withData = note.images.filter { $0.imageData != nil }.count
                logger.info("Note '\(note.content.prefix(40))': \(imageCount) image(s), \(withData) with data, \(imageCount - withData) nil data")
            }
        }
    }

    // MARK: - Follow-Up Draft Card

    @ViewBuilder
    private func followUpDraftCard(_ note: SamNote) -> some View {
        if let draft = note.followUpDraft, !draft.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                        .font(.caption)
                        .foregroundStyle(.teal)
                    Text("Suggested Follow-up")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.teal)
                    Spacer()
                    CopyButton(text: draft)
                    Button {
                        note.followUpDraft = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss suggestion")
                }

                Text(draft)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(.teal.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Inline Content (text + images interleaved)

    /// Renders note text with images placed inline at their insertion points.
    @ViewBuilder
    private func inlineContent(_ note: SamNote) -> some View {
        let images = note.images.sorted(by: { ($0.textInsertionPoint ?? Int.max) < ($1.textInsertionPoint ?? Int.max) })
        let content = note.content

        if images.isEmpty {
            // No images — simple text display
            Text(content)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            // Split text at image insertion points and interleave
            let segments = buildInlineSegments(content: content, images: images)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let str):
                        if !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(str)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    case .image(let noteImage):
                        if let data = noteImage.imageData, let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: min(nsImage.size.width, 600))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .onTapGesture(count: 2) {
                                    copyImageToClipboard(nsImage)
                                }
                                .help("Double-click to copy")
                        } else {
                            // Visible placeholder so missing images are obvious
                            HStack(spacing: 6) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.title3)
                                Text("Image failed to load (\(noteImage.mimeType))")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
    }

    /// Content segment: either a text chunk or an inline image.
    private enum InlineSegment {
        case text(String)
        case image(NoteImage)
    }

    /// Splits note content at image insertion points to produce interleaved segments.
    private func buildInlineSegments(content: String, images: [NoteImage]) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var lastOffset = 0

        for noteImage in images {
            let insertAt = min(noteImage.textInsertionPoint ?? Int.max, content.count)

            // Add text before this image
            if insertAt > lastOffset {
                let startIdx = content.index(content.startIndex, offsetBy: lastOffset)
                let endIdx = content.index(content.startIndex, offsetBy: insertAt)
                segments.append(.text(String(content[startIdx..<endIdx])))
            }

            segments.append(.image(noteImage))
            lastOffset = insertAt
        }

        // Remaining text after last image
        if lastOffset < content.count {
            let startIdx = content.index(content.startIndex, offsetBy: lastOffset)
            segments.append(.text(String(content[startIdx...])))
        }

        return segments
    }

    private func copyImageToClipboard(_ nsImage: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    // MARK: - Editing

    private func beginEditing(note: SamNote) {
        editingNoteID = note.id
        editText = note.content
    }

    private func cancelEdit() {
        if isDictating {
            dictationService.stopRecognition()
            isDictating = false
        }
        editingNoteID = nil
        editText = ""
    }

    private func saveEdit(note: SamNote) {
        // Guard against deferred onCommit after cancel/navigation
        guard editingNoteID == note.id else { return }

        let (rawText, extractedImages) = editHandle.extractContent()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Delete note if all content was removed
        if trimmed.isEmpty && extractedImages.isEmpty {
            do {
                try repository.delete(note: note)
            } catch {
                logger.error("Failed to delete note: \(error)")
            }
            editingNoteID = nil
            editText = ""
            onUpdated()
            return
        }

        // No changes — just exit editing
        guard trimmed != note.content || !extractedImages.isEmpty else {
            editingNoteID = nil
            editText = ""
            return
        }

        isSaving = true

        do {
            try repository.update(note: note, content: trimmed)

            // Replace images with current set from editor
            let context = note.modelContext
            for oldImage in note.images {
                context?.delete(oldImage)
            }
            note.images.removeAll()
            try context?.save()

            if !extractedImages.isEmpty {
                try repository.addImages(to: note, images: extractedImages)
            }

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

    // MARK: - Attach Image

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
            editHandle.insertImage(data: data, mimeType: mime)
        }
    }

    // MARK: - Dictation

    private func startDictation(for note: SamNote) {
        let availability = dictationService.checkAvailability()

        switch availability {
        case .available:
            break
        case .notAuthorized:
            Task {
                let granted = await dictationService.requestAuthorization()
                guard granted else { return }
                beginDictationStream(for: note)
            }
            return
        case .notAvailable, .restricted:
            return
        }

        beginDictationStream(for: note)
    }

    private func beginDictationStream(for note: SamNote) {
        isDictating = true
        accumulatedSegments = []
        lastSegmentPeakLength = 0

        // Preserve existing editor text as the first segment
        let existingText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingText.isEmpty {
            accumulatedSegments.append(existingText)
        }

        Task {
            do {
                let stream = try await dictationService.startRecognition()
                for await result in stream {
                    let currentText = result.text

                    // Detect recognizer reset
                    if currentText.count < lastSegmentPeakLength / 2 && lastSegmentPeakLength > 5 {
                        let previousSegment = extractCurrentDictationSegment()
                        if !previousSegment.isEmpty {
                            accumulatedSegments.append(previousSegment)
                        }
                        lastSegmentPeakLength = 0
                    }

                    lastSegmentPeakLength = max(lastSegmentPeakLength, currentText.count)

                    let prefix = accumulatedSegments.joined(separator: " ")
                    editText = prefix.isEmpty ? currentText : "\(prefix) \(currentText)"

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
                if !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await polishDictatedText()
                }
            } catch {
                logger.error("Dictation error: \(error.localizedDescription)")
                isDictating = false
            }
        }
    }

    private func extractCurrentDictationSegment() -> String {
        let prefix = accumulatedSegments.joined(separator: " ")
        if prefix.isEmpty {
            return editText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let full = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }

    private func stopDictation(for note: SamNote) {
        dictationService.stopRecognition()
        isDictating = false

        if !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                await polishDictatedText()
            }
        }
    }

    private func polishDictatedText() async {
        isPolishing = true
        do {
            let polished = try await NoteAnalysisService.shared.polishDictation(rawText: editText)
            editText = polished
        } catch {
            logger.debug("Dictation polish unavailable: \(error.localizedDescription)")
        }
        isPolishing = false
    }
}
