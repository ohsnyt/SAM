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
            Text("Import iMessage conversations, phone calls, and FaceTime history as relationship evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            databaseAccessSection

            Divider()

            iMessageSection

            Divider()

            callsSection

            Divider()

            importSection
        }
    }

    // MARK: - Database Access Section

    private var databaseAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Database Access")
                .font(.headline)

            Text("SAM needs permission to read your local message and call history databases. Select each folder when prompted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Messages DB
            HStack(spacing: 12) {
                Image(systemName: bookmarkManager.hasMessagesAccess ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(bookmarkManager.hasMessagesAccess ? .green : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages Database")
                        .font(.body)
                    Text("~/Library/Messages/chat.db")
                        .font(.caption)
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
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Call History Database")
                        .font(.body)
                    Text("~/Library/Application Support/CallHistoryDB/")
                        .font(.caption)
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
        }
    }

    // MARK: - iMessage Section

    private var iMessageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iMessage")
                .font(.headline)

            Toggle("Import iMessage conversations", isOn: Binding(
                get: { coordinator.messagesEnabled },
                set: { coordinator.setMessagesEnabled($0) }
            ))
            .disabled(!bookmarkManager.hasMessagesAccess)

            if !bookmarkManager.hasMessagesAccess {
                Text("Grant messages database access above to enable.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("Analyze message threads with AI", isOn: Binding(
                get: { coordinator.analyzeMessages },
                set: { coordinator.setAnalyzeMessages($0) }
            ))
            .disabled(!coordinator.messagesEnabled)

            Text("When enabled, conversation threads are summarized by on-device AI. Raw message text is never stored.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Lookback period:")
                Picker("", selection: Binding(
                    get: { coordinator.lookbackDays },
                    set: { coordinator.setLookbackDays($0) }
                )) {
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("365 days").tag(365)
                }
                .frame(width: 120)
            }
        }
    }

    // MARK: - Calls Section

    private var callsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Calls & FaceTime")
                .font(.headline)

            Toggle("Import phone calls and FaceTime", isOn: Binding(
                get: { coordinator.callsEnabled },
                set: { coordinator.setCallsEnabled($0) }
            ))
            .disabled(!bookmarkManager.hasCallHistoryAccess)

            if !bookmarkManager.hasCallHistoryAccess {
                Text("Grant call history database access above to enable.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Imports call duration and direction. No audio content is accessed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Import Section

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import")
                .font(.headline)

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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if coordinator.lastImportedAt != nil {
                HStack(spacing: 16) {
                    Label("\(coordinator.lastMessageCount) messages", systemImage: "message")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label("\(coordinator.lastCallCount) calls", systemImage: "phone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = coordinator.lastError {
                Text(error)
                    .font(.caption)
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
                      || (!coordinator.messagesEnabled && !coordinator.callsEnabled))
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
                        .font(.title2)
                        .bold()

                    CommunicationsSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}
