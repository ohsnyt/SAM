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
    var splitCount: Int = 0
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
        splitCount = 0

        do {
            let raw = try ENEXParserService.parse(fileURL: url)
            var expandedCount = 0
            let notes = raw.flatMap { note -> [EvernoteNoteDTO] in
                let parts = splitByDateEntries(note: note)
                if parts.count > 1 { expandedCount += parts.count - 1 }
                return parts
            }
            splitCount = expandedCount
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
        splitCount = 0
        importStatus = .idle
        lastError = nil
    }

    // MARK: - Date Entry Splitting

    /// Date formats for parsing date-prefixed lines in Evernote notes
    private static let entryDateFormatters: [DateFormatter] = {
        let formats = [
            "M/d/yyyy", "M/d/yy",
            "M-d-yyyy", "M-d-yy",
            "MMMM d, yyyy", "MMM d, yyyy",
            "yyyy-MM-dd"
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }()

    /// Numeric date pattern: 1/15/2026, 01-15-26, etc.
    private static let numericDateRegex = try! NSRegularExpression(
        pattern: #"^\s*(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})"#
    )

    /// Named month pattern: January 15, 2026 or Jan 15, 2026
    private static let namedDateRegex = try! NSRegularExpression(
        pattern: #"^\s*((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*\.?\s+\d{1,2},?\s+\d{2,4})"#,
        options: .caseInsensitive
    )

    /// Attempt to parse a date string using known entry formats
    private func parseEntryDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        for formatter in Self.entryDateFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    /// Extract a date prefix from a line, returning (dateString, Date) if found
    private func extractDatePrefix(from line: String) -> (String, Date)? {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)

        for regex in [Self.numericDateRegex, Self.namedDateRegex] {
            if let match = regex.firstMatch(in: line, range: range),
               match.numberOfRanges > 1 {
                let dateStr = nsLine.substring(with: match.range(at: 1))
                if let date = parseEntryDate(dateStr) {
                    return (dateStr, date)
                }
            }
        }
        return nil
    }

    /// Split a note with date-prefixed entries into individual sub-notes
    private func splitByDateEntries(note: EvernoteNoteDTO) -> [EvernoteNoteDTO] {
        let lines = note.plainTextContent.components(separatedBy: "\n")

        // Find lines that start with a date
        var dateLineIndices: [(index: Int, date: Date)] = []
        for (i, line) in lines.enumerated() {
            if let (_, date) = extractDatePrefix(from: line) {
                dateLineIndices.append((i, date))
            }
        }

        // Need at least 2 date entries to justify splitting
        guard dateLineIndices.count >= 2 else { return [note] }

        var subNotes: [EvernoteNoteDTO] = []

        // Preamble: text before the first date line
        if dateLineIndices[0].index > 0 {
            let preambleLines = Array(lines[0..<dateLineIndices[0].index])
            let preambleText = preambleLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if preambleText.count > 20 {
                subNotes.append(EvernoteNoteDTO(
                    guid: "\(note.guid)#0",
                    title: note.title,
                    plainTextContent: preambleText,
                    createdAt: note.createdAt,
                    updatedAt: note.createdAt,
                    tags: note.tags
                ))
            }
        }

        // Each date-to-next-date segment
        for (segIdx, entry) in dateLineIndices.enumerated() {
            let startLine = entry.index
            let endLine = segIdx + 1 < dateLineIndices.count
                ? dateLineIndices[segIdx + 1].index
                : lines.count

            let chunkLines = Array(lines[startLine..<endLine])
            let chunkText = chunkLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            guard !chunkText.isEmpty else { continue }

            let subIndex = subNotes.count
            subNotes.append(EvernoteNoteDTO(
                guid: "\(note.guid)#\(subIndex)",
                title: note.title,
                plainTextContent: chunkText,
                createdAt: entry.date,
                updatedAt: entry.date,
                tags: note.tags
            ))
        }

        logger.info("Split note '\(note.title)' into \(subNotes.count) date entries")
        return subNotes
    }
}
