//
//  LinkedInImportSheet.swift
//  SAM
//
//  Smart auto-detection import sheet for LinkedIn data exports.
//  Handles the full lifecycle: requesting data, watching for the export email,
//  detecting the ZIP, parsing, reviewing matches, and importing.
//
//  Opened from File → Import → LinkedIn...
//

import SwiftUI
import UniformTypeIdentifiers

struct LinkedInImportSheet: View {

    @State private var coordinator = LinkedInImportCoordinator.shared
    @State private var classifications: [UUID: LinkedInClassification] = [:]
    @State private var deleteZipAfterImport: Bool = true
    @State private var selectedTab: ImportTab = .profilePDFs
    @State private var showManualFilePicker = false
    @State private var showPDFReviewSheet = false
    @State private var showSyncConfirmation = false
    @State private var syncCandidatesSnapshot: [AppleContactsSyncCandidate] = []

    private enum ImportTab: String, CaseIterable {
        case profilePDFs = "Profile PDFs"
        case dataExport = "Data Export"
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbarView

            Divider()

            // Tab picker
            Picker("Import Type", selection: $selectedTab) {
                ForEach(ImportTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab content
            switch selectedTab {
            case .profilePDFs:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        pdfImportSection
                    }
                    .padding()
                }

            case .dataExport:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Description
                        Text("Import connections, messages, and interaction data from a LinkedIn data export.")
                            .samFont(.callout)
                            .foregroundStyle(.secondary)

                        // Last import info
                        if let lastImport = coordinator.lastConnectionImportAt {
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Last import:")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text(lastImport, style: .relative)
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text("ago")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        phaseContent
                    }
                    .padding()
                }
            }
        }
        .frame(width: 580, height: 500)
        .onAppear {
            coordinator.beginImportFlow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .samDismissLinkedInImportSheet)) { _ in
            dismiss()
        }
        .fileImporter(
            isPresented: $showManualFilePicker,
            allowedContentTypes: [.zip, .archive],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                Task {
                    await coordinator.processZip(url: url)
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }
            case .failure(let error):
                coordinator.sheetPhase = .failed(error.localizedDescription)
            }
        }
        .sheet(isPresented: $showSyncConfirmation) {
            AppleContactsSyncConfirmationSheet(
                candidates: syncCandidatesSnapshot,
                onSync: {
                    Task {
                        await coordinator.performAppleContactsSync(candidates: syncCandidatesSnapshot)
                        showSyncConfirmation = false
                    }
                },
                onSkip: {
                    coordinator.dismissAppleContactsSync()
                    showSyncConfirmation = false
                }
            )
        }
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack {
            Button("Cancel") {
                coordinator.cancelWatchers()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Text("LinkedIn")
                .samFont(.headline)

            Spacer()

            // Context-dependent action button
            switch coordinator.sheetPhase {
            case .awaitingReview:
                Button("Import") {
                    Task {
                        await coordinator.completeImportFromSheet(classifications: classifications)
                        // Handle Apple Contacts sync prompt
                        if !coordinator.autoSyncLinkedInURLs {
                            await coordinator.prepareSyncCandidates(classifications: classifications)
                            if !coordinator.appleContactsSyncCandidates.isEmpty {
                                syncCandidatesSnapshot = coordinator.appleContactsSyncCandidates
                                showSyncConfirmation = true
                                return
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            case .complete:
                Button("Done") {
                    if deleteZipAfterImport {
                        try? coordinator.deleteSourceZip()
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            default:
                // Invisible spacer to balance layout
                Button("") { }
                    .hidden()
            }
        }
        .padding()
    }

    // MARK: - Dynamic Height

    private var phaseHeight: CGFloat {
        switch coordinator.sheetPhase {
        case .awaitingReview: return 600
        case .complete:       return 400
        case .noZipFound:     return 450
        default:              return 380
        }
    }

    // MARK: - Phase Content

    @ViewBuilder
    private var phaseContent: some View {
        switch coordinator.sheetPhase {
        case .setup:
            setupPhase
        case .scanning:
            scanningPhase
        case .zipFound(let info):
            zipFoundPhase(info: info)
        case .processing:
            processingPhase
        case .awaitingReview:
            awaitingReviewPhase
        case .importing:
            importingPhase
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
        VStack(alignment: .leading, spacing: 16) {
            Label("Getting Started", systemImage: "info.circle")
                .samFont(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: 1, text: "Go to LinkedIn and request your data export")
                instructionRow(number: 2, text: "Select \"Download larger data archive\" for the complete export")
                instructionRow(number: 3, text: "Wait for the email from LinkedIn (up to 24 hours)")
                instructionRow(number: 4, text: "Download the ZIP file to your Downloads folder")
            }

            HStack(spacing: 12) {
                Button("Request LinkedIn Data...") {
                    coordinator.openLinkedInExportPage()
                }
                .buttonStyle(.borderedProminent)

                Button("Select ZIP File...") {
                    showManualFilePicker = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Profile PDF Import Section

    private var pdfImportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Profile PDFs", systemImage: "doc.text")
                .samFont(.subheadline)
                .fontWeight(.semibold)

            Text("Scan your Downloads folder for LinkedIn Profile PDFs. Matched contacts are auto-enriched; new profiles are shown for review.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: Binding(
                get: { coordinator.pdfDeleteAfterImport },
                set: { coordinator.pdfDeleteAfterImport = $0 }
            )) {
                Text("Delete PDFs after importing")
                    .samFont(.caption)
            }

            HStack {
                pdfStatusView
                Spacer()
            }
        }
        .sheet(isPresented: $showPDFReviewSheet) {
            LinkedInPDFImportReviewSheet()
        }
    }

    @ViewBuilder
    private var pdfStatusView: some View {
        switch coordinator.pdfScanStatus {
        case .idle:
            Button("Scan Downloads for Profiles") {
                Task { await coordinator.scanFolderForProfilePDFs() }
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .scanning:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(coordinator.pdfScanProgress ?? "Scanning…")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear { dismiss() }

        case .awaitingReview:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if coordinator.pdfAutoEnrichedCount > 0 {
                        Text("\(coordinator.pdfAutoEnrichedCount) matched and enriched.")
                            .samFont(.caption)
                            .foregroundStyle(.green)
                    }
                    Text("\(coordinator.pdfImportCandidates.count) need review.")
                        .samFont(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Review & Import") {
                    showPDFReviewSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .importing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Importing…")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

        case .complete(let count):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .samFont(.caption)
                    Text("\(count) profile(s) imported successfully.")
                        .samFont(.caption)
                        .foregroundStyle(.green)
                }
                Button("Scan Again") {
                    Task { await coordinator.scanFolderForProfilePDFs() }
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case .needsFolderAccess:
            VStack(alignment: .leading, spacing: 4) {
                Text("SAM needs access to your Downloads folder to scan for Profile PDFs.")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose Downloads Folder…") {
                    pickFolderForPDFScan()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .samFont(.caption)
                    Text(message)
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Try Again") {
                    Task { await coordinator.scanFolderForProfilePDFs() }
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func pickFolderForPDFScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Scan"
        panel.message = "Select the folder containing LinkedIn Profile PDFs"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await coordinator.scanFolderForProfilePDFs(folderURL: url) }
        dismiss()
    }

    private var scanningPhase: some View {
        VStack(spacing: 12) {
            ProgressView("Checking Downloads folder...")
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 20)
    }

    private func zipFoundPhase(info: LinkedInZipInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Export Found", systemImage: "doc.zipper")
                .samFont(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.green)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("File:")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                        Text(info.fileName)
                            .samFont(.caption)
                            .fontWeight(.medium)
                    }
                    HStack {
                        Text("Date:")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                        Text(info.fileDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                            .samFont(.caption)
                    }
                    HStack {
                        Text("Size:")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                        Text(info.formattedSize)
                            .samFont(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button("Import This File") {
                    Task { await coordinator.processZip(url: info.url) }
                }
                .buttonStyle(.borderedProminent)

                Button("Not This File") {
                    coordinator.sheetPhase = .noZipFound
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var processingPhase: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)

            if let progress = coordinator.progressMessage {
                Text(progress)
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Processing LinkedIn export...")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var awaitingReviewPhase: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Summary line
            HStack(spacing: 8) {
                if coordinator.exactMatchCount > 0 {
                    Text("\(coordinator.exactMatchCount) auto-matched")
                        .samFont(.caption)
                        .foregroundStyle(.green)
                }
                Text("\(coordinator.pendingConnectionCount) connections to review")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                if coordinator.newMessageCount > 0 {
                    Text("\u{00B7} \(coordinator.newMessageCount) new messages")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Inline review content
            LinkedInReviewContent(
                candidates: coordinator.importCandidates,
                classifications: $classifications
            )
            .frame(minHeight: 300)
        }
    }

    private var importingPhase: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.linear)

            if let progress = coordinator.progressMessage {
                Text(progress)
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Importing...")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 20)
    }

    private var noZipFoundPhase: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("No Export Found in Downloads", systemImage: "folder.badge.questionmark")
                .samFont(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: 1, text: "Go to LinkedIn and request your data export")
                instructionRow(number: 2, text: "Select \"Download larger data archive\" for the complete export")
                instructionRow(number: 3, text: "Wait for the email from LinkedIn (up to 24 hours)")
                instructionRow(number: 4, text: "Download the ZIP file to your Downloads folder")
                instructionRow(number: 5, text: "Come back here — SAM will detect it automatically")
            }

            HStack(spacing: 12) {
                Button("Request LinkedIn Data...") {
                    coordinator.openLinkedInExportPage()
                }
                .buttonStyle(.borderedProminent)

                if coordinator.isMailAvailableForWatching {
                    Button("Watch for Email") {
                        coordinator.startEmailWatcher()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button("Select ZIP File...") {
                showManualFilePicker = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
    }

    private var watchingEmailPhase: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Watching for LinkedIn export email...")
                    .samFont(.callout)
            }

            if let startDate = UserDefaults.standard.object(forKey: "sam.linkedin.emailWatcherStartDate") as? Date {
                let elapsed = Date.now.timeIntervalSince(startDate)
                let hours = Int(elapsed / 3600)
                let minutes = Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60)
                Text("Checking every 5 minutes \u{00B7} \(hours)h \(minutes)m elapsed")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("SAM will notify you when the export email arrives. This typically takes up to 24 hours.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel Watch") {
                    coordinator.stopEmailWatcher()
                    coordinator.sheetPhase = .noZipFound
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Select ZIP File...") {
                    showManualFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func emailFoundPhase(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Export Email Detected!", systemImage: "envelope.open.fill")
                .samFont(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.green)

            Text("SAM found the LinkedIn data export email. Open the download page, download the ZIP file, then come back here.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Open Download Page") {
                    NSWorkspace.shared.open(url)
                    coordinator.startFileWatcher()
                }
                .buttonStyle(.borderedProminent)

                Button("Select ZIP File...") {
                    showManualFilePicker = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var watchingFilePhase: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Monitoring ~/Downloads for LinkedIn export...")
                    .samFont(.callout)
            }

            if let startDate = UserDefaults.standard.object(forKey: "sam.linkedin.fileWatcherStartDate") as? Date {
                let elapsed = Date.now.timeIntervalSince(startDate)
                let minutes = Int(elapsed / 60)
                Text("Checking every 30 seconds \u{00B7} \(minutes) min elapsed")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Cancel Watch") {
                    coordinator.stopFileWatcher()
                    coordinator.sheetPhase = .noZipFound
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Select ZIP File...") {
                    showManualFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func completePhase(stats: LinkedInImportStats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Import Complete", systemImage: "checkmark.circle.fill")
                .samFont(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.green)

            // Summary stats
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if stats.connectionCount > 0 {
                        summaryRow("Connections processed:", value: stats.connectionCount)
                    }
                    if stats.messageCount > 0 {
                        summaryRow("Messages imported:", value: stats.messageCount)
                    }
                    if stats.matchedCount > 0 {
                        summaryRow("Matched to existing contacts:", value: stats.matchedCount)
                    }
                    if stats.newContacts > 0 {
                        summaryRow("New contacts created:", value: stats.newContacts)
                    }
                    if stats.enrichments > 0 {
                        summaryRow("Contact updates queued:", value: stats.enrichments)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Delete ZIP toggle
            if coordinator.importedZipURL != nil {
                Toggle(isOn: $deleteZipAfterImport) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete export file from Downloads")
                            .samFont(.caption)
                            .fontWeight(.medium)
                        Text("The import data is now in SAM — the ZIP file is no longer needed.")
                            .samFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func failedPhase(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Import Failed", systemImage: "xmark.circle.fill")
                .samFont(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.red)

            Text(message)
                .samFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Retry") {
                    coordinator.beginImportFlow()
                }
                .buttonStyle(.borderedProminent)

                Button("Select ZIP File...") {
                    showManualFilePicker = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Helpers

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .samFont(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .samFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryRow(_ label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .samFont(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .samFont(.caption)
                .fontWeight(.semibold)
        }
    }
}

// MARK: - Preview

#Preview {
    LinkedInImportSheet()
        .frame(width: 580, height: 500)
}
