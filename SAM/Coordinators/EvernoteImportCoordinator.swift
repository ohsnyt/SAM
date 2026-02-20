//
//  EvernoteImportCoordinator.swift
//  SAM
//
//  Phase L: Notes Pro — Evernote import coordinator
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "EvernoteImportCoordinator")

/// Coordinates Evernote ENEX file import into SAM notes (Phase L)
@MainActor
@Observable
final class EvernoteImportCoordinator {

    // MARK: - Singleton

    static let shared = EvernoteImportCoordinator()

    private init() {}

    // MARK: - Dependencies

    private let notesRepository = NotesRepository.shared
    private let peopleRepository = PeopleRepository.shared
    private let analysisCoordinator = NoteAnalysisCoordinator.shared

    // MARK: - Observable State

    var importStatus: ImportStatus = .idle
    var parsedNotes: [EvernoteNoteDTO] = []
    var newCount: Int = 0
    var duplicateCount: Int = 0
    var importedCount: Int = 0
    var lastError: String?

    // MARK: - Status

    enum ImportStatus: Equatable {
        case idle
        case parsing
        case previewing
        case importing
        case success
        case failed

        var displayText: String {
            switch self {
            case .idle: return "Ready"
            case .parsing: return "Reading file..."
            case .previewing: return "Preview"
            case .importing: return "Importing..."
            case .success: return "Complete"
            case .failed: return "Failed"
            }
        }
    }

    // MARK: - Public API

    /// Parse an ENEX file and prepare for preview
    func loadFile(url: URL) async {
        importStatus = .parsing
        lastError = nil
        parsedNotes = []
        newCount = 0
        duplicateCount = 0
        importedCount = 0

        do {
            let notes = try ENEXParserService.parse(fileURL: url)
            parsedNotes = notes

            // Check for duplicates
            var newNotes = 0
            var dupes = 0
            for note in notes {
                let uid = "evernote:\(note.guid)"
                if let _ = try notesRepository.fetchBySourceImportUID(uid) {
                    dupes += 1
                } else {
                    newNotes += 1
                }
            }

            newCount = newNotes
            duplicateCount = dupes
            importStatus = .previewing

            logger.info("ENEX preview: \(newNotes) new, \(dupes) duplicates out of \(notes.count) total")

        } catch {
            importStatus = .failed
            lastError = error.localizedDescription
            logger.error("ENEX parse failed: \(error)")
        }
    }

    /// Import previewed notes into SAM
    func confirmImport() async {
        importStatus = .importing
        lastError = nil
        importedCount = 0

        do {
            let allPeople = try peopleRepository.fetchAll()

            for dto in parsedNotes {
                let uid = "evernote:\(dto.guid)"

                // Skip duplicates
                if let _ = try notesRepository.fetchBySourceImportUID(uid) {
                    continue
                }

                // Match tags to people (case-insensitive)
                let matchedPeopleIDs: [UUID] = dto.tags.compactMap { tag in
                    let lowTag = tag.lowercased()
                    return allPeople.first { person in
                        (person.displayNameCache ?? person.displayName).lowercased() == lowTag
                    }?.id
                }

                // Build content: title + body
                let content = dto.title.isEmpty
                    ? dto.plainTextContent
                    : "\(dto.title)\n\n\(dto.plainTextContent)"

                let note = try notesRepository.createFromImport(
                    sourceImportUID: uid,
                    content: content,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    linkedPeopleIDs: matchedPeopleIDs
                )

                importedCount += 1

                // Fire background analysis
                Task {
                    await analysisCoordinator.analyzeNote(note)
                }
            }

            importStatus = .success
            logger.info("ENEX import complete: \(self.importedCount) notes imported")

        } catch {
            importStatus = .failed
            lastError = error.localizedDescription
            logger.error("ENEX import failed: \(error)")
        }
    }

    /// Cancel and reset state
    func cancelImport() {
        parsedNotes = []
        newCount = 0
        duplicateCount = 0
        importedCount = 0
        importStatus = .idle
        lastError = nil
    }
}
