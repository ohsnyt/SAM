//
//  MinionsView.swift
//  SAM
//
//  Displays individual animated rows for each active background task in the sidebar footer.
//  Replaces the old comma-separated ProcessingStatusView.
//

import SwiftUI

struct MinionItem: Identifiable {
    let id: String
    let icon: String
    let label: String
    let tooltip: String
}

struct MinionsView: View {
    @State private var contactsCoordinator = ContactsImportCoordinator.shared
    @State private var calendarCoordinator = CalendarImportCoordinator.shared
    @State private var mailCoordinator = MailImportCoordinator.shared
    @State private var commsCoordinator = CommunicationsImportCoordinator.shared
    @State private var evernoteCoordinator = EvernoteImportCoordinator.shared
    @State private var noteAnalysis = NoteAnalysisCoordinator.shared
    @State private var insightGenerator = InsightGenerator.shared
    @State private var outcomeEngine = OutcomeEngine.shared
    @State private var briefingCoordinator = DailyBriefingCoordinator.shared
    @State private var strategicCoordinator = StrategicCoordinator.shared
    @State private var roleDeduction = RoleDeductionEngine.shared
    @State private var linkedInCoordinator = LinkedInImportCoordinator.shared
    @State private var facebookCoordinator = FacebookImportCoordinator.shared
    @State private var presentationAnalysis = PresentationAnalysisCoordinator.shared

    var body: some View {
        let minions = activeMinions
        if !minions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(minions) { minion in
                        MinionRow(item: minion)
                    }
                }
            }
            .frame(maxHeight: 130)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .animation(.easeInOut(duration: 0.3), value: minions.map(\.id))
        }
    }

    private var activeMinions: [MinionItem] {
        var items: [MinionItem] = []

        if contactsCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "contacts", icon: "person.crop.rectangle",
                label: "Contacts", tooltip: "Importing contacts from Apple Contacts"))
        }
        if calendarCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "calendar", icon: "calendar",
                label: "Calendar", tooltip: "Importing calendar events"))
        }
        if mailCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "emails", icon: "envelope",
                label: "Emails", tooltip: "Importing and analyzing emails"))
        }
        if commsCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "messages", icon: "message",
                label: "Messages", tooltip: "Importing iMessages and call records"))
        }
        if evernoteCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "notes", icon: "note.text",
                label: "Notes", tooltip: "Importing notes from Evernote"))
        }
        if noteAnalysis.analysisStatus == .analyzing || evernoteCoordinator.analysisTaskCount > 0 {
            items.append(MinionItem(
                id: "analyzing", icon: "sparkles",
                label: "Analyzing", tooltip: "Analyzing note content with AI"))
        }
        if insightGenerator.generationStatus == .generating {
            items.append(MinionItem(
                id: "insights", icon: "lightbulb",
                label: "Insights", tooltip: "Generating relationship insights"))
        }
        if outcomeEngine.generationStatus == .generating {
            items.append(MinionItem(
                id: "coaching", icon: "arrow.triangle.turn.up.right.diamond",
                label: "Coaching", tooltip: "Generating coaching suggestions"))
        }
        if briefingCoordinator.generationStatus == .generating {
            items.append(MinionItem(
                id: "briefing", icon: "sun.horizon",
                label: "Briefing", tooltip: "Preparing your daily briefing"))
        }
        if strategicCoordinator.generationStatus == .generating {
            items.append(MinionItem(
                id: "strategy", icon: "chart.bar.xaxis.ascending",
                label: "Strategy", tooltip: "Running business intelligence analysis"))
        }
        if roleDeduction.deductionStatus == .running {
            items.append(MinionItem(
                id: "roles", icon: "person.text.rectangle",
                label: "Roles", tooltip: "Deducing roles from your data"))
        }
        if linkedInCoordinator.importStatus == .parsing || linkedInCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "linkedin", icon: "link",
                label: "LinkedIn", tooltip: "Processing LinkedIn data"))
        }
        if facebookCoordinator.importStatus == .parsing || facebookCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "facebook", icon: "face.smiling",
                label: "Facebook", tooltip: "Processing Facebook data"))
        }
        if presentationAnalysis.analysisStatus == .extracting || presentationAnalysis.analysisStatus == .analyzing {
            let label = presentationAnalysis.analysisStatus == .extracting ? "Extracting" : "Analyzing"
            let title = presentationAnalysis.currentPresentationTitle ?? "presentation"
            items.append(MinionItem(
                id: "presentation", icon: "doc.richtext",
                label: label, tooltip: "Digesting \(title)"))
        }

        return items
    }
}

private struct MinionRow: View {
    let item: MinionItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(item.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            ProgressView()
                .controlSize(.mini)
        }
        .help(item.tooltip)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
