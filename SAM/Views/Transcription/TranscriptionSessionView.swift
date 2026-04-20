//
//  TranscriptionSessionView.swift
//  SAM
//
//  Mac-side view for transcription sessions.
//  Shows connection status, Whisper model loading, live streaming transcript,
//  and session history. M4 will add speaker labels.
//

import SwiftUI
import SwiftData

struct TranscriptionSessionView: View {
    /// Use the app-wide singleton — the listener and Whisper model are started
    /// at app launch in SAMApp and stay running across all visits to this view.
    private let coordinator = TranscriptionSessionCoordinator.shared
    @State private var reviewSession: TranscriptSession?
    @State private var showEnrollment = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptSession.recordedAt, order: .reverse)
    private var sessions: [TranscriptSession]

    /// Query for the enrolled agent voice profile — nil if the user hasn't
    /// enrolled yet, in which case we show a friendly nudge banner.
    @Query(filter: #Predicate<SpeakerProfile> { $0.isAgent == true })
    private var agentProfiles: [SpeakerProfile]

    private var hasEnrolledVoice: Bool {
        !agentProfiles.isEmpty
    }

    var body: some View {
        HSplitView {
            // Left: status + controls + history
            VStack(spacing: 0) {
                activeSessionPanel
                Divider()
                sessionHistoryList
            }
            .frame(minWidth: 320, idealWidth: 360)

            // Right: live transcript
            liveTranscriptPane
                .frame(minWidth: 400)
        }
        .onAppear {
            // Coordinator is configured + listening from app launch in SAMApp.task,
            // but if the view opens before that runs (unlikely) we make sure here too.
            coordinator.configure(container: modelContext.container)
            if coordinator.sessionState == .idle {
                coordinator.startListening()
            }
        }
        .navigationTitle("Transcription")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEnrollment = true
                } label: {
                    Label("Enroll Voice", systemImage: "person.wave.2")
                }
                .help("Train SAM to recognize your voice in meeting transcripts")
            }
        }
        .sheet(item: $reviewSession) { session in
            TranscriptionReviewView(session: session)
        }
        .sheet(isPresented: $showEnrollment) {
            SpeakerEnrollmentView()
        }
    }

    // MARK: - Active Session Panel

    @ViewBuilder
    private var activeSessionPanel: some View {
        VStack(spacing: 16) {
            // Gentle nudge when the user hasn't enrolled their voice yet.
            // Shown above the status icon so it's the first thing they see.
            if !hasEnrolledVoice {
                enrollmentNudge
            }

            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 40))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: coordinator.sessionState == .listening)

            Text(statusText)
                .font(.headline)

            if let device = coordinator.connectedDeviceName {
                Text(device)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Chunk counter during receiving
            if coordinator.sessionState == .receiving {
                HStack(spacing: 16) {
                    Label("\(coordinator.chunksReceived)", systemImage: "waveform")
                    Label("\(coordinator.windowsProcessed)", systemImage: "rectangle.dashed")
                }
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            // Pipeline state
            pipelineStatusBadge

            // Hint text — Mac is passive; all control is on the phone
            Text(hintText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .padding(.top, 4)

            // Only show a retry button if the listener errored out
            if case .error = coordinator.sessionState {
                Button("Retry") {
                    coordinator.startListening()
                }
                .buttonStyle(.borderedProminent)
            }

            // Last session info stays visible after completion
            if coordinator.lastSessionDuration > 0 {
                GroupBox("Last session") {
                    LabeledContent("Duration", value: formatDuration(coordinator.lastSessionDuration))
                }
                .frame(maxWidth: 280)
            }

            // Meeting summary status/preview
            summaryStatusBadge
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Enrollment Nudge

    /// Friendly "train your voice" card shown when no agent profile exists.
    /// Tapping it opens the enrollment wizard.
    private var enrollmentNudge: some View {
        Button {
            showEnrollment = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.wave.2.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Train me to learn your voice")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text("So I can tell you apart from clients in meeting transcripts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.25), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summary Status Badge

    @ViewBuilder
    private var summaryStatusBadge: some View {
        switch coordinator.summaryState {
        case .idle:
            EmptyView()

        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Generating meeting summary…")
                    .font(.caption)
            }
            .foregroundStyle(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1), in: Capsule())

        case .ready:
            if let summary = coordinator.lastMeetingSummary, summary.hasContent {
                GroupBox("Meeting Summary") {
                    VStack(alignment: .leading, spacing: 8) {
                        // Review Notes — prose narrative, shown first for lectures.
                        // Replaces the TLDR as the opening for training/lecture.
                        if let notes = summary.reviewNotes, !notes.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Review Notes", systemImage: "doc.text")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                Text(notes).font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !summary.tldr.isEmpty {
                            Text("Summary: \(summary.tldr)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Compliance flags — front and center when present
                        if !summary.complianceFlags.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Compliance Review", systemImage: "exclamationmark.shield.fill")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.red)
                                ForEach(summary.complianceFlags, id: \.self) { flag in
                                    Text("• \(flag)")
                                        .font(.caption2)
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                            }
                            .padding(6)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }

                        // Action items — the most valuable structured output
                        if !summary.actionItems.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Action Items", systemImage: "checkmark.circle")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .top, spacing: 4) {
                                        Image(systemName: "circle")
                                            .font(.system(size: 7))
                                            .foregroundStyle(.tertiary)
                                            .padding(.top, 3)
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(item.task)
                                                .font(.caption)
                                            if item.owner != nil || item.dueDate != nil {
                                                HStack(spacing: 6) {
                                                    if let owner = item.owner {
                                                        Text(owner)
                                                            .font(.caption2)
                                                            .foregroundStyle(.blue)
                                                    }
                                                    if let due = item.dueDate {
                                                        Text(due)
                                                            .font(.caption2)
                                                            .foregroundStyle(.orange)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Decisions
                        if !summary.decisions.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Decisions", systemImage: "checkmark.seal")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(summary.decisions, id: \.self) { decision in
                                    Text("• \(decision)")
                                        .font(.caption)
                                }
                            }
                        }

                        // Follow-ups
                        if !summary.followUps.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Follow-ups", systemImage: "person.2")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(Array(summary.followUps.enumerated()), id: \.offset) { _, followUp in
                                    Text("• \(followUp.person): \(followUp.reason)")
                                        .font(.caption)
                                }
                            }
                        }

                        // Life events
                        if !summary.lifeEvents.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Life Events", systemImage: "heart")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(summary.lifeEvents, id: \.self) { event in
                                    Text("• \(event)")
                                        .font(.caption)
                                }
                            }
                        }

                        // Training/Lecture fields — Learning Objectives then Key Points.
                        // Review Notes is rendered up top; no duplicate here.
                        if !summary.learningObjectives.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Learning Objectives", systemImage: "target")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(summary.learningObjectives, id: \.self) { obj in
                                    Text("• \(obj)").font(.caption)
                                }
                            }
                        }

                        if !summary.keyPoints.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Key Points", systemImage: "lightbulb")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(summary.keyPoints, id: \.self) { pt in
                                    Text("• \(pt)").font(.caption)
                                }
                            }
                        }

                        // Board Meeting fields
                        if !summary.attendees.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Attendees", systemImage: "person.3")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                Text(summary.attendees.joined(separator: ", "))
                                    .font(.caption)
                            }
                        }

                        if !summary.agendaItems.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Agenda", systemImage: "list.bullet.clipboard")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(Array(summary.agendaItems.enumerated()), id: \.offset) { _, item in
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(alignment: .top, spacing: 4) {
                                            Text("•").foregroundStyle(.tertiary).font(.caption)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(item.title).font(.caption.bold())
                                                if let s = item.summary {
                                                    Text(s).font(.caption2).foregroundStyle(.secondary)
                                                }
                                                if let outcome = item.outcome {
                                                    Text(outcome).font(.caption2).foregroundStyle(.blue)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if !summary.votes.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Votes", systemImage: "hand.raised")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                ForEach(Array(summary.votes.enumerated()), id: \.offset) { _, vote in
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("•").foregroundStyle(.tertiary).font(.caption)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(vote.motion).font(.caption)
                                            Text(vote.result).font(.caption2.bold())
                                                .foregroundStyle(vote.result == "Passed" ? .green : vote.result == "Failed" ? .red : .secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: 380)
            }

        case .failed(let msg):
            HStack(spacing: 8) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button {
                    coordinator.regenerateSummary()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Pipeline Status Badge

    @ViewBuilder
    private var pipelineStatusBadge: some View {
        switch coordinator.pipelineState {
        case .idle:
            EmptyView()

        case .loadingModel:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading Whisper model…")
                    .font(.caption)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.1), in: Capsule())
            .help("First run downloads ~140MB. Subsequent runs load from cache instantly.")

        case .ready:
            Label("Whisper ready", systemImage: "brain.head.profile")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.1), in: Capsule())

        case .processing:
            Label("Transcribing…", systemImage: "brain.head.profile")
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1), in: Capsule())

        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.1), in: Capsule())
        }
    }

    // MARK: - Live Transcript Pane

    @ViewBuilder
    private var liveTranscriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live Transcript")
                    .font(.headline)
                Spacer()
                if coordinator.sessionState == .receiving {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .symbolEffect(.pulse)
                    Text("LIVE")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            .padding()

            Divider()

            if coordinator.liveSegments.isEmpty {
                emptyTranscriptState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(coordinator.liveSegments.enumerated()), id: \.offset) { idx, segment in
                                transcriptSegmentRow(segment, index: idx)
                                    .id(idx)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: coordinator.liveSegments.count) { _, newCount in
                        // Auto-scroll to latest
                        if newCount > 0 {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(newCount - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var emptyTranscriptState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.3))
            Text(emptyTranscriptMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyTranscriptMessage: String {
        switch coordinator.sessionState {
        case .idle, .completed:
            return "Start listening, then record on iPhone — transcript will appear here as you speak."
        case .listening, .connected:
            if case .loadingModel = coordinator.pipelineState {
                return "Loading Whisper model… (first run downloads ~140MB)"
            }
            return "Waiting for recording to begin…"
        case .receiving:
            switch coordinator.pipelineState {
            case .loadingModel:
                return "Audio is being buffered, but the Whisper model is still loading. Transcription will catch up once it's ready."
            case .processing:
                return "Transcribing first window…"
            default:
                return "Buffering audio — transcript appears after ~30 seconds."
            }
        case .error(let msg):
            return msg
        }
    }

    private func transcriptSegmentRow(_ segment: TranscriptionPipelineService.EmittedSegment, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // Speaker label pill
                Text(segment.speakerLabel)
                    .font(.caption.bold())
                    .foregroundStyle(speakerColor(for: segment.speakerClusterID))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(speakerColor(for: segment.speakerClusterID).opacity(0.15))
                    )

                Text(formatTimestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text("→")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(formatTimestamp(segment.end))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                if segment.speakerConfidence < 0.4 {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Low speaker confidence")
                }
            }

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// Color for a speaker cluster — Agent gets accent color, others cycle through palette.
    private func speakerColor(for clusterID: Int) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .brown]
        return palette[clusterID % palette.count]
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds - floor(seconds)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, ms)
    }

    // MARK: - Session History

    private var sessionHistoryList: some View {
        List {
            Section("Recent Sessions") {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "waveform.slash",
                        description: Text("Recorded meeting transcriptions will appear here.")
                    )
                } else {
                    // Sessions are click-to-open only. Deletion lives in
                    // the review view header, so the user can verify the
                    // actual transcript text before confirming the delete.
                    ForEach(sessions) { session in
                        Button {
                            reviewSession = session
                        } label: {
                            sessionRow(session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: TranscriptSession) -> some View {
        HStack {
            Image(systemName: session.status == .completed ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(session.status == .completed ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.body)

                HStack(spacing: 8) {
                    Text(formatDuration(session.durationSeconds))
                    let segmentCount = session.segments?.count ?? 0
                    if segmentCount > 0 {
                        Text("·")
                        Text("\(segmentCount) segments")
                    }
                    if let lang = session.detectedLanguage {
                        Text("·")
                        Text(lang.uppercased())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Title column — between date and context. Shown even when empty
            // (placeholder dash) so the column alignment stays consistent.
            Text((session.title?.isEmpty == false) ? session.title! : "—")
                .font(.body)
                .foregroundStyle((session.title?.isEmpty == false) ? .primary : .tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)

            // Context badge — only shown for non-default contexts
            if session.recordingContext != .clientMeeting {
                Label(session.recordingContext.displayName, systemImage: session.recordingContext.systemIcon)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.12)))
                    .foregroundStyle(.purple)
            }

            Text(session.status.rawValue.capitalized)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(session.status == .completed ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                )
        }
    }

    // MARK: - Status Helpers

    private var statusIcon: String {
        switch coordinator.sessionState {
        case .idle: return "antenna.radiowaves.left.and.right.slash"
        case .listening: return "antenna.radiowaves.left.and.right"
        case .connected: return "iphone.and.arrow.forward"
        case .receiving: return "waveform.circle.fill"
        case .completed: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch coordinator.sessionState {
        case .idle: return .secondary
        case .listening: return .blue
        case .connected: return .green
        case .receiving: return .red
        case .completed: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch coordinator.sessionState {
        case .idle: return "Starting…"
        case .listening: return "Ready for iPhone"
        case .connected: return "iPhone Connected"
        case .receiving: return "Receiving Audio…"
        case .completed: return "Session Saved"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var hintText: String {
        switch coordinator.sessionState {
        case .idle:
            return "SAM is starting up the meeting listener."
        case .listening:
            return "Open SAM Field on your iPhone and tap the Meeting tab — recording is controlled from the phone."
        case .connected:
            return "iPhone connected. Tap Start Recording on the phone to begin."
        case .receiving:
            return "Transcribing live. Tap Stop on the phone when you're done."
        case .completed:
            return "Transcript saved and analyzed. Ready for the next session."
        case .error:
            return "Something went wrong with the listener. Tap Retry or check Console.app."
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
