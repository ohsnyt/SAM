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

    /// Parse endorsement/recommendation date strings in the format "2016/07/14 14:34:13 UTC".
    private static func makeEndorsementDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm:ss zzz"
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

        logger.debug("Parsed \(messages.count) LinkedIn messages (after watermark filter)")
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

        logger.debug("Parsed \(connections.count) LinkedIn connections")
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

    // MARK: - Parse Endorsements Received

    /// Parse Endorsement_Received_Info.csv — people who endorsed the user.
    /// Columns: Endorsement Date, Skill Name, Endorser First Name, Endorser Last Name,
    ///          Endorser Public Url, Endorsement Status
    func parseEndorsementsReceived(at url: URL) async -> [LinkedInEndorsementReceivedDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Endorsement_Received_Info.csv at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard
            let firstIdx  = header.firstIndex(of: "Endorser First Name"),
            let lastIdx   = header.firstIndex(of: "Endorser Last Name"),
            let urlIdx    = header.firstIndex(of: "Endorser Public Url"),
            let skillIdx  = header.firstIndex(of: "Skill Name"),
            let statusIdx = header.firstIndex(of: "Endorsement Status")
        else {
            logger.error("Endorsement_Received_Info.csv: missing expected headers. Found: \(header.joined(separator: ", "))")
            return []
        }

        let dateIdx = header.firstIndex(of: "Endorsement Date")
        let dateFormatter = Self.makeEndorsementDateFormatter()

        var results: [LinkedInEndorsementReceivedDTO] = []
        for row in rows.dropFirst() {
            guard row.count > max(firstIdx, lastIdx, urlIdx, skillIdx, statusIdx) else { continue }
            let status = row[statusIdx].trimmingCharacters(in: .whitespaces)
            guard status == "ACCEPTED" else { continue }
            let profileURL = normalizeProfileURL(row[urlIdx])
            guard !profileURL.isEmpty else { continue }
            let firstName = row[firstIdx].trimmingCharacters(in: .whitespaces)
            let lastName  = row[lastIdx].trimmingCharacters(in: .whitespaces)
            let fullName  = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
            let skill     = row[skillIdx].trimmingCharacters(in: .whitespaces)
            var endorsementDate: Date? = nil
            if let dIdx = dateIdx, row.count > dIdx {
                endorsementDate = dateFormatter.date(from: row[dIdx].trimmingCharacters(in: .whitespaces))
            }
            results.append(LinkedInEndorsementReceivedDTO(
                fullName: fullName.isEmpty ? nil : fullName,
                profileURL: profileURL,
                skillName: skill.isEmpty ? nil : skill,
                endorsementDate: endorsementDate
            ))
        }

        logger.debug("Parsed \(results.count) accepted endorsements received")
        return results
    }

    // MARK: - Parse Endorsements Given

    /// Parse Endorsement_Given_Info.csv — people the user endorsed.
    /// Columns: Endorsement Date, Skill Name, Endorsee First Name, Endorsee Last Name,
    ///          Endorsee Public Url, Endorsement Status
    func parseEndorsementsGiven(at url: URL) async -> [LinkedInEndorsementGivenDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Endorsement_Given_Info.csv at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard
            let firstIdx  = header.firstIndex(of: "Endorsee First Name"),
            let lastIdx   = header.firstIndex(of: "Endorsee Last Name"),
            let urlIdx    = header.firstIndex(of: "Endorsee Public Url"),
            let skillIdx  = header.firstIndex(of: "Skill Name"),
            let statusIdx = header.firstIndex(of: "Endorsement Status")
        else {
            logger.error("Endorsement_Given_Info.csv: missing expected headers. Found: \(header.joined(separator: ", "))")
            return []
        }

        let dateIdx = header.firstIndex(of: "Endorsement Date")
        let dateFormatter = Self.makeEndorsementDateFormatter()

        var results: [LinkedInEndorsementGivenDTO] = []
        for row in rows.dropFirst() {
            guard row.count > max(firstIdx, lastIdx, urlIdx, skillIdx, statusIdx) else { continue }
            let status = row[statusIdx].trimmingCharacters(in: .whitespaces)
            guard status == "ACCEPTED" else { continue }
            let profileURL = normalizeProfileURL(row[urlIdx])
            guard !profileURL.isEmpty else { continue }
            let firstName = row[firstIdx].trimmingCharacters(in: .whitespaces)
            let lastName  = row[lastIdx].trimmingCharacters(in: .whitespaces)
            let fullName  = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
            let skill     = row[skillIdx].trimmingCharacters(in: .whitespaces)
            var endorsementDate: Date? = nil
            if let dIdx = dateIdx, row.count > dIdx {
                endorsementDate = dateFormatter.date(from: row[dIdx].trimmingCharacters(in: .whitespaces))
            }
            results.append(LinkedInEndorsementGivenDTO(
                fullName: fullName.isEmpty ? nil : fullName,
                profileURL: profileURL,
                skillName: skill.isEmpty ? nil : skill,
                endorsementDate: endorsementDate
            ))
        }

        logger.debug("Parsed \(results.count) accepted endorsements given")
        return results
    }

    // MARK: - Parse Recommendations Given

    /// Parse Recommendations_Given.csv — recommendations the user wrote for others.
    /// Columns: First Name, Last Name, Company, Job Title, Text, Creation Date, Status
    func parseRecommendationsGiven(at url: URL) async -> [LinkedInRecommendationGivenDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Recommendations_Given.csv at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard
            let firstIdx   = header.firstIndex(of: "First Name"),
            let lastIdx    = header.firstIndex(of: "Last Name"),
            let companyIdx = header.firstIndex(of: "Company"),
            let titleIdx   = header.firstIndex(of: "Job Title")
        else {
            logger.error("Recommendations_Given.csv: missing expected headers. Found: \(header.joined(separator: ", "))")
            return []
        }

        var results: [LinkedInRecommendationGivenDTO] = []
        for row in rows.dropFirst() {
            guard row.count > max(firstIdx, lastIdx, companyIdx, titleIdx) else { continue }
            let firstName = row[firstIdx].trimmingCharacters(in: .whitespaces)
            let lastName  = row[lastIdx].trimmingCharacters(in: .whitespaces)
            let fullName  = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
            guard !fullName.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let company   = row[companyIdx].trimmingCharacters(in: .whitespaces)
            let jobTitle  = row[titleIdx].trimmingCharacters(in: .whitespaces)
            results.append(LinkedInRecommendationGivenDTO(
                fullName: fullName,
                company: company.isEmpty ? nil : company,
                jobTitle: jobTitle.isEmpty ? nil : jobTitle
            ))
        }

        logger.debug("Parsed \(results.count) recommendations given")
        return results
    }

    // MARK: - Parse Invitations

    /// Parse Invitations.csv — sent and received connection invitations.
    /// Columns: From, To, Sent At, Message, Direction, inviterProfileUrl, inviteeProfileUrl
    func parseInvitations(at url: URL) async -> [LinkedInInvitationDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Invitations.csv at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard
            let directionIdx  = header.firstIndex(of: "Direction"),
            let inviterURLIdx = header.firstIndex(of: "inviterProfileUrl"),
            let inviteeURLIdx = header.firstIndex(of: "inviteeProfileUrl"),
            let fromIdx       = header.firstIndex(of: "From"),
            let toIdx         = header.firstIndex(of: "To")
        else {
            logger.error("Invitations.csv: missing expected headers. Found: \(header.joined(separator: ", "))")
            return []
        }

        let messageIdx = header.firstIndex(of: "Message")
        let sentAtIdx  = header.firstIndex(of: "Sent At")
        let isoFormatter = ISO8601DateFormatter()
        // LinkedIn exports "Sent At" as either ISO8601 or locale-formatted "M/d/yy, h:mm a"
        let localeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "M/d/yy, h:mm a"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        var results: [LinkedInInvitationDTO] = []
        for row in rows.dropFirst() {
            guard row.count > max(directionIdx, inviterURLIdx, inviteeURLIdx, fromIdx, toIdx) else { continue }
            let direction   = row[directionIdx].trimmingCharacters(in: .whitespaces)
            let inviterURL  = normalizeProfileURL(row[inviterURLIdx])
            let inviteeURL  = normalizeProfileURL(row[inviteeURLIdx])
            let fromName    = row[fromIdx].trimmingCharacters(in: .whitespaces)
            let toName      = row[toIdx].trimmingCharacters(in: .whitespaces)

            // Determine the contact's name and URL (not the user's side)
            // INCOMING: user is invitee, contact is inviter
            // OUTGOING: user is inviter, contact is invitee
            let contactName: String
            let contactURL: String
            if direction == "INCOMING" {
                contactName = fromName
                contactURL  = inviterURL
            } else {
                contactName = toName
                contactURL  = inviteeURL
            }

            guard !contactURL.isEmpty else { continue }

            var message: String? = nil
            if let mIdx = messageIdx, row.count > mIdx {
                let m = row[mIdx].trimmingCharacters(in: .whitespaces)
                message = m.isEmpty ? nil : m
            }

            var sentAt: Date? = nil
            if let sIdx = sentAtIdx, row.count > sIdx {
                let raw = row[sIdx].trimmingCharacters(in: .whitespaces)
                sentAt = isoFormatter.date(from: raw) ?? localeFormatter.date(from: raw) ?? {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    f.timeZone = TimeZone(identifier: "UTC")
                    return f.date(from: raw)
                }()
            }

            results.append(LinkedInInvitationDTO(
                contactName: contactName.isEmpty ? nil : contactName,
                contactProfileURL: contactURL,
                direction: direction == "INCOMING" ? .incoming : .outgoing,
                message: message,
                sentAt: sentAt
            ))
        }

        logger.debug("Parsed \(results.count) invitations")
        return results
    }

    // MARK: - Parse User Profile

    /// Parse Profile.csv — the user's own LinkedIn headline, summary, industry, and location.
    /// Columns: First Name, Last Name, Maiden Name, Address, Birth Date, Headline, Summary,
    ///          Industry, Zip Code, Geo Location, Twitter Handles, Websites, Instant Messengers
    func parseProfile(at url: URL) async -> (firstName: String, lastName: String, headline: String, summary: String, industry: String, geoLocation: String)? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Profile.csv at \(url.path)")
            return nil
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return nil }

        let header = rows[0]
        guard
            let firstNameIdx  = header.firstIndex(of: "First Name"),
            let lastNameIdx   = header.firstIndex(of: "Last Name"),
            let headlineIdx   = header.firstIndex(of: "Headline"),
            let summaryIdx    = header.firstIndex(of: "Summary"),
            let industryIdx   = header.firstIndex(of: "Industry"),
            let geoIdx        = header.firstIndex(of: "Geo Location")
        else {
            logger.error("Profile.csv: missing expected headers. Found: \(header.joined(separator: ", "))")
            return nil
        }

        let row = rows[1]
        let maxIdx = max(firstNameIdx, lastNameIdx, headlineIdx, summaryIdx, industryIdx, geoIdx)
        guard row.count > maxIdx else { return nil }

        return (
            firstName:   row[firstNameIdx].trimmingCharacters(in: .whitespaces),
            lastName:    row[lastNameIdx].trimmingCharacters(in: .whitespaces),
            headline:    row[headlineIdx].trimmingCharacters(in: .whitespaces),
            summary:     row[summaryIdx].trimmingCharacters(in: .whitespaces),
            industry:    row[industryIdx].trimmingCharacters(in: .whitespaces),
            geoLocation: row[geoIdx].trimmingCharacters(in: .whitespaces)
        )
    }

    /// Parse Positions.csv — the user's career history.
    /// Columns: Company Name, Title, Description, Location, Started On, Finished On
    func parsePositions(at url: URL) async -> [LinkedInPositionDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Positions.csv at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard
            let companyIdx    = header.firstIndex(of: "Company Name"),
            let titleIdx      = header.firstIndex(of: "Title"),
            let descIdx       = header.firstIndex(of: "Description"),
            let locationIdx   = header.firstIndex(of: "Location"),
            let startedIdx    = header.firstIndex(of: "Started On"),
            let finishedIdx   = header.firstIndex(of: "Finished On")
        else {
            logger.error("Positions.csv: missing expected headers. Found: \(header.joined(separator: ", "))")
            return []
        }

        var results: [LinkedInPositionDTO] = []
        for row in rows.dropFirst() {
            let maxIdx = max(companyIdx, titleIdx, descIdx, locationIdx, startedIdx, finishedIdx)
            guard row.count > maxIdx else { continue }
            let company = row[companyIdx].trimmingCharacters(in: .whitespaces)
            let title   = row[titleIdx].trimmingCharacters(in: .whitespaces)
            guard !company.isEmpty || !title.isEmpty else { continue }
            results.append(LinkedInPositionDTO(
                companyName: company,
                title: title,
                description: row[descIdx].trimmingCharacters(in: .whitespaces),
                location: row[locationIdx].trimmingCharacters(in: .whitespaces),
                startedOn: row[startedIdx].trimmingCharacters(in: .whitespaces),
                finishedOn: row[finishedIdx].trimmingCharacters(in: .whitespaces)
            ))
        }

        logger.debug("Parsed \(results.count) positions")
        return results
    }

    /// Parse Education.csv — the user's education history.
    /// Columns: School Name, Start Date, End Date, Notes, Degree Name, Activities
    func parseEducation(at url: URL) async -> [LinkedInEducationDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Education.csv at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard
            let schoolIdx     = header.firstIndex(of: "School Name"),
            let startIdx      = header.firstIndex(of: "Start Date"),
            let endIdx        = header.firstIndex(of: "End Date"),
            let notesIdx      = header.firstIndex(of: "Notes"),
            let degreeIdx     = header.firstIndex(of: "Degree Name"),
            let activitiesIdx = header.firstIndex(of: "Activities")
        else {
            logger.error("Education.csv: missing expected headers. Found: \(header.joined(separator: ", "))")
            return []
        }

        var results: [LinkedInEducationDTO] = []
        for row in rows.dropFirst() {
            let maxIdx = max(schoolIdx, startIdx, endIdx, notesIdx, degreeIdx, activitiesIdx)
            guard row.count > maxIdx else { continue }
            results.append(LinkedInEducationDTO(
                schoolName: row[schoolIdx].trimmingCharacters(in: .whitespaces),
                startDate: row[startIdx].trimmingCharacters(in: .whitespaces),
                endDate: row[endIdx].trimmingCharacters(in: .whitespaces),
                notes: row[notesIdx].trimmingCharacters(in: .whitespaces),
                degreeName: row[degreeIdx].trimmingCharacters(in: .whitespaces),
                activities: row[activitiesIdx].trimmingCharacters(in: .whitespaces)
            ))
        }

        logger.debug("Parsed \(results.count) education entries")
        return results
    }

    /// Parse Skills.csv — the user's listed skills.
    /// Column: Name
    func parseSkills(at url: URL) async -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Skills.csv at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard let nameIdx = header.firstIndex(of: "Name") else {
            logger.error("Skills.csv: missing 'Name' header. Found: \(header.joined(separator: ", "))")
            return []
        }

        let skills = rows.dropFirst().compactMap { row -> String? in
            guard row.count > nameIdx else { return nil }
            let skill = row[nameIdx].trimmingCharacters(in: .whitespaces)
            return skill.isEmpty ? nil : skill
        }

        logger.debug("Parsed \(skills.count) skills")
        return skills
    }

    /// Parse Certifications.csv — the user's professional certifications.
    /// Columns: Name, Url, Authority, Started On, Finished On, License Number
    func parseCertifications(at url: URL) async -> [LinkedInCertificationDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.error("Could not read Certifications.csv at \(url.path)")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard
            let nameIdx      = header.firstIndex(of: "Name"),
            let urlIdx       = header.firstIndex(of: "Url"),
            let authorityIdx = header.firstIndex(of: "Authority"),
            let startedIdx   = header.firstIndex(of: "Started On"),
            let finishedIdx  = header.firstIndex(of: "Finished On"),
            let licenseIdx   = header.firstIndex(of: "License Number")
        else {
            logger.error("Certifications.csv: missing expected headers. Found: \(header.joined(separator: ", "))")
            return []
        }

        var results: [LinkedInCertificationDTO] = []
        for row in rows.dropFirst() {
            let maxIdx = max(nameIdx, urlIdx, authorityIdx, startedIdx, finishedIdx, licenseIdx)
            guard row.count > maxIdx else { continue }
            let name = row[nameIdx].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            results.append(LinkedInCertificationDTO(
                name: name,
                url: row[urlIdx].trimmingCharacters(in: .whitespaces),
                authority: row[authorityIdx].trimmingCharacters(in: .whitespaces),
                startedOn: row[startedIdx].trimmingCharacters(in: .whitespaces),
                finishedOn: row[finishedIdx].trimmingCharacters(in: .whitespaces),
                licenseNumber: row[licenseIdx].trimmingCharacters(in: .whitespaces)
            ))
        }

        logger.debug("Parsed \(results.count) certifications")
        return results
    }

    // MARK: - Parse Recommendations Received

    /// Parse Recommendations_Received.csv — recommendations written FOR the user by others.
    /// Columns vary but typically: First Name, Last Name, Company, Job Title, Text, Creation Date, Status
    /// The "Received" file (inbound) complements Recommendations_Given.csv (outbound).
    func parseRecommendationsReceived(at url: URL) async -> [LinkedInRecommendationReceivedDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.debug("Recommendations_Received.csv not found at \(url.path) — skipping")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        // The file may use "Recommender Name" or split first/last name
        let fullNameIdx   = header.firstIndex(of: "Recommender Name")
        let firstIdx      = header.firstIndex(of: "First Name")
        let lastIdx       = header.firstIndex(of: "Last Name")
        let profileURLIdx = header.firstIndex(of: "Recommender Profile URL")
        let companyIdx    = header.firstIndex(of: "Company")
        let titleIdx      = header.firstIndex(of: "Job Title")
        let textIdx       = header.firstIndex(of: "Text")
        let dateIdx       = header.firstIndex(of: "Creation Date")

        let isoFormatter = ISO8601DateFormatter()
        let dateFormatter = Self.makeConnectionDateFormatter()

        var results: [LinkedInRecommendationReceivedDTO] = []
        for row in rows.dropFirst() {
            guard !row.allSatisfy(\.isEmpty) else { continue }

            // Resolve name
            var resolvedName: String? = nil
            if let idx = fullNameIdx, row.count > idx {
                let n = row[idx].trimmingCharacters(in: .whitespaces)
                resolvedName = n.isEmpty ? nil : n
            } else if let fIdx = firstIdx, let lIdx = lastIdx,
                      row.count > max(fIdx, lIdx) {
                let full = "\(row[fIdx].trimmingCharacters(in: .whitespaces)) \(row[lIdx].trimmingCharacters(in: .whitespaces))".trimmingCharacters(in: .whitespaces)
                resolvedName = full.isEmpty ? nil : full
            }

            let profileURL: String? = {
                guard let idx = profileURLIdx, row.count > idx else { return nil }
                let u = normalizeProfileURL(row[idx])
                return u.isEmpty ? nil : u
            }()

            let company: String? = {
                guard let idx = companyIdx, row.count > idx else { return nil }
                let c = row[idx].trimmingCharacters(in: .whitespaces)
                return c.isEmpty ? nil : c
            }()

            let jobTitle: String? = {
                guard let idx = titleIdx, row.count > idx else { return nil }
                let t = row[idx].trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }()

            let text: String? = {
                guard let idx = textIdx, row.count > idx else { return nil }
                let t = row[idx].trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }()

            var sentAt: Date? = nil
            if let idx = dateIdx, row.count > idx {
                let ds = row[idx].trimmingCharacters(in: .whitespaces)
                sentAt = isoFormatter.date(from: ds) ?? dateFormatter.date(from: ds) ?? {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    f.timeZone = TimeZone(identifier: "UTC")
                    return f.date(from: ds)
                }()
            }

            results.append(LinkedInRecommendationReceivedDTO(
                recommenderName: resolvedName,
                recommenderProfileURL: profileURL,
                company: company,
                jobTitle: jobTitle,
                recommendationText: text,
                sentAt: sentAt
            ))
        }

        logger.debug("Parsed \(results.count) recommendations received")
        return results
    }

    // MARK: - Parse Reactions Given

    /// Parse Reactions.csv — reactions the user gave on other people's posts.
    /// Columns: Date, Type, Link
    func parseReactionsGiven(at url: URL) async -> [LinkedInReactionDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.debug("Reactions.csv not found at \(url.path) — skipping")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        // Column names may vary; try multiple candidates
        guard let dateIdx = header.firstIndex(of: "Date") ?? header.firstIndex(of: "Reaction Date") else {
            logger.error("Reactions.csv: missing Date header. Found: \(header.joined(separator: ", "))")
            return []
        }
        let typeIdx = header.firstIndex(of: "Type") ?? header.firstIndex(of: "Reaction Type")
        let linkIdx = header.firstIndex(of: "Link") ?? header.firstIndex(of: "Post Link") ?? header.firstIndex(of: "URL")

        let isoFormatter = ISO8601DateFormatter()
        let fallbackFmt = DateFormatter()
        fallbackFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fallbackFmt.timeZone = TimeZone(identifier: "UTC")

        var results: [LinkedInReactionDTO] = []
        for row in rows.dropFirst() {
            guard row.count > dateIdx else { continue }
            let dateStr = row[dateIdx].trimmingCharacters(in: .whitespaces)
            guard let date = isoFormatter.date(from: dateStr) ?? fallbackFmt.date(from: dateStr) else { continue }

            let reactionType: String = {
                guard let idx = typeIdx, row.count > idx else { return "like" }
                let t = row[idx].trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? "like" : t.lowercased()
            }()

            let postUrl: String = {
                guard let idx = linkIdx, row.count > idx else { return "" }
                return row[idx].trimmingCharacters(in: .whitespaces)
            }()

            guard !postUrl.isEmpty else { continue }

            results.append(LinkedInReactionDTO(
                postUrl: postUrl,
                reactionType: reactionType,
                date: date
            ))
        }

        logger.debug("Parsed \(results.count) reactions given")
        return results
    }

    // MARK: - Parse Comments Given

    /// Parse Comments.csv — comments the user wrote on other people's posts.
    /// Columns: Date, Message (or Comment), Link
    func parseCommentsGiven(at url: URL) async -> [LinkedInCommentDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.debug("Comments.csv not found at \(url.path) — skipping")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard let dateIdx = header.firstIndex(of: "Date") ?? header.firstIndex(of: "Comment Date") else {
            logger.error("Comments.csv: missing Date header. Found: \(header.joined(separator: ", "))")
            return []
        }
        let messageIdx = header.firstIndex(of: "Message") ?? header.firstIndex(of: "Comment")
        let linkIdx    = header.firstIndex(of: "Link") ?? header.firstIndex(of: "Post Link") ?? header.firstIndex(of: "URL")

        let isoFormatter = ISO8601DateFormatter()
        let fallbackFmt = DateFormatter()
        fallbackFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fallbackFmt.timeZone = TimeZone(identifier: "UTC")

        var results: [LinkedInCommentDTO] = []
        for row in rows.dropFirst() {
            guard row.count > dateIdx else { continue }
            let dateStr = row[dateIdx].trimmingCharacters(in: .whitespaces)
            guard let date = isoFormatter.date(from: dateStr) ?? fallbackFmt.date(from: dateStr) else { continue }

            let commentText: String? = {
                guard let idx = messageIdx, row.count > idx else { return nil }
                let t = stripHTML(row[idx]).trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : String(t.prefix(200))
            }()

            let postUrl: String = {
                guard let idx = linkIdx, row.count > idx else { return "" }
                return row[idx].trimmingCharacters(in: .whitespaces)
            }()

            guard !postUrl.isEmpty else { continue }

            results.append(LinkedInCommentDTO(
                postUrl: postUrl,
                commentText: commentText,
                date: date
            ))
        }

        logger.debug("Parsed \(results.count) comments given")
        return results
    }

    // MARK: - Parse Shares (user's posts)

    /// Parse Shares.csv — posts the user published on LinkedIn.
    /// Columns: Date, ShareCommentary (or Share Comment), SharedUrl (or Share Link), Visibility
    func parseShares(at url: URL) async -> [LinkedInShareDTO] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.debug("Shares.csv not found at \(url.path) — skipping")
            return []
        }

        let rows = parseCSV(content)
        guard rows.count > 1 else { return [] }

        let header = rows[0]
        guard let dateIdx = header.firstIndex(of: "Date") ?? header.firstIndex(of: "Share Date") else {
            logger.error("Shares.csv: missing Date header. Found: \(header.joined(separator: ", "))")
            return []
        }
        let commentIdx    = header.firstIndex(of: "ShareCommentary") ?? header.firstIndex(of: "Share Comment") ?? header.firstIndex(of: "Comment")
        let mediaIdx      = header.firstIndex(of: "SharedUrl") ?? header.firstIndex(of: "Share Link") ?? header.firstIndex(of: "URL")
        let visibilityIdx = header.firstIndex(of: "Visibility")

        let isoFormatter = ISO8601DateFormatter()
        // LinkedIn exports dates as "2026-03-02 17:23:08" (space-separated, no T, no timezone)
        let fallbackFormatter = DateFormatter()
        fallbackFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fallbackFormatter.timeZone = TimeZone(identifier: "UTC")

        var results: [LinkedInShareDTO] = []
        for row in rows.dropFirst() {
            guard row.count > dateIdx else { continue }
            let dateStr = row[dateIdx].trimmingCharacters(in: .whitespaces)
            guard let date = isoFormatter.date(from: dateStr) ?? fallbackFormatter.date(from: dateStr) else { continue }

            let comment: String? = {
                guard let idx = commentIdx, row.count > idx else { return nil }
                let t = stripHTML(row[idx]).trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }()

            let mediaUrl: String? = {
                guard let idx = mediaIdx, row.count > idx else { return nil }
                let u = row[idx].trimmingCharacters(in: .whitespaces)
                return u.isEmpty ? nil : u
            }()

            let visibility: String? = {
                guard let idx = visibilityIdx, row.count > idx else { return nil }
                let v = row[idx].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }()

            results.append(LinkedInShareDTO(
                shareDate: date,
                shareComment: comment,
                mediaUrl: mediaUrl,
                visibility: visibility
            ))
        }

        logger.debug("Parsed \(results.count) shares")
        return results
    }

    // MARK: - Parse User Profile

    /// Composite: parse all user profile CSVs from a LinkedIn export folder.
    /// Silently skips files that are absent or malformed.
    func parseUserProfile(folder: URL) async -> UserLinkedInProfileDTO? {
        let profileURL        = folder.appendingPathComponent("Profile.csv")
        let positionsURL      = folder.appendingPathComponent("Positions.csv")
        let educationURL      = folder.appendingPathComponent("Education.csv")
        let skillsURL         = folder.appendingPathComponent("Skills.csv")
        let certificationsURL = folder.appendingPathComponent("Certifications.csv")

        guard let profileBase = await parseProfile(at: profileURL) else {
            logger.debug("Profile.csv not found or empty — skipping user profile parse")
            return nil
        }

        async let positions     = parsePositions(at: positionsURL)
        async let education     = parseEducation(at: educationURL)
        async let skills        = parseSkills(at: skillsURL)
        async let certifications = parseCertifications(at: certificationsURL)

        return UserLinkedInProfileDTO(
            firstName:    profileBase.firstName,
            lastName:     profileBase.lastName,
            headline:     profileBase.headline,
            summary:      profileBase.summary,
            industry:     profileBase.industry,
            geoLocation:  profileBase.geoLocation,
            positions:    await positions,
            education:    await education,
            skills:       await skills,
            certifications: await certifications
        )
    }
}

// MARK: - New DTOs (contact-enriching)

/// Someone who endorsed the user on LinkedIn.
public struct LinkedInEndorsementReceivedDTO: Sendable {
    public let fullName: String?
    public let profileURL: String
    public let skillName: String?
    public let endorsementDate: Date?
}

/// Someone the user endorsed on LinkedIn.
public struct LinkedInEndorsementGivenDTO: Sendable {
    public let fullName: String?
    public let profileURL: String
    public let skillName: String?
    public let endorsementDate: Date?
}

/// Someone the user recommended on LinkedIn (company/title from their profile at time of recommendation).
public struct LinkedInRecommendationGivenDTO: Sendable {
    public let fullName: String
    public let company: String?
    public let jobTitle: String?
}

/// A LinkedIn connection invitation (sent or received).
public struct LinkedInInvitationDTO: Sendable {
    public enum Direction: Sendable { case incoming, outgoing }
    public let contactName: String?
    public let contactProfileURL: String
    public let direction: Direction
    /// Non-empty when the inviter included a personal note.
    public let message: String?
    /// When the invitation was sent.
    public let sentAt: Date?
}

/// A recommendation someone wrote for the user.
public struct LinkedInRecommendationReceivedDTO: Sendable {
    public let recommenderName: String?
    public let recommenderProfileURL: String?
    public let company: String?
    public let jobTitle: String?
    public let recommendationText: String?
    public let sentAt: Date?
}

/// A reaction the user gave on someone else's LinkedIn post.
public struct LinkedInReactionDTO: Sendable {
    /// The URL of the post that was reacted to.
    public let postUrl: String
    public let reactionType: String
    public let date: Date
}

/// A comment the user wrote on someone else's LinkedIn post.
public struct LinkedInCommentDTO: Sendable {
    /// The URL of the post that was commented on.
    public let postUrl: String
    public let commentText: String?
    public let date: Date
}

/// A post (share) the user published on LinkedIn.
public struct LinkedInShareDTO: Sendable {
    public let shareDate: Date
    public let shareComment: String?
    public let mediaUrl: String?
    public let visibility: String?
}

// MARK: - String Helper

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
