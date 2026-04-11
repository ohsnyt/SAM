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

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Connection status
            connectionStatusView

            // Recording time
            if coordinator.captureState == .recording || coordinator.captureState == .paused {
                timeDisplay
                audioLevelIndicator
            }

            // Orange warning if the streaming connection dropped mid-session.
            if let warning = coordinator.connectionLossWarning {
                connectionLossBanner(warning)
            }

            // Pending upload status — shown when there are queued
            // recordings waiting to sync to the Mac, OR when an upload
            // is currently in progress.
            pendingUploadStatusBanner

            Spacer()

            // Controls
            controlsView

            // Buffered chunks indicator
            if coordinator.bufferedChunkCount > 0 {
                Label(
                    "\(coordinator.bufferedChunkCount) chunks buffered",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Record")
        .onAppear {
            coordinator.autoConnectIfNeeded()
            // Refresh pending queue count so the badge is accurate when
            // the user opens the tab.
            PendingUploadService.shared.refreshPendingCount()
            // If we're already connected and idle, try to drain the queue.
            coordinator.maybeProcessPendingQueue()
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
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                    Text("\(pendingCount) meeting\(pendingCount == 1 ? "" : "s") waiting to sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
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

            if let name = coordinator.connectedMacName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
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
            Button {
                coordinator.startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

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

                // Single-tap "record another meeting" — reuses the existing
                // TCP connection so there's no browse/connect step.
                Button {
                    coordinator.recordAgain()
                } label: {
                    Label("Record Another Meeting", systemImage: "record.circle")
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
