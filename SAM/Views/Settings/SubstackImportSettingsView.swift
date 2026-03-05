//
//  SubstackImportSettingsView.swift
//  SAM
//
//  Settings UI for Substack integration.
//  Track 1: RSS feed URL for content voice intelligence.
//  Track 2: Subscriber CSV import for lead pipeline.
//  Embeds as a DisclosureGroup in DataSourcesSettingsView.
//

import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SubstackImportSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct SubstackImportSettingsContent: View {

    @State private var coordinator = SubstackImportCoordinator.shared
    @State private var feedURLInput: String = SubstackImportCoordinator.shared.feedURL
    @State private var showSubscriberImporter = false

    private var isActive: Bool {
        if case .importing = coordinator.importStatus { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Description
            Text("Connect your Substack publication to get content suggestions that extend your existing articles and identify warm leads from your subscriber base.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Track 1: Feed URL
            feedSection

            Divider()

            // Track 2: Subscriber Import
            subscriberSection

            // Voice Summary (if available)
            voiceSummarySection
        }
        .fileImporter(
            isPresented: $showSubscriberImporter,
            allowedContentTypes: [.commaSeparatedText, .folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await coordinator.loadSubscriberCSV(url: url)
                }
            case .failure(let error):
                logger.error("File importer failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Feed Section

    @ViewBuilder
    private var feedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Publication Feed")
                .font(.headline)

            HStack {
                TextField("e.g. sarahksnyder.substack.com", text: $feedURLInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveFeedURL() }

                Button("Fetch Posts") {
                    saveFeedURL()
                    Task { await coordinator.fetchFeed() }
                }
                .disabled(feedURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActive)
            }

            if let lastFetch = coordinator.lastFeedFetchDate {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Last fetched: \(lastFetch.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !coordinator.parsedPosts.isEmpty {
                        Text("(\(coordinator.parsedPosts.count) posts)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            statusView
        }
    }

    // MARK: - Subscriber Section

    @ViewBuilder
    private var subscriberSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscriber Import")
                .font(.headline)

            Text("Go to Substack Settings → Exports → Download. Select the downloaded CSV file.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Select Subscriber CSV...") {
                    showSubscriberImporter = true
                }
                .disabled(isActive)

                if case .awaitingReview = coordinator.importStatus {
                    Button("Confirm Import") {
                        Task { await coordinator.confirmSubscriberImport() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let lastImport = coordinator.lastSubscriberImportDate {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Last imported: \(lastImport.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Candidate summary when awaiting review
            if case .awaitingReview = coordinator.importStatus {
                let matched = coordinator.subscriberCandidates.filter {
                    if case .exactMatchEmail = $0.matchStatus { return true }; return false
                }.count
                let unmatched = coordinator.subscriberCandidates.count - matched
                let paid = coordinator.subscriberCandidates.filter { $0.planType == "paid" }.count

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(coordinator.subscriberCandidates.count) subscribers found")
                        .font(.caption).bold()
                    Text("\(matched) matched to existing contacts • \(unmatched) new • \(paid) paid")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Voice Summary

    @ViewBuilder
    private var voiceSummarySection: some View {
        let profile = getSubstackProfile()
        if let profile, !profile.writingVoiceSummary.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Writing Voice")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        Task { await coordinator.fetchFeed() }
                    }
                    .font(.caption)
                    .disabled(isActive)
                }

                Text(profile.writingVoiceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !profile.topicSummary.isEmpty {
                    HStack(spacing: 4) {
                        Text("Topics:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(profile.topicSummary.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusView: some View {
        switch coordinator.importStatus {
        case .idle:
            EmptyView()
        case .importing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(coordinator.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .awaitingReview:
            EmptyView() // Handled in subscriber section
        case .complete:
            if !coordinator.statusMessage.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(coordinator.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    private func saveFeedURL() {
        coordinator.feedURL = feedURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Synchronously load the cached Substack profile for display.
    /// Uses a nonisolated helper since BusinessProfileService is an actor.
    private func getSubstackProfile() -> UserSubstackProfileDTO? {
        // Read from UserDefaults directly to avoid actor isolation issues in View body
        guard let data = UserDefaults.standard.data(forKey: "sam.userSubstackProfile"),
              let decoded = try? JSONDecoder().decode(UserSubstackProfileDTO.self, from: data) else { return nil }
        return decoded
    }
}
