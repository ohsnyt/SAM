//
//  LinkedInImportSettingsView.swift
//  SAM
//
//  Phase S+: LinkedIn Archive Import
//
//  Settings UI for importing LinkedIn data export archives.
//  Embeds as a DisclosureGroup in DataSourcesSettingsView.
//

import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LinkedInImportSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct LinkedInImportSettingsContent: View {

    @State private var coordinator = LinkedInImportCoordinator.shared
    @Environment(\.openURL) private var openURL

    private var isActive: Bool { coordinator.importStatus.isActive }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Description
            Text("Import messages and connection data from a LinkedIn data export. Request your archive from LinkedIn — it may take up to 24 hours to prepare.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Request archive section
            requestArchiveSection

            Divider()

            // Import section
            importSection

            // Status display
            if coordinator.importStatus != .idle {
                Divider()
                statusSection
            }

            // Last import info
            if let lastImport = coordinator.lastImportedAt {
                Divider()
                HStack {
                    Text("Last import:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(lastImport, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(coordinator.lastImportCount) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let watermark = coordinator.lastMessageImportAt {
                HStack {
                    Text("Message watermark:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(watermark, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        coordinator.resetWatermark()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }
            }

            if let error = coordinator.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sub-sections

    private var requestArchiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Step 1 — Request your LinkedIn archive")
                .font(.caption)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                Button("Open LinkedIn Data Export") {
                    if let url = URL(string: "https://www.linkedin.com/mypreferences/d/download-my-data") {
                        openURL(url)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(false)

                Text("Select Basic data, request archive. Allow up to 24 hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Step 2 — Import the archive")
                .font(.caption)
                .fontWeight(.semibold)

            // Preview state — show counts and confirm/cancel
            if coordinator.parsedMessageCount > 0 || coordinator.pendingConnectionCount > 0 {
                previewSection
            } else {
                // Folder picker
                HStack(spacing: 8) {
                    Button("Select LinkedIn Export Folder") {
                        selectFolder()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isActive)

                    if coordinator.importStatus == .parsing {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Reading files...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Select the folder that contains your unzipped LinkedIn export (messages.csv, Connections.csv, etc.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Counts
            Group {
                summaryRow("Messages found:", value: coordinator.parsedMessageCount)
                if coordinator.newMessageCount > 0 {
                    summaryRow("New (will import):", value: coordinator.newMessageCount, color: .green)
                }
                if coordinator.duplicateMessageCount > 0 {
                    summaryRow("Already imported (skip):", value: coordinator.duplicateMessageCount, color: .orange)
                }
                if coordinator.pendingConnectionCount > 0 {
                    summaryRow("Connections to match:", value: coordinator.pendingConnectionCount)
                }
            }
            .padding(.leading, 8)

            HStack(spacing: 12) {
                Button("Import") {
                    Task {
                        await coordinator.confirmImport()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.newMessageCount == 0 && coordinator.pendingConnectionCount == 0)

                Button("Cancel") {
                    coordinator.cancelImport()
                }
                .buttonStyle(.bordered)
                .disabled(isActive)
            }
        }
    }

    private var statusSection: some View {
        HStack(spacing: 8) {
            if isActive {
                ProgressView()
                    .scaleEffect(0.7)
            } else if coordinator.importStatus == .success {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else if coordinator.importStatus == .failed {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Text(coordinator.importStatus.displayText)
                .font(.caption)
                .foregroundStyle(coordinator.importStatus == .failed ? .red : .secondary)

            if coordinator.importStatus == .success && coordinator.matchedConnectionCount > 0 {
                Text("· \(coordinator.matchedConnectionCount) connection(s) matched")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func summaryRow(_ label: String, value: Int, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder containing your LinkedIn data export files"
        panel.prompt = "Select Folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await coordinator.loadFolder(url: url)
        }
    }
}

// MARK: - Standalone wrapper

struct LinkedInImportSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("LinkedIn Import", systemImage: "network")
                        .font(.title2)
                        .bold()

                    LinkedInImportSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    LinkedInImportSettingsView()
        .frame(width: 650, height: 500)
}
