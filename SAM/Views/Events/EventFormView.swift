//
//  EventFormView.swift
//  SAM
//
//  Created on March 11, 2026.
//  Event creation/editing form.
//

import SwiftUI

struct EventFormView: View {

    @Environment(\.dismiss) private var dismiss

    var onCreated: ((SamEvent) -> Void)?

    @State private var title = ""
    @State private var description = ""
    @State private var format: EventFormat = .inPerson
    @State private var startDate = Date.now.addingTimeInterval(7 * 86400) // Default: 1 week out
    @State private var durationMinutes = 60
    @State private var venue = ""
    @State private var joinLink = ""
    @State private var targetParticipants = 20

    // Auto-acknowledge
    @State private var autoAckEnabled = true
    @State private var autoAckTemplate = "Thanks {name}! See you on {date}."
    @State private var autoAckDeclines = false
    @State private var autoAckDeclineTemplate = "Thanks for letting me know, {name}!"

    // Topic suggestions
    @State private var selectedTopic: SuggestedEventTopic?
    @State private var isGeneratingDescription = false
    @State private var showTopicSuggestions = true

    private var suggestedTopics: [SuggestedEventTopic] {
        StrategicCoordinator.shared.suggestedEventTopics
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Event")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            // Form
            Form {
                // Suggested Topics (when available)
                if !suggestedTopics.isEmpty && showTopicSuggestions {
                    suggestedTopicsSection
                }

                Section("Event Details") {
                    TextField("Title", text: $title)

                    HStack(alignment: .top) {
                        TextField("Description (optional)", text: $description, axis: .vertical)
                            .lineLimit(2...4)

                        if !title.isEmpty {
                            Button {
                                Task { await generateDescription() }
                            } label: {
                                if isGeneratingDescription {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .help("Generate description from title")
                        }
                    }

                    Picker("Format", selection: $format) {
                        ForEach(EventFormat.allCases, id: \.self) { f in
                            Label(f.displayName, systemImage: f.icon).tag(f)
                        }
                    }

                    DatePicker("Start", selection: $startDate, displayedComponents: [.date, .hourAndMinute])

                    Picker("Duration", selection: $durationMinutes) {
                        ForEach(stride(from: 10, through: 60, by: 5).map { $0 }, id: \.self) { mins in
                            Text("\(mins) minutes").tag(mins)
                        }
                        Text("75 minutes").tag(75)
                        Text("90 minutes").tag(90)
                        Text("2 hours").tag(120)
                    }

                    Stepper("Target: \(targetParticipants) participants", value: $targetParticipants, in: 5...200, step: 5)
                }

                Section("Location") {
                    if format == .inPerson || format == .hybrid {
                        TextField("Venue", text: $venue)
                    }
                    if format == .virtual || format == .hybrid {
                        TextField("Join Link (Zoom, Teams, etc.)", text: $joinLink)
                    }
                }

                Section("Auto-Acknowledgment") {
                    Toggle("Auto-acknowledge RSVPs", isOn: $autoAckEnabled)

                    if autoAckEnabled {
                        TextField("Acceptance template", text: $autoAckTemplate)
                            .font(.callout)

                        Text("Placeholders: {name}, {date}")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Toggle("Also auto-acknowledge declines", isOn: $autoAckDeclines)

                        if autoAckDeclines {
                            TextField("Decline template", text: $autoAckDeclineTemplate)
                                .font(.callout)
                        }

                        Text("Auto-ack only applies to Standard priority participants. VIP and Key participants always get personal responses.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Create Event") {
                    createEvent()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(title.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 740)
    }

    // MARK: - Suggested Topics Section

    private var suggestedTopicsSection: some View {
        Section {
            DisclosureGroup("Suggested Topics", isExpanded: $showTopicSuggestions) {
                ForEach(suggestedTopics) { topic in
                    topicCard(topic)
                }
            }
        } footer: {
            Text("Based on recent conversations and seasonal trends")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func topicCard(_ topic: SuggestedEventTopic) -> some View {
        let isSelected = selectedTopic?.id == topic.id

        return Button {
            selectTopic(topic)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: topic.format.icon)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(topic.title)
                        .font(.callout.bold())
                        .lineLimit(2)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }

                Text(topic.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    ForEach(topic.targetAudience, id: \.self) { role in
                        Text(role)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let hook = topic.seasonalHook {
                        Text(hook)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .italic()
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func selectTopic(_ topic: SuggestedEventTopic) {
        selectedTopic = topic
        title = topic.title
        format = topic.format
    }

    private func generateDescription() async {
        isGeneratingDescription = true
        do {
            let generated = try await EventTopicAdvisorService.shared.generateDescription(
                title: title,
                rationale: selectedTopic?.rationale,
                audience: selectedTopic?.targetAudience ?? [],
                format: format
            )
            description = generated
        } catch {
            // Silently fail — user can write description manually
        }
        isGeneratingDescription = false
    }

    private func createEvent() {
        do {
            let event = try EventCoordinator.shared.createEvent(
                title: title,
                description: description.isEmpty ? nil : description,
                format: format,
                startDate: startDate,
                duration: Double(durationMinutes) * 60,
                venue: venue.isEmpty ? nil : venue,
                joinLink: joinLink.isEmpty ? nil : joinLink,
                targetParticipants: targetParticipants
            )

            // Apply auto-ack settings
            try EventRepository.shared.updateAutoAcknowledge(
                eventID: event.id,
                enabled: autoAckEnabled,
                acceptTemplate: autoAckTemplate,
                declineTemplate: autoAckDeclines ? autoAckDeclineTemplate : nil
            )

            onCreated?(event)
            dismiss()
        } catch {
            // Error handling — could add @State alert here
        }
    }
}
