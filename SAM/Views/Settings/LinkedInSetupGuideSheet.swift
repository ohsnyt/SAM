//
//  LinkedInSetupGuideSheet.swift
//  SAM
//
//  Sheet view shown when the user acts on a LinkedIn notification setup guidance outcome.
//  Displays "why this matters" context, numbered steps, and action buttons.
//
//  Phase 6 — LinkedIn Notification Setup Guidance
//

import SwiftUI

// MARK: - LinkedInSetupGuideSheet

struct LinkedInSetupGuideSheet: View {

    // MARK: - Input

    let outcome: SamOutcome

    /// Called when the user taps "Done" (just closes the sheet).
    var onDone: () -> Void = {}

    /// Called when the user taps "Already Done" (records acknowledgement).
    var onAlreadyDone: () -> Void = {}

    /// Called when the user taps "Remind Me Later" (records dismissal).
    var onDismiss: () -> Void = {}

    // MARK: - Derived State

    private var payload: SetupGuidePayload? {
        let json = outcome.sourceInsightSummary
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SetupGuidePayload.self, from: data)
    }

    private var settingsURL: URL? {
        guard let urlString = outcome.draftMessageText ?? payload?.settingsURL else { return nil }
        return URL(string: urlString)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let payload {
                        whyItMattersSection(payload: payload)
                        stepsSection(payload: payload)
                    } else {
                        Text("Setup guidance is unavailable.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            Divider()

            // Action bar
            actionBar
        }
        .frame(width: 500, height: 460)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.2")
                .samFont(.title2)
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.title)
                    .samFont(.headline)
                Text("LinkedIn Notification Setup")
                    .samFont(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
    }

    private func whyItMattersSection(payload: SetupGuidePayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Why this matters", systemImage: "lightbulb")
                .samFont(.subheadline, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(payload.whyItMatters)
                .samFont(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepsSection(payload: SetupGuidePayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Steps", systemImage: "list.number")
                .samFont(.subheadline, weight: .semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(payload.instructions.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .samFont(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(.cyan, in: Circle())

                        Text(step)
                            .samFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Remind Me Later") {
                onDismiss()
            }
            .buttonStyle(.bordered)

            Button("Already Done") {
                onAlreadyDone()
            }
            .buttonStyle(.bordered)

            Spacer()

            if let url = settingsURL {
                Button("Open LinkedIn Settings") {
                    NSWorkspace.shared.open(url)
                    onDone()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

// MARK: - Preview

#Preview {
    let outcome = SamOutcome(
        title: "Enable LinkedIn message notifications",
        rationale: "SAM hasn't seen any LinkedIn message notifications yet.",
        outcomeKind: .setup,
        priorityScore: 0.7,
        sourceInsightSummary: {
            let payload = SetupGuidePayload(
                touchTypeRawValue: "message",
                userDefaultsKey: "sam.linkedin.setup.message",
                instructions: [
                    "Open LinkedIn Settings (link below)",
                    "Select \"Email\" in the left sidebar",
                    "Under the \"Messages\" category, click the edit icon",
                    "Set frequency to \"Individual email\"",
                    "Your changes save automatically"
                ],
                whyItMatters: "Message notifications let SAM detect when contacts reach out to you on LinkedIn, keeping your relationship timeline complete.",
                settingsURL: "https://www.linkedin.com/psettings/communications"
            )
            return (try? String(data: JSONEncoder().encode(payload), encoding: .utf8)) ?? ""
        }(),
        suggestedNextStep: "Open LinkedIn notification settings and follow the steps"
    )
    outcome.draftMessageText = "https://www.linkedin.com/psettings/communications"

    return LinkedInSetupGuideSheet(
        outcome: outcome,
        onDone: {},
        onAlreadyDone: {},
        onDismiss: {}
    )
}
