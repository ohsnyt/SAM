//
//  SubstackImportSheet.swift
//  SAM
//
//  Standalone sheet for the Substack auto-detection import flow.
//  Combines publication feed management with smart subscriber ZIP detection.
//

import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SubstackImportSheet")

struct SubstackImportSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var coordinator = SubstackImportCoordinator.shared
    @State private var feedURLInput: String = SubstackImportCoordinator.shared.feedURL
    @State private var deleteZipAfterImport = true
    @State private var showManualFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Connect your Substack publication to get content suggestions and identify warm leads from your subscriber base.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    // Publication Feed section (always visible)
                    feedSection
                        .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

                    // Subscriber Import section (phase-dependent)
                    subscriberSection
                        .padding(.horizontal)
                }
                .padding(.vertical, 16)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 400, maxHeight: 600)
        .onAppear {
            coordinator.beginImportFlow()
            FeatureAdoptionTracker.shared.recordUsage(.substackImport)
        }
        .onDisappear {
            // Clean up if user closed the sheet while watchers were running
            // (watchers persist via UserDefaults and will resume on next launch)
        }
        .fileImporter(
            isPresented: $showManualFilePicker,
            allowedContentTypes: [.commaSeparatedText, .folder, UTType(filenameExtension: "zip")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if url.pathExtension.lowercased() == "zip" {
                    Task { await coordinator.processZip(url: url) }
                } else {
                    Task { await coordinator.loadSubscriberCSV(url: url) }
                }
            case .failure(let error):
                logger.error("File picker failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            Text("Substack")
                .font(.headline)

            Spacer()

            toolbarAction
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var toolbarAction: some View {
        switch coordinator.sheetPhase {
        case .complete:
            Button("Done") {
                if deleteZipAfterImport {
                    try? coordinator.deleteSourceZip()
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        case .awaitingReview:
            Button("Confirm Import") {
                Task { await coordinator.completeImportFromSheet() }
            }
            .buttonStyle(.borderedProminent)
        default:
            // Invisible spacer to keep title centered
            Button("Cancel") { dismiss() }
                .opacity(0)
                .disabled(true)
        }
    }

    // MARK: - Feed Section

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
                .disabled(feedURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
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

            if case .importing = coordinator.importStatus {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(coordinator.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Subscriber Section

    private var subscriberSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscriber Import")
                .font(.headline)

            subscriberPhaseContent
        }
    }

    @ViewBuilder
    private var subscriberPhaseContent: some View {
        switch coordinator.sheetPhase {
        case .setup:
            setupPhase

        case .scanning:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking Downloads folder...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .zipFound(let info):
            zipFoundPhase(info: info)

        case .processing:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(coordinator.statusMessage.isEmpty ? "Processing..." : coordinator.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

        case .awaitingReview:
            awaitingReviewPhase

        case .noZipFound:
            noZipFoundPhase

        case .watchingEmail:
            watchingEmailPhase

        case .emailFound(let url):
            emailFoundPhase(url: url)

        case .watchingFile:
            watchingFilePhase

        case .complete(let stats):
            completePhase(stats: stats)

        case .failed(let message):
            failedPhase(message: message)
        }
    }

    // MARK: - Phase Views

    private var setupPhase: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your Substack feed URL above to get started. You can also import a subscriber CSV directly.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Select File Manually...") {
                showManualFilePicker = true
            }
        }
    }

    private func zipFoundPhase(info: ZipInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "doc.zipper")
                            .foregroundStyle(.blue)
                        Text(info.fileName)
                            .font(.callout).bold()
                    }

                    HStack(spacing: 16) {
                        Label(info.fileDate.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(info.formattedSize, systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button("Import This File") {
                    Task { await coordinator.processZip(url: info.url) }
                }
                .buttonStyle(.borderedProminent)

                Button("Not This File") {
                    coordinator.sheetPhase = .noZipFound
                }
            }
        }
    }

    private var awaitingReviewPhase: some View {
        VStack(alignment: .leading, spacing: 8) {
            let matched = coordinator.subscriberCandidates.filter {
                if case .exactMatchEmail = $0.matchStatus { return true }; return false
            }.count
            let unmatched = coordinator.subscriberCandidates.count - matched
            let paid = coordinator.subscriberCandidates.filter { $0.planType == "paid" }.count

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(coordinator.subscriberCandidates.count) subscribers found")
                        .font(.callout).bold()
                    Text("\(matched) matched to contacts \u{2022} \(unmatched) new \u{2022} \(paid) paid")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Text("Matched subscribers will get a touch event. Unmatched will be routed to Unknown Sender triage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var noZipFoundPhase: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("To import subscribers, download your Substack data export:")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                instructionRow(1, "Go to your Substack Settings → Exports")
                instructionRow(2, "Click \"Create new export\" (this may take minutes to hours)")
                instructionRow(3, "When ready, Substack sends an email with a download link")
                instructionRow(4, "Download the ZIP to your Downloads folder")
                instructionRow(5, "Return here — SAM will detect it automatically")
            }

            HStack(spacing: 12) {
                Button("Download Substack Data...") {
                    coordinator.openSubstackExportPage()
                }
                .buttonStyle(.borderedProminent)

                if coordinator.isMailAvailableForWatching {
                    Button("Watch for Email") {
                        coordinator.startEmailWatcher()
                    }
                }
            }

            if !coordinator.isMailAvailableForWatching {
                Text("Tip: Configure Mail in Settings to let SAM automatically detect when Substack sends the export email.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            Button("Select File Manually...") {
                showManualFilePicker = true
            }
            .font(.callout)
        }
    }

    private var watchingEmailPhase: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Watching for Substack export email...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let start = emailWatcherStartDate {
                let elapsed = Date.now.timeIntervalSince(start)
                let minutes = Int(elapsed / 60)
                Text("Polling every 5 minutes \u{2022} \(minutes) min elapsed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("SAM is checking your Mail for the Substack export notification. You can close this sheet — SAM will notify you when it arrives.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel Watch") {
                    coordinator.stopEmailWatcher()
                    coordinator.sheetPhase = .noZipFound
                }

                Button("Select File Manually...") {
                    showManualFilePicker = true
                }
            }
        }
    }

    private func emailFoundPhase(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "envelope.badge.fill")
                    .foregroundStyle(.green)
                Text("Export email detected!")
                    .font(.callout).bold()
            }

            Text("Substack has prepared your data export. Click below to download it, then SAM will automatically detect the ZIP in your Downloads folder.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Open Download Page") {
                    openURL(url)
                    coordinator.startFileWatcher()
                }
                .buttonStyle(.borderedProminent)

                Button("Select File Manually...") {
                    showManualFilePicker = true
                }
            }
        }
    }

    private var watchingFilePhase: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Monitoring ~/Downloads for export ZIP...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let start = fileWatcherStartDate {
                let elapsed = Date.now.timeIntervalSince(start)
                let minutes = Int(elapsed / 60)
                Text("Checking every 30 seconds \u{2022} \(minutes) min elapsed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("You can close this sheet — SAM will notify you when the file appears.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel Watch") {
                    coordinator.stopFileWatcher()
                    coordinator.sheetPhase = .noZipFound
                }

                Button("Select File Manually...") {
                    showManualFilePicker = true
                }
            }
        }
    }

    private func completePhase(stats: ImportStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Import complete!")
                    .font(.callout).bold()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.subscriberCount) subscribers processed")
                        .font(.caption).bold()
                    Text("\(stats.matchedCount) matched \u{2022} \(stats.newLeads) new leads \u{2022} \(stats.touchesCreated) touch events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if coordinator.importedZipURL != nil {
                Toggle("Delete export file from Downloads", isOn: $deleteZipAfterImport)
                    .font(.caption)
            }
        }
    }

    private func failedPhase(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Retry") {
                    coordinator.beginImportFlow()
                }

                Button("Select File Manually...") {
                    showManualFilePicker = true
                }
            }
        }
    }

    // MARK: - Helpers

    private func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveFeedURL() {
        coordinator.feedURL = feedURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isImporting: Bool {
        if case .importing = coordinator.importStatus { return true }
        return false
    }

    // Read-only access to watcher start date for elapsed time display
    private var emailWatcherStartDate: Date? {
        UserDefaults.standard.object(forKey: "sam.substack.emailWatcherStartDate") as? Date
    }

    private var fileWatcherStartDate: Date? {
        UserDefaults.standard.object(forKey: "sam.substack.fileWatcherStartDate") as? Date
    }
}
