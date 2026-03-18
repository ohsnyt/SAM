//
//  EventUpdateSheet.swift
//  SAM
//
//  Created on March 12, 2026.
//  Step-through update notification: generate → edit → send, one participant at a time.
//  Shown when material event details (time, venue, link, format) change.
//

import SwiftUI

struct EventUpdateSheet: View {

    let event: SamEvent
    let changes: EventCoordinator.EventChangeSummary
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var audience: EventCoordinator.UpdateAudience = .allContacted
    @State private var recipients: [EventParticipation] = []
    @State private var currentIndex = 0
    @State private var draftText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var sentCount = 0
    @State private var skippedCount = 0
    @State private var selectedChannel: CommunicationChannel = .iMessage
    @State private var didPickAudience = false

    private var currentParticipation: EventParticipation? {
        guard currentIndex < recipients.count else { return nil }
        return recipients[currentIndex]
    }

    private var currentPersonName: String {
        currentParticipation?.person?.displayNameCache ?? "Unknown"
    }

    private var isFinished: Bool {
        currentIndex >= recipients.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !didPickAudience {
                audiencePicker
            } else if recipients.isEmpty {
                ContentUnavailableView(
                    "No One to Notify",
                    systemImage: "checkmark.circle",
                    description: Text("No participants match the selected audience")
                )
                .frame(maxHeight: .infinity)
            } else if isFinished {
                completionView
                    .frame(maxHeight: .infinity)
            } else {
                draftEditor
            }

            Divider()
            footer
        }
        .frame(width: 620, height: 540)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send Event Update")
                    .samFont(.title3, weight: .bold)
                if didPickAudience && !recipients.isEmpty && !isFinished {
                    Text("\(currentIndex + 1) of \(recipients.count) — \(currentPersonName)")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if didPickAudience && !recipients.isEmpty {
                Text("\(sentCount) sent, \(skippedCount) skipped")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Audience Picker

    private var audiencePicker: some View {
        VStack(spacing: 20) {
            // Change summary
            VStack(alignment: .leading, spacing: 8) {
                Label("What Changed", systemImage: "arrow.triangle.2.circlepath")
                    .samFont(.headline)

                Text(changes.changeDescription)
                    .samFont(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }

            // Audience selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Who should be notified?")
                    .samFont(.headline)

                ForEach(EventCoordinator.UpdateAudience.allCases, id: \.self) { option in
                    let count = EventCoordinator.shared.participantsForUpdate(event: event, audience: option).count
                    Button {
                        audience = option
                    } label: {
                        HStack {
                            Image(systemName: audience == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(audience == option ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.rawValue)
                                    .samFont(.callout, weight: .bold)
                                Text("\(option.description) (\(count) \(count == 1 ? "person" : "people"))")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(audience == option ? Color.blue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Draft Editor

    private var draftEditor: some View {
        VStack(spacing: 0) {
            if let participation = currentParticipation {
                HStack(spacing: 8) {
                    Text(currentPersonName)
                        .samFont(.headline)

                    Text(participation.rsvpStatus.displayName)
                        .samFont(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(rsvpColor(participation.rsvpStatus).opacity(0.2), in: Capsule())
                        .foregroundStyle(rsvpColor(participation.rsvpStatus))

                    Spacer()

                    Picker("Send via", selection: $selectedChannel) {
                        Label("iMessage", systemImage: "message.fill")
                            .tag(CommunicationChannel.iMessage)
                        Label("Email", systemImage: "envelope.fill")
                            .tag(CommunicationChannel.email)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .onChange(of: selectedChannel) {
                        Task { await generateCurrentDraft() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.3))
            }

            if isGenerating {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Generating update for \(currentPersonName)...")
                        .samFont(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $draftText)
                    .samFont(.body)
                    .padding(8)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .samFont(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") {
                        Task { await generateCurrentDraft() }
                    }
                    .samFont(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Completion View

    private var completionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Updates Sent")
                .samFont(.title2, weight: .bold)

            VStack(spacing: 4) {
                if sentCount > 0 {
                    Text("\(sentCount) update\(sentCount == 1 ? "" : "s") sent")
                        .foregroundStyle(.green)
                }
                if skippedCount > 0 {
                    Text("\(skippedCount) skipped")
                        .foregroundStyle(.secondary)
                }
            }
            .samFont(.callout)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Close") {
                onComplete()
                dismiss()
            }
            .keyboardShortcut(.escape)

            Spacer()

            if !didPickAudience {
                Button("Continue") {
                    recipients = EventCoordinator.shared.participantsForUpdate(event: event, audience: audience)
                        .sorted { ($0.person?.displayNameCache ?? "") < ($1.person?.displayNameCache ?? "") }
                    didPickAudience = true
                    if !recipients.isEmpty {
                        setDefaultChannel()
                        Task { await generateCurrentDraft() }
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if !isFinished && !recipients.isEmpty {
                Button("Skip") {
                    skippedCount += 1
                    advanceToNext()
                }
                .disabled(isGenerating)

                Button("Send") {
                    sendAndAdvance()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || draftText.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func generateCurrentDraft() async {
        guard let participation = currentParticipation else { return }
        isGenerating = true
        errorMessage = nil
        draftText = ""

        do {
            let text = try await EventCoordinator.shared.generateUpdateText(
                for: participation,
                changes: changes,
                channel: selectedChannel
            )
            draftText = text
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }

    private func sendAndAdvance() {
        guard let participation = currentParticipation else { return }
        do {
            try EventCoordinator.shared.sendUpdateNotification(
                for: participation,
                body: draftText,
                channel: selectedChannel
            )
            sentCount += 1
            advanceToNext()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func advanceToNext() {
        currentIndex += 1
        draftText = ""
        errorMessage = nil
        if !isFinished {
            setDefaultChannel()
            Task { await generateCurrentDraft() }
        }
    }

    private func setDefaultChannel() {
        guard let participation = currentParticipation, let person = participation.person else { return }
        if let existing = participation.inviteChannel {
            selectedChannel = existing
        } else if person.emailCache != nil && person.phoneAliases.isEmpty {
            selectedChannel = .email
        } else {
            selectedChannel = .iMessage
        }
    }

    private func rsvpColor(_ status: RSVPStatus) -> Color {
        switch status {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        default: return .blue
        }
    }
}
