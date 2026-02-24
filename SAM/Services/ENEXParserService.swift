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

    // MARK: - ENML → Plain Text with Image Position Tracking

    /// Unique marker that survives HTML stripping (not an HTML tag, unlikely in real content)
    private static let markerPrefix = "\u{2318}SAMIMG:"
    private static let markerSuffix = "\u{2318}"

    /// Regex to find <en-media hash="..." .../> or <en-media hash="...">...</en-media>
    private static let enMediaRegex = try! NSRegularExpression(
        pattern: #"<en-media[^>]*\bhash\s*=\s*"([a-fA-F0-9]+)"[^>]*/?>(?:</en-media>)?"#,
        options: .caseInsensitive
    )

    /// Regex to find our markers after HTML stripping
    private static let markerRegex = try! NSRegularExpression(
        pattern: "\u{2318}SAMIMG:([a-fA-F0-9]+)\u{2318}"
    )

    /// Convert ENML content to plain text, preserving image positions.
    /// Returns (plainText, [md5Hash: characterPosition]).
    nonisolated static func convertENML(_ enml: String) -> (String, [String: Int]) {
        let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ENEXParserService")
        var text = enml

        // 1. Replace <en-media hash="XX" .../> with text markers (processed in reverse
        //    to preserve earlier match positions)
        let nsText = text as NSString
        let matches = enMediaRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let hashRange = match.range(at: 1)
            let hash = nsText.substring(with: hashRange).lowercased()
            let marker = "\(markerPrefix)\(hash)\(markerSuffix)"
            text = (text as NSString).replacingCharacters(in: match.range, with: marker)
            logger.debug("ENML: found <en-media hash=\"\(hash)\"> → inserted marker")
        }

        if matches.isEmpty {
            logger.debug("ENML: no <en-media> tags found in content (\(enml.count) chars)")
        }

        // 2. Run normal HTML stripping (markers survive because they're not HTML tags)
        text = stripHTML(text)

        // 3. Find markers in the stripped text and record their positions
        let nsStripped = text as NSString
        let markerMatches = markerRegex.matches(in: text, range: NSRange(location: 0, length: nsStripped.length))

        var positions: [String: Int] = [:]
        var cumulativeRemoved = 0

        for match in markerMatches {
            guard match.numberOfRanges > 1 else { continue }
            let hashRange = match.range(at: 1)
            let hash = nsStripped.substring(with: hashRange).lowercased()
            // Character position in the final text (after removing prior markers)
            let position = match.range.location - cumulativeRemoved
            positions[hash] = position
            cumulativeRemoved += match.range.length
            logger.debug("ENML: marker for hash \(hash) at char offset \(position)")
        }

        // 4. Remove all markers from the text
        text = markerRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsStripped.length),
            withTemplate: ""
        )

        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if !positions.isEmpty {
            logger.info("ENML conversion: \(positions.count) image position(s) extracted from \(matches.count) <en-media> tag(s)")
        }

        return (finalText, positions)
    }

    // MARK: - HTML Stripping

    /// HTML tag stripping with newline preservation for block elements
    nonisolated static func stripHTML(_ html: String) -> String {
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

// MARK: - XMLParser Delegate

private class ENEXParserDelegate: NSObject, XMLParserDelegate {
    var notes: [EvernoteNoteDTO] = []

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ENEXParserDelegate")

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

    // Resource parsing state
    private var insideResource = false
    private var currentResourceData = ""
    private var currentResourceMime = ""
    private var currentResources: [EvernoteResourceDTO] = []

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
            currentResources = []
        } else if elementName == "tag" {
            currentTag = ""
        } else if elementName == "resource" && insideNote {
            insideResource = true
            currentResourceData = ""
            currentResourceMime = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideNote else { return }

        if insideResource {
            switch currentElement {
            case "data": currentResourceData += string
            case "mime": currentResourceMime += string
            default: break
            }
            return
        }

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
        if elementName == "resource" && insideNote {
            insideResource = false
            let mime = currentResourceMime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Only keep image resources
            if mime.hasPrefix("image/") {
                let base64 = currentResourceData
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Use .ignoreUnknownCharacters to handle whitespace (spaces, tabs, newlines)
                // that Evernote embeds in base64 data blocks
                if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty {
                    let resource = EvernoteResourceDTO(data: data, mimeType: mime)
                    currentResources.append(resource)
                    logger.debug("Resource: \(mime), \(data.count) bytes, md5=\(resource.md5Hash)")
                }
            }
            currentElement = ""
            return
        }

        if elementName == "tag" && insideNote && !insideResource {
            let tag = currentTag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty {
                currentTags.append(tag)
            }
        }

        if elementName == "note" {
            insideNote = false

            let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let guid = currentGuid.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveGuid = guid.isEmpty ? String(title.hashValue) : guid

            // Convert ENML to plain text, extracting image positions
            let (plainText, imagePositions) = ENEXParserService.convertENML(currentContent)

            let createdAt = Self.dateFormatter.date(from: currentCreated.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Date()
            let updatedAt = Self.dateFormatter.date(from: currentUpdated.trimmingCharacters(in: .whitespacesAndNewlines)) ?? createdAt

            // Log matching summary
            if !self.currentResources.isEmpty {
                let resources = self.currentResources
                let resourceHashes = resources.map { $0.md5Hash }
                let matchedCount = resourceHashes.filter { imagePositions[$0] != nil }.count
                self.logger.info("Note '\(title)': \(resources.count) image(s), \(imagePositions.count) <en-media> tag(s), \(matchedCount) matched by hash")
                for resource in resources {
                    let hash = resource.md5Hash
                    if let pos = imagePositions[hash] {
                        self.logger.debug("  ✓ hash \(hash) → char offset \(pos)")
                    } else {
                        self.logger.debug("  ✗ hash \(hash) — no matching <en-media> tag (will place at end)")
                    }
                }
            }

            let dto = EvernoteNoteDTO(
                guid: effectiveGuid,
                title: title,
                plainTextContent: plainText,
                createdAt: createdAt,
                updatedAt: updatedAt,
                tags: currentTags,
                resources: currentResources,
                imagePositions: imagePositions
            )
            notes.append(dto)
        }

        currentElement = ""
    }
}
