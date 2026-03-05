//
//  SubstackService.swift
//  SAM
//
//  Pure parsing actor for Substack data.
//  Track 1: RSS feed parsing for posts and publication profile.
//  Track 2: Export CSV parsing for subscriber data.
//

import Foundation
import os.log

// MARK: - DTOs

/// A single Substack post parsed from RSS.
struct SubstackPostDTO: Sendable {
    let title: String
    let link: String
    let pubDate: Date
    let htmlContent: String
    let plainTextContent: String
    let description: String
    let tags: [String]
}

/// The user's Substack publication profile parsed from RSS.
struct SubstackProfileDTO: Sendable {
    let publicationName: String
    let publicationDescription: String
    let authorName: String
    let feedURL: String
    let imageURL: String?
}

/// A single subscriber from the Substack export CSV.
struct SubstackSubscriberDTO: Sendable {
    let email: String
    let createdAt: Date
    let planType: String       // "free" or "paid"
    let isActive: Bool
}

// MARK: - SubstackService

actor SubstackService {

    static let shared = SubstackService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SubstackService")

    private init() {}

    // MARK: - RSS Feed Parsing (Track 1)

    /// Fetch and parse a Substack RSS feed.
    /// Returns the publication profile and all posts found in the feed.
    func fetchAndParseFeed(url: URL) async throws -> (profile: SubstackProfileDTO, posts: [SubstackPostDTO]) {
        logger.info("Fetching Substack RSS feed: \(url.absoluteString)")

        let (data, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw SubstackError.feedFetchFailed(httpResponse.statusCode)
        }

        let parser = RSSFeedParser(data: data, feedURL: url.absoluteString)
        let result = parser.parse()

        logger.info("Parsed \(result.posts.count) posts from '\(result.profile.publicationName)'")
        return result
    }

    // MARK: - Subscriber CSV Parsing (Track 2)

    /// Parse a Substack subscriber CSV file.
    /// Expected columns: email, created_at, plan_type, is_active (or similar Substack export format).
    func parseSubscriberCSV(at url: URL) throws -> [SubstackSubscriberDTO] {
        logger.info("Parsing Substack subscriber CSV: \(url.lastPathComponent)")

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard lines.count > 1 else {
            logger.warning("Subscriber CSV is empty or has only a header")
            return []
        }

        // Parse header to find column indices
        let header = parseCSVRow(lines[0])
        let emailIdx = header.firstIndex(where: { $0.lowercased().contains("email") })
        let createdIdx = header.firstIndex(where: { $0.lowercased().contains("created") || $0.lowercased().contains("subscribed") })
        let planIdx = header.firstIndex(where: { $0.lowercased().contains("plan") || $0.lowercased().contains("type") })
        let activeIdx = header.firstIndex(where: { $0.lowercased().contains("active") })

        guard let emailCol = emailIdx else {
            throw SubstackError.csvMissingEmailColumn
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = DateFormatter()
        fallbackFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"

        let simpleFormatter = DateFormatter()
        simpleFormatter.dateFormat = "yyyy-MM-dd"

        var subscribers: [SubstackSubscriberDTO] = []

        for i in 1..<lines.count {
            let cols = parseCSVRow(lines[i])
            guard cols.count > emailCol else { continue }

            let email = cols[emailCol].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty, email.contains("@") else { continue }

            var createdAt = Date()
            if let idx = createdIdx, cols.count > idx {
                let dateStr = cols[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                createdAt = dateFormatter.date(from: dateStr)
                    ?? fallbackFormatter.date(from: dateStr)
                    ?? simpleFormatter.date(from: dateStr)
                    ?? Date()
            }

            var planType = "free"
            if let idx = planIdx, cols.count > idx {
                let raw = cols[idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                planType = raw.contains("paid") ? "paid" : "free"
            }

            var isActive = true
            if let idx = activeIdx, cols.count > idx {
                let raw = cols[idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                isActive = raw == "true" || raw == "1" || raw == "yes" || raw == "active"
            }

            subscribers.append(SubstackSubscriberDTO(
                email: email,
                createdAt: createdAt,
                planType: planType,
                isActive: isActive
            ))
        }

        logger.info("Parsed \(subscribers.count) subscribers from CSV")
        return subscribers
    }

    // MARK: - CSV Helpers

    /// Parse a single CSV row, handling quoted fields.
    private func parseCSVRow(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }

    /// Strip HTML tags from content for AI analysis.
    static func stripHTML(_ html: String) -> String {
        // Remove HTML tags
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum SubstackError: LocalizedError {
    case feedFetchFailed(Int)
    case csvMissingEmailColumn
    case invalidFeedURL

    var errorDescription: String? {
        switch self {
        case .feedFetchFailed(let code):
            return "Failed to fetch RSS feed (HTTP \(code))"
        case .csvMissingEmailColumn:
            return "Subscriber CSV is missing an email column"
        case .invalidFeedURL:
            return "Invalid Substack feed URL"
        }
    }
}

// MARK: - RSS XML Parser

/// XMLParser delegate that extracts RSS 2.0 channel info and items.
private final class RSSFeedParser: NSObject, XMLParserDelegate {

    private let data: Data
    private let feedURL: String
    private var profile = SubstackProfileDTO(publicationName: "", publicationDescription: "", authorName: "", feedURL: "", imageURL: nil)
    private var posts: [SubstackPostDTO] = []

    // Parser state
    private var currentElement = ""
    private var currentText = ""
    private var isInItem = false
    private var isInChannel = false

    // Current item fields
    private var itemTitle = ""
    private var itemLink = ""
    private var itemPubDate = ""
    private var itemContent = ""
    private var itemDescription = ""
    private var itemCategories: [String] = []
    private var itemAuthor = ""

    // Channel fields
    private var channelTitle = ""
    private var channelDescription = ""
    private var channelImage: String?

    // Date formatters for RSS pubDate (RFC 822)
    private let rfc822Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private let iso8601Formatter = ISO8601DateFormatter()

    init(data: Data, feedURL: String) {
        self.data = data
        self.feedURL = feedURL
    }

    func parse() -> (profile: SubstackProfileDTO, posts: [SubstackPostDTO]) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        profile = SubstackProfileDTO(
            publicationName: channelTitle,
            publicationDescription: channelDescription,
            authorName: posts.first.map { _ in itemAuthor }.flatMap { $0.isEmpty ? nil : $0 } ?? "",
            feedURL: feedURL,
            imageURL: channelImage
        )

        return (profile, posts)
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "item" {
            isInItem = true
            itemTitle = ""
            itemLink = ""
            itemPubDate = ""
            itemContent = ""
            itemDescription = ""
            itemCategories = []
            itemAuthor = ""
        } else if elementName == "channel" {
            isInChannel = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) {
            currentText += text
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isInItem {
            switch elementName {
            case "title":
                itemTitle = trimmed
            case "link":
                itemLink = trimmed
            case "pubDate":
                itemPubDate = trimmed
            case "content:encoded", "content":
                itemContent = trimmed
            case "description":
                if itemDescription.isEmpty { itemDescription = trimmed }
            case "category":
                if !trimmed.isEmpty { itemCategories.append(trimmed) }
            case "dc:creator", "author":
                itemAuthor = trimmed
            case "item":
                // Finish item
                let pubDate = rfc822Formatter.date(from: itemPubDate)
                    ?? iso8601Formatter.date(from: itemPubDate)
                    ?? Date()

                let plainText = SubstackService.stripHTML(itemContent.isEmpty ? itemDescription : itemContent)

                posts.append(SubstackPostDTO(
                    title: itemTitle,
                    link: itemLink,
                    pubDate: pubDate,
                    htmlContent: itemContent,
                    plainTextContent: plainText,
                    description: SubstackService.stripHTML(itemDescription),
                    tags: itemCategories
                ))
                isInItem = false
            default:
                break
            }
        } else if isInChannel {
            switch elementName {
            case "title":
                if channelTitle.isEmpty { channelTitle = trimmed }
            case "description":
                if channelDescription.isEmpty { channelDescription = trimmed }
            case "url":
                // Inside <image><url>
                if channelImage == nil { channelImage = trimmed }
            case "dc:creator":
                // Channel-level author
                if itemAuthor.isEmpty { itemAuthor = trimmed }
            case "channel":
                isInChannel = false
            default:
                break
            }
        }

        currentText = ""
    }
}
