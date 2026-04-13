//
//  TranscriptionReviewView.swift
//  SAM
//
//  Post-session review for a TranscriptSession. Users can:
//    - Scroll through labeled segments
//    - Edit segment text inline
//    - Change speaker labels (rename Agent/Client/Spouse/etc.)
//    - Link a cluster to a SamPerson
//    - Save the transcript as a SamNote + SamEvidenceItem (M6)
//

import SwiftUI
import SwiftData

struct TranscriptionReviewView: View {
    let session: TranscriptSession

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var speakerLabels: [Int: String] = [:]  // clusterID → label
    @State private var speakerPeople: [Int: SamPerson] = [:] // clusterID → linked person
    @State private var showPersonPicker: Bool = false
    @State private var pickerTargetCluster: Int?
    @State private var isSaving: Bool = false
    @State private var saveError: String?
    @State private var savedAsNote: Bool = false
    @State private var confirmDelete: Bool = false

    @Query(sort: \SamPerson.displayName) private var allPeople: [SamPerson]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if savedAsNote {
                savedConfirmation
            } else {
                HSplitView {
                    transcriptPane
                        .frame(minWidth: 500)

                    speakerPanel
                        .frame(minWidth: 260, idealWidth: 300)
                }
            }
        }
        // Give the review sheet a real size — default SwiftUI sheet sizing
        // shrinks to fit content which made this unusable at small heights.
        .frame(
            minWidth: 900, idealWidth: 1100, maxWidth: .infinity,
            minHeight: 600, idealHeight: 760, maxHeight: .infinity
        )
        .onAppear { loadInitialState() }
        .sheet(isPresented: $showPersonPicker) {
            personPickerSheet
        }
        .alert("Save Failed", isPresented: Binding(get: { saveError != nil }, set: { _ in saveError = nil })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Transcript")
                    .font(.title2.bold())
                HStack(spacing: 8) {
                    Text(session.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(formatDuration(session.durationSeconds))
                    Text("·")
                    Text("\(session.sortedSegments.count) segments")
                    if let lang = session.detectedLanguage {
                        Text("·")
                        Text(lang.uppercased())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)

            Button("Close") { dismiss() }
                .buttonStyle(.bordered)

            // "Looks Good" is the single primary action: saves the note,
            // triggers analysis, AND signs off (starts the retention
            // timer). Sarah's mental model is "I've reviewed this, use it."
            if session.signedOffAt != nil {
                // Already approved — show a green badge, no action needed.
                Label {
                    Text("Saved")
                        .font(.caption)
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.12), in: Capsule())
            } else {
                Button {
                    Task { await saveAndSignOff() }
                } label: {
                    if isSaving {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Saving…")
                        }
                    } else {
                        Label("Looks Good", systemImage: "checkmark.seal")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding()
        .confirmationDialog(
            "Delete this recording?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                performDelete()
            }
            Button("Cancel", role: .cancel) {
                confirmDelete = false
            }
        } message: {
            Text("This permanently removes the transcript, summary, and all related notes. Linked contacts are not affected.")
        }
    }

    // MARK: - Delete

    private func performDelete() {
        // Delete the audio file on disk if present
        if let relativePath = session.audioFilePath {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let audioURL = appSupport.appendingPathComponent(relativePath)
            try? FileManager.default.removeItem(at: audioURL)
        }

        // Clean up linked SamNote + SamEvidenceItem — they were auto-created
        // by the session and would be orphaned without this.
        if let note = session.linkedNote {
            for evidence in note.linkedEvidence {
                modelContext.delete(evidence)
            }
            modelContext.delete(note)
        }

        // Delete the session itself. TranscriptSegments cascade automatically.
        modelContext.delete(session)

        do {
            try modelContext.save()
        } catch {
            // Non-fatal — SwiftData rolls back on next access
        }

        confirmDelete = false
        dismiss()
    }

    // MARK: - Paragraph Grouping

    /// A run of consecutive segments from the same speaker, displayed as a
    /// single paragraph with one timestamp + one speaker label. Each paragraph
    /// remembers its underlying segments so editing writes back correctly.
    private struct TranscriptParagraph: Identifiable {
        let id: UUID // first segment's id, stable across renders
        let segments: [TranscriptSegment]
        let speakerClusterID: Int
        let speakerLabel: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let hasLowConfidenceSegment: Bool

        var joinedText: String {
            segments
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    /// Build paragraphs from sorted segments. A paragraph boundary is any
    /// speaker change OR a pause longer than 8 seconds (so long silences
    /// from the same speaker still get broken up naturally).
    private var paragraphs: [TranscriptParagraph] {
        let sorted = session.sortedSegments
        guard !sorted.isEmpty else { return [] }

        let maxGap: TimeInterval = 8.0
        var result: [TranscriptParagraph] = []
        var currentSegments: [TranscriptSegment] = []

        func flush() {
            guard let first = currentSegments.first else { return }
            let last = currentSegments.last!
            let anyLowConfidence = currentSegments.contains(where: { $0.speakerConfidence < 0.4 })
            result.append(
                TranscriptParagraph(
                    id: first.id,
                    segments: currentSegments,
                    speakerClusterID: first.speakerClusterID,
                    speakerLabel: first.speakerLabel,
                    startTime: first.startTime,
                    endTime: last.endTime,
                    hasLowConfidenceSegment: anyLowConfidence
                )
            )
            currentSegments.removeAll()
        }

        for segment in sorted {
            if let last = currentSegments.last {
                let gap = segment.startTime - last.endTime
                let sameSpeaker = segment.speakerClusterID == last.speakerClusterID
                if !sameSpeaker || gap > maxGap {
                    flush()
                }
            }
            currentSegments.append(segment)
        }
        flush()

        return result
    }

    // MARK: - Transcript Pane

    private var transcriptPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                // Meeting summary at the top — the actionable output Sarah
                // reads first before scrolling down into the full transcript.
                meetingSummarySection

                // Show the polished transcript when SAM has generated one.
                // Fall back to raw paragraphs if polish hasn't run yet or
                // failed. "Show raw segments" toggle lets users verify the
                // polish didn't drop anything.
                if let polished = session.polishedText, !polished.isEmpty {
                    polishedTranscriptSection(polished)
                } else {
                    ForEach(paragraphs) { paragraph in
                        paragraphRow(paragraph)
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Meeting Summary Section

    @ViewBuilder
    private var meetingSummarySection: some View {
        if let json = session.meetingSummaryJSON,
           let summary = MeetingSummary.from(jsonString: json),
           summary.hasContent {

            VStack(alignment: .leading, spacing: 12) {
                // TLDR
                if !summary.tldr.isEmpty {
                    Text("Summary: \(summary.tldr)")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Topics as inline tags
                if !summary.topics.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(summary.topics, id: \.self) { topic in
                            Text(topic)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.1), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                }

                // Compliance flags — shown first and prominently if present
                if !summary.complianceFlags.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Compliance Review Needed", systemImage: "exclamationmark.shield.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        ForEach(summary.complianceFlags, id: \.self) { flag in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                Text(flag)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                // Action items
                if !summary.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Action Items", systemImage: "checkmark.circle")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "circle")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.task)
                                        .font(.callout)
                                    HStack(spacing: 8) {
                                        if let owner = item.owner, !owner.isEmpty {
                                            Label(owner, systemImage: "person")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let due = item.dueDate, !due.isEmpty {
                                            Label(due, systemImage: "calendar")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Decisions
                if !summary.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Decisions", systemImage: "checkmark.seal")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(summary.decisions, id: \.self) { decision in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                    .padding(.top, 2)
                                Text(decision)
                                    .font(.callout)
                            }
                        }
                    }
                }

                // Follow-ups
                if !summary.followUps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Follow-ups", systemImage: "person.2")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(Array(summary.followUps.enumerated()), id: \.offset) { _, followUp in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(followUp.person)
                                        .font(.callout.bold())
                                    Text(followUp.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Life events
                if !summary.lifeEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Life Events", systemImage: "heart")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(summary.lifeEvents, id: \.self) { event in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.pink)
                                Text(event)
                                    .font(.callout)
                            }
                        }
                    }
                }

                // Open questions
                if !summary.openQuestions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Open Questions", systemImage: "questionmark.circle")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(summary.openQuestions, id: \.self) { question in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                                Text(question)
                                    .font(.callout)
                            }
                        }
                    }
                }

                // Sentiment
                if let sentiment = summary.sentiment, !sentiment.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "face.smiling")
                            .font(.caption2)
                        Text("Tone: \(sentiment)")
                            .font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )

            Divider()
                .padding(.vertical, 4)
        }
    }

    /// Simple horizontal wrapping layout for topic tags.
    private struct FlowLayout: Layout {
        var spacing: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let result = layout(in: proposal.width ?? 0, subviews: subviews)
            return result.size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let result = layout(in: bounds.width, subviews: subviews)
            for (index, position) in result.positions.enumerated() where index < subviews.count {
                subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
            }
        }

        private func layout(in maxWidth: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
            var positions: [CGPoint] = []
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            var maxX: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
                maxX = max(maxX, x)
            }

            return (CGSize(width: maxX, height: y + rowHeight), positions)
        }
    }

    /// Display the polished transcript with inline diff highlights showing
    /// what the AI changed from the raw Whisper output. Changed words get
    /// a subtle blue background; hovering shows the original raw text.
    /// The polished text is directly editable — click to edit any paragraph.
    @ViewBuilder
    private func polishedTranscriptSection(_ polished: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label("Transcript", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))

                if let polishedAt = session.polishedAt {
                    Text("· \(polishedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if session.polishedEditedByUser {
                    Label("Edited", systemImage: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("Click text to edit")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }

            // Compute diff paragraphs between raw segments and polished text
            let diffParagraphs = TranscriptDiffService.diff(
                rawSegments: session.sortedSegments,
                polishedText: polished
            )

            ForEach(diffParagraphs) { diffParagraph in
                polishedDiffParagraphRow(diffParagraph)
            }
        }
    }

    /// State for editing a specific paragraph inline.
    @State private var editingPolishedParagraphIndex: Int?
    @State private var polishedEditDraft: String = ""

    @ViewBuilder
    private func polishedDiffParagraphRow(_ diffParagraph: DiffParagraph) -> some View {
        let clusterID = clusterIDForSpeaker(diffParagraph.speakerLabel)

        VStack(alignment: .leading, spacing: 6) {
            if !diffParagraph.speakerLabel.isEmpty {
                HStack(spacing: 8) {
                    Text(diffParagraph.speakerLabel)
                        .font(.caption.bold())
                        .foregroundStyle(speakerColor(for: clusterID))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(speakerColor(for: clusterID).opacity(0.15))
                        )
                    Spacer()
                }
            }

            // Editable text with diff highlights
            if editingPolishedParagraphIndex == diffParagraph.id.hashValue {
                // Editing mode: plain TextEditor
                TextEditor(text: $polishedEditDraft)
                    .font(.body)
                    .frame(minHeight: 60)
                    .padding(4)
                    .background(Color.blue.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )

                HStack {
                    Spacer()
                    Button("Cancel") {
                        editingPolishedParagraphIndex = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Save") {
                        commitPolishedEdit(
                            paragraphID: diffParagraph.id,
                            speakerLabel: diffParagraph.speakerLabel,
                            newText: polishedEditDraft
                        )
                        editingPolishedParagraphIndex = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                // Display mode: diff-highlighted text with click-to-edit
                diffHighlightedText(diffParagraph.words)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Enter edit mode for this paragraph
                        let plainText = diffParagraph.words.map(\.text).joined(separator: " ")
                        polishedEditDraft = plainText
                        editingPolishedParagraphIndex = diffParagraph.id.hashValue
                    }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// Render diff-highlighted text. Changed words get a subtle blue background.
    /// On hover, a tooltip shows the original raw text.
    private func diffHighlightedText(_ words: [DiffWord]) -> some View {
        let parts: [AttributedString] = words.map { word in
            var attr = AttributedString(word.text + " ")
            if word.isChanged {
                attr.backgroundColor = Color.blue.opacity(0.12)
            }
            return attr
        }
        let combined = parts.reduce(AttributedString(), +)

        // For the hover tooltips, we use a custom view that wraps each word
        // individually. But AttributedString + Text is simpler for basic
        // display. Use Text for now; hover tooltips can be added when
        // NSView interop is implemented.
        return Text(combined)
            .textSelection(.enabled)
    }

    /// Commit a user edit to the polished text. Updates the full
    /// `session.polishedText` by replacing the edited paragraph's content
    /// and marks `polishedEditedByUser = true`.
    private func commitPolishedEdit(
        paragraphID: UUID,
        speakerLabel: String,
        newText: String
    ) {
        guard var polished = session.polishedText else { return }

        // Parse existing paragraphs, find the one that was edited, rebuild
        let blocks = polished.components(separatedBy: "\n\n")
        var newBlocks: [String] = []

        // Find the paragraph by matching speaker label and approximate
        // position. Since we only allow editing one paragraph at a time,
        // we use the edit draft to identify which block changed.
        var found = false
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if !found, trimmed.hasPrefix(speakerLabel + ":") {
                // Replace this paragraph's text
                if speakerLabel.isEmpty {
                    newBlocks.append(newText)
                } else {
                    newBlocks.append("\(speakerLabel): \(newText)")
                }
                found = true
            } else {
                newBlocks.append(trimmed)
            }
        }

        if !found {
            // Fallback: append as new paragraph
            if speakerLabel.isEmpty {
                newBlocks.append(newText)
            } else {
                newBlocks.append("\(speakerLabel): \(newText)")
            }
        }

        session.polishedText = newBlocks.joined(separator: "\n\n")
        session.polishedEditedByUser = true
        try? modelContext.save()
    }

    /// Look up the cluster ID for a speaker label string.
    private func clusterIDForSpeaker(_ label: String) -> Int {
        // Check in-session edits first
        for (cluster, editedLabel) in speakerLabels {
            if editedLabel == label { return cluster }
        }
        // Check raw segments
        for segment in session.sortedSegments {
            if segment.speakerLabel == label { return segment.speakerClusterID }
        }
        return 0
    }

    /// Identifies a paragraph for the in-place editor. We edit the whole
    /// paragraph's joined text at once; on commit we write it back to the
    /// FIRST segment and blank out the rest (keeping their timestamps intact
    /// so word-timing data for the block isn't lost entirely).
    @State private var editingParagraphID: UUID?
    @State private var paragraphDrafts: [UUID: String] = [:]

    @ViewBuilder
    private func paragraphRow(_ paragraph: TranscriptParagraph) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: speaker pill + start timestamp + confidence warning
            // + edit toggle. Shown ONCE per paragraph, not per segment.
            HStack(spacing: 8) {
                Text(displayLabel(forClusterID: paragraph.speakerClusterID,
                                  fallback: paragraph.speakerLabel))
                    .font(.caption.bold())
                    .foregroundStyle(speakerColor(for: paragraph.speakerClusterID))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(speakerColor(for: paragraph.speakerClusterID).opacity(0.15))
                    )

                Text(formatTimestamp(paragraph.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                if paragraph.hasLowConfidenceSegment {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Some segments in this paragraph have low speaker confidence — please verify")
                }

                Spacer()

                Button {
                    if editingParagraphID == paragraph.id {
                        commitParagraphEdit(paragraph)
                    } else {
                        editingParagraphID = paragraph.id
                        paragraphDrafts[paragraph.id] = paragraph.joinedText
                    }
                } label: {
                    Image(systemName: editingParagraphID == paragraph.id ? "checkmark.circle.fill" : "pencil")
                        .foregroundStyle(editingParagraphID == paragraph.id ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }

            if editingParagraphID == paragraph.id {
                TextEditor(text: Binding(
                    get: { paragraphDrafts[paragraph.id] ?? paragraph.joinedText },
                    set: { paragraphDrafts[paragraph.id] = $0 }
                ))
                .font(.body)
                .frame(minHeight: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
            } else {
                Text(paragraph.joinedText)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineSpacing(2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    // Commit a paragraph edit back to its underlying segments.
    // Strategy: write the new joined text to the first segment, clear all
    // subsequent segments' text. This preserves segment count + timestamps
    // (so word-level timings on other segments still line up for future
    // re-processing) while letting the user edit the paragraph as one block.
    private func commitParagraphEdit(_ paragraph: TranscriptParagraph) {
        if let draft = paragraphDrafts[paragraph.id] {
            let cleaned = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = paragraph.segments.first {
                first.text = cleaned
            }
            for segment in paragraph.segments.dropFirst() {
                segment.text = ""
            }
            try? modelContext.save()
        }
        editingParagraphID = nil
    }

    /// Display label for a cluster ID, consulting in-session speaker label
    /// edits made via the Speakers panel.
    private func displayLabel(forClusterID clusterID: Int, fallback: String) -> String {
        speakerLabels[clusterID] ?? fallback
    }

    // MARK: - Speaker Panel

    private var speakerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Speakers")
                .font(.headline)
                .padding()

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(uniqueClusterIDs, id: \.self) { clusterID in
                        speakerRow(clusterID: clusterID)
                    }
                }
                .padding()
            }
        }
    }

    private func speakerRow(clusterID: Int) -> some View {
        let segmentCount = session.sortedSegments.filter { $0.speakerClusterID == clusterID }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(speakerColor(for: clusterID))
                    .frame(width: 12, height: 12)

                TextField("Label", text: Binding(
                    get: { speakerLabels[clusterID] ?? "Speaker \(clusterID + 1)" },
                    set: { speakerLabels[clusterID] = $0 }
                ))
                .textFieldStyle(.roundedBorder)

                Text("\(segmentCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let person = speakerPeople[clusterID] {
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(.blue)
                    Text(person.displayName)
                        .font(.caption)
                    Spacer()
                    Button {
                        speakerPeople.removeValue(forKey: clusterID)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.1)))
            } else {
                Button {
                    pickerTargetCluster = clusterID
                    showPersonPicker = true
                } label: {
                    Label("Link to contact", systemImage: "person.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var uniqueClusterIDs: [Int] {
        Array(Set(session.sortedSegments.map(\.speakerClusterID))).sorted()
    }

    // MARK: - Person Picker Sheet

    private var personPickerSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Link Speaker to Contact")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    showPersonPicker = false
                    pickerTargetCluster = nil
                }
            }
            .padding()
            Divider()
            List(allPeople, id: \.persistentModelID) { person in
                Button {
                    if let cid = pickerTargetCluster {
                        speakerPeople[cid] = person
                        // Auto-fill label with person name
                        speakerLabels[cid] = person.displayName
                    }
                    showPersonPicker = false
                    pickerTargetCluster = nil
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text(person.displayName)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 360, minHeight: 480)
    }

    // MARK: - Saved Confirmation

    private var savedConfirmation: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Saved to SAM")
                .font(.title.bold())
            Text("The transcript is saved as a note in SAM and linked to everyone you mentioned. You can find it under each person's profile in People.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - State Loading

    private func loadInitialState() {
        // Populate speaker labels from first segment in each cluster
        var seen = Set<Int>()
        for segment in session.sortedSegments {
            if !seen.contains(segment.speakerClusterID) {
                speakerLabels[segment.speakerClusterID] = segment.speakerLabel
                seen.insert(segment.speakerClusterID)
            }
            if let person = segment.speakerPerson {
                speakerPeople[segment.speakerClusterID] = person
            }
        }
    }

    // MARK: - "Looks Good" — save + sign off in one action

    /// Combined save + sign-off. Creates (or updates) the SamNote, triggers
    /// NoteAnalysisCoordinator, AND sets signedOffAt so the retention timer
    /// starts. This is the single primary action in the review view.
    private func saveAndSignOff() async {
        await saveAsNote()

        // Sign off the session (starts the retention timer). Only runs if
        // save succeeded (savedAsNote is true). Idempotent via
        // RetentionService — calling on an already-signed session is a no-op.
        if savedAsNote {
            let container = modelContext.container
            _ = RetentionService.shared.signOff(session: session, container: container)
        }
    }

    private func saveAsNote() async {
        isSaving = true
        defer { isSaving = false }

        // 1. Commit any pending speaker label edits back to segments so the
        //    persisted transcript reflects the corrections the user made in
        //    this review session.
        for segment in session.sortedSegments {
            if let label = speakerLabels[segment.speakerClusterID], label != segment.speakerLabel {
                segment.speakerLabel = label
            }
            if let person = speakerPeople[segment.speakerClusterID] {
                segment.speakerPerson = person
            }
        }

        // 2. Build the formatted transcript text. Prefer the polished
        //    version if SAM has one; fall back to raw segments otherwise.
        //    Apply any in-review speaker label edits to the polished text
        //    by re-deriving labels from the (now-updated) segments.
        let transcriptText: String
        if let polished = session.polishedText, !polished.isEmpty {
            transcriptText = polished
        } else {
            transcriptText = session.sortedSegments.map { seg in
                let label = speakerLabels[seg.speakerClusterID] ?? seg.speakerLabel
                return "\(label): \(seg.text)"
            }.joined(separator: "\n\n")
        }

        let linkedPeople = Array(Set(speakerPeople.values))

        do {
            // 3. If handleSessionEnd already auto-created a SamNote for
            //    this session (the normal case), UPDATE it in place —
            //    don't create a duplicate. The auto-save happens on every
            //    session completion, so this path runs virtually always.
            if let existingNote = session.linkedNote {
                existingNote.content = transcriptText
                // Merge in any newly-linked people the user picked in
                // the review view, preserving any that were already there.
                var mergedPeople = existingNote.linkedPeople
                for person in linkedPeople where !mergedPeople.contains(where: { $0.persistentModelID == person.persistentModelID }) {
                    mergedPeople.append(person)
                }
                existingNote.linkedPeople = mergedPeople

                // Update the auto-created evidence item's snippet + people
                // so it reflects the polished text and current links.
                if let existingEvidence = existingNote.linkedEvidence.first {
                    existingEvidence.snippet = String(transcriptText.prefix(200))
                    var mergedEvidencePeople = existingEvidence.linkedPeople
                    for person in linkedPeople where !mergedEvidencePeople.contains(where: { $0.persistentModelID == person.persistentModelID }) {
                        mergedEvidencePeople.append(person)
                    }
                    existingEvidence.linkedPeople = mergedEvidencePeople
                }

                // Update the session's own linked-people set
                var mergedSessionPeople = session.linkedPeople ?? []
                for person in linkedPeople where !mergedSessionPeople.contains(where: { $0.persistentModelID == person.persistentModelID }) {
                    mergedSessionPeople.append(person)
                }
                session.linkedPeople = mergedSessionPeople

                try modelContext.save()
                savedAsNote = true
                return
            }

            // 4. Fallback: no auto-save happened (rare — e.g. user reopens
            //    an old session from before autoSaveAsNote existed, or the
            //    auto-save hit an error). Create a fresh note + evidence.
            let note = SamNote(
                content: transcriptText,
                sourceType: .dictated
            )
            note.linkedPeople = linkedPeople
            modelContext.insert(note)

            let titleDate = session.recordedAt.formatted(date: .abbreviated, time: .shortened)
            let evidence = SamEvidenceItem(
                id: UUID(),
                state: .done,
                source: .meetingTranscript,
                occurredAt: session.recordedAt,
                title: "Meeting transcript — \(titleDate)",
                snippet: String(transcriptText.prefix(200))
            )
            evidence.direction = .bidirectional
            evidence.linkedPeople = linkedPeople
            modelContext.insert(evidence)

            note.linkedEvidence = [evidence]
            session.linkedNote = note
            session.linkedPeople = linkedPeople

            try modelContext.save()
            savedAsNote = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func speakerColor(for clusterID: Int) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .brown, .green]
        return palette[clusterID % palette.count]
    }
}
