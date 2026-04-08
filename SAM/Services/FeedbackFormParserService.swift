//
//  FeedbackFormParserService.swift
//  SAM
//
//  Created on April 7, 2026.
//  Parses Google Forms CSV exports into structured feedback responses.
//

import Foundation
import os.log

// MARK: - DTO

/// A single parsed row from a feedback form CSV export.
struct ParsedFeedbackRow: Sendable {
    let values: [String: String]    // column header → cell value
}

// MARK: - Service

actor FeedbackFormParserService {

    static let shared = FeedbackFormParserService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "FeedbackFormParser")

    private init() {}

    // MARK: - Parse

    /// Parse a Google Forms CSV export into structured feedback responses.
    /// Returns the column headers and parsed rows.
    func parse(url: URL) throws -> (headers: [String], rows: [ParsedFeedbackRow]) {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(text: content)
    }

    /// Parse raw CSV text content.
    func parse(text: String) -> (headers: [String], rows: [ParsedFeedbackRow]) {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .carriageReturns) }
            .filter { !$0.isEmpty }

        guard let headerLine = lines.first else {
            logger.warning("Empty CSV file")
            return (headers: [], rows: [])
        }

        let headers = parseCSVLine(headerLine)

        var rows: [ParsedFeedbackRow] = []
        for line in lines.dropFirst() {
            let fields = parseCSVLine(line)
            var values: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < fields.count {
                let value = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    values[header] = value
                }
            }
            if !values.isEmpty {
                rows.append(ParsedFeedbackRow(values: values))
            }
        }

        logger.info("Parsed feedback CSV: \(rows.count) responses, \(headers.count) columns")
        return (headers: headers, rows: rows)
    }

    /// Map parsed rows to FeedbackResponse structs using a column mapping.
    func mapResponses(rows: [ParsedFeedbackRow], mapping: FeedbackColumnMapping) -> [FeedbackResponse] {
        rows.map { row in
            let name = mapping.nameColumn.flatMap { row.values[$0] }
            let email = mapping.emailColumn.flatMap { row.values[$0] }
            let phone = mapping.phoneColumn.flatMap { row.values[$0] }
            let mostHelpful = mapping.mostHelpfulColumn.flatMap { row.values[$0] }
            let deeperUnderstanding = mapping.deeperUnderstandingColumn.flatMap { row.values[$0] }
            let otherTopics = mapping.otherTopicsColumn.flatMap { row.values[$0] }
            let currentSituation = mapping.currentSituationColumn.flatMap { row.values[$0] }

            // Parse areas to strengthen (semicolon or comma-separated in Google Forms CSV)
            let areasRaw = mapping.areasToStrengthenColumn.flatMap { row.values[$0] } ?? ""
            let areas = areasRaw
                .components(separatedBy: ";")
                .flatMap { $0.components(separatedBy: ",") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // Parse rating
            let ratingRaw = mapping.overallRatingColumn.flatMap { row.values[$0] }
            let rating = ratingRaw.flatMap { matchFeedbackRating($0) }

            // Parse follow-up interest
            let continueRaw = mapping.wouldContinueColumn.flatMap { row.values[$0] }
            let wouldContinue = continueRaw.flatMap { matchFollowUpInterest($0) }

            return FeedbackResponse(
                respondentName: name,
                respondentEmail: email,
                respondentPhone: phone,
                mostHelpful: mostHelpful,
                areasToStrengthen: areas,
                deeperUnderstanding: deeperUnderstanding,
                overallRating: rating,
                wouldContinue: wouldContinue,
                currentSituation: currentSituation,
                otherTopics: otherTopics
            )
        }
    }

    // MARK: - CSV Parsing

    /// Parse a single CSV line handling quoted fields with commas and escaped quotes.
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = line.makeIterator()

        while let c = chars.next() {
            if inQuotes {
                if c == "\"" {
                    // Check for escaped quote ("")
                    // We need to peek at the next character
                    current.append(c)
                    // Handle by checking later
                } else {
                    current.append(c)
                }
            } else {
                if c == "," {
                    fields.append(cleanCSVField(current))
                    current = ""
                } else if c == "\"" {
                    inQuotes = true
                } else {
                    current.append(c)
                }
            }

            // Toggle quotes on paired double-quotes
            if inQuotes && current.hasSuffix("\"\"") {
                current = String(current.dropLast(2)) + "\""
            } else if inQuotes && current.hasSuffix("\"") && c == "\"" {
                // End of quoted field
                current = String(current.dropLast())
                inQuotes = false
            }
        }

        fields.append(cleanCSVField(current))
        return fields
    }

    private func cleanCSVField(_ field: String) -> String {
        var result = field.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove surrounding quotes if present
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }

    // MARK: - Value Matching

    /// Match a free-text rating to the FeedbackRating enum using fuzzy matching.
    private func matchFeedbackRating(_ text: String) -> FeedbackRating? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("extremely") || lower.contains("very") { return .extremelyValuable }
        if lower.contains("helpful") && !lower.contains("not") { return .helpful }
        if lower.contains("neutral") { return .neutral }
        if lower.contains("not") { return .notHelpful }
        return nil
    }

    /// Match a free-text follow-up response to the FollowUpInterest enum.
    private func matchFollowUpInterest(_ text: String) -> FollowUpInterest? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("yes") || lower.contains("schedule") { return .yes }
        if lower.contains("maybe") || lower.contains("more info") { return .maybe }
        if lower.contains("not") || lower.contains("no") { return .notNow }
        return nil
    }
}

// MARK: - CharacterSet Extension

private extension CharacterSet {
    static let carriageReturns = CharacterSet(charactersIn: "\r")
}
