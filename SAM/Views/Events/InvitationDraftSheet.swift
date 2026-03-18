//
//  InvitationDraftSheet.swift
//  SAM
//
//  Created on March 11, 2026.
//  Step-through invitation drafting: generate → edit → send, one participant at a time.
//

import SwiftUI

struct InvitationDraftSheet: View {

    let event: SamEvent
    var singleParticipation: EventParticipation?
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var uninvited: [EventParticipation] = []
    @State private var currentIndex = 0
    @State private var draftText = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var sentCount = 0
    @State private var skippedCount = 0
    @State private var originalDraftText = ""
    @State private var selectedChannel: CommunicationChannel = .iMessage

    private var currentParticipation: EventParticipation? {
        guard currentIndex < uninvited.count else { return nil }
        return uninvited[currentIndex]
    }

    private var currentPersonName: String {
        currentParticipation?.person?.displayNameCache ?? "Unknown"
    }

    private var isFinished: Bool {
        currentIndex >= uninvited.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            if uninvited.isEmpty {
                ContentUnavailableView(
                    "Everyone Has Been Invited",
                    systemImage: "checkmark.circle",
                    description: Text("All participants already have invitation drafts")
                )
                .frame(maxHeight: .infinity)
            } else if isFinished {
                completionView
                    .frame(maxHeight: .infinity)
            } else {
                // Draft editor
                draftEditor
            }

            Divider()
            // Footer
            footer
        }
        .frame(width: 600, height: 500)
        .task {
            if let single = singleParticipation {
                uninvited = [single]
            } else {
                uninvited = EventRepository.shared.fetchParticipations(for: event)
                    .filter { $0.inviteStatus == .notInvited }
                    .sorted { ($0.person?.displayNameCache ?? "") < ($1.person?.displayNameCache ?? "") }
            }
            if !uninvited.isEmpty {
                // Set default channel for first person
                if let first = uninvited.first, let person = first.person {
                    if let existing = first.inviteChannel {
                        selectedChannel = existing
                    } else if person.emailCache != nil && person.phoneAliases.isEmpty {
                        selectedChannel = .email
                    } else {
                        selectedChannel = .iMessage
                    }
                }
                await generateCurrentDraft()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Draft Invitations")
                    .samFont(.title3, weight: .bold)
                if !uninvited.isEmpty && !isFinished {
                    Text("\(currentIndex + 1) of \(uninvited.count) — \(currentPersonName)")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Progress indicator
            if !uninvited.isEmpty {
                Text("\(sentCount) sent, \(skippedCount) skipped")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Draft Editor

    private var draftEditor: some View {
        VStack(spacing: 0) {
            // Recipient info bar
            if let participation = currentParticipation {
                HStack(spacing: 8) {
                    Text(currentPersonName)
                        .samFont(.headline)
                    if let roles = participation.person?.roleBadges, !roles.isEmpty {
                        ForEach(roles.prefix(3), id: \.self) { badge in
                            Text(badge)
                                .samFont(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Spacer()

                    // Channel picker
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

                    if participation.priority != .standard {
                        Label(participation.priority.displayName, systemImage: participation.priority.icon)
                            .samFont(.caption)
                            .foregroundStyle(participation.priority == .vip ? .yellow : .blue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.3))
            }

            // Text editor area
            if isGenerating {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Generating invitation for \(currentPersonName)...")
                        .samFont(.callout)
                        .foregroundStyle(.secondary)
                    ProgressView(value: nil as Double?)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
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

            Text("All Done")
                .samFont(.title2, weight: .bold)

            VStack(spacing: 4) {
                if sentCount > 0 {
                    Text("\(sentCount) invitation\(sentCount == 1 ? "" : "s") sent")
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

            if !isFinished && !uninvited.isEmpty {
                Button("Skip") {
                    skippedCount += 1
                    advanceToNext()
                }
                .disabled(isGenerating)

                Button("Save as Draft") {
                    saveDraft()
                    advanceToNext()
                }
                .disabled(isGenerating || draftText.isEmpty)

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
            let text = try await EventCoordinator.shared.generateInvitationText(for: participation, channel: selectedChannel)
            draftText = text
            originalDraftText = text
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }

    private func saveDraft() {
        guard let participation = currentParticipation else { return }
        do {
            try EventCoordinator.shared.saveInvitationDraft(for: participation, body: draftText, channel: selectedChannel)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendAndAdvance() {
        guard let participation = currentParticipation else { return }
        learnClosingIfChanged(person: participation.person)
        do {
            try EventCoordinator.shared.sendInvitation(for: participation, body: draftText, channel: selectedChannel)
            sentCount += 1
            // Auto-dismiss for single-participant flow
            if singleParticipation != nil {
                onComplete()
                dismiss()
                return
            }
            advanceToNext()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func advanceToNext() {
        currentIndex += 1
        draftText = ""
        originalDraftText = ""
        errorMessage = nil
        if !isFinished {
            // Default channel for new person: use their existing inviteChannel or infer from contact info
            if let next = currentParticipation, let person = next.person {
                if let existing = next.inviteChannel {
                    selectedChannel = existing
                } else if person.emailCache != nil && person.phoneAliases.isEmpty {
                    selectedChannel = .email
                } else {
                    selectedChannel = .iMessage
                }
            }
            Task { await generateCurrentDraft() }
        }
    }

    /// Detect if the user changed the closing/signature and learn the preference.
    private func learnClosingIfChanged(person: SamPerson?) {
        let editedClosing = extractClosing(from: draftText)
        let originalClosing = extractClosing(from: originalDraftText)
        guard let edited = editedClosing, edited != originalClosing else { return }

        // Determine warmth from recent evidence
        let isWarm: Bool = {
            guard let person else { return true }
            let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .now
            return person.linkedEvidence.filter { $0.occurredAt > cutoff }.count >= 3
        }()

        AIService.learnClosing(edited, forMessageKind: "invitation", isWarm: isWarm)
    }

    /// Extract the closing line (e.g. "Best,") from the last few lines of a message.
    private func extractClosing(from text: String) -> String? {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Closing is typically the second-to-last line (last line is the name)
        guard lines.count >= 2 else { return nil }
        let candidate = lines[lines.count - 2]
        // Closing lines are short and usually end with a comma
        if candidate.count <= 30 {
            return candidate
        }
        return nil
    }
}
