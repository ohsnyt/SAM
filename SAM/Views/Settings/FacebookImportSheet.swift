//
//  FacebookImportSheet.swift
//  SAM
//
//  Smart auto-detection import sheet for Facebook data exports.
//  Handles the full lifecycle: requesting data, watching for the export email,
//  detecting the ZIP, parsing, reviewing matches, and importing.
//
//  Opened from File → Import → Facebook...
//

import SwiftUI
import UniformTypeIdentifiers

struct FacebookImportSheet: View {

    @State private var coordinator = FacebookImportCoordinator.shared
    @State private var classifications: [UUID: FacebookClassification] = [:]
    @State private var deleteZipAfterImport: Bool = true
    @State private var showFilePicker = false
    @State private var filePickerMode: FilePickerMode = .zip

    private enum FilePickerMode {
        case zip, folder

        var allowedTypes: [UTType] {
            switch self {
            case .zip: [.zip, .archive]
            case .folder: [.folder]
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbarView

            Divider()

            // Phase-dependent content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Description
                    Text("Import friends, messages, comments, and reactions from a Facebook data export.")
                        .samFont(.callout)
                        .foregroundStyle(.secondary)

                    // Last import info
                    if let lastImport = coordinator.lastFacebookImportAt {
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
                            if coordinator.parsedFriendCount > 0 {
                                Text("· \(coordinator.parsedFriendCount) friends")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if coordinator.parsedMessageCount > 0 {
                                Text("· \(coordinator.parsedMessageCount) messages")
                                    .samFont(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    phaseContent
                }
                .padding()
            }
        }
        .frame(width: 580, height: phaseHeight)
        .onAppear {
            coordinator.beginImportFlow()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: filePickerMode.allowedTypes,
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

            Text("Facebook")
                .samFont(.headline)

            Spacer()

            // Context-dependent action button
            switch coordinator.sheetPhase {
            case .awaitingReview:
                Button("Import") {
                    Task {
                        await coordinator.completeImportFromSheet(classifications: classifications)
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
        case .noZipFound:     return 480
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
                instructionRow(number: 1, text: "Go to Facebook and request your data export in JSON format")
                instructionRow(number: 2, text: "Wait for the email from Facebook (up to 48 hours)")
                instructionRow(number: 3, text: "Download the ZIP file to your Downloads folder")
                instructionRow(number: 4, text: "Come back here — SAM will detect it automatically")
            }

            HStack(spacing: 12) {
                Button("Request Facebook Data...") {
                    coordinator.openFacebookExportPage()
                }
                .buttonStyle(.borderedProminent)

                Button("Select ZIP File...") {
                    filePickerMode = .zip
                    showFilePicker = true
                }
                .buttonStyle(.bordered)

                Button("Select Folder...") {
                    filePickerMode = .folder
                    showFilePicker = true
                }
                .buttonStyle(.bordered)
            }

            Text("If your download was auto-unzipped, use \"Select Folder\" to choose the Facebook export folder directly.")
                .samFont(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var scanningPhase: some View {
        VStack(spacing: 12) {
            ProgressView("Checking Downloads folder...")
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 20)
    }

    private func zipFoundPhase(info: FacebookZipInfo) -> some View {
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
                Text("Processing Facebook export...")
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
                Text("\(coordinator.parsedFriendCount) friends to review")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
                if coordinator.parsedMessageCount > 0 {
                    Text("\u{00B7} \(coordinator.parsedMessageCount) messages")
                        .samFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Inline review content
            FacebookReviewContent(
                coordinator: coordinator,
                classifications: $classifications
            )
            .frame(minHeight: 300)
            .onAppear {
                // Seed classifications when review content appears
                for candidate in coordinator.importCandidates {
                    if classifications[candidate.id] == nil {
                        classifications[candidate.id] = candidate.defaultClassification
                    }
                }
            }
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
                instructionRow(number: 1, text: "Go to Facebook and request your data export in JSON format")
                instructionRow(number: 2, text: "Wait for the email from Facebook (up to 48 hours)")
                instructionRow(number: 3, text: "Download the ZIP file to your Downloads folder")
                instructionRow(number: 4, text: "Come back here — SAM will detect it automatically")
            }

            HStack(spacing: 12) {
                Button("Request Facebook Data...") {
                    coordinator.openFacebookExportPage()
                }
                .buttonStyle(.borderedProminent)

                if coordinator.isMailAvailableForWatching {
                    Button("Watch for Email") {
                        coordinator.startEmailWatcher()
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 8) {
                Button("Select ZIP File...") {
                    filePickerMode = .zip
                    showFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Select Folder...") {
                    filePickerMode = .folder
                    showFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var watchingEmailPhase: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Watching for Facebook export email...")
                    .samFont(.callout)
            }

            if let startDate = UserDefaults.standard.object(forKey: "sam.facebook.emailWatcherStartDate") as? Date {
                let elapsed = Date.now.timeIntervalSince(startDate)
                let hours = Int(elapsed / 3600)
                let minutes = Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60)
                Text("Checking every 5 minutes \u{00B7} \(hours)h \(minutes)m elapsed")
                    .samFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("SAM will notify you when the export email arrives. Facebook exports can take up to 48 hours.")
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
                    filePickerMode = .zip
                    showFilePicker = true
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

            Text("SAM found the Facebook data export email. Open the download page, download the ZIP file, then come back here.")
                .samFont(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Open Download Page") {
                    NSWorkspace.shared.open(url)
                    coordinator.startFileWatcher()
                }
                .buttonStyle(.borderedProminent)

                Button("Select ZIP File...") {
                    filePickerMode = .zip
                    showFilePicker = true
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
                Text("Monitoring ~/Downloads for Facebook export...")
                    .samFont(.callout)
            }

            if let startDate = UserDefaults.standard.object(forKey: "sam.facebook.fileWatcherStartDate") as? Date {
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
                    filePickerMode = .zip
                    showFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func completePhase(stats: FacebookImportStats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Import Complete", systemImage: "checkmark.circle.fill")
                .samFont(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.green)

            // Summary stats
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if stats.friendCount > 0 {
                        summaryRow("Friends processed:", value: stats.friendCount)
                    }
                    if stats.messageCount > 0 {
                        summaryRow("Messages parsed:", value: stats.messageCount)
                    }
                    if stats.matchedCount > 0 {
                        summaryRow("Matched to existing contacts:", value: stats.matchedCount)
                    }
                    if stats.newContacts > 0 {
                        summaryRow("New contacts created:", value: stats.newContacts)
                    }
                    if stats.postCount > 0 {
                        summaryRow("Posts analyzed:", value: stats.postCount)
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

            Button("Done") {
                if deleteZipAfterImport {
                    try? coordinator.deleteSourceZip()
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
                Button("Select ZIP File...") {
                    filePickerMode = .zip
                    showFilePicker = true
                }
                .buttonStyle(.borderedProminent)

                Button("Select Folder...") {
                    filePickerMode = .folder
                    showFilePicker = true
                }
                .buttonStyle(.bordered)
            }

            Text("If macOS auto-unzipped your download, use \"Select Folder\" to choose the Facebook export folder directly.")
                .samFont(.caption2)
                .foregroundStyle(.tertiary)
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
    FacebookImportSheet()
        .frame(width: 580, height: 500)
}
