//
//  MinionsView.swift
//  SAM
//
//  Sidebar footer showing background activity. Two sections:
//
//  - **AI activity** (top) — reads InferenceRegistry, the source of truth
//    for any FoundationModels / MLX call. New labeled task = new row, no
//    MinionsView update required. Replaces the old hand-curated AI rows
//    that hid the actual specialist running underneath umbrella states
//    like "Strategy" or "Briefing".
//
//  - **Imports** (bottom) — coordinator-level rows for non-AI work that
//    doesn't flow through the inference gate (Contacts/Calendar/Mail/
//    Comms/Evernote/LinkedIn/Facebook syncs, plus rule-based engines
//    like InsightGenerator and RoleDeductionEngine).
//

import SwiftUI

struct MinionItem: Identifiable {
    let id: String
    let icon: String
    let label: String
    let tooltip: String
    let isRunning: Bool

    init(id: String, icon: String, label: String, tooltip: String, isRunning: Bool = true) {
        self.id = id
        self.icon = icon
        self.label = label
        self.tooltip = tooltip
        self.isRunning = isRunning
    }
}

struct MinionsView: View {
    @State private var registry = InferenceRegistry.shared
    @State private var contactsCoordinator = ContactsImportCoordinator.shared
    @State private var calendarCoordinator = CalendarImportCoordinator.shared
    @State private var mailCoordinator = MailImportCoordinator.shared
    @State private var commsCoordinator = CommunicationsImportCoordinator.shared
    @State private var evernoteCoordinator = EvernoteImportCoordinator.shared
    @State private var insightGenerator = InsightGenerator.shared
    @State private var outcomeEngine = OutcomeEngine.shared
    @State private var roleDeduction = RoleDeductionEngine.shared
    @State private var linkedInCoordinator = LinkedInImportCoordinator.shared
    @State private var facebookCoordinator = FacebookImportCoordinator.shared

    var body: some View {
        let aiItems = aiActivityMinions
        let importItems = importMinions
        let allItems = aiItems + importItems

        if !allItems.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allItems) { minion in
                        MinionRow(item: minion)
                    }
                }
            }
            .frame(maxHeight: 130)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .animation(.easeInOut(duration: 0.3), value: allItems.map(\.id))
        }
    }

    // MARK: - AI Activity (registry-driven)

    /// One row per distinct AI label. Running groups sort first; queued
    /// items show paler/no spinner so the user can tell what's happening
    /// vs what's waiting. Count badge for repeats (e.g. batch note
    /// analysis would show "Note analysis ×3").
    private var aiActivityMinions: [MinionItem] {
        registry.groupedActivity.map { group in
            let countSuffix = group.count > 1 ? " ×\(group.count)" : ""
            let label = group.label + countSuffix
            let tooltip = group.isRunning
                ? "\(group.label) — running"
                : "\(group.label) — queued"
            return MinionItem(
                id: "ai.\(group.id)",
                icon: group.icon,
                label: label,
                tooltip: tooltip,
                isRunning: group.isRunning
            )
        }
    }

    // MARK: - Imports + non-AI work

    private var importMinions: [MinionItem] {
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
                label: "Emails", tooltip: "Importing emails"))
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
        if linkedInCoordinator.importStatus == .parsing || linkedInCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "linkedin", icon: "link",
                label: "LinkedIn", tooltip: "Processing LinkedIn data"))
        }
        if linkedInCoordinator.pdfScanStatus == .scanning || linkedInCoordinator.pdfScanStatus == .importing {
            items.append(MinionItem(
                id: "linkedinPDF", icon: "doc.text.magnifyingglass",
                label: linkedInCoordinator.pdfScanProgress ?? "LinkedIn Profiles",
                tooltip: "Scanning and matching LinkedIn Profile PDFs"))
        }
        if facebookCoordinator.importStatus == .parsing || facebookCoordinator.importStatus == .importing {
            items.append(MinionItem(
                id: "facebook", icon: "face.smiling",
                label: "Facebook", tooltip: "Processing Facebook data"))
        }

        // Rule-based engines (no AI inference, so not in the registry)
        if insightGenerator.generationStatus == .generating {
            items.append(MinionItem(
                id: "insights", icon: "lightbulb",
                label: "Insights", tooltip: "Generating relationship insights"))
        }
        if outcomeEngine.generationStatus == .generating {
            items.append(MinionItem(
                id: "coaching", icon: "arrow.triangle.turn.up.right.diamond",
                label: "Coaching", tooltip: "Refreshing coaching outcomes"))
        }
        if roleDeduction.deductionStatus == .running {
            items.append(MinionItem(
                id: "roles", icon: "person.text.rectangle",
                label: "Roles", tooltip: "Deducing roles from your data"))
        }

        return items
    }
}

private struct MinionRow: View {
    let item: MinionItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .samFont(.caption2)
                .foregroundStyle(item.isRunning ? .tertiary : .quaternary)
                .frame(width: 14)
            Text(item.label)
                .samFont(.caption)
                .foregroundStyle(item.isRunning ? .secondary : .tertiary)
            Spacer()
            if item.isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "hourglass")
                    .samFont(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(item.tooltip)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
