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
    @State private var showProfileAnalysis = false
    @State private var autoSyncLinkedInURLs: Bool = UserDefaults.standard.bool(forKey: "sam.linkedin.autoSyncAppleContactURLs")
    @State private var showDisconnectConfirm = false
    @State private var hasConnectedProfile: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Description — point to the import sheet
            Text("Use **File \u{2192} Import \u{2192} LinkedIn** to import connections, messages, and interaction data from a LinkedIn data export.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            // Last import info
            if let lastImport = coordinator.lastImportedAt {
                Divider()
                HStack {
                    Text("Last import:")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(lastImport, style: .relative)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    Text("ago")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(coordinator.lastImportCount) item(s)")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let watermark = coordinator.lastMessageImportAt {
                HStack {
                    Text("Message watermark:")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(watermark, style: .date)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") {
                        coordinator.resetWatermark()
                    }
                    .samFont(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }
            }

            // §13.2 — Auto-sync preference
            Divider()
            autoSyncSection

            // Profile Analysis section
            if coordinator.latestProfileAnalysis != nil {
                Divider()
                profileAnalysisSection
            }

            // Writing Voice section
            voiceSummarySection

            if let error = coordinator.lastError {
                Text(error)
                    .samFont(.caption)
                    .foregroundStyle(.red)
            }

            // Disconnect (only when connected)
            if hasConnectedProfile {
                Divider()
                disconnectSection
            }
        }
        .padding(.vertical, 4)
        .managedSheet(
            isPresented: $showProfileAnalysis,
            priority: .userInitiated,
            identifier: "settings.linkedin-profile-analysis"
        ) {
            if let analysis = coordinator.latestProfileAnalysis {
                ProfileAnalysisSheet(analysis: analysis) {
                    await coordinator.runProfileAnalysis()
                }
            }
        }
        .onAppear {
            FeatureAdoptionTracker.shared.recordUsage(.linkedInImport)
            refreshConnectedState()
        }
        .confirmationDialog(
            "Disconnect LinkedIn?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await coordinator.disconnect()
                    refreshConnectedState()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the cached LinkedIn profile, the Grow analysis, and the import watermarks. Imported contacts, messages, and interaction history are preserved.")
        }
    }

    // MARK: - Disconnect Section

    @ViewBuilder
    private var disconnectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Disconnect")
                .samFont(.headline)

            Text("Remove the LinkedIn association from SAM. Use this if you're switching accounts or no longer want LinkedIn data influencing coaching.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            Button("Disconnect LinkedIn...", role: .destructive) {
                showDisconnectConfirm = true
            }
        }
    }

    private func refreshConnectedState() {
        hasConnectedProfile = UserDefaults.standard.data(forKey: "sam.userLinkedInProfile") != nil
            || coordinator.latestProfileAnalysis != nil
            || coordinator.lastImportedAt != nil
    }

    // MARK: - Auto-Sync (§13.2)

    private var autoSyncSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $autoSyncLinkedInURLs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically add LinkedIn URLs to Apple Contacts")
                        .samFont(.caption)
                        .fontWeight(.medium)
                    Text("When contacts are marked Add, SAM writes their LinkedIn profile URL to your Apple Contacts without asking each time.")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: autoSyncLinkedInURLs) { _, newValue in
                coordinator.autoSyncLinkedInURLs = newValue
            }
        }
    }

    // MARK: - Profile Analysis

    @ViewBuilder
    private var profileAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("LinkedIn Profile Analysis")
                        .samFont(.caption)
                        .fontWeight(.semibold)
                    if let date = coordinator.latestProfileAnalysis?.analysisDate {
                        Text("Last analyzed: \(date, style: .relative) ago")
                            .samFont(.caption)
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
                Button("Profile analysis ready — View in Grow \u{2192}") {
                    NotificationCenter.default.post(name: .samNavigateToGrow, object: nil)
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.cyan)
                .samFont(.caption)
            }
        }
    }

    // MARK: - Writing Voice

    @ViewBuilder
    private var voiceSummarySection: some View {
        if let voice = linkedInVoiceSummary, !voice.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Writing Voice")
                        .samFont(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Refresh") {
                        Task { await coordinator.runProfileAnalysis() }
                    }
                    .samFont(.caption)
                    .buttonStyle(.borderless)
                    .disabled(coordinator.profileAnalysisStatus == .analyzing)
                }

                Text(voice)
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Fetches the LinkedIn voice summary from the stored profile DTO.
    private var linkedInVoiceSummary: String? {
        // Synchronous check — BusinessProfileService caches after first load,
        // and the coordinator already populated it during import.
        // We read from UserDefaults directly to avoid async in a computed property.
        guard let data = UserDefaults.standard.data(forKey: "sam.userLinkedInProfile"),
              let profile = try? JSONDecoder().decode(UserLinkedInProfileDTO.self, from: data),
              !profile.writingVoiceSummary.isEmpty else { return nil }
        return profile.writingVoiceSummary
    }

}

