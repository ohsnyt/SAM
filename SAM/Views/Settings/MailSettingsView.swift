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
    @State private var bookmarkManager = BookmarkManager.shared

    @State private var accessError: String?
    @State private var meEmailAliases: [String] = []
    @State private var hasMeContact = false
    @State private var newFilterEmail: String = ""

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
                    .samFont(.headline)

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
                                        .samFont(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Text("Showing accounts that match your Me contact's email addresses. SAM reads email metadata and generates summaries — raw message bodies are never stored.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // ── Import Settings ──
            VStack(alignment: .leading, spacing: 8) {
                Text("Import Settings")
                    .samFont(.headline)

                Toggle("Automatically import email", isOn: Binding(
                    get: { coordinator.mailEnabled },
                    set: { coordinator.setMailEnabled($0) }
                ))

                Picker("Check every", selection: Binding(
                    get: { coordinator.importIntervalSeconds },
                    set: { coordinator.setImportInterval($0) }
                )) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                    Text("30 minutes").tag(1800.0)
                    Text("1 hour").tag(3600.0)
                }

            }

            Divider()

            // ── Direct Access (Performance) ──
            VStack(alignment: .leading, spacing: 8) {
                Text("Direct Access")
                    .samFont(.headline)

                if bookmarkManager.hasMailDirAccess {
                    Label("Direct database access enabled", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    Text("SAM reads Mail's database files directly — Mail.app is never blocked during imports.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Button("Revoke Access") {
                        bookmarkManager.revokeMailDirAccess()
                    }
                    .foregroundStyle(.red)
                } else {
                    Text("Grant SAM direct access to Mail's data files for faster imports that don't slow down Mail.app.")
                        .samFont(.callout)
                        .foregroundStyle(.secondary)

                    Button("Grant Mail Data Access") {
                        bookmarkManager.requestMailDirAccess()
                    }

                    Text("You'll be asked to select ~/Library/Mail. This gives SAM read-only access to email metadata and message files. Mail.app is never touched.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // ── Inbox Filters ──
            VStack(alignment: .leading, spacing: 8) {
                Text("Inbox Filters")
                    .samFont(.headline)

                // Me card addresses
                if hasMeContact && !meEmailAliases.isEmpty {
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

                // Custom addresses (not on Me card)
                let customRules = coordinator.filterRules.filter { rule in
                    !meEmailAliases.contains(where: { $0.lowercased() == rule.value.lowercased() })
                }
                if !customRules.isEmpty {
                    ForEach(customRules) { rule in
                        HStack {
                            Image(systemName: "envelope.badge.person.crop")
                                .foregroundStyle(.secondary)
                            Text(rule.value)
                            Spacer()
                            Button {
                                var rules = coordinator.filterRules
                                rules.removeAll { $0.id == rule.id }
                                coordinator.setFilterRules(rules)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this address")
                        }
                    }
                }

                // Add custom address
                HStack {
                    TextField("Add address...", text: $newFilterEmail)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addCustomFilterEmail() }

                    Button {
                        addCustomFilterEmail()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(!isValidEmail(newFilterEmail))
                    .buttonStyle(.plain)
                    .help("Add this address to inbox filters")
                }

                if !hasMeContact {
                    Text("Set up your Me card in Contacts to see your existing email addresses here.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Only emails sent to enabled addresses will be imported. If none are selected, all emails are imported.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            if coordinator.isConfigured {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Status")
                        .samFont(.headline)

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
                            .samFont(.caption)
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

    private func addCustomFilterEmail() {
        let trimmed = newFilterEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(trimmed) else { return }
        guard !coordinator.filterRules.contains(where: { $0.value.lowercased() == trimmed.lowercased() }) else {
            newFilterEmail = ""
            return
        }
        var rules = coordinator.filterRules
        rules.append(MailFilterRule(id: UUID(), value: trimmed))
        coordinator.setFilterRules(rules)
        newFilterEmail = ""
    }

    private func isValidEmail(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Simple check: contains @ with text on both sides
        let parts = trimmed.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
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
