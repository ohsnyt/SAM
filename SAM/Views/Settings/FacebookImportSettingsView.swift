//
//  FacebookImportSettingsView.swift
//  SAM
//
//  Phase FB-1: Facebook Archive Import
//
//  Simplified settings UI — import flow moved to File → Import → Facebook sheet.
//  Retains: profile analysis, writing voice, last import info, error display.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FacebookImportSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct FacebookImportSettingsContent: View {

    @State private var coordinator = FacebookImportCoordinator.shared

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Description
            Text("Import friends, messages, comments, and reactions from a Facebook data export. Use **File → Import → Facebook** to start.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Profile Analysis section (FB-3)
            if coordinator.latestProfileAnalysis != nil || coordinator.profileAnalysisStatus == .analyzing {
                Divider()
                profileAnalysisSection
            }

            // Writing Voice section
            voiceSummarySection

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
        .onAppear { FeatureAdoptionTracker.shared.recordUsage(.facebookImport) }
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

    // MARK: - Writing Voice

    @ViewBuilder
    private var voiceSummarySection: some View {
        if let voice = facebookVoiceSummary, !voice.isEmpty {
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

                if coordinator.parsedPostCount > 0 {
                    let sampled = min(coordinator.parsedPostCount, 10)
                    Text("Analyzed from \(sampled) of \(coordinator.parsedPostCount) posts")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Fetches the Facebook voice summary from the stored profile DTO.
    private var facebookVoiceSummary: String? {
        guard let data = UserDefaults.standard.data(forKey: "sam.userFacebookProfile"),
              let profile = try? JSONDecoder().decode(UserFacebookProfileDTO.self, from: data),
              !profile.writingVoiceSummary.isEmpty else { return nil }
        return profile.writingVoiceSummary
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
