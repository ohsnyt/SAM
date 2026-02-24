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
    var fileCount: Int = 0
    var processedFileCount: Int = 0
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
        fileCount = 1
        processedFileCount = 0

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

    /// Parse all .enex files in a directory and prepare for preview
    func loadDirectory(url: URL) async {
        importStatus = .parsing
        lastError = nil
        parsedNotes = []
        newCount = 0
        duplicateCount = 0
        importedCount = 0
        splitCount = 0
        fileCount = 0
        processedFileCount = 0

        do {
            // Find all .enex files in the directory (non-recursive)
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let enexFiles = contents.filter { $0.pathExtension.lowercased() == "enex" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            guard !enexFiles.isEmpty else {
                importStatus = .failed
                lastError = "No .enex files found in the selected folder"
                return
            }

            fileCount = enexFiles.count
            logger.info("Found \(enexFiles.count) .enex files in directory")

            var allNotes: [EvernoteNoteDTO] = []
            var totalExpanded = 0

            for fileURL in enexFiles {
                let raw = try ENEXParserService.parse(fileURL: fileURL)
                var expandedCount = 0
                let notes = raw.flatMap { note -> [EvernoteNoteDTO] in
                    let parts = splitByDateEntries(note: note)
                    if parts.count > 1 { expandedCount += parts.count - 1 }
                    return parts
                }
                totalExpanded += expandedCount
                allNotes.append(contentsOf: notes)
                processedFileCount += 1
                logger.info("Parsed \(fileURL.lastPathComponent): \(raw.count) notes (\(notes.count) after split)")
            }

            splitCount = totalExpanded
            parsedNotes = allNotes

            // Check for duplicates
            var newNotes = 0
            var dupes = 0
            for note in allNotes {
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

            logger.info("Directory preview: \(newNotes) new, \(dupes) duplicates out of \(allNotes.count) total from \(enexFiles.count) files")

        } catch {
            importStatus = .failed
            lastError = error.localizedDescription
            logger.error("Directory ENEX parse failed: \(error)")
        }
    }

    /// Import previewed notes into SAM
    func confirmImport() async {
        importStatus = .importing
        lastError = nil
        importedCount = 0

        do {
            let allPeople = try peopleRepository.fetchAll()
            var createdNotes: [SamNote] = []

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

                if matchedPeopleIDs.isEmpty {
                    logger.info("Note '\(dto.title)': no tags matched to people (tags: \(dto.tags.joined(separator: ", ")))")
                } else {
                    let matchedNames = matchedPeopleIDs.compactMap { id in
                        allPeople.first { $0.id == id }.map { $0.displayNameCache ?? $0.displayName }
                    }
                    logger.info("Note '\(dto.title)': linked to \(matchedNames.joined(separator: ", "))")
                }

                // Build content: title + body
                let titlePrefix = dto.title.isEmpty ? "" : "\(dto.title)\n\n"
                let titleOffset = titlePrefix.count
                let content = titlePrefix + dto.plainTextContent

                // Build image data with inline positions from ENML parsing
                var imageData: [(Data, String, Int)] = []
                if !dto.resources.isEmpty {
                    imageData = dto.resources.map { resource -> (Data, String, Int) in
                        let hash = resource.md5Hash
                        if let enmlOffset = dto.imagePositions[hash] {
                            let position = enmlOffset + titleOffset
                            logger.debug("Image hash \(hash) → position \(position) (enml offset \(enmlOffset) + title \(titleOffset))")
                            return (resource.data, resource.mimeType, position)
                        } else {
                            logger.debug("Image hash \(hash) — no ENML position, placing at end")
                            return (resource.data, resource.mimeType, Int.max)
                        }
                    }
                }

                // Create note AND images atomically in a single save
                let note = try notesRepository.createFromImportWithImages(
                    sourceImportUID: uid,
                    content: content,
                    createdAt: dto.createdAt,
                    updatedAt: dto.updatedAt,
                    linkedPeopleIDs: matchedPeopleIDs,
                    images: imageData
                )

                if !imageData.isEmpty {
                    let positioned = imageData.filter { $0.2 != Int.max }.count
                    logger.info("Saved \(dto.resources.count) image(s) for '\(dto.title)': \(positioned) inline, \(dto.resources.count - positioned) at end")
                }

                createdNotes.append(note)
                importedCount += 1
            }

            importStatus = .success
            logger.info("ENEX import complete: \(self.importedCount) notes imported")

            // Fire background analysis AFTER all notes are imported
            // (avoids concurrent context modifications during import)
            for note in createdNotes {
                Task {
                    await analysisCoordinator.analyzeNote(note)
                }
            }

        } catch {
            importStatus = .failed
            lastError = error.localizedDescription
            logger.error("ENEX import failed: \(error)")
        }
    }

    // MARK: - Re-link

    /// Re-link previously imported Evernote notes that have no linked people.
    /// First tries direct name matching against note content, then queues AI analysis
    /// which will also auto-link based on extracted mentions.
    /// Returns the number of notes processed.
    func relinkImportedNotes() async -> Int {
        do {
            let allNotes = try notesRepository.fetchAll()
            let unlinked = allNotes.filter { note in
                note.sourceImportUID?.hasPrefix("evernote:") == true && note.linkedPeople.isEmpty
            }

            guard !unlinked.isEmpty else {
                logger.info("Re-link: no unlinked Evernote notes found")
                return 0
            }

            let allPeople = try peopleRepository.fetchAll()
            logger.info("Re-link: found \(unlinked.count) unlinked Evernote notes, matching against \(allPeople.count) people")

            var linkedCount = 0

            for note in unlinked {
                // Direct name matching: check if any person's name appears in note content
                let contentLower = note.content.lowercased()
                let matchedIDs = allPeople.compactMap { person -> UUID? in
                    let name = (person.displayNameCache ?? person.displayName).lowercased()
                    guard name.count >= 3 else { return nil }
                    return contentLower.contains(name) ? person.id : nil
                }

                if !matchedIDs.isEmpty {
                    try notesRepository.updateLinks(note: note, peopleIDs: matchedIDs)
                    linkedCount += 1
                    let names = matchedIDs.compactMap { id in
                        allPeople.first { $0.id == id }.map { $0.displayNameCache ?? $0.displayName }
                    }
                    logger.info("Re-link: linked '\(note.content.prefix(40))...' to \(names.joined(separator: ", "))")
                }

                // Mark for re-analysis so AI can also process
                note.isAnalyzed = false

                // Queue AI analysis (will also auto-link from mentions)
                Task {
                    await analysisCoordinator.analyzeNote(note)
                }
            }

            logger.info("Re-link: directly linked \(linkedCount)/\(unlinked.count) notes, all queued for AI analysis")
            return unlinked.count
        } catch {
            logger.error("Re-link failed: \(error)")
            return 0
        }
    }

    /// Cancel and reset state
    func cancelImport() {
        parsedNotes = []
        newCount = 0
        duplicateCount = 0
        importedCount = 0
        splitCount = 0
        fileCount = 0
        processedFileCount = 0
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

    /// Split a note with date-prefixed entries into individual sub-notes.
    /// Images are distributed to the sub-note whose text range contains their position.
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

        // Build line → character offset map (for image position distribution)
        var lineCharOffsets: [Int] = []
        var offset = 0
        for line in lines {
            lineCharOffsets.append(offset)
            offset += line.count + 1 // +1 for \n
        }

        // Define segments as (startLine, endLine, date, charStart, charEnd)
        struct Segment {
            let startLine: Int
            let endLine: Int
            let date: Date
            let charStart: Int
            let charEnd: Int
        }

        var segments: [Segment] = []

        // Preamble (before first date line)
        if dateLineIndices[0].index > 0 {
            let preambleLines = Array(lines[0..<dateLineIndices[0].index])
            let preambleText = preambleLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if preambleText.count > 20 {
                segments.append(Segment(
                    startLine: 0,
                    endLine: dateLineIndices[0].index,
                    date: note.createdAt,
                    charStart: 0,
                    charEnd: lineCharOffsets[dateLineIndices[0].index]
                ))
            }
        }

        // Date-delimited segments
        for (segIdx, entry) in dateLineIndices.enumerated() {
            let endLine = segIdx + 1 < dateLineIndices.count
                ? dateLineIndices[segIdx + 1].index
                : lines.count

            let chunkLines = Array(lines[entry.index..<endLine])
            let chunkText = chunkLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunkText.isEmpty else { continue }

            let charStart = lineCharOffsets[entry.index]
            let charEnd = endLine < lineCharOffsets.count ? lineCharOffsets[endLine] : offset

            segments.append(Segment(
                startLine: entry.index,
                endLine: endLine,
                date: entry.date,
                charStart: charStart,
                charEnd: charEnd
            ))
        }

        // Distribute resources and image positions to segments
        var subNotes: [EvernoteNoteDTO] = []
        var unassignedResources = note.resources

        for (segIdx, segment) in segments.enumerated() {
            let chunkLines = Array(lines[segment.startLine..<segment.endLine])
            let chunkText = chunkLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            // Find resources whose image position falls within this segment's char range
            var segmentResources: [EvernoteResourceDTO] = []
            var segmentPositions: [String: Int] = [:]
            var remainingResources: [EvernoteResourceDTO] = []

            for resource in unassignedResources {
                let hash = resource.md5Hash
                if let pos = note.imagePositions[hash], pos >= segment.charStart && pos < segment.charEnd {
                    segmentResources.append(resource)
                    // Adjust position relative to this segment's start
                    segmentPositions[hash] = pos - segment.charStart
                } else {
                    remainingResources.append(resource)
                }
            }
            unassignedResources = remainingResources

            // Last segment gets any unassigned resources (no matching position)
            if segIdx == segments.count - 1 && !unassignedResources.isEmpty {
                segmentResources.append(contentsOf: unassignedResources)
                unassignedResources = []
            }

            subNotes.append(EvernoteNoteDTO(
                guid: "\(note.guid)#\(segIdx)",
                title: note.title,
                plainTextContent: chunkText,
                createdAt: segment.date,
                updatedAt: segment.date,
                tags: note.tags,
                resources: segmentResources,
                imagePositions: segmentPositions
            ))
        }

        logger.info("Split note '\(note.title)' into \(subNotes.count) date entries")
        return subNotes
    }
}
