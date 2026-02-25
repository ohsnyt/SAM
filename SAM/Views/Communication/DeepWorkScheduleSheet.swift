//
//  DeepWorkScheduleSheet.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Phase O: Intelligent Actions
//
//  Sheet for scheduling a calendar time block when a deep work outcome
//  is acted on. Creates an event on the "SAM Tasks" calendar.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DeepWorkScheduleSheet")

struct DeepWorkScheduleSheet: View {

    let payload: DeepWorkPayload
    let onScheduled: () -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var selectedDuration: Int
    @State private var selectedDate: Date = {
        // Default to next hour
        let cal = Calendar.current
        let now = Date()
        let nextHour = cal.date(byAdding: .hour, value: 1, to: now)!
        return cal.date(bySetting: .minute, value: 0, of: nextHour)!
    }()
    @State private var isScheduling = false
    @State private var errorMessage: String?

    // MARK: - Init

    init(payload: DeepWorkPayload, onScheduled: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.payload = payload
        self.onScheduled = onScheduled
        self.onCancel = onCancel
        _selectedDuration = State(initialValue: payload.suggestedDurationMinutes)
    }

    // MARK: - Duration Options

    private let durationOptions: [(label: String, minutes: Int)] = [
        ("30 min", 30),
        ("1 hour", 60),
        ("2 hours", 120),
        ("3 hours", 180),
    ]

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text("Schedule Deep Work")
                .font(.title3)
                .fontWeight(.semibold)

            // Outcome context
            VStack(alignment: .leading, spacing: 4) {
                Text(payload.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(payload.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                if let name = payload.personName {
                    HStack(spacing: 4) {
                        Image(systemName: "person")
                            .font(.caption2)
                        Text(name)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Duration picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Duration")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    ForEach(durationOptions, id: \.minutes) { option in
                        Button {
                            selectedDuration = option.minutes
                        } label: {
                            Text(option.label)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedDuration == option.minutes
                                    ? Color.accentColor.opacity(0.2)
                                    : Color(nsColor: .controlBackgroundColor))
                                .foregroundStyle(selectedDuration == option.minutes
                                    ? Color.accentColor
                                    : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Date/time picker
            VStack(alignment: .leading, spacing: 8) {
                Text("When")
                    .font(.subheadline)
                    .fontWeight(.medium)

                DatePicker(
                    "Start time",
                    selection: $selectedDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
            }

            // Time block preview
            let endDate = Calendar.current.date(byAdding: .minute, value: selectedDuration, to: selectedDate)!
            HStack(spacing: 4) {
                Image(systemName: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(selectedDate.formatted(date: .abbreviated, time: .shortened)) — \(endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // Action buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)

                Button("Create Task Block") {
                    scheduleTaskBlock()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isScheduling)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Actions

    private func scheduleTaskBlock() {
        isScheduling = true
        errorMessage = nil

        Task {
            let endDate = Calendar.current.date(byAdding: .minute, value: selectedDuration, to: selectedDate)!

            let eventID = await CalendarService.shared.createEvent(
                title: payload.title,
                startDate: selectedDate,
                endDate: endDate,
                notes: payload.rationale,
                calendarTitle: "SAM Tasks"
            )

            if eventID != nil {
                logger.info("Created deep work task block: \(payload.title)")
                onScheduled()
            } else {
                errorMessage = "Could not create calendar event. Check Calendar permissions in Settings."
                isScheduling = false
            }
        }
    }
}
