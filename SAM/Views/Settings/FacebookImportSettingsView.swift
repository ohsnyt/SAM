//
//  FacebookImportSettingsView.swift
//  SAM
//
//  Phase FB-1: Facebook Archive Import
//
//  Settings UI for importing Facebook data export archives.
//  Embeds as a DisclosureGroup in DataSourcesSettingsView.
//

import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FacebookImportSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct FacebookImportSettingsContent: View {

    @State private var coordinator = FacebookImportCoordinator.shared
    @Environment(\.openURL) private var openURL
    @State private var showReviewSheet = false

    private var isActive: Bool { coordinator.importStatus.isActive }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Description
            Text("Import friends, messages, comments, and reactions from a Facebook data export. Request your archive from Facebook in JSON format — it may take up to 48 hours to prepare.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Stale import warning (>90 days since last import)
            if let warning = coordinator.staleImportWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            // Request archive section
            requestArchiveSection

            Divider()

            // Import section
            importSection

            // Status display
            if coordinator.importStatus != .idle && coordinator.importStatus != .awaitingReview {
                Divider()
                statusSection
            }

            // Profile Analysis section (FB-3)
            if coordinator.latestProfileAnalysis != nil || coordinator.profileAnalysisStatus == .analyzing {
                Divider()
                profileAnalysisSection
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

            if let error = coordinator.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showReviewSheet) {
            FacebookImportReviewSheet(coordinator: coordinator) {
                showReviewSheet = false
            }
        }
    }

    // MARK: - Sub-sections

    private var requestArchiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Step 1 — Request your Facebook archive")
                .font(.caption)
                .fontWeight(.semibold)

            HStack(spacing: 8) {
                Button("Open Facebook Data Export") {
                    if let url = URL(string: "https://www.facebook.com/dyi/?referrer=yfi_settings") {
                        openURL(url)
                    }
                }
                .buttonStyle(.bordered)

                Text("Select JSON format, request archive. Allow up to 48 hours.")
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

            // Preview state — show counts and Review button when ready
            if coordinator.importStatus == .awaitingReview || coordinator.parsedFriendCount > 0 {
                previewSection
            } else {
                // Folder picker
                HStack(spacing: 8) {
                    Button("Select Facebook Export Folder") {
                        selectFolder()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isActive)

                    if coordinator.importStatus == .parsing {
                        ProgressView()
                            .scaleEffect(0.7)
                        if let progress = coordinator.progressMessage {
                            Text(progress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Select the top-level folder of your unzipped Facebook export (contains connections/, messages/, etc.)")
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
                summaryRow("Friends found:", value: coordinator.parsedFriendCount)
                if coordinator.parsedMessageThreadCount > 0 {
                    summaryRow("Message threads:", value: coordinator.parsedMessageThreadCount)
                }
                if coordinator.parsedMessageCount > 0 {
                    summaryRow("Messages parsed:", value: coordinator.parsedMessageCount)
                }
                if coordinator.matchedFriendCount > 0 {
                    summaryRow("Matched to existing:", value: coordinator.matchedFriendCount, color: .green)
                }
                if coordinator.unmatchedFriendCount > 0 {
                    summaryRow("New (unmatched):", value: coordinator.unmatchedFriendCount, color: .blue)
                }
                if coordinator.userProfileParsed {
                    HStack {
                        Text("User profile:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Parsed")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.leading, 8)

            HStack(spacing: 12) {
                Button("Review & Import") {
                    showReviewSheet = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.importStatus != .awaitingReview)

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

            // Show granular phase description while importing, status text otherwise
            if let progress = coordinator.progressMessage, isActive {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(coordinator.importStatus.displayText)
                    .font(.caption)
                    .foregroundStyle(coordinator.importStatus == .failed ? .red : .secondary)
            }

            if coordinator.importStatus == .success {
                if coordinator.exactMatchCount > 0 {
                    Text("· \(coordinator.exactMatchCount) auto-matched")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if coordinator.unmatchedFriendCount > 0 {
                    Text("· \(coordinator.unmatchedFriendCount) unmatched — see Today → Unknown Senders")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Profile Analysis

    @ViewBuilder
    private var profileAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Facebook Presence Analysis")
                        .font(.caption)
                        .fontWeight(.semibold)
                    if let date = coordinator.latestProfileAnalysis?.analysisDate {
                        Text("Last analyzed: \(date, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if coordinator.profileAnalysisStatus == .analyzing {
                    ProgressView().controlSize(.small)
                }
                Button("Re-Analyze") {
                    Task { await coordinator.runProfileAnalysis() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(coordinator.profileAnalysisStatus == .analyzing)
            }

            // Analysis-ready banner (shown after a fresh import)
            if coordinator.importStatus == .success && coordinator.profileAnalysisStatus == .complete {
                Button("Presence analysis ready — View in Grow \u{2192}") {
                    NotificationCenter.default.post(name: .samNavigateToGrow, object: nil)
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.cyan)
                .font(.caption)
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
        panel.message = "Select the folder containing your Facebook data export files"
        panel.prompt = "Select Folder"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Persist a security-scoped bookmark so we can re-access this folder later
        BookmarkManager.shared.saveFacebookFolderBookmark(url)

        Task {
            await coordinator.loadFolder(url: url)
        }
    }
}

// MARK: - Standalone wrapper

struct FacebookImportSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Facebook Import", systemImage: "person.2.fill")
                        .font(.title2)
                        .bold()

                    FacebookImportSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    FacebookImportSettingsView()
        .frame(width: 650, height: 500)
}
