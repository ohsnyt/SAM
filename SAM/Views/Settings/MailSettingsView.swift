//
//  MailSettingsView.swift
//  SAM_crm
//
//  Email Integration - Settings View
//
//  Mail.app account selection and import configuration.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MailSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct MailSettingsContent: View {
    @State private var coordinator = MailImportCoordinator.shared

    @State private var accessError: String?
    @State private var meEmailAliases: [String] = []
    @State private var hasMeContact = false

    private var relevantAccounts: [MailAccountDTO] {
        guard !meEmailAliases.isEmpty else { return [] }
        let meEmails = Set(meEmailAliases.map { $0.lowercased() })
        return coordinator.availableAccounts.filter { account in
            account.emailAddresses.contains { meEmails.contains($0.lowercased()) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ── Mail.app Accounts ──
            VStack(alignment: .leading, spacing: 8) {
                Text("Mail.app Accounts")
                    .font(.headline)

                if let error = accessError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if !hasMeContact {
                    Text("Set up your Me card in Contacts to see your Mail accounts.")
                        .foregroundStyle(.secondary)
                } else if relevantAccounts.isEmpty {
                    Text("No Mail accounts match your Me contact's email addresses.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relevantAccounts) { account in
                        Toggle(isOn: accountBinding(for: account.id)) {
                            VStack(alignment: .leading) {
                                Text(account.name)
                                if !account.emailAddresses.isEmpty {
                                    Text(account.emailAddresses.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Text("Showing accounts that match your Me contact's email addresses. SAM reads email metadata and generates summaries — raw message bodies are never stored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // ── Import Settings ──
            VStack(alignment: .leading, spacing: 8) {
                Text("Import Settings")
                    .font(.headline)

                Toggle("Enable Email Import", isOn: Binding(
                    get: { coordinator.mailEnabled },
                    set: { coordinator.setMailEnabled($0) }
                ))

                Picker("Check every", selection: Binding(
                    get: { coordinator.importIntervalSeconds },
                    set: { coordinator.setImportInterval($0) }
                )) {
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                    Text("30 minutes").tag(1800.0)
                    Text("1 hour").tag(3600.0)
                }

                Picker("Look back", selection: Binding(
                    get: { coordinator.lookbackDays },
                    set: { coordinator.setLookbackDays($0) }
                )) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
            }

            Divider()

            // ── Inbox Filters ──
            VStack(alignment: .leading, spacing: 8) {
                Text("Inbox Filters")
                    .font(.headline)

                if hasMeContact {
                    if meEmailAliases.isEmpty {
                        Text("Your Me card has no email addresses. Add emails to your Me card in Contacts.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(meEmailAliases, id: \.self) { email in
                            Toggle(isOn: filterBinding(for: email)) {
                                HStack {
                                    Image(systemName: "envelope")
                                        .foregroundStyle(.secondary)
                                    Text(email)
                                }
                            }
                        }
                    }
                } else {
                    Text("Set up your Me card in Contacts to configure email filtering.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Only emails sent to these addresses will be imported. If none are selected, all emails are imported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if coordinator.isConfigured {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Status")
                        .font(.headline)

                    HStack {
                        Text("Last Import")
                        Spacer()
                        if let date = coordinator.lastImportedAt {
                            Text("\(coordinator.lastImportCount) emails, \(date, style: .relative) ago")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Never")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = coordinator.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    Button("Import Now") {
                        Task { await coordinator.importNow() }
                    }
                    .disabled(coordinator.importStatus == .importing)
                }
            }
        }
        .task {
            loadMeContact()
            accessError = await coordinator.checkMailAccess()
            await coordinator.loadAccounts()
        }
    }

    private func loadMeContact() {
        do {
            if let me = try PeopleRepository.shared.fetchMe() {
                meEmailAliases = me.emailAliases
                hasMeContact = true
            } else {
                meEmailAliases = []
                hasMeContact = false
            }
        } catch {
            logger.error("Failed to fetch Me contact: \(error.localizedDescription)")
            meEmailAliases = []
            hasMeContact = false
        }
    }

    private func accountBinding(for accountID: String) -> Binding<Bool> {
        Binding(
            get: { coordinator.selectedAccountIDs.contains(accountID) },
            set: { isOn in
                var ids = coordinator.selectedAccountIDs
                if isOn {
                    if !ids.contains(accountID) { ids.append(accountID) }
                } else {
                    ids.removeAll { $0 == accountID }
                }
                coordinator.setSelectedAccountIDs(ids)
            }
        )
    }

    private func filterBinding(for email: String) -> Binding<Bool> {
        Binding(
            get: {
                coordinator.filterRules.contains { $0.value.lowercased() == email.lowercased() }
            },
            set: { isOn in
                var rules = coordinator.filterRules
                if isOn {
                    if !rules.contains(where: { $0.value.lowercased() == email.lowercased() }) {
                        rules.append(MailFilterRule(id: UUID(), value: email))
                    }
                } else {
                    rules.removeAll { $0.value.lowercased() == email.lowercased() }
                }
                coordinator.setFilterRules(rules)
            }
        )
    }
}

// MARK: - Standalone wrapper

struct MailSettingsView: View {
    var body: some View {
        Form {
            Section {
                MailSettingsContent()
                    .padding()
            }
        }
        .formStyle(.grouped)
    }
}
