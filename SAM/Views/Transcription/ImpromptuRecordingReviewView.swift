//
//  ImpromptuRecordingReviewView.swift
//  SAM
//
//  Block 4: compact review sheet shown when a recording finishes
//  summarization without a calendar event to tie it to. Asks three
//  questions in a single glance — who, what kind, keep or discard —
//  and either approves (attach + sign-off) or deletes the session.
//
//  The session itself is fetched via @Query so edits made elsewhere
//  (e.g., a backfill running while the sheet is open) don't crash us.
//

import SwiftUI
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ImpromptuReviewView")

struct ImpromptuRecordingReviewView: View {
    let payload: ImpromptuReviewPayload

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SamPerson.displayName) private var allPeople: [SamPerson]

    @State private var selectedPersonID: UUID?
    @State private var context: RecordingContext = .clientMeeting
    @State private var isWorking: Bool = false
    @State private var errorMessage: String?
    @State private var confirmDiscard: Bool = false

    private var session: TranscriptSession? {
        let sessionID = payload.sessionID
        let descriptor = FetchDescriptor<TranscriptSession>(
            predicate: #Predicate { $0.id == sessionID }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private var selectedPerson: SamPerson? {
        guard let id = selectedPersonID else { return nil }
        return allPeople.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            if let tldr = payload.summaryTLDR, !tldr.isEmpty {
                tldrSection(tldr)
            }

            contextPicker
            personPicker

            if let message = errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
            actionRow
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420)
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                Task { await performDiscard() }
            }
            Button("Cancel", role: .cancel) { confirmDiscard = false }
        } message: {
            Text("Deletes the audio, transcript, and summary. Can't be undone.")
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(payload.suggestedTitle ?? "Untitled recording")
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }

    private var headerSubtitle: String {
        let when = Self.relativeFormatter.localizedString(for: payload.recordedAt, relativeTo: .now)
        let mins = max(1, Int((payload.durationSeconds / 60).rounded()))
        return "\(when.capitalized) · \(mins) min"
    }

    private func tldrSection(_ tldr: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Text(tldr)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contextPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Picker("", selection: $context) {
                ForEach(RecordingContext.allCases, id: \.self) { ctx in
                    Label(ctx.displayName, systemImage: ctx.systemIcon).tag(ctx)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var personPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(context.supportsPersonLinking ? "Who was this with?" : "Primary person (optional)")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Picker("", selection: $selectedPersonID) {
                Text("— None —").tag(UUID?.none)
                ForEach(allPeople, id: \.id) { person in
                    Text(person.displayName).tag(Optional(person.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Discard", role: .destructive) {
                confirmDiscard = true
            }
            .disabled(isWorking)

            Spacer()

            Button("Skip") {
                Task { await performSkip() }
            }
            .disabled(isWorking)

            Button {
                Task { await performApprove() }
            } label: {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Approve", systemImage: "checkmark.seal")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isWorking || !canApprove)
        }
    }

    private var canApprove: Bool {
        // Person linkage is required for client/board contexts. Training
        // recordings can be approved without a person since they're
        // usually solo listening.
        if context.supportsPersonLinking {
            return selectedPersonID != nil
        }
        return true
    }

    // MARK: - Actions

    private func performApprove() async {
        guard let session = session else {
            errorMessage = "Recording not found. It may have already been deleted."
            return
        }
        isWorking = true
        defer { isWorking = false }

        session.recordingContext = context
        if let person = selectedPerson {
            var linked = session.linkedPeople ?? []
            if !linked.contains(where: { $0.id == person.id }) {
                linked.append(person)
            }
            session.linkedPeople = linked
        }
        session.impromptuReviewOutcome = .approved
        session.impromptuReviewedAt = .now

        do {
            try modelContext.save()
        } catch {
            logger.error("Impromptu approve save failed: \(error.localizedDescription)")
            errorMessage = "Couldn't save — try again."
            return
        }

        _ = RetentionService.shared.signOff(session: session, container: modelContext.container)
        dismiss()
    }

    private func performSkip() async {
        if let session = session {
            session.impromptuReviewOutcome = .skipped
            session.impromptuReviewedAt = .now
            try? modelContext.save()
        }
        dismiss()
    }

    private func performDiscard() async {
        guard let session = session else {
            dismiss()
            return
        }
        isWorking = true
        defer { isWorking = false }

        // Mirror TranscriptionReviewView.performDelete: audio file, linked
        // note + its evidence, tombstone so SAMField can't re-upload, then
        // the session itself.
        if let relativePath = session.audioFilePath {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let audioURL = appSupport.appendingPathComponent(relativePath)
            try? FileManager.default.removeItem(at: audioURL)
        }
        if let note = session.linkedNote {
            for evidence in note.linkedEvidence {
                modelContext.delete(evidence)
            }
            modelContext.delete(note)
        }
        let sessionID = session.id
        let tombstoneDescriptor = FetchDescriptor<ProcessedSessionTombstone>(
            predicate: #Predicate { $0.sessionID == sessionID }
        )
        if (try? modelContext.fetch(tombstoneDescriptor).first) == nil {
            modelContext.insert(ProcessedSessionTombstone(sessionID: sessionID))
        }
        modelContext.delete(session)
        try? modelContext.save()
        dismiss()
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
