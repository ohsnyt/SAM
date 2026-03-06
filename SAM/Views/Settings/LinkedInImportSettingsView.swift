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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Description — point to the import sheet
            Text("Use **File \u{2192} Import \u{2192} LinkedIn** to import connections, messages, and interaction data from a LinkedIn data export.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showProfileAnalysis) {
            if let analysis = coordinator.latestProfileAnalysis {
                ProfileAnalysisSheet(analysis: analysis) {
                    await coordinator.runProfileAnalysis()
                }
            }
        }
        .onAppear { FeatureAdoptionTracker.shared.recordUsage(.linkedInImport) }
    }

    // MARK: - Auto-Sync (§13.2)

    private var autoSyncSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $autoSyncLinkedInURLs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatically add LinkedIn URLs to Apple Contacts")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("When contacts are marked Add, SAM writes their LinkedIn profile URL to your Apple Contacts without asking each time.")
                        .font(.caption)
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
                Button("Profile analysis ready — View in Grow \u{2192}") {
                    NotificationCenter.default.post(name: .samNavigateToGrow, object: nil)
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.cyan)
                .font(.caption)
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
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Refresh") {
                        Task { await coordinator.runProfileAnalysis() }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(coordinator.profileAnalysisStatus == .analyzing)
                }

                Text(voice)
                    .font(.caption)
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
