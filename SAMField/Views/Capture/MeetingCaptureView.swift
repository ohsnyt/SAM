//
//  MeetingCaptureView.swift
//  SAM Field
//
//  Meeting recording UI with connection status, recording controls,
//  elapsed time, and audio level visualization.
//

import SwiftUI

struct MeetingCaptureView: View {
    /// Use the app-wide singleton so state survives tab switches and
    /// backgrounding. Acquired + configured in SAMFieldApp on launch.
    private let coordinator = MeetingCaptureCoordinator.shared

    @State private var showDeleteConfirmation = false
    @State private var showPendingUploadsManagement = false
    @State private var speakerCount: Int = 2
    @State private var speakerNames: [String] = ["You (Agent)", "Client"]
    /// Parallel array to speakerNames — CNContact thumbnail data (nil = use default icon).
    @State private var speakerThumbnails: [Data?] = [nil, nil]
    @State private var upcomingMeetingTitle: String? = nil
    @State private var hasCheckedCalendar = false
    @State private var showEditParticipants = false
    /// Recording context chosen by the user. Hidden for calendar-matched meetings (always .clientMeeting).
    @State private var selectedContext: RecordingContext = .clientMeeting

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch coordinator.captureState {
                case .idle, .connecting, .connected:
                    Spacer(minLength: 16)

                    // Subtle background connection status — never blocks recording
                    connectionStatusPill

                    // Upcoming meeting from calendar
                    if let title = upcomingMeetingTitle {
                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .foregroundStyle(.blue)
                            Text(title)
                                .font(.subheadline.bold())
                            Spacer()
                        }
                        .padding(.horizontal)
                    }

                    // Context picker — only for ad-hoc recordings (no calendar match)
                    if upcomingMeetingTitle == nil {
                        contextPicker
                    }

                    // Participant list — hidden for solo training recordings
                    if selectedContext != .trainingLecture {
                        participantListView
                        addParticipantButton
                    } else {
                        soloRecordingLabel
                    }

                    Spacer(minLength: 8)
                    recordButton

                    if let warning = coordinator.connectionLossWarning {
                        connectionLossBanner(warning)
                    }

                case .recording, .paused:
                    Spacer(minLength: 20)
                    participantListView

                    if coordinator.captureState == .paused {
                        addParticipantButton
                    }

                    Spacer(minLength: 8)
                    recordButton
                    secondaryControls

                    if let warning = coordinator.connectionLossWarning {
                        connectionLossBanner(warning)
                    }

                case .stopping:
                    Spacer(minLength: 60)
                    ProgressView("Finalizing…")

                case .completed:
                    completedView

                case .error(let message):
                    Spacer(minLength: 60)
                    VStack(spacing: 12) {
                        Label("Error", systemImage: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") { coordinator.reset() }
                            .buttonStyle(.bordered)
                    }
                }

                // Pending upload status
                if coordinator.captureState == .idle
                    || coordinator.captureState == .connected
                    || coordinator.captureState == .connecting {
                    pendingUploadStatusBanner
                }

                Spacer(minLength: 20)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            // Pull-to-refresh does two things:
            // 1. Restart the Bonjour browse and reconnect flow.
            // 2. If the phone is stuck on "Generating summary..." because
            //    the Mac never pushed the result (connection dropped, Mac
            //    errored), clear the stale awaiting state so Sarah isn't
            //    stuck on a spinner forever.
            coordinator.autoConnectIfNeeded()
            if coordinator.isAwaitingSummary {
                coordinator.clearStaleSummaryState()
            }
        }
        .navigationTitle(upcomingMeetingTitle != nil ? "Record Meeting" : "New Recording")
        .onAppear {
            coordinator.autoConnectIfNeeded()
            PendingUploadService.shared.refreshPendingCount()
            coordinator.maybeProcessPendingQueue()

            // Auto-populate participants from upcoming calendar event
            if !hasCheckedCalendar {
                hasCheckedCalendar = true
                if let meeting = FieldCalendarService.shared.upcomingMeeting() {
                    upcomingMeetingTitle = meeting.title
                    // Use attendee names directly from the calendar event.
                    // The user (organizer) is already in the attendee list
                    // so we don't add "You (Agent)" separately.
                    let names = meeting.attendeeNames
                    if !names.isEmpty {
                        speakerNames = names
                        speakerCount = names.count
                        speakerThumbnails = Array(repeating: nil, count: names.count)
                        // Enrich with contact thumbnails in the background
                        Task {
                            let enriched = await FieldCalendarService.shared.enrichWithThumbnails(meeting)
                            speakerThumbnails = enriched.attendees.map(\.thumbnailData)
                        }
                    }
                }
            }
        }
        .onChange(of: coordinator.captureState) { _, newState in
            // When Mac connects and we haven't yet loaded calendar data, check now.
            // Skip if calendar was already populated (don't overwrite user edits).
            if newState == .connected && !hasCheckedCalendar {
                if let meeting = FieldCalendarService.shared.upcomingMeeting() {
                    upcomingMeetingTitle = meeting.title
                    let names = meeting.attendeeNames
                    if !names.isEmpty {
                        speakerNames = names
                        speakerCount = names.count
                        speakerThumbnails = Array(repeating: nil, count: names.count)
                        Task {
                            let enriched = await FieldCalendarService.shared.enrichWithThumbnails(meeting)
                            speakerThumbnails = enriched.attendees.map(\.thumbnailData)
                        }
                    }
                }
                hasCheckedCalendar = true
            }
        }
        .alert(
            "Can't find your Mac",
            isPresented: Binding(
                get: { coordinator.showConnectionTimeoutPrompt },
                set: { newValue in
                    if !newValue { coordinator.dismissConnectionTimeoutPrompt() }
                }
            )
        ) {
            Button("Retry") {
                coordinator.dismissConnectionTimeoutAndRetry()
            }
            Button("Record Locally") {
                coordinator.dismissConnectionTimeoutAndRecordLocally()
            }
            Button("Cancel", role: .cancel) {
                coordinator.dismissConnectionTimeoutPrompt()
            }
        } message: {
            Text("SAM couldn't find your Mac on the local network. Make sure SAM is open on your Mac and both devices are on the same WiFi, or record locally and SAM will sync this meeting later.")
        }
        .sheet(isPresented: $showPendingUploadsManagement) {
            PendingUploadsManagementView()
        }
        .alert("Delete this recording?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                coordinator.deleteSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the recording, transcript, and summary from your Mac.")
        }
    }

    // MARK: - Pending Upload Banner

    @ViewBuilder
    private var pendingUploadStatusBanner: some View {
        let pendingCount = coordinator.pendingUploadCount
        let uploadState = PendingUploadService.shared.uploadState

        switch uploadState {
        case .sendingChunks(_, let bytesSent, let totalBytes):
            let progress = totalBytes > 0 ? Double(bytesSent) / Double(totalBytes) : 0
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundStyle(.blue)
                    Text("Syncing meeting to Mac")
                        .font(.subheadline.bold())
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.horizontal)

        case .sendingStart, .sendingEnd:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting sync…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .awaitingAck:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Mac is processing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(_, let reason):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Sync failed: \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal)

        case .idle:
            if pendingCount > 0 {
                Button {
                    showPendingUploadsManagement = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        Text("\(pendingCount) recording\(pendingCount == 1 ? "" : "s") waiting to sync")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Connection Loss Banner

    @ViewBuilder
    private func connectionLossBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording locally")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }

    // MARK: - Connection Status

    @ViewBuilder
    private var connectionStatusView: some View {
        VStack(spacing: 8) {
            Image(systemName: connectionIcon)
                .font(.system(size: 48))
                .foregroundStyle(connectionColor)
                .symbolEffect(.pulse, isActive: isConnecting)

            Text(coordinator.connectionStatus)
                .font(.headline)
                .foregroundStyle(.secondary)

            // Intentionally omitting the raw Bonjour endpoint name
            // (e.g. "David's\032MacBook\032Pro..._tcp.local") which is
            // meaningless to Sarah. "Connected to Mac" is enough.
        }
    }

    private var connectionIcon: String {
        switch coordinator.captureState {
        case .idle: return "laptopcomputer.and.iphone"
        case .connecting: return "wifi.exclamationmark"
        case .connected: return "checkmark.circle.fill"
        case .recording: return "waveform.circle.fill"
        case .paused: return "pause.circle.fill"
        case .stopping: return "stop.circle.fill"
        case .completed: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var connectionColor: Color {
        switch coordinator.captureState {
        case .idle: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .recording: return .red
        case .paused: return .orange
        case .stopping: return .secondary
        case .completed: return .green
        case .error: return .red
        }
    }

    private var isConnecting: Bool {
        coordinator.captureState == .connecting
    }

    // MARK: - Context Picker

    private var contextPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recording Type")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Picker("Recording Type", selection: $selectedContext) {
                ForEach(RecordingContext.allCases, id: \.self) { ctx in
                    Label(ctx.displayName, systemImage: ctx.systemIcon).tag(ctx)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
    }

    /// Shown instead of participant list when Training/Lecture is selected.
    private var soloRecordingLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Solo recording")
                    .font(.subheadline.bold())
                Text("No participants needed — SAM will extract key points and learning objectives.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.horizontal)
    }

    // MARK: - Connection Status Pill

    /// Subtle ambient indicator shown above participant list when Mac is not yet connected.
    /// Empty view when connected — success is the default expectation.
    @ViewBuilder
    private var connectionStatusPill: some View {
        switch coordinator.captureState {
        case .connecting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Searching for Mac…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.1), in: Capsule())
        case .idle:
            EmptyView()
        default:
            EmptyView()
        }
    }

    // MARK: - Time Display

    private var timeDisplay: some View {
        Text(formatTime(coordinator.elapsedTime))
            .font(.system(size: 56, weight: .thin, design: .monospaced))
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    // MARK: - Audio Level

    private var audioLevelIndicator: some View {
        GeometryReader { geo in
            let barCount = 30
            let spacing: CGFloat = 2
            let barWidth = (geo.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount)

            HStack(spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let threshold = Float(i) / Float(barCount)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(coordinator.audioLevel > threshold ? Color.red : Color.red.opacity(0.15))
                        .frame(width: barWidth, height: 8)
                }
            }
        }
        .frame(height: 8)
        .padding(.horizontal)
        .animation(.easeOut(duration: 0.1), value: coordinator.audioLevel)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsView: some View {
        switch coordinator.captureState {
        case .idle:
            Button {
                coordinator.connectToMac()
            } label: {
                Label("Connect to Mac", systemImage: "laptopcomputer.and.iphone")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .connecting:
            Button("Cancel") {
                coordinator.reset()
            }
            .buttonStyle(.bordered)

        case .connected:
            participantPrepAndRecord

        case .recording:
            HStack(spacing: 32) {
                Button {
                    coordinator.pauseRecording()
                } label: {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.orange)
                }

                Button {
                    coordinator.stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.red)
                }
            }

        case .paused:
            VStack(spacing: 12) {
                Button {
                    showEditParticipants.toggle()
                } label: {
                    Label(
                        showEditParticipants ? "Hide Participants" : "Edit Participants",
                        systemImage: "person.2"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if showEditParticipants {
                    participantEditor
                }
            }
            .padding(.horizontal)

            HStack(spacing: 32) {
                Button {
                    coordinator.resumeRecording()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                }

                Button {
                    coordinator.stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.red)
                }
            }

        case .stopping:
            ProgressView("Finalizing…")

        case .completed:
            completedView

        case .error(let message):
            VStack(spacing: 12) {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try Again") {
                    coordinator.reset()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Participant Prep

    /// Shown when connected to Mac and ready to record. Lets the user
    /// set the expected speaker count and names before starting.
    @ViewBuilder
    private var participantPrepAndRecord: some View {
        VStack(spacing: 16) {
            // Upcoming meeting from calendar
            if let title = upcomingMeetingTitle {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .foregroundStyle(.blue)
                    Text(title)
                        .font(.subheadline.bold())
                    Spacer()
                }
                .padding(.horizontal)
            }

            // Speaker count stepper
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Participants")
                        .font(.subheadline.bold())

                    HStack {
                        Text("How many people?")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 0) {
                            Button {
                                if speakerCount > 1 {
                                    speakerCount -= 1
                                    syncSpeakerNames()
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)

                            Text("\(speakerCount)")
                                .font(.title2.bold())
                                .frame(width: 40)
                                .multilineTextAlignment(.center)

                            Button {
                                if speakerCount < 8 {
                                    speakerCount += 1
                                    syncSpeakerNames()
                                }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Speaker name fields
                    ForEach(0..<speakerNames.count, id: \.self) { i in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(speakerDotColor(i))
                                .frame(width: 8, height: 8)
                            TextField("Speaker \(i + 1)", text: $speakerNames[i])
                                .textFieldStyle(.roundedBorder)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Start Recording button
            Button {
                coordinator.expectedSpeakerCount = selectedContext == .trainingLecture ? 1 : speakerCount
                coordinator.expectedSpeakerNames = selectedContext == .trainingLecture ? [] : speakerNames
                coordinator.expectedRecordingContext = upcomingMeetingTitle != nil ? .clientMeeting : selectedContext
                coordinator.startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(.horizontal)
        }
    }

    // MARK: - Unified Participant List

    /// Participant list with contact thumbnails (or person icon fallback).
    /// Tight spacing, no heading. Editable when not recording.
    private var participantListView: some View {
        List {
            ForEach(Array(speakerNames.enumerated()), id: \.offset) { i, name in
                HStack(spacing: 12) {
                    participantAvatar(index: i)

                    if coordinator.captureState != .recording {
                        TextField("Participant", text: $speakerNames[i])
                            .font(.body)
                    } else {
                        Text(name)
                            .font(.body)
                    }

                    Spacer()
                }
                .listRowSeparatorTint(.secondary.opacity(0.2))
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .onDelete { indices in
                guard speakerNames.count > 1 else { return }
                speakerNames.remove(atOffsets: indices)
                speakerThumbnails.remove(atOffsets: indices)
                speakerCount = speakerNames.count
            }
        }
        .listStyle(.plain)
        .frame(height: CGFloat(speakerNames.count) * 52)
        .scrollDisabled(true)
    }

    /// Contact thumbnail if available, colored person icon otherwise.
    @ViewBuilder
    private func participantAvatar(index: Int) -> some View {
        let thumbnail = index < speakerThumbnails.count ? speakerThumbnails[index] : nil
        if let data = thumbnail, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(speakerDotColor(index).opacity(0.7))
        }
    }

    /// Add participant row — appears below the list
    private var addParticipantButton: some View {
        Button {
            speakerCount += 1
            syncSpeakerNames()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Add participant...")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Record Button

    /// Large circular button that transforms between states:
    /// - Connected: red "Start Recording" with glass effect
    /// - Recording: pulsing red glow with timer, audio level drives glow intensity
    /// - Paused: orange, static, "Paused"
    private var recordButton: some View {
        ZStack {
            // Audio level glow (recording only)
            if coordinator.captureState == .recording {
                Circle()
                    .fill(Color.red.opacity(0.2 + Double(coordinator.audioLevel) * 0.5))
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)
                    .animation(.easeOut(duration: 0.1), value: coordinator.audioLevel)
            }

            let canStartRecording = coordinator.captureState == .idle
                || coordinator.captureState == .connecting
                || coordinator.captureState == .connected
            if canStartRecording {
                // Start recording button — works regardless of Mac connection
                Button {
                    coordinator.expectedSpeakerCount = selectedContext == .trainingLecture ? 1 : speakerCount
                    coordinator.expectedSpeakerNames = selectedContext == .trainingLecture ? [] : speakerNames
                    coordinator.expectedRecordingContext = upcomingMeetingTitle != nil ? .clientMeeting : selectedContext
                    coordinator.startRecording()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 80, height: 80)
                            .overlay(
                                Circle()
                                    .stroke(Color.red.opacity(0.6), lineWidth: 3)
                            )
                        Circle()
                            .fill(Color.red)
                            .frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(.plain)
            } else {
                // Timer display during recording/paused
                VStack(spacing: 4) {
                    Text(formatTime(coordinator.elapsedTime))
                        .font(.system(size: 40, weight: .light, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())

                    if coordinator.captureState == .paused {
                        Text("PAUSED")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }


    // MARK: - Secondary Controls (Pause / Stop)

    private var secondaryControls: some View {
        HStack(spacing: 40) {
            if coordinator.captureState == .recording {
                Button {
                    coordinator.pauseRecording()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("Pause")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if coordinator.captureState == .paused {
                Button {
                    coordinator.resumeRecording()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text("Resume")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                coordinator.stopRecording()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.red)
                    Text("Stop")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Compact participant list shown during recording — no heading, scrollable if >3
    @available(*, deprecated, message: "Use participantListView instead")
    private var compactParticipantList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<speakerNames.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(speakerDotColor(i))
                            .frame(width: 6, height: 6)
                        Text(speakerNames[i])
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }
            }
            .padding(.horizontal)
        }
    }

    /// Editable participant list shown when paused and "Edit Participants" is tapped
    private var participantEditor: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Participants")
                    .font(.caption.bold())
                Spacer()
                HStack(spacing: 0) {
                    Button {
                        if speakerCount > 1 { speakerCount -= 1; syncSpeakerNames() }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Text("\(speakerCount)").font(.subheadline.bold()).frame(width: 30)

                    Button {
                        if speakerCount < 8 { speakerCount += 1; syncSpeakerNames() }
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(0..<speakerNames.count, id: \.self) { i in
                HStack(spacing: 6) {
                    Circle().fill(speakerDotColor(i)).frame(width: 6, height: 6)
                    TextField("Speaker \(i + 1)", text: $speakerNames[i])
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
            }

            Button("Update") {
                coordinator.expectedSpeakerCount = speakerCount
                coordinator.expectedSpeakerNames = speakerNames
                showEditParticipants = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    /// Keep speakerNames and speakerThumbnails arrays in sync with speakerCount.
    private func syncSpeakerNames() {
        let defaults = ["You (Agent)", "Client", "Spouse", "Speaker 4", "Speaker 5", "Speaker 6", "Speaker 7", "Speaker 8"]
        while speakerNames.count < speakerCount {
            let idx = speakerNames.count
            speakerNames.append(idx < defaults.count ? defaults[idx] : "Speaker \(idx + 1)")
            speakerThumbnails.append(nil)
        }
        while speakerNames.count > speakerCount {
            speakerNames.removeLast()
            if !speakerThumbnails.isEmpty { speakerThumbnails.removeLast() }
        }
    }

    private func speakerDotColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .teal, .pink, .indigo, .brown]
        return colors[index % colors.count]
    }

    // MARK: - Completed / Summary

    @ViewBuilder
    private var completedView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Label("Recording Complete", systemImage: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)

                Text(formatTime(coordinator.elapsedTime))
                    .font(.title2.monospaced())
                    .foregroundStyle(.secondary)

                if let summary = coordinator.lastSummary, summary.hasContent {
                    summaryCard(summary)
                } else if coordinator.isAwaitingSummary {
                    awaitingSummaryCard
                } else {
                    Text("Saved to SAM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Session lifecycle actions — Delete is always available,
                // Done waits until the summary has arrived (or timed out).
                if coordinator.captureState == .completed {
                    if coordinator.showDoneConfirmation {
                        Label("Done!", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                            .padding(.top, 8)
                    } else {
                        let summaryReady = !coordinator.isAwaitingSummary

                        HStack(spacing: 12) {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            if summaryReady {
                                Button {
                                    coordinator.markSessionDone()
                                } label: {
                                    Label("Done", systemImage: "checkmark")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .controlSize(.large)
                            }
                        }
                        .padding(.top, 8)
                    }
                }

                // Single-tap "record another meeting" — reuses the existing
                // TCP connection so there's no browse/connect step.
                Button {
                    upcomingMeetingTitle = nil
                    hasCheckedCalendar = false
                    selectedContext = .clientMeeting
                    coordinator.recordAgain()
                } label: {
                    Label(selectedContext == .trainingLecture ? "Record Another Training" : selectedContext == .boardMeeting ? "Record Another Board Meeting" : "Record Another Meeting", systemImage: "record.circle")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .padding(.top, 8)
            }
            .padding(.horizontal)
        }
    }

    private var awaitingSummaryCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating summary…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("SAM is analyzing your meeting. The summary will appear here in a few seconds.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func summaryCard(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // TL;DR
            if !summary.tldr.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TL;DR")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(summary.tldr)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !summary.actionItems.isEmpty {
                summarySection(title: "Action Items", systemImage: "checkmark.circle") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.task)
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if item.owner != nil || item.dueDate != nil {
                                        HStack(spacing: 4) {
                                            if let owner = item.owner {
                                                Text(owner)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                                                    .foregroundStyle(Color.accentColor)
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
            }

            if !summary.decisions.isEmpty {
                summarySection(title: "Decisions", systemImage: "hand.raised") {
                    bulletList(summary.decisions)
                }
            }

            if !summary.followUps.isEmpty {
                summarySection(title: "Follow-ups", systemImage: "person.2") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(summary.followUps.enumerated()), id: \.offset) { _, followUp in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(followUp.person)
                                        .font(.subheadline.bold())
                                    Text(followUp.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }

            if !summary.openQuestions.isEmpty {
                summarySection(title: "Open Questions", systemImage: "questionmark.circle") {
                    bulletList(summary.openQuestions)
                }
            }

            if !summary.lifeEvents.isEmpty {
                summarySection(title: "Life Events", systemImage: "heart") {
                    bulletList(summary.lifeEvents)
                }
            }

            // Training/Lecture fields
            if !summary.keyPoints.isEmpty {
                summarySection(title: "Key Points", systemImage: "lightbulb") {
                    bulletList(summary.keyPoints)
                }
            }

            if !summary.learningObjectives.isEmpty {
                summarySection(title: "Learning Objectives", systemImage: "target") {
                    bulletList(summary.learningObjectives)
                }
            }

            if let reviewNotes = summary.reviewNotes, !reviewNotes.isEmpty {
                summarySection(title: "Review Notes", systemImage: "doc.text") {
                    Text(reviewNotes)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Board Meeting fields
            if !summary.attendees.isEmpty {
                summarySection(title: "Attendees", systemImage: "person.3") {
                    Text(summary.attendees.joined(separator: ", "))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !summary.agendaItems.isEmpty {
                summarySection(title: "Agenda", systemImage: "list.bullet.clipboard") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(summary.agendaItems.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundStyle(.tertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.subheadline.bold())
                                        if let summary = item.summary {
                                            Text(summary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        if let outcome = item.outcome {
                                            Text(outcome)
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.blue.opacity(0.12)))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !summary.votes.isEmpty {
                summarySection(title: "Votes", systemImage: "hand.raised") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.votes.enumerated()), id: \.offset) { _, vote in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").foregroundStyle(.tertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vote.motion).font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(vote.result)
                                        .font(.caption2.bold())
                                        .foregroundStyle(vote.result == "Passed" ? .green : vote.result == "Failed" ? .red : .secondary)
                                }
                            }
                        }
                    }
                }
            }

            if !summary.complianceFlags.isEmpty {
                summarySection(title: "Compliance Review", systemImage: "exclamationmark.shield") {
                    bulletList(summary.complianceFlags)
                }
                .foregroundStyle(.orange)
            }

            if !summary.topics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TOPICS")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(summary.topics, id: \.self) { topic in
                                Text(topic)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func summarySection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(item)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
