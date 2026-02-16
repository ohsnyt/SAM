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
    @State private var mailCoordinator = MailImportCoordinator.shared
    @State private var calendarCoordinator = CalendarImportCoordinator.shared

    var body: some View {
        Group {
            content
        }
        .onAppear {
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

    @ViewBuilder
    private var content: some View {
        if !pendingSenders.isEmpty {
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

                // Scrollable list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pendingSenders, id: \.id) { sender in
                            TriageRow(
                                sender: sender,
                                choice: binding(for: sender.id)
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)

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

    // MARK: - Data Loading

    func loadPendingSenders() {
        do {
            pendingSenders = try repository.fetchPending()
            // Reset choices to default (notNow) for any new senders
            for sender in pendingSenders where choices[sender.id] == nil {
                choices[sender.id] = .notNow
            }
            // Clean up choices for senders no longer pending
            let validIDs = Set(pendingSenders.map(\.id))
            choices = choices.filter { validIDs.contains($0.key) }
        } catch {
            logger.error("Failed to fetch pending senders: \(error)")
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
        var toDismiss: [UnknownSender] = []

        for (id, choice) in currentChoices {
            guard let sender = sendersByID[id] else { continue }
            switch choice {
            case .add: toAdd.append(sender)
            case .never: toNever.append(sender)
            case .notNow: toDismiss.append(sender)
            }
        }

        // Process never-include and dismissed synchronously (fast)
        do {
            for sender in toNever {
                try repository.markNeverInclude(sender)
            }
            for sender in toDismiss {
                try repository.markDismissed(sender)
            }
        } catch {
            logger.error("Failed to save triage choices: \(error)")
        }

        if toAdd.isEmpty {
            // Nothing to add — done immediately
            pendingSenders = []
            choices = [:]
            isSaving = false
            logger.info("Triage complete: \(toNever.count) blocked, \(toDismiss.count) deferred")
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

            // Clear UI immediately
            pendingSenders = []
            choices = [:]
            isSaving = false

            logger.info("Triage complete: \(addedEmails.count) added, \(toNever.count) blocked, \(toDismiss.count) deferred")

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
