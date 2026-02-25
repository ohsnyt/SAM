//
//  EvernoteImportSettingsView.swift
//  SAM
//
//  Phase L: Notes Pro — Evernote ENEX import UI
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EvernoteImportSettingsView")

// MARK: - Content (embeddable in DisclosureGroup)

struct EvernoteImportSettingsContent: View {

    @State private var coordinator = EvernoteImportCoordinator.shared
    @State private var showingFilePicker = false
    @State private var isRelinking = false
    @State private var relinkResult: Int?
    @State private var isCleaning = false
    @State private var cleanResult: Int?

    private var isDisabled: Bool {
        coordinator.importStatus == .importing || coordinator.importStatus == .parsing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Import notes from Evernote .enex export files. Tags will be matched to existing people by name.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // File/folder picker
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button("Select .enex File") {
                        showingFilePicker = true
                    }
                    .disabled(isDisabled)

                    Button("Select Folder") {
                        selectFolder()
                    }
                    .disabled(isDisabled)
                }

                // Status display
                switch coordinator.importStatus {
                case .idle:
                    Text("No file selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                case .parsing:
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        if coordinator.fileCount > 1 {
                            Text("Reading file \(coordinator.processedFileCount + 1) of \(coordinator.fileCount)...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Reading file...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                case .previewing:
                    previewSection

                case .importing:
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Importing \(coordinator.importedCount) notes...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .success:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Successfully imported \(coordinator.importedCount) notes")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Button("Import More") {
                        coordinator.cancelImport()
                    }
                    .buttonStyle(.bordered)

                case .failed:
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(coordinator.lastError ?? "Import failed")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button("Try Again") {
                        coordinator.cancelImport()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            // Maintenance
            VStack(alignment: .leading, spacing: 12) {
                Text("Maintenance")
                    .font(.headline)

                Text("Re-analyze previously imported Evernote notes that aren't linked to any people. This uses AI analysis to detect person references in note content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        Task {
                            isRelinking = true
                            relinkResult = nil
                            let count = await coordinator.relinkImportedNotes()
                            relinkResult = count
                            isRelinking = false
                        }
                    } label: {
                        if isRelinking {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Re-linking...")
                            }
                        } else {
                            Text("Re-link Imported Notes")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRelinking)

                    if let count = relinkResult {
                        Text(count > 0
                            ? "\(count) notes queued for analysis"
                            : "No unlinked notes found")
                            .font(.caption)
                            .foregroundStyle(count > 0 ? .green : .secondary)
                    }
                }

                Divider()

                Text("Remove malformed JSON text that may have leaked into note summaries from AI analysis failures.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        isCleaning = true
                        cleanResult = nil
                        do {
                            let count = try NotesRepository.shared.sanitizeJSONSummaries()
                            cleanResult = count
                        } catch {
                            logger.error("JSON cleanup failed: \(error)")
                        }
                        isCleaning = false
                    } label: {
                        Text("Clean Up JSON Summaries")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCleaning)

                    if let count = cleanResult {
                        Text(count > 0
                            ? "\(count) summaries cleaned"
                            : "No contaminated summaries found")
                            .font(.caption)
                            .foregroundStyle(count > 0 ? .green : .secondary)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.xml],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    // MARK: - Preview Section

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if coordinator.fileCount > 1 {
                        HStack {
                            Text("Files parsed:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(coordinator.fileCount)")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                    }

                    HStack {
                        Text("Total notes:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(coordinator.parsedNotes.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }

                    if coordinator.splitCount > 0 {
                        HStack {
                            Text("  ↳ Expanded by dates:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("+\(coordinator.splitCount)")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                    }

                    HStack {
                        Text("New (will import):")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(coordinator.newCount)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }

                    if coordinator.duplicateCount > 0 {
                        HStack {
                            Text("Already imported (skip):")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(coordinator.duplicateCount)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 12) {
                Button("Import") {
                    Task {
                        await coordinator.confirmImport()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.newCount == 0)

                Button("Cancel") {
                    coordinator.cancelImport()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Actions

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing .enex files"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await coordinator.loadDirectory(url: url)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                coordinator.importStatus = .failed
                coordinator.lastError = "Could not access the selected file"
                return
            }

            Task {
                await coordinator.loadFile(url: url)
                url.stopAccessingSecurityScopedResource()
            }

        case .failure(let error):
            logger.error("File picker error: \(error)")
            coordinator.importStatus = .failed
            coordinator.lastError = error.localizedDescription
        }
    }
}

// MARK: - Standalone wrapper

struct EvernoteImportSettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Evernote Import", systemImage: "square.and.arrow.down")
                        .font(.title2)
                        .bold()

                    EvernoteImportSettingsContent()
                }
                .padding()
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    EvernoteImportSettingsView()
        .frame(width: 650, height: 500)
}
