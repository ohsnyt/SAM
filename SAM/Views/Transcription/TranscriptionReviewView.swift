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
    @State private var showRawSegments: Bool = false
    @State private var confirmDelete: Bool = false
    @State private var confirmSignOff: Bool = false

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

            // Destructive delete lives in the header of the transcript
            // itself — users see the actual transcript text before
            // confirming, so there's no ambiguity about which session
            // is being deleted.
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)

            // Sign Off / Signed Off badge. Once signed off, SAM starts the
            // 30-day audio retention timer (per RetentionService).
            if session.signedOffAt != nil {
                Label {
                    Text("Signed off")
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
                    confirmSignOff = true
                } label: {
                    Label("Sign Off", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .help("Mark this meeting as reviewed. SAM will purge the audio file after \(RetentionService.shared.audioRetentionDays) days.")
            }

            Button("Close") { dismiss() }
                .buttonStyle(.bordered)

            Button {
                Task { await saveAsNote() }
            } label: {
                if isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Label("Save to SAM", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
        .padding()
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Meeting", role: .destructive) {
                performDelete()
            }
            Button("Cancel", role: .cancel) {
                confirmDelete = false
            }
        } message: {
            Text(deleteDialogMessage)
        }
        .confirmationDialog(
            "Sign off on this meeting?",
            isPresented: $confirmSignOff,
            titleVisibility: .visible
        ) {
            Button("Sign Off") {
                performSignOff()
            }
            Button("Cancel", role: .cancel) {
                confirmSignOff = false
            }
        } message: {
            Text("Marks the meeting as reviewed. SAM will keep the polished transcript, summary, and linked note forever, and will purge the audio recording from disk after \(RetentionService.shared.audioRetentionDays) days. You can also pin specific meetings to keep their audio indefinitely.")
        }
    }

    private func performSignOff() {
        let container = modelContext.container
        _ = RetentionService.shared.signOff(session: session, container: container)
        confirmSignOff = false
    }

    // MARK: - Delete (local to the review view)

    private var deleteDialogMessage: String {
        var lostItems: [String] = []

        let segmentCount = session.segments?.count ?? 0
        if segmentCount > 0 {
            lostItems.append("The full transcript (\(segmentCount) segment\(segmentCount == 1 ? "" : "s")) with speaker labels")
        }
        if session.polishedText != nil {
            lostItems.append("The polished transcript")
        }
        if session.audioFilePath != nil {
            lostItems.append("The audio recording")
        }
        if let json = session.meetingSummaryJSON, !json.isEmpty {
            lostItems.append("The AI-generated summary (TL;DR, action items, decisions, follow-ups)")
        }
        if session.linkedNote != nil {
            lostItems.append("The linked note in SAM and any extracted action items, topics, and mentions")
        }

        let header = "This permanently removes this meeting from SAM. The following will be lost:"
        let bullets = lostItems.map { "• \($0)" }.joined(separator: "\n")
        let footer = "\n\nLinked contacts are NOT deleted — they stay in your People list."

        if lostItems.isEmpty {
            return "This permanently removes this meeting from SAM.\(footer)"
        }
        return "\(header)\n\n\(bullets)\(footer)"
    }

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
                // Show the polished transcript when SAM has generated one.
                // Fall back to raw paragraphs if polish hasn't run yet or
                // failed. "Show raw segments" toggle lets users verify the
                // polish didn't drop anything.
                if let polished = session.polishedText, !polished.isEmpty {
                    polishedTranscriptSection(polished)

                    if showRawSegments {
                        Divider().padding(.vertical, 8)
                        Text("Raw segments")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(paragraphs) { paragraph in
                            paragraphRow(paragraph)
                        }
                    }
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

    /// Display the polished, speaker-attributed transcript. We render each
    /// "Speaker: text" paragraph using the same visual style as raw paragraphs
    /// so the eye parses them consistently.
    @ViewBuilder
    private func polishedTranscriptSection(_ polished: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header with "Polished" badge + toggle for raw view
            HStack {
                Label("Polished", systemImage: "sparkles")
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

                Toggle(isOn: $showRawSegments) {
                    Text("Show raw")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            // Parse paragraphs from the polished text. Format is
            // "Speaker: text\n\nSpeaker: text", so we split on blank lines.
            let polishedParagraphs = parsePolishedParagraphs(polished)
            ForEach(Array(polishedParagraphs.enumerated()), id: \.offset) { _, paragraph in
                polishedParagraphRow(paragraph)
            }
        }
    }

    private struct PolishedParagraph {
        let speaker: String?
        let text: String
        let clusterID: Int  // best-effort match to the raw cluster IDs
    }

    private func parsePolishedParagraphs(_ polished: String) -> [PolishedParagraph] {
        let paragraphBlocks = polished
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Build a label→cluster lookup from the raw segments so the polished
        // paragraphs can inherit speaker colors.
        var labelToCluster: [String: Int] = [:]
        for segment in session.sortedSegments {
            if labelToCluster[segment.speakerLabel] == nil {
                labelToCluster[segment.speakerLabel] = segment.speakerClusterID
            }
        }
        // Also consult in-session speaker-label edits
        for (cluster, label) in speakerLabels {
            labelToCluster[label] = cluster
        }

        return paragraphBlocks.map { block -> PolishedParagraph in
            if let colonIdx = block.firstIndex(of: ":") {
                let speaker = String(block[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let text = String(block[block.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                let cluster = labelToCluster[speaker] ?? 0
                return PolishedParagraph(speaker: speaker, text: text, clusterID: cluster)
            } else {
                return PolishedParagraph(speaker: nil, text: block, clusterID: 0)
            }
        }
    }

    @ViewBuilder
    private func polishedParagraphRow(_ paragraph: PolishedParagraph) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let speaker = paragraph.speaker {
                HStack(spacing: 8) {
                    Text(speaker)
                        .font(.caption.bold())
                        .foregroundStyle(speakerColor(for: paragraph.clusterID))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(speakerColor(for: paragraph.clusterID).opacity(0.15))
                        )
                    Spacer()
                }
            }
            Text(paragraph.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
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

    // MARK: - Save to SAM (M6)

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
