//
//  PostMeetingCaptureView.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase T: Meeting Lifecycle Automation Enhancement
//
//  Structured post-meeting capture sheet replacing plain-text templates.
//  Four sections: Discussion, Action Items, Follow-Up, Life Events.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "PostMeetingCaptureView")

struct PostMeetingCaptureView: View {

    // MARK: - Parameters

    let eventTitle: String
    let eventDate: Date
    let attendeeIDs: [UUID]
    let onSave: () -> Void

    // MARK: - State

    @State private var discussionText = ""
    @State private var actionItems: [ActionItemEntry] = [ActionItemEntry()]
    @State private var followUpText = ""
    @State private var lifeEventsText = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    // Dictation state per section
    @State private var activeDictationSection: DictationSection?
    @State private var dictationService = DictationService.shared
    @State private var accumulatedSegments: [String] = []
    @State private var lastSegmentPeakLength = 0

    @Environment(\.dismiss) private var dismiss

    // MARK: - Types

    struct ActionItemEntry: Identifiable {
        let id = UUID()
        var description: String = ""
    }

    private enum DictationSection {
        case discussion, followUp, lifeEvents
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    discussionSection
                    actionItemsSection
                    followUpSection
                    lifeEventsSection
                }
                .padding()
            }

            Divider()

            // Footer
            footer
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 500, idealHeight: 650)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Meeting Notes")
                .font(.title2)
                .fontWeight(.semibold)
            HStack(spacing: 8) {
                Text(eventTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(eventDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    // MARK: - Discussion Section

    private var discussionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Discussion", icon: "text.bubble", dictationSection: .discussion)

            TextEditor(text: $discussionText)
                .font(.body)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if discussionText.isEmpty {
                        Text("Key discussion points, decisions made, important context...")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Action Items Section

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundStyle(.orange)
                Text("Action Items")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }

            ForEach($actionItems) { $item in
                HStack(spacing: 8) {
                    Image(systemName: "circle")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    TextField("Action item...", text: $item.description)
                        .textFieldStyle(.plain)
                        .font(.body)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }

            Button {
                actionItems.append(ActionItemEntry())
            } label: {
                Label("Add Action Item", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Follow-Up Section

    private var followUpSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Follow-Up", icon: "arrow.turn.up.right", dictationSection: .followUp)

            TextEditor(text: $followUpText)
                .font(.body)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if followUpText.isEmpty {
                        Text("Commitments made, next steps, deadlines...")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Life Events Section

    private var lifeEventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Life Events", icon: "star", dictationSection: .lifeEvents)

            TextEditor(text: $lifeEventsText)
                .font(.body)
                .frame(minHeight: 40)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if lifeEventsText.isEmpty {
                        Text("Birthdays, anniversaries, milestones mentioned...")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Section Header with Dictation

    private func sectionHeader(_ title: String, icon: String, dictationSection: DictationSection) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.blue)
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            Spacer()
            Button {
                if activeDictationSection == dictationSection {
                    stopDictation()
                } else {
                    startDictation(for: dictationSection)
                }
            } label: {
                Image(systemName: activeDictationSection == dictationSection ? "mic.fill" : "mic")
                    .font(.caption)
                    .foregroundStyle(activeDictationSection == dictationSection ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(activeDictationSection == dictationSection ? "Stop dictation" : "Dictate")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button("Cancel") {
                stopDictation()
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])

            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(isSaving || !hasContent)
        }
        .padding()
    }

    // MARK: - Computed

    private var hasContent: Bool {
        !discussionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || actionItems.contains(where: { !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        || !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        errorMessage = nil

        let dateStr = eventDate.formatted(date: .abbreviated, time: .shortened)

        // Compose combined content
        var parts: [String] = []
        parts.append("Meeting: \(eventTitle)")
        parts.append("Date: \(dateStr)")
        parts.append("")

        let discussion = discussionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !discussion.isEmpty {
            parts.append("Discussion:")
            parts.append(discussion)
            parts.append("")
        }

        let validActions = actionItems.map(\.description).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !validActions.isEmpty {
            parts.append("Action Items:")
            for action in validActions {
                parts.append("- \(action)")
            }
            parts.append("")
        }

        let followUp = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !followUp.isEmpty {
            parts.append("Follow-Up:")
            parts.append(followUp)
            parts.append("")
        }

        let lifeEvents = lifeEventsText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lifeEvents.isEmpty {
            parts.append("Life Events:")
            parts.append(lifeEvents)
        }

        let content = parts.joined(separator: "\n")

        do {
            let note = try NotesRepository.shared.create(
                content: content,
                sourceType: .typed,
                linkedPeopleIDs: attendeeIDs
            )

            logger.info("Created post-meeting note for '\(eventTitle)' with \(attendeeIDs.count) attendees")

            // Background analysis
            Task {
                await NoteAnalysisCoordinator.shared.analyzeNote(note)
            }

            isSaving = false
            onSave()
            dismiss()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            isSaving = false
            logger.error("Post-meeting note save failed: \(error)")
        }
    }

    // MARK: - Dictation

    private func startDictation(for section: DictationSection) {
        // Stop any active dictation first
        if activeDictationSection != nil {
            stopDictation()
        }

        let availability = dictationService.checkAvailability()
        guard availability == .available else {
            errorMessage = "Speech recognition is not available"
            return
        }

        activeDictationSection = section
        accumulatedSegments = []
        lastSegmentPeakLength = 0

        // Preserve existing text
        let existingText = currentText(for: section).trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingText.isEmpty {
            accumulatedSegments.append(existingText)
        }

        Task {
            do {
                let stream = try await dictationService.startRecognition()
                for await result in stream {
                    let currentText = result.text

                    if currentText.count < lastSegmentPeakLength / 2 && lastSegmentPeakLength > 5 {
                        let previousSegment = extractCurrentSegment(for: section)
                        if !previousSegment.isEmpty {
                            accumulatedSegments.append(previousSegment)
                        }
                        lastSegmentPeakLength = 0
                    }

                    lastSegmentPeakLength = max(lastSegmentPeakLength, currentText.count)

                    let prefix = accumulatedSegments.joined(separator: " ")
                    let fullText = prefix.isEmpty ? currentText : "\(prefix) \(currentText)"
                    setCurrentText(fullText, for: section)

                    if result.isFinal {
                        activeDictationSection = nil
                    }
                }
                if activeDictationSection != nil {
                    activeDictationSection = nil
                    dictationService.stopRecognition()
                }
            } catch {
                errorMessage = error.localizedDescription
                activeDictationSection = nil
            }
        }
    }

    private func stopDictation() {
        dictationService.stopRecognition()
        activeDictationSection = nil
    }

    private func currentText(for section: DictationSection) -> String {
        switch section {
        case .discussion: return discussionText
        case .followUp: return followUpText
        case .lifeEvents: return lifeEventsText
        }
    }

    private func setCurrentText(_ text: String, for section: DictationSection) {
        switch section {
        case .discussion: discussionText = text
        case .followUp: followUpText = text
        case .lifeEvents: lifeEventsText = text
        }
    }

    private func extractCurrentSegment(for section: DictationSection) -> String {
        let prefix = accumulatedSegments.joined(separator: " ")
        let full = currentText(for: section).trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty {
            return full
        }
        if full.hasPrefix(prefix) {
            return String(full.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }
}

// MARK: - Payload for notification-driven presentation

struct PostMeetingPayload: Identifiable {
    let id = UUID()
    let eventTitle: String
    let eventDate: Date
    let attendeeIDs: [UUID]
}
