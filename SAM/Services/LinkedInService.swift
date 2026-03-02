//
//  LinkedInService.swift
//  SAM
//
//  Phase S+: LinkedIn Archive Import
//
//  Parses LinkedIn data export CSV files and returns structured DTOs.
//  Handles HTML content stripping, three date formats, and dedup key generation.
//  This service is pure parsing — no SwiftData or UI dependencies.
//

import Foundation
import os.log

// MARK: - DTOs

/// A parsed LinkedIn message suitable for import as SamEvidenceItem.
public struct LinkedInMessageDTO: Sendable {
    /// Stable dedup key: "linkedin:senderProfileURL:ISO8601timestamp:first50hash"
    public let sourceUID: String
    public let conversationID: String
    public let conversationTitle: String
    public let senderName: String
    public let senderProfileURL: String
    public let recipientProfileURLs: [String]
    public let occurredAt: Date
    public let subject: String
    public let plainTextContent: String
    public let folder: String       // INBOX, SENT, etc.
}

/// A parsed LinkedIn connection suitable for enriching SamPerson records.
public struct LinkedInConnectionDTO: Sendable {
    public let firstName: String
    public let lastName: String
    public let profileURL: String   // normalized: "www.linkedin.com/in/..."
    public let email: String?
    public let company: String?
    public let position: String?
    public let connectedOn: Date?
}

// MARK: - Service

actor LinkedInService {

    // MARK: - Singleton

    static let shared = LinkedInService()
    private init() {}

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "LinkedInService")

    // MARK: - Date Formatters (nonisolated static helpers to avoid actor hop issues)

    private static func makeMessageDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private static func makeConnectionDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "dd MMM yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    // MARK: - Parse Messages

    /// Parse a LinkedIn messages.csv export file.
    /// Returns messages newer than `since` (pass nil to import all).
    func parseMessages(at url: URL, since watermark: Date?) async -> [LinkedInMessageDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read messages file at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard
            let convIDIdx        = header.firstIndex(of: "CONVERSATION ID"),
            let convTitleIdx     = header.firstIndex(of: "CONVERSATION TITLE"),
            let fromIdx          = header.firstIndex(of: "FROM"),
            let senderURLIdx     = header.firstIndex(of: "SENDER PROFILE URL"),
            let recipientsIdx    = header.firstIndex(of: "RECIPIENT PROFILE URLS"),
            let dateIdx          = header.firstIndex(of: "DATE"),
            let subjectIdx       = header.firstIndex(of: "SUBJECT"),
            let contentIdx       = header.firstIndex(of: "CONTENT"),
            let folderIdx        = header.firstIndex(of: "FOLDER")
        else {
            logger.error("messages.csv missing expected headers")
            return []
        }

        let dateFormatter = Self.makeMessageDateFormatter()
        let isoFormatter  = ISO8601DateFormatter()
        var messages: [LinkedInMessageDTO] = []

        for row in rows.dropFirst() {
            guard row.count > max(convIDIdx, convTitleIdx, fromIdx, senderURLIdx,
                                  recipientsIdx, dateIdx, subjectIdx, contentIdx, folderIdx)
            else { continue }

            let dateString = row[dateIdx].trimmingCharacters(in: .whitespaces)
            guard let date = dateFormatter.date(from: dateString) else {
                logger.warning("Could not parse message date: \(dateString)")
                continue
            }

            // Apply watermark filter
            if let since = watermark, date <= since { continue }

            let senderProfileURL = normalizeProfileURL(row[senderURLIdx])
            let plainText = stripHTML(row[contentIdx])
            let contentPrefix = String(plainText.prefix(50))

            let sourceUID = "linkedin:\(senderProfileURL):\(isoFormatter.string(from: date)):\(contentPrefix.hashValue)"

            let recipientURLs = row[recipientsIdx]
                .split(separator: ",")
                .map { normalizeProfileURL(String($0).trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }

            messages.append(LinkedInMessageDTO(
                sourceUID:            sourceUID,
                conversationID:       row[convIDIdx],
                conversationTitle:    row[convTitleIdx],
                senderName:           row[fromIdx].trimmingCharacters(in: .whitespaces),
                senderProfileURL:     senderProfileURL,
                recipientProfileURLs: recipientURLs,
                occurredAt:           date,
                subject:              row[subjectIdx].trimmingCharacters(in: .whitespaces),
                plainTextContent:     plainText,
                folder:               row[folderIdx].trimmingCharacters(in: .whitespaces)
            ))
        }

        logger.info("Parsed \(messages.count) LinkedIn messages (after watermark filter)")
        return messages
    }

    // MARK: - Parse Connections

    /// Parse a LinkedIn Connections.csv export file.
    func parseConnections(at url: URL) async -> [LinkedInConnectionDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read connections file at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        // Connections.csv has 3 note rows before the header — find it
        // Header row contains "First Name"
        var headerRowIndex: Int? = nil
        for (idx, row) in rows.enumerated() {
            if row.first?.trimmingCharacters(in: .whitespaces) == "First Name" {
                headerRowIndex = idx
                break
            }
        }

        guard let headerIdx = headerRowIndex else {
            logger.error("Connections.csv: could not locate header row")
            return []
        }

        let header = rows[headerIdx]
        guard
            let firstIdx    = header.firstIndex(of: "First Name"),
            let lastIdx     = header.firstIndex(of: "Last Name"),
            let urlIdx      = header.firstIndex(of: "URL"),
            let emailIdx    = header.firstIndex(of: "Email Address"),
            let companyIdx  = header.firstIndex(of: "Company"),
            let positionIdx = header.firstIndex(of: "Position"),
            let dateIdx     = header.firstIndex(of: "Connected On")
        else {
            logger.error("Connections.csv missing expected headers. Found: \(header.joined(separator: ", "))")
            return []
        }

        let dateFormatter = Self.makeConnectionDateFormatter()
        var connections: [LinkedInConnectionDTO] = []

        for row in rows.dropFirst(headerIdx + 1) {
            guard row.count > max(firstIdx, lastIdx, urlIdx, emailIdx, companyIdx, positionIdx, dateIdx)
            else { continue }

            let profileURL = normalizeProfileURL(row[urlIdx])
            guard !profileURL.isEmpty else { continue }

            let dateString = row[dateIdx].trimmingCharacters(in: .whitespaces)
            let connectedOn = dateFormatter.date(from: dateString)

            let email = row[emailIdx].trimmingCharacters(in: .whitespaces)

            let company  = row[companyIdx].trimmingCharacters(in: .whitespaces)
            let position = row[positionIdx].trimmingCharacters(in: .whitespaces)
            connections.append(LinkedInConnectionDTO(
                firstName:   row[firstIdx].trimmingCharacters(in: .whitespaces),
                lastName:    row[lastIdx].trimmingCharacters(in: .whitespaces),
                profileURL:  profileURL,
                email:       email.isEmpty ? nil : email,
                company:     company.isEmpty ? nil : company,
                position:    position.isEmpty ? nil : position,
                connectedOn: connectedOn
            ))
        }

        logger.info("Parsed \(connections.count) LinkedIn connections")
        return connections
    }

    // MARK: - Helpers

    /// Normalize a LinkedIn profile URL to consistent form "www.linkedin.com/in/slug".
    /// Strips "https://", trailing slashes, and whitespace.
    private func normalizeProfileURL(_ raw: String) -> String {
        var url = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }

    /// Strip HTML tags from a string. Uses a simple regex approach
    /// for speed rather than loading a full DOM parser.
    private func stripHTML(_ html: String) -> String {
        // Replace <br>, </p>, </div> with newlines before stripping tags
        var result = html
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)

        // Strip all remaining tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Decode common HTML entities
        result = result
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse multiple blank lines
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - RFC-4180 CSV Parser

    /// Minimal RFC-4180-compliant CSV parser that handles quoted fields,
    /// embedded commas, and escaped quotes ("" → ").
    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]

            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        // Escaped quote
                        currentField.append("\"")
                        i = text.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(c)
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                } else if c == "," {
                    currentRow.append(currentField)
                    currentField = ""
                } else if c == "\n" {
                    currentRow.append(currentField)
                    currentField = ""
                    rows.append(currentRow)
                    currentRow = []
                } else if c == "\r" {
                    // Handle \r\n — skip the \r, \n will be handled on next iteration
                } else {
                    currentField.append(c)
                }
            }

            i = text.index(after: i)
        }

        // Flush last field/row
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        return rows.filter { !$0.allSatisfy(\.isEmpty) }
    }
}

// MARK: - String Helper

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
