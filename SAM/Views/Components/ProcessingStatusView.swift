//
//  ProcessingStatusView.swift
//  SAM
//
//  Created by Assistant on 2/15/26.
//  Phase J Part 4: Background processing status indicator
//
//  Displays a spinner + label in the sidebar footer when AI processing is active.
//

import SwiftUI

struct ProcessingStatusView: View {
    @State private var contactsCoordinator = ContactsImportCoordinator.shared
    @State private var mailCoordinator = MailImportCoordinator.shared
    @State private var insightGenerator = InsightGenerator.shared
    @State private var calendarCoordinator = CalendarImportCoordinator.shared
    @State private var commsCoordinator = CommunicationsImportCoordinator.shared
    @State private var noteAnalysis = NoteAnalysisCoordinator.shared
    @State private var outcomeEngine = OutcomeEngine.shared
    @State private var briefingCoordinator = DailyBriefingCoordinator.shared
    @State private var evernoteCoordinator = EvernoteImportCoordinator.shared

    var body: some View {
        let activities = activeLabels
        if !activities.isEmpty {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                Text(activities.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var activeLabels: [String] {
        var labels: [String] = []
        if contactsCoordinator.importStatus == .importing {
            labels.append("Importing contacts\u{2026}")
        }
        if calendarCoordinator.importStatus == .importing {
            labels.append("Importing calendar\u{2026}")
        }
        if mailCoordinator.importStatus == .importing {
            labels.append("Importing emails\u{2026}")
        }
        if commsCoordinator.importStatus == .importing {
            labels.append("Importing messages\u{2026}")
        }
        if evernoteCoordinator.importStatus == .importing {
            labels.append("Importing notes\u{2026}")
        }
        if noteAnalysis.analysisStatus == .analyzing {
            labels.append("Analyzing notes\u{2026}")
        }
        if insightGenerator.generationStatus == .generating {
            labels.append("Generating insights\u{2026}")
        }
        if outcomeEngine.generationStatus == .generating {
            labels.append("Generating coaching\u{2026}")
        }
        if briefingCoordinator.generationStatus == .generating {
            labels.append("Preparing briefing\u{2026}")
        }
        return labels
    }
}
