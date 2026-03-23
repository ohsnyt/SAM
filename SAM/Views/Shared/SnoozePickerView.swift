//
//  SnoozePickerView.swift
//  SAM
//
//  Created on March 23, 2026.
//  Compact popover for snoozing an outcome to a future date.
//

import SwiftUI

struct SnoozePickerView: View {

    @Binding var date: Date
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let calendar = Calendar.current

    private var tomorrow: Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))!
    }

    private var in3Days: Date {
        calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: .now))!
    }

    private var nextMonday: Date {
        let today = calendar.startOfDay(for: .now)
        let weekday = calendar.component(.weekday, from: today)
        let daysUntilMonday = (9 - weekday) % 7  // Sunday=1, Mon=2, ...
        let days = daysUntilMonday == 0 ? 7 : daysUntilMonday
        return calendar.date(byAdding: .day, value: days, to: today)!
    }

    private var nextWeek: Date {
        calendar.date(byAdding: .weekOfYear, value: 1, to: calendar.startOfDay(for: .now))!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Snooze until")
                .samFont(.headline)

            // Quick-pick buttons
            HStack(spacing: 6) {
                quickButton("Tomorrow", date: tomorrow)
                quickButton("3 Days", date: in3Days)
                quickButton("Monday", date: nextMonday)
                quickButton("1 Week", date: nextWeek)
            }

            Divider()

            // Custom date picker
            DatePicker(
                "Custom date",
                selection: $date,
                in: tomorrow...,
                displayedComponents: .date
            )
            .datePickerStyle(.field)
            .labelsHidden()

            HStack {
                Spacer()
                Button("Snooze") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func quickButton(_ label: String, date: Date) -> some View {
        Button(label) {
            self.date = date
            onConfirm()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
