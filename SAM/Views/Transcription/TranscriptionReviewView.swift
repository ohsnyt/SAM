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

    @State private var editingSegmentID: UUID?
    @State private var segmentDrafts: [UUID: String] = [:]
    @State private var speakerLabels: [Int: String] = [:]  // clusterID → label
    @State private var speakerPeople: [Int: SamPerson] = [:] // clusterID → linked person
    @State private var showPersonPicker: Bool = false
    @State private var pickerTargetCluster: Int?
    @State private var isSaving: Bool = false
    @State private var saveError: String?
    @State private var savedAsNote: Bool = false

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
    }

    // MARK: - Transcript Pane

    private var transcriptPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(session.sortedSegments, id: \.id) { segment in
                    segmentRow(segment)
                }
            }
            .padding()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(displayLabel(for: segment))
                    .font(.caption.bold())
                    .foregroundStyle(speakerColor(for: segment.speakerClusterID))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(speakerColor(for: segment.speakerClusterID).opacity(0.15))
                    )

                Text(formatTimestamp(segment.startTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                if segment.speakerConfidence < 0.4 {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Low speaker confidence — please verify")
                }

                Spacer()

                Button {
                    if editingSegmentID == segment.id {
                        commitEdit(segment)
                    } else {
                        editingSegmentID = segment.id
                        segmentDrafts[segment.id] = segment.text
                    }
                } label: {
                    Image(systemName: editingSegmentID == segment.id ? "checkmark.circle.fill" : "pencil")
                        .foregroundStyle(editingSegmentID == segment.id ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }

            if editingSegmentID == segment.id {
                TextEditor(text: Binding(
                    get: { segmentDrafts[segment.id] ?? segment.text },
                    set: { segmentDrafts[segment.id] = $0 }
                ))
                .font(.body)
                .frame(minHeight: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
            } else {
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
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
            Text("The transcript is now a note with linked evidence. You can find it under People for any linked contact.")
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

    // MARK: - Editing

    private func commitEdit(_ segment: TranscriptSegment) {
        if let draft = segmentDrafts[segment.id] {
            segment.text = draft
            try? modelContext.save()
        }
        editingSegmentID = nil
    }

    private func displayLabel(for segment: TranscriptSegment) -> String {
        speakerLabels[segment.speakerClusterID] ?? segment.speakerLabel
    }

    // MARK: - Save to SAM (M6)

    private func saveAsNote() async {
        isSaving = true
        defer { isSaving = false }

        // Commit any pending speaker label edits back to segments
        for segment in session.sortedSegments {
            if let label = speakerLabels[segment.speakerClusterID], label != segment.speakerLabel {
                segment.speakerLabel = label
            }
            if let person = speakerPeople[segment.speakerClusterID] {
                segment.speakerPerson = person
            }
        }

        // Build formatted transcript text
        let transcriptText = session.sortedSegments.map { seg in
            let label = speakerLabels[seg.speakerClusterID] ?? seg.speakerLabel
            return "\(label): \(seg.text)"
        }.joined(separator: "\n\n")

        let linkedPeople = Array(Set(speakerPeople.values))

        do {
            // Create SamNote with linked people
            let note = SamNote(
                content: transcriptText,
                sourceType: .dictated
            )
            note.linkedPeople = linkedPeople
            modelContext.insert(note)

            // Create SamEvidenceItem with linked people
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

            // Cross-link note and evidence
            note.linkedEvidence = [evidence]

            // Link the session back to the note + speakers for provenance
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
