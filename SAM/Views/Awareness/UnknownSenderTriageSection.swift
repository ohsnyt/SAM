//
//  UnknownSenderTriageSection.swift
//  SAM
//
//  Compact triage list for unknown email/calendar senders in the Awareness view.
//  Radio buttons: Add | Not Now (default) | Never — staged until user clicks Done.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "UnknownSenderTriage")

/// Per-sender triage choice. Default is .notNow.
private enum TriageChoice: String, CaseIterable {
    case add       // promote to contact, reprocess emails
    case notNow    // dismiss for now, resurfaces on next email
    case never     // permanently block
}

struct UnknownSenderTriageSection: View {

    @State private var pendingSenders: [UnknownSender] = []
    @State private var choices: [UUID: TriageChoice] = [:]  // staged choices
    @State private var isSaving = false

    private let repository = UnknownSenderRepository.shared
    private let contactsService = ContactsService.shared
    private let peopleRepository = PeopleRepository.shared
    private var mailCoordinator: MailImportCoordinator { MailImportCoordinator.shared }
    private var calendarCoordinator: CalendarImportCoordinator { CalendarImportCoordinator.shared }

    var body: some View {
        // VStack is always present so lifecycle modifiers always fire.
        // Content inside is conditional — avoids Group + @ViewBuilder re-render bug.
        VStack(spacing: 0) {
            if !pendingSenders.isEmpty {
                triageCard
            }
        }
        .task {
            loadPendingSenders()
        }
        .onChange(of: mailCoordinator.importStatus) { _, newStatus in
            if newStatus == .success {
                loadPendingSenders()
            }
        }
        .onChange(of: calendarCoordinator.importStatus) { _, newStatus in
            if newStatus == .success {
                loadPendingSenders()
            }
        }
    }

    private var triageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Label("Unknown Senders", systemImage: "person.fill.questionmark")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text("\(pendingSenders.count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange)
                    .clipShape(Capsule())

                Spacer()

                if hasChanges {
                    Text("\(changesSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Column header
            HStack(spacing: 0) {
                Text("Add")
                    .frame(width: 36, alignment: .center)
                Text("Later")
                    .frame(width: 36, alignment: .center)
                Text("Never")
                    .frame(width: 36, alignment: .center)

                Text("Sender")
                    .padding(.leading, 8)

                Spacer()

                Text("Subject")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal)
            .padding(.bottom, 4)

            Divider()
                .padding(.horizontal)

            // Sender list
            VStack(spacing: 0) {
                // Personal / business senders (default: Later)
                ForEach(regularSenders, id: \.id) { sender in
                    TriageRow(sender: sender, choice: binding(for: sender.id))
                }

                // Mailing list / marketing senders (default: Never)
                if !marketingSenders.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.badge.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Mailing Lists & Marketing")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Defaulting to Never")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.top, regularSenders.isEmpty ? 0 : 8)
                    .padding(.bottom, 4)

                    if !regularSenders.isEmpty {
                        Divider().padding(.horizontal)
                    }

                    ForEach(marketingSenders, id: \.id) { sender in
                        TriageRow(sender: sender, choice: binding(for: sender.id))
                    }
                }
            }

            Divider()
                .padding(.horizontal)

            // Footer with Done button
            HStack {
                Spacer()

                if isSaving {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Saving...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Done") {
                    saveChoices()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSaving)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding()
    }

    // MARK: - Helpers

    private func binding(for id: UUID) -> Binding<TriageChoice> {
        Binding(
            get: { choices[id] ?? .notNow },
            set: { choices[id] = $0 }
        )
    }

    private var hasChanges: Bool {
        choices.values.contains(where: { $0 != .notNow })
    }

    private var changesSummary: String {
        let addCount = choices.values.filter { $0 == .add }.count
        let neverCount = choices.values.filter { $0 == .never }.count
        var parts: [String] = []
        if addCount > 0 { parts.append("\(addCount) to add") }
        if neverCount > 0 { parts.append("\(neverCount) to block") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Sender Groups

    /// Regular (personal/business) senders — default choice: Later.
    private var regularSenders: [UnknownSender] {
        pendingSenders.filter { !$0.isLikelyMarketing }
    }

    /// Likely mailing list or marketing senders — default choice: Never.
    private var marketingSenders: [UnknownSender] {
        pendingSenders.filter { $0.isLikelyMarketing }
    }

    // MARK: - Data Loading

    func loadPendingSenders() {
        do {
            let fetched = try repository.fetchPending()
            logger.info("loadPendingSenders: fetched \(fetched.count) pending senders")
            pendingSenders = fetched
            // Set default choice for any new senders:
            // marketing senders default to Never; personal senders default to Later.
            for sender in pendingSenders where choices[sender.id] == nil {
                choices[sender.id] = sender.isLikelyMarketing ? .never : .notNow
            }
            // Clean up choices for senders no longer pending
            let validIDs = Set(pendingSenders.map(\.id))
            choices = choices.filter { validIDs.contains($0.key) }
        } catch {
            logger.error("loadPendingSenders failed: \(error)")
        }
    }

    // MARK: - Save

    private func saveChoices() {
        isSaving = true

        // Snapshot the current choices before async work
        let currentChoices = choices
        let sendersByID = Dictionary(uniqueKeysWithValues: pendingSenders.map { ($0.id, $0) })

        // Collect senders by action
        var toAdd: [UnknownSender] = []
        var toNever: [UnknownSender] = []
        var notNowCount = 0

        for (id, choice) in currentChoices {
            guard let sender = sendersByID[id] else { continue }
            switch choice {
            case .add: toAdd.append(sender)
            case .never: toNever.append(sender)
            case .notNow: notNowCount += 1  // leave as .pending — no DB change
            }
        }

        // Process never-include synchronously (fast)
        do {
            for sender in toNever {
                try repository.markNeverInclude(sender)
            }
        } catch {
            logger.error("Failed to save triage choices: \(error)")
        }

        if toAdd.isEmpty {
            // Reload to reflect removals (never-include gone, notNow still visible)
            loadPendingSenders()
            isSaving = false
            logger.info("Triage complete: \(toNever.count) blocked, \(notNowCount) deferred")
            return
        }

        // Add contacts + reprocess in background
        Task {
            var addedEmails: [String] = []

            for sender in toAdd {
                let displayName = sender.displayName ?? sender.email
                guard let contactDTO = await contactsService.createContact(
                    fullName: displayName,
                    email: sender.email,
                    note: nil
                ) else {
                    logger.error("Failed to create contact for \(sender.email, privacy: .public)")
                    continue
                }

                do {
                    try peopleRepository.upsert(contact: contactDTO)
                    try repository.markAdded(sender)
                    addedEmails.append(sender.email)
                } catch {
                    logger.error("Failed to upsert/mark added for \(sender.email, privacy: .public): \(error)")
                }
            }

            // Refresh participant hints on existing evidence now that new contacts exist
            if !addedEmails.isEmpty {
                do {
                    try EvidenceRepository.shared.refreshParticipantResolution()
                } catch {
                    logger.error("Failed to refresh participant resolution after triage: \(error)")
                }
            }

            // Reload to reflect removals (added/never gone, notNow still visible)
            loadPendingSenders()
            isSaving = false

            logger.info("Triage complete: \(addedEmails.count) added, \(toNever.count) blocked, \(notNowCount) deferred")

            // Reprocess added senders' emails in background
            for email in addedEmails {
                await mailCoordinator.reprocessForSender(email: email)
            }
        }
    }
}

// MARK: - Triage Row

private struct TriageRow: View {
    let sender: UnknownSender
    @Binding var choice: TriageChoice

    var body: some View {
        HStack(spacing: 0) {
            // Radio buttons
            radioButton(.add, color: .blue)
                .frame(width: 36)
            radioButton(.notNow, color: .secondary)
                .frame(width: 36)
            radioButton(.never, color: .red)
                .frame(width: 36)

            // Sender email
            Text(sender.displayName ?? sender.email)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 180, alignment: .leading)
                .padding(.leading, 8)

            // Subject
            if let subject = sender.latestSubject {
                Text(subject)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            } else {
                Spacer()
            }

            // Email count badge
            if sender.emailCount > 1 {
                Text("\(sender.emailCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal)
        .background(choice == .add ? Color.accentColor.opacity(0.05) :
                     choice == .never ? Color.red.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
    }

    private func radioButton(_ value: TriageChoice, color: Color) -> some View {
        Button {
            choice = value
        } label: {
            Image(systemName: choice == value ? "circle.inset.filled" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(choice == value ? color : .secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
    }
}
