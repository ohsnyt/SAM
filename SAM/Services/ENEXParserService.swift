//
//  ENEXParserService.swift
//  SAM
//
//  Phase L: Notes Pro — Evernote ENEX XML parser
//

import Foundation
import os.log

/// Parses Evernote .enex XML export files into EvernoteNoteDTO values (Phase L)
@MainActor
enum ENEXParserService {

    private static let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ENEXParserService")

    static func parse(fileURL: URL) throws -> [EvernoteNoteDTO] {
        let data = try Data(contentsOf: fileURL)
        let delegate = ENEXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate

        guard parser.parse() else {
            if let error = parser.parserError {
                throw ENEXParseError.xmlParseError(error.localizedDescription)
            }
            throw ENEXParseError.unknownError
        }

        logger.info("Parsed \(delegate.notes.count) notes from ENEX file")
        return delegate.notes
    }

    enum ENEXParseError: Error, LocalizedError {
        case xmlParseError(String)
        case unknownError

        var errorDescription: String? {
            switch self {
            case .xmlParseError(let msg): return "ENEX parse error: \(msg)"
            case .unknownError: return "Unknown ENEX parse error"
            }
        }
    }
}

// MARK: - XMLParser Delegate

private class ENEXParserDelegate: NSObject, XMLParserDelegate {
    var notes: [EvernoteNoteDTO] = []

    // Current parsing state
    private var currentElement = ""
    private var currentTitle = ""
    private var currentContent = ""
    private var currentCreated = ""
    private var currentUpdated = ""
    private var currentGuid = ""
    private var currentTags: [String] = []
    private var currentTag = ""
    private var insideNote = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName

        if elementName == "note" {
            insideNote = true
            currentTitle = ""
            currentContent = ""
            currentCreated = ""
            currentUpdated = ""
            currentGuid = ""
            currentTags = []
            currentTag = ""
        } else if elementName == "tag" {
            currentTag = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideNote else { return }

        switch currentElement {
        case "title": currentTitle += string
        case "content": currentContent += string
        case "created": currentCreated += string
        case "updated": currentUpdated += string
        case "guid": currentGuid += string
        case "tag": currentTag += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard insideNote, currentElement == "content" else { return }
        if let str = String(data: CDATABlock, encoding: .utf8) {
            currentContent += str
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "tag" && insideNote {
            let tag = currentTag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty {
                currentTags.append(tag)
            }
        }

        if elementName == "note" {
            insideNote = false

            let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let plainText = Self.stripHTML(currentContent)
            let guid = currentGuid.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveGuid = guid.isEmpty ? String(title.hashValue) : guid

            let createdAt = Self.dateFormatter.date(from: currentCreated.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date()
            let updatedAt = Self.dateFormatter.date(from: currentUpdated.trimmingCharacters(in: .whitespacesAndNewlines)) ?? createdAt

            let dto = EvernoteNoteDTO(
                guid: effectiveGuid,
                title: title,
                plainTextContent: plainText,
                createdAt: createdAt,
                updatedAt: updatedAt,
                tags: currentTags
            )
            notes.append(dto)
        }

        currentElement = ""
    }

    // HTML tag stripping with newline preservation for block elements
    static func stripHTML(_ html: String) -> String {
        var text = html
        // Convert block-level closing tags and <br> to newlines
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
        // Strip remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&#xa0;", with: " ")
        // Collapse horizontal whitespace only (preserve newlines)
        text = text.replacingOccurrences(of: "[^\\S\\n]+", with: " ", options: .regularExpression)
        // Collapse 3+ consecutive newlines into 2
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        // Trim each line and remove leading/trailing blank lines
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        text = lines.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
