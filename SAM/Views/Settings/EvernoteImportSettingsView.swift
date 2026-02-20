//
//  EvernoteImportSettingsView.swift
//  SAM
//
//  Phase L: Notes Pro — Evernote ENEX import UI
//

import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EvernoteImportSettingsView")

struct EvernoteImportSettingsView: View {

    @State private var coordinator = EvernoteImportCoordinator.shared
    @State private var showingFilePicker = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Evernote Import", systemImage: "square.and.arrow.down")
                        .font(.title2)
                        .bold()

                    Text("Import notes from an Evernote .enex export file. Tags will be matched to existing people by name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // File picker
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Select .enex File") {
                            showingFilePicker = true
                        }
                        .disabled(coordinator.importStatus == .importing || coordinator.importStatus == .parsing)

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
                                Text("Reading file...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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

                            Button("Import Another File") {
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
                }
                .padding()
            }
        }
        .formStyle(.grouped)
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
                    HStack {
                        Text("Total notes in file:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(coordinator.parsedNotes.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
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

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Need security-scoped access for sandboxed apps
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

#Preview {
    EvernoteImportSettingsView()
        .frame(width: 650, height: 500)
}
