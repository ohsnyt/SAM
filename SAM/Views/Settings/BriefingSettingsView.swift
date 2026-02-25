//
//  BriefingSettingsView.swift
//  SAM
//
//  Created by Assistant on 2/24/26.
//  Daily Briefing System
//
//  Settings tab for configuring morning/evening briefings.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "BriefingSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct BriefingSettingsContent: View {

    // MARK: - State

    @State private var morningEnabled: Bool = UserDefaults.standard.object(forKey: "briefingMorningEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "briefingMorningEnabled")

    @State private var eveningEnabled: Bool = UserDefaults.standard.object(forKey: "briefingEveningEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "briefingEveningEnabled")

    @State private var eveningHour: Int = {
        let stored = UserDefaults.standard.integer(forKey: "briefingEveningHour")
        return stored > 0 ? stored : 17
    }()

    @State private var eveningMinute: Int = UserDefaults.standard.integer(forKey: "briefingEveningMinute")

    @State private var narrativeEnabled: Bool = UserDefaults.standard.object(forKey: "briefingNarrativeEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "briefingNarrativeEnabled")

    // Evening time options: 3 PM–10 PM in 15-min increments
    private var eveningTimeOptions: [(hour: Int, minute: Int, label: String)] {
        var options: [(Int, Int, String)] = []
        for h in 15...22 {
            for m in stride(from: 0, to: 60, by: 15) {
                let date = Calendar.current.date(from: DateComponents(hour: h, minute: m))!
                let label = date.formatted(date: .omitted, time: .shortened)
                options.append((h, m, label))
            }
        }
        return options
    }

    private var selectedTimeTag: String {
        "\(eveningHour):\(String(format: "%02d", eveningMinute))"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            morningSection

            Divider()

            eveningSection

            Divider()

            narrativeSection
        }
    }

    // MARK: - Sections

    private var morningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Morning Briefing")
                .font(.headline)

            Toggle("Show morning briefing on first open", isOn: $morningEnabled)
                .onChange(of: morningEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "briefingMorningEnabled")
                }

            Text("When enabled, SAM shows a daily briefing with your schedule, priority actions, and follow-ups when you first open the app each day.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var eveningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Evening Recap")
                .font(.headline)

            Toggle("Enable end-of-day summary", isOn: $eveningEnabled)
                .onChange(of: eveningEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "briefingEveningEnabled")
                }

            if eveningEnabled {
                HStack {
                    Text("Recap time:")
                    Picker("", selection: Binding(
                        get: { selectedTimeTag },
                        set: { newTag in
                            let parts = newTag.split(separator: ":")
                            if parts.count == 2,
                               let h = Int(parts[0]),
                               let m = Int(parts[1]) {
                                eveningHour = h
                                eveningMinute = m
                                UserDefaults.standard.set(h, forKey: "briefingEveningHour")
                                UserDefaults.standard.set(m, forKey: "briefingEveningMinute")
                            }
                        }
                    )) {
                        ForEach(eveningTimeOptions, id: \.label) { option in
                            Text(option.label).tag("\(option.hour):\(String(format: "%02d", option.minute))")
                        }
                    }
                    .frame(width: 140)
                }
            }

            Text("SAM will prompt you with a summary of today's accomplishments and tomorrow's highlights. The prompt is non-modal — you can defer or dismiss it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var narrativeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Narrative")
                .font(.headline)

            Toggle("Generate prose summary", isOn: $narrativeEnabled)
                .onChange(of: narrativeEnabled) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "briefingNarrativeEnabled")
                }

            Text("When enabled, SAM uses on-device AI to generate a brief narrative summary at the top of each briefing. Structured sections always appear regardless of this setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Standalone wrapper

struct BriefingSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Daily Briefings", systemImage: "text.book.closed")
                        .font(.title2)
                        .bold()

                    Divider()

                    BriefingSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}
