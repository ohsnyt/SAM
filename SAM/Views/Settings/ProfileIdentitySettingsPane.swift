//
//  ProfileIdentitySettingsPane.swift
//  SAM
//
//  Settings pane for user identity, signature, style preferences, and legacy data.
//

import SwiftUI

struct PersonalizationSettingsPane: View {

    @AppStorage("sam.user.firstName") private var userFirstName = ""
    @AppStorage("sam.user.lastName") private var userLastName = ""
    @AppStorage("sam.user.defaultClosing") private var defaultClosing = "Best,"
    @AppStorage("sam.messages.allowEmoji") private var allowEmoji = false

    @State private var migrationService = LegacyStoreMigrationService.shared
    @State private var showCleanupConfirmation = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9"
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    // App info
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Version:")
                                .foregroundStyle(.secondary)
                            Text(appVersion)
                        }

                        HStack {
                            Text("Schema:")
                                .foregroundStyle(.secondary)
                            Text(SAMModelContainer.schemaVersion)
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // Identity & Signature
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Identity")
                            .samFont(.headline)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("First Name")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("First name", text: $userFirstName)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Last Name")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Last name", text: $userLastName)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default Closing")
                                .samFont(.caption)
                                .foregroundStyle(.secondary)
                            TextField("e.g. Best, / Yours, / Warm regards,", text: $defaultClosing)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 250)
                        }

                        Text("Used to sign AI-generated messages. SAM uses your first name for people you interact with regularly, and your full name for others. SAM learns your preferred closing style as you edit drafts.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)

                        if userFirstName.isEmpty {
                            Button("Auto-fill from Me Contact") {
                                autoFillFromMeContact()
                            }
                            .samFont(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    Divider()

                    // AI Messages Emoji
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Allow emoji and icons in AI messages", isOn: $allowEmoji)
                        Text("When off, SAM will not use emoji, emoticons, or Unicode symbols in generated messages, briefings, and coaching text.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Legacy Data — only visible when orphaned stores are detected
                    if let discovery = migrationService.discovery, !discovery.isEmpty {
                        Divider()
                        legacyDataSection(discovery: discovery)
                    }
                }
                .padding()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if migrationService.discovery == nil {
                migrationService.discoverLegacyStores()
            }
            if userFirstName.isEmpty {
                autoFillFromMeContact()
            }
        }
        .alert("Clean Up Legacy Files?", isPresented: $showCleanupConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Old Files", role: .destructive) {
                migrationService.cleanupLegacyStores()
            }
        } message: {
            if let discovery = migrationService.discovery {
                Text("This will permanently delete \(discovery.count) legacy store\(discovery.count == 1 ? "" : "s") (\(discovery.formattedSize)). Make sure you have migrated any data you need first.")
            }
        }
        .dismissOnLock(isPresented: $showCleanupConfirmation)
    }

    // MARK: - Auto-fill

    private func autoFillFromMeContact() {
        guard let me = try? PeopleRepository.shared.fetchMe(),
              let fullName = me.displayNameCache, !fullName.isEmpty else { return }

        let parts = fullName.split(separator: " ", maxSplits: 1)
        if let first = parts.first {
            userFirstName = String(first)
        }
        if parts.count > 1 {
            userLastName = String(parts[1])
        }
    }

    // MARK: - Legacy Data Section

    private func legacyDataSection(discovery: LegacyStoreDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Legacy Data", systemImage: "clock.arrow.circlepath")
                .samFont(.headline)

            Text("Data from a previous SAM version was found on this Mac.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("\(discovery.count) legacy store\(discovery.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(discovery.formattedSize)
                    .foregroundStyle(.secondary)
            }

            if let mostRecent = discovery.mostRecent {
                Text("Most recent: \(mostRecent.version)")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            switch migrationService.status {
            case .migrating(let message):
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(message)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            case .cleaning:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cleaning up...")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .samFont(.caption)
                    .foregroundStyle(.green)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "xmark.circle.fill")
                        .samFont(.caption)
                        .foregroundStyle(.red)
                    if message.contains("schemas too old") {
                        Text("Try \"Import Roles Only\" to recover role assignments via direct database read.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                EmptyView()
            }

            HStack(spacing: 12) {
                Button("Migrate All Data...") {
                    Task { await migrationService.migrate() }
                }
                .disabled(migrationService.isBusy)

                Button("Import Roles Only...") {
                    Task { await migrationService.migrateRolesOnly() }
                }
                .disabled(migrationService.isBusy)
                .help("Reads role assignments directly from the legacy database and applies them to matching contacts. Works even when full migration fails.")

                Button("Clean Up Old Files...", role: .destructive) {
                    showCleanupConfirmation = true
                }
                .disabled(migrationService.isBusy)
            }
        }
    }
}
