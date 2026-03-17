//
//  EventFormView.swift
//  SAM
//
//  Created on March 11, 2026.
//  Event creation/editing form.
//

import SwiftUI
import MapKit

struct EventFormView: View {

    @Environment(\.dismiss) private var dismiss

    /// When editing, pass the existing event. Nil means create mode.
    var existingEvent: SamEvent?
    var onCreated: ((SamEvent) -> Void)?
    /// Called after saving changes. Passes the change summary if material details changed (time, venue, link, format).
    var onUpdated: ((EventCoordinator.EventChangeSummary?) -> Void)?

    @State private var title = ""
    @State private var description = ""
    @State private var format: EventFormat = .inPerson
    @State private var startDate = Self.learnedDefaultDate()
    @State private var durationMinutes = 60
    @State private var venue = ""
    @State private var address = ""
    @State private var addressValidationMessage: String?
    @State private var isValidatingAddress = false
    @State private var lastValidatedAddress: String?
    @State private var joinLink = ""
    @State private var targetParticipants = 20

    // Auto-acknowledge
    @State private var autoAckEnabled = true
    @State private var autoAckTemplate = "Thanks {name}! See you at {date}."
    @State private var autoAckDeclines = false
    @State private var autoAckDeclineTemplate = "Thanks for letting me know, {name}!"
    @State private var autoReplyUnknownSenders = false

    // Topic suggestions
    @State private var selectedTopic: SuggestedEventTopic?
    @State private var isGeneratingDescription = false
    @State private var showTopicSuggestions = true

    // Confirmation
    @State private var showMaterialChangeConfirmation = false

    private var isEditing: Bool { existingEvent != nil }

    private var suggestedTopics: [SuggestedEventTopic] {
        StrategicCoordinator.shared.suggestedEventTopics
    }

    // MARK: - Validation

    private var needsVenue: Bool {
        format == .inPerson || format == .hybrid
    }

    private var needsJoinLink: Bool {
        format == .virtual || format == .hybrid
    }

    private var venueValid: Bool {
        !needsVenue || !venue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var addressValid: Bool {
        !needsVenue || !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var joinLinkValid: Bool {
        !needsJoinLink || !joinLink.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && venueValid && addressValid && joinLinkValid
    }

    /// True when the event has participants who have already been invited.
    private var hasInvitees: Bool {
        guard let event = existingEvent else { return false }
        return event.participations.contains { $0.inviteStatus != .notInvited }
    }

    /// Number of people already contacted.
    private var inviteeCount: Int {
        guard let event = existingEvent else { return 0 }
        return event.participations.filter { $0.inviteStatus != .notInvited }.count
    }

    /// Detects whether the user has made material changes that would affect invitees.
    private var hasMaterialChanges: Bool {
        guard let event = existingEvent else { return false }
        if startDate != event.startDate { return true }
        if (venue.isEmpty ? nil : venue) != event.venue { return true }
        if (address.isEmpty ? nil : address) != event.address { return true }
        if (joinLink.isEmpty ? nil : joinLink) != event.joinLink { return true }
        if format != event.format { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit Event" : "New Event")
                    .font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            // Form
            Form {
                // Suggested Topics (only in create mode, when available)
                if !isEditing && !suggestedTopics.isEmpty && showTopicSuggestions {
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
                    if needsVenue {
                        TextField("Venue name", text: $venue)
                        TextField("Street address", text: $address)
                            .onChange(of: address) {
                                if address != lastValidatedAddress {
                                    addressValidationMessage = nil
                                    lastValidatedAddress = nil
                                }
                            }
                        if !venueValid {
                            Label("Venue is required for \(format.displayName.lowercased()) events", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !addressValid {
                            Label("Address is required for \(format.displayName.lowercased()) events", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !address.trimmingCharacters(in: .whitespaces).isEmpty {
                            HStack(spacing: 6) {
                                if isValidatingAddress {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Verifying address...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if let message = addressValidationMessage {
                                    Image(systemName: message.starts(with: "✓") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(message.starts(with: "✓") ? .green : .orange)
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(message.starts(with: "✓") ? .green : .orange)
                                } else {
                                    Button("Verify Address") {
                                        Task { await validateAddress() }
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    if needsJoinLink {
                        TextField("Join Link (Zoom, Teams, etc.)", text: $joinLink)
                        if !joinLinkValid {
                            Label("Join link is required for \(format.displayName.lowercased()) events", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    if !needsVenue && !needsJoinLink {
                        Text("No location needed for this format.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Material change warning (only when editing with existing invitees)
                if isEditing && hasInvitees {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Changes to date, time, venue, link, or format will prompt you to notify \(inviteeCount) invited \(inviteeCount == 1 ? "participant" : "participants").")
                                    .font(.caption)
                                if hasMaterialChanges {
                                    Text("You have unsaved changes that will affect invitees.")
                                        .font(.caption.bold())
                                        .foregroundStyle(.orange)
                                }
                            }
                        } icon: {
                            Image(systemName: hasMaterialChanges ? "exclamationmark.triangle.fill" : "info.circle")
                                .foregroundStyle(hasMaterialChanges ? .orange : .secondary)
                        }
                    }
                }

                Section("Auto-Acknowledgment") {
                    Toggle("Auto-acknowledge RSVPs", isOn: $autoAckEnabled)

                    if autoAckEnabled {
                        TextField("Acceptance template", text: $autoAckTemplate)
                            .font(.callout)

                        Text("Placeholders: {name} (first name), {date} (smart date & time)")
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

                    Toggle("Auto-reply to unknown senders", isOn: $autoReplyUnknownSenders)

                    Text(autoReplyUnknownSenders
                         ? "When an unknown number texts about this event, SAM will auto-send a holding reply if direct send is enabled."
                         : "Unknown sender holding replies will still fire if auto-acknowledge RSVPs is on above. Enable this to also send holding replies when auto-acknowledge is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(isEditing ? "Save Changes" : "Create Event") {
                    if isEditing {
                        if hasMaterialChanges && hasInvitees {
                            showMaterialChangeConfirmation = true
                        } else {
                            saveChanges()
                        }
                    } else {
                        createEvent()
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 520, height: 740)
        .task {
            if let event = existingEvent {
                populateFromEvent(event)
            }
        }
        .alert("Confirm Changes", isPresented: $showMaterialChangeConfirmation) {
            Button("Save Changes") {
                saveChanges()
            }
            .keyboardShortcut(.return)
            Button("Keep Editing", role: .cancel) {
                // Dismisses alert, returns to form
            }
            Button("Discard Changes", role: .destructive) {
                dismiss()
            }
        } message: {
            Text("You've changed details that \(inviteeCount) \(inviteeCount == 1 ? "person has" : "people have") already been invited with. After saving, SAM will ask if you'd like to notify them.\n\n\(materialChangeDescription)")
        }
    }

    /// Human-readable description of pending material changes for the confirmation alert.
    private var materialChangeDescription: String {
        guard let event = existingEvent else { return "" }
        var parts: [String] = []
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        if startDate != event.startDate {
            parts.append("Time: \(df.string(from: event.startDate)) → \(df.string(from: startDate))")
        }
        let newVenue = venue.isEmpty ? nil : venue
        let newAddress = address.isEmpty ? nil : address
        if newVenue != event.venue || newAddress != event.address {
            let from = [event.venue, event.address].compactMap { $0 }.joined(separator: ", ")
            let to = [newVenue, newAddress].compactMap { $0 }.joined(separator: ", ")
            parts.append("Location: \(from.isEmpty ? "none" : from) → \(to.isEmpty ? "none" : to)")
        }
        let newLink = joinLink.isEmpty ? nil : joinLink
        if newLink != event.joinLink {
            parts.append("Join link: \(event.joinLink != nil ? "changed" : "added")")
        }
        if format != event.format {
            parts.append("Format: \(event.format.displayName) → \(format.displayName)")
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Populate from existing event (edit mode)

    private func populateFromEvent(_ event: SamEvent) {
        title = event.title
        description = event.eventDescription ?? ""
        format = event.format
        startDate = event.startDate
        durationMinutes = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
        venue = event.venue ?? ""
        address = event.address ?? ""
        joinLink = event.joinLink ?? ""
        targetParticipants = event.targetParticipantCount
        autoAckEnabled = event.autoAcknowledgeEnabled
        autoAckTemplate = event.ackAcceptTemplate
        autoAckDeclines = event.ackDeclineTemplate != nil
        autoAckDeclineTemplate = event.ackDeclineTemplate ?? "Thanks for letting me know, {name}!"
        autoReplyUnknownSenders = event.autoReplyUnknownSenders
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
                address: address.isEmpty ? nil : address,
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
            event.autoReplyUnknownSenders = autoReplyUnknownSenders

            // Learn user's preferred lead time and time-of-day
            Self.recordEventDefaults(startDate: startDate)

            onCreated?(event)
            dismiss()
        } catch {
            // Error handling — could add @State alert here
        }
    }

    private func saveChanges() {
        guard let event = existingEvent else { return }

        // Detect material changes before saving
        var changes = EventCoordinator.EventChangeSummary()

        if startDate != event.startDate {
            changes.timeChanged = true
            changes.oldStartDate = event.startDate
            changes.newStartDate = startDate
        }

        let newVenue = venue.isEmpty ? nil : venue
        let newAddress = address.isEmpty ? nil : address
        if newVenue != event.venue || newAddress != event.address {
            changes.venueChanged = true
            changes.oldVenue = [event.venue, event.address].compactMap { $0 }.joined(separator: ", ")
            changes.newVenue = [newVenue, newAddress].compactMap { $0 }.joined(separator: ", ")
        }

        let newJoinLink = joinLink.isEmpty ? nil : joinLink
        if newJoinLink != event.joinLink {
            changes.joinLinkChanged = true
            changes.oldJoinLink = event.joinLink
            changes.newJoinLink = newJoinLink
        }

        if format != event.format {
            changes.formatChanged = true
            changes.oldFormat = event.format
            changes.newFormat = format
        }

        do {
            try EventRepository.shared.updateEvent(
                id: event.id,
                title: title,
                eventDescription: description.isEmpty ? nil : description,
                format: format,
                startDate: startDate,
                endDate: startDate.addingTimeInterval(Double(durationMinutes) * 60),
                venue: newVenue,
                address: newAddress,
                joinLink: newJoinLink,
                targetParticipantCount: targetParticipants
            )

            try EventRepository.shared.updateAutoAcknowledge(
                eventID: event.id,
                enabled: autoAckEnabled,
                acceptTemplate: autoAckTemplate,
                declineTemplate: autoAckDeclines ? autoAckDeclineTemplate : nil
            )
            event.autoReplyUnknownSenders = autoReplyUnknownSenders

            // Pass change summary only if there are material changes and people have been invited
            let hasInvitedParticipants = event.participations.contains { $0.inviteStatus != .notInvited }
            onUpdated?(changes.hasChanges && hasInvitedParticipants ? changes : nil)
            dismiss()
        } catch {
            // Error handling
        }
    }

    // MARK: - Address Validation

    private func validateAddress() async {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isValidatingAddress = true

        do {
            guard let request = MKGeocodingRequest(addressString: trimmed) else {
                addressValidationMessage = "Could not verify this address. Please check it."
                isValidatingAddress = false
                return
            }
            let items = try await request.mapItems
            if let item = items.first,
               let formatted = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true),
               !formatted.isEmpty, formatted != trimmed {
                lastValidatedAddress = formatted
                address = formatted
                addressValidationMessage = "✓ Verified: \(formatted)"
            } else if items.first != nil {
                lastValidatedAddress = address
                addressValidationMessage = "✓ Address verified"
            } else {
                addressValidationMessage = "Could not verify this address. Please check it."
            }
        } catch {
            addressValidationMessage = "Could not verify this address. Please check it."
        }
        isValidatingAddress = false
    }

    // MARK: - Learned Defaults

    private static let leadTimeDaysKey = "eventDefaultLeadTimeDays"
    private static let preferredHourKey = "eventDefaultPreferredHour"
    private static let eventCountKey = "eventDefaultEventCount"

    /// Compute a default start date based on learned preferences.
    /// Starts at 2 weeks out at 6 pm, then adapts based on user history.
    static func learnedDefaultDate() -> Date {
        let cal = Calendar.current
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: eventCountKey)

        let leadTimeDays: Int
        let preferredHour: Int

        if count >= 2 {
            // Use learned values
            leadTimeDays = defaults.integer(forKey: leadTimeDaysKey)
            preferredHour = defaults.integer(forKey: preferredHourKey)
        } else {
            // Initial defaults: 2 weeks out at 6 pm
            leadTimeDays = 14
            preferredHour = 18
        }

        let futureDate = cal.date(byAdding: .day, value: leadTimeDays, to: .now) ?? .now
        // Set to the preferred hour, 0 minutes
        var components = cal.dateComponents([.year, .month, .day], from: futureDate)
        components.hour = preferredHour
        components.minute = 0
        components.second = 0
        return cal.date(from: components) ?? futureDate
    }

    /// Record the user's chosen start date to learn their preferences over time.
    /// Uses a rolling average to smooth out one-off changes.
    static func recordEventDefaults(startDate: Date) {
        let cal = Calendar.current
        let defaults = UserDefaults.standard

        let leadTimeDays = cal.dateComponents([.day], from: .now, to: startDate).day ?? 14
        let hour = cal.component(.hour, from: startDate)
        let count = defaults.integer(forKey: eventCountKey)

        if count < 2 {
            // Not enough data yet — store raw values
            defaults.set(max(1, leadTimeDays), forKey: leadTimeDaysKey)
            defaults.set(hour, forKey: preferredHourKey)
        } else {
            // Rolling average (weight new value at ~30%)
            let oldDays = defaults.integer(forKey: leadTimeDaysKey)
            let oldHour = defaults.integer(forKey: preferredHourKey)
            let newDays = max(1, Int(round(Double(oldDays) * 0.7 + Double(leadTimeDays) * 0.3)))
            let newHour = Int(round(Double(oldHour) * 0.7 + Double(hour) * 0.3))
            defaults.set(newDays, forKey: leadTimeDaysKey)
            defaults.set(newHour, forKey: preferredHourKey)
        }

        defaults.set(count + 1, forKey: eventCountKey)
    }
}
