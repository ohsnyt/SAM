//
//  CommunicationsSettingsView.swift
//  SAM
//
//  Phase M: Communications Evidence
//
//  Settings for iMessage, phone call, and FaceTime evidence import.
//  Manages security-scoped bookmarks and import configuration.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "CommunicationsSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct CommunicationsSettingsContent: View {

    @State private var coordinator = CommunicationsImportCoordinator.shared
    @State private var bookmarkManager = BookmarkManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Import iMessage conversations, phone calls, FaceTime, and WhatsApp history as relationship evidence.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            Divider()

            databaseAccessSection

            Divider()

            iMessageSection

            Divider()

            callsSection

            Divider()

            whatsAppSection

            Divider()

            importSection
        }
    }

    // MARK: - Database Access Section

    private var databaseAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Database Access")
                .samFont(.headline)

            Text("SAM needs permission to read your local message and call history databases. Select each folder when prompted.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            // Messages DB
            HStack(spacing: 12) {
                Image(systemName: bookmarkManager.hasMessagesAccess ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(bookmarkManager.hasMessagesAccess ? .green : .secondary)
                    .samFont(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages Database")
                        .samFont(.body)
                    Text("~/Library/Messages/chat.db")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if bookmarkManager.hasMessagesAccess {
                    Button("Revoke") {
                        bookmarkManager.revokeMessagesAccess()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Grant Access") {
                        bookmarkManager.requestMessagesAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)

            // Call History DB
            HStack(spacing: 12) {
                Image(systemName: bookmarkManager.hasCallHistoryAccess ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(bookmarkManager.hasCallHistoryAccess ? .green : .secondary)
                    .samFont(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Call History Database")
                        .samFont(.body)
                    Text("~/Library/Application Support/CallHistoryDB/")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if bookmarkManager.hasCallHistoryAccess {
                    Button("Revoke") {
                        bookmarkManager.revokeCallHistoryAccess()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Grant Access") {
                        bookmarkManager.requestCallHistoryAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)

            // WhatsApp DB
            HStack(spacing: 12) {
                Image(systemName: bookmarkManager.hasWhatsAppAccess ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(bookmarkManager.hasWhatsAppAccess ? .green : .secondary)
                    .samFont(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("WhatsApp Database")
                        .samFont(.body)
                    Text("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if bookmarkManager.hasWhatsAppAccess {
                    Button("Revoke") {
                        bookmarkManager.revokeWhatsAppAccess()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Grant Access") {
                        bookmarkManager.requestWhatsAppAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - iMessage Section

    private var iMessageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iMessage")
                .samFont(.headline)

            Toggle("Import iMessage conversations", isOn: Binding(
                get: { coordinator.messagesEnabled },
                set: { coordinator.setMessagesEnabled($0) }
            ))
            .disabled(!bookmarkManager.hasMessagesAccess)

            if !bookmarkManager.hasMessagesAccess {
                Text("Grant messages database access above to enable.")
                    .samFont(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Analyze message threads with AI", isOn: Binding(
                get: { coordinator.analyzeMessages },
                set: { coordinator.setAnalyzeMessages($0) }
            ))
            .disabled(!coordinator.messagesEnabled)

            Text("When enabled, conversation threads are summarized by on-device AI. Raw message text is never stored.")
                .samFont(.caption)
                .foregroundStyle(.secondary)


        }
    }

    // MARK: - Calls Section

    private var callsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calls & FaceTime")
                .samFont(.headline)

            Toggle("Import phone calls and FaceTime", isOn: Binding(
                get: { coordinator.callsEnabled },
                set: { coordinator.setCallsEnabled($0) }
            ))
            .disabled(!bookmarkManager.hasCallHistoryAccess)

            if !bookmarkManager.hasCallHistoryAccess {
                Text("Grant call history database access above to enable.")
                    .samFont(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Imports call duration and direction. No audio content is accessed.")
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - WhatsApp Section

    private var whatsAppSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WhatsApp")
                .samFont(.headline)

            Toggle("Import WhatsApp messages", isOn: Binding(
                get: { coordinator.whatsAppMessagesEnabled },
                set: { coordinator.setWhatsAppMessagesEnabled($0) }
            ))
            .disabled(!bookmarkManager.hasWhatsAppAccess)

            if !bookmarkManager.hasWhatsAppAccess {
                Text("Grant WhatsApp database access above to enable.")
                    .samFont(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Analyze WhatsApp threads with AI", isOn: Binding(
                get: { coordinator.analyzeWhatsAppMessages },
                set: { coordinator.setAnalyzeWhatsAppMessages($0) }
            ))
            .disabled(!coordinator.whatsAppMessagesEnabled)

            Toggle("Import WhatsApp calls", isOn: Binding(
                get: { coordinator.whatsAppCallsEnabled },
                set: { coordinator.setWhatsAppCallsEnabled($0) }
            ))
            .disabled(!bookmarkManager.hasWhatsAppAccess)

            Text("Message text is analyzed on-device then discarded. Only AI summaries are stored. Call metadata only (duration, direction).")
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Import Section

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import")
                .samFont(.headline)

            HStack {
                Text("Import Status:")
                    .foregroundStyle(.secondary)

                switch coordinator.importStatus {
                case .idle:
                    Text("Idle").bold()
                case .importing:
                    Text("Importing...").bold().foregroundStyle(.blue)
                case .success:
                    Text("Success").bold().foregroundStyle(.green)
                case .failed:
                    Text("Failed").bold().foregroundStyle(.red)
                }

                Spacer()

                if let date = coordinator.lastImportedAt {
                    Text("\(date, style: .relative) ago")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if coordinator.lastImportedAt != nil {
                HStack(spacing: 16) {
                    Label("\(coordinator.lastMessageCount) messages", systemImage: "message")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)

                    Label("\(coordinator.lastCallCount) calls", systemImage: "phone")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }

                if coordinator.lastWhatsAppMessageCount > 0 || coordinator.lastWhatsAppCallCount > 0 {
                    HStack(spacing: 16) {
                        Label("\(coordinator.lastWhatsAppMessageCount) WhatsApp messages", systemImage: "text.bubble")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)

                        Label("\(coordinator.lastWhatsAppCallCount) WhatsApp calls", systemImage: "phone.bubble")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = coordinator.lastError {
                Text(error)
                    .samFont(.caption)
                    .foregroundStyle(.red)
            }

            if coordinator.importStatus == .importing {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Button("Import Now") {
                Task {
                    await coordinator.importNow()
                }
            }
            .disabled(coordinator.importStatus == .importing
                      || (!coordinator.messagesEnabled && !coordinator.callsEnabled
                          && !coordinator.whatsAppMessagesEnabled && !coordinator.whatsAppCallsEnabled))
        }
    }
}

// MARK: - Standalone wrapper

struct CommunicationsSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Communications", systemImage: "message.fill")
                        .samFont(.title2)
                        .bold()

                    CommunicationsSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}
