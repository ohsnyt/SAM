//
//  ComplianceScanner.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase Z: Compliance Awareness
//
//  Deterministic keyword-based compliance scanning for draft messages.
//  Advisory only — never blocks sending.
//

import Foundation
import SwiftUI

// MARK: - ComplianceCategory

enum ComplianceCategory: String, Sendable, CaseIterable, Codable {
    case guarantees
    case returns
    case promises
    case comparativeClaims
    case suitability
    case specificAdvice

    var displayName: String {
        switch self {
        case .guarantees:       return "Guarantees"
        case .returns:          return "Returns/Performance"
        case .promises:         return "Promises"
        case .comparativeClaims: return "Comparative Claims"
        case .suitability:      return "Suitability"
        case .specificAdvice:   return "Specific Advice"
        }
    }

    var icon: String {
        switch self {
        case .guarantees:       return "shield.slash"
        case .returns:          return "chart.line.uptrend.xyaxis"
        case .promises:         return "hand.raised"
        case .comparativeClaims: return "arrow.left.arrow.right"
        case .suitability:      return "person.fill.questionmark"
        case .specificAdvice:   return "exclamationmark.bubble"
        }
    }

    var color: Color {
        switch self {
        case .guarantees:       return .red
        case .returns:          return .orange
        case .promises:         return .red
        case .comparativeClaims: return .purple
        case .suitability:      return .yellow
        case .specificAdvice:   return .orange
        }
    }

    /// UserDefaults key for per-category enable/disable.
    var settingsKey: String {
        "complianceCat_\(rawValue)"
    }
}

// MARK: - ComplianceFlag

struct ComplianceFlag: Sendable, Identifiable, Codable {
    let id: UUID
    let category: ComplianceCategory
    let matchedPhrase: String
    let suggestion: String?

    init(category: ComplianceCategory, matchedPhrase: String, suggestion: String? = nil) {
        self.id = UUID()
        self.category = category
        self.matchedPhrase = matchedPhrase
        self.suggestion = suggestion
    }
}

// MARK: - ComplianceScanner

enum ComplianceScanner {

    // MARK: - Public API

    /// Scan text for compliance-sensitive phrases.
    /// - Parameters:
    ///   - text: The draft text to scan.
    ///   - enabledCategories: Which categories to check (defaults to all).
    ///   - customKeywords: Additional keywords matched as `.specificAdvice`.
    /// - Returns: Deduplicated flags sorted by category order.
    static func scan(
        _ text: String,
        enabledCategories: Set<ComplianceCategory> = Set(ComplianceCategory.allCases),
        customKeywords: [String] = []
    ) -> [ComplianceFlag] {
        guard !text.isEmpty else { return [] }

        let lowered = text.lowercased()
        var flags: [ComplianceFlag] = []
        var matchedRanges: [Range<String.Index>] = []

        // Check each enabled category
        for category in ComplianceCategory.allCases where enabledCategories.contains(category) {
            let patterns = phrasePatterns[category] ?? []
            for pattern in patterns {
                switch pattern {
                case .literal(let phrase, let suggestion):
                    if let range = lowered.range(of: phrase) {
                        if !overlaps(range, with: matchedRanges) {
                            matchedRanges.append(range)
                            let matched = String(text[range])
                            flags.append(ComplianceFlag(
                                category: category,
                                matchedPhrase: matched,
                                suggestion: suggestion
                            ))
                        }
                    }

                case .regex(let regexPattern, let suggestion):
                    if let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive) {
                        let nsRange = NSRange(lowered.startIndex..., in: lowered)
                        let matches = regex.matches(in: lowered, range: nsRange)
                        for match in matches {
                            if let swiftRange = Range(match.range, in: lowered) {
                                if !overlaps(swiftRange, with: matchedRanges) {
                                    matchedRanges.append(swiftRange)
                                    let matched = String(text[swiftRange])
                                    flags.append(ComplianceFlag(
                                        category: category,
                                        matchedPhrase: matched,
                                        suggestion: suggestion
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }

        // Custom keywords → specificAdvice
        if enabledCategories.contains(.specificAdvice) {
            for keyword in customKeywords where !keyword.isEmpty {
                let loweredKW = keyword.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if let range = lowered.range(of: loweredKW) {
                    if !overlaps(range, with: matchedRanges) {
                        matchedRanges.append(range)
                        let matched = String(text[range])
                        flags.append(ComplianceFlag(
                            category: .specificAdvice,
                            matchedPhrase: matched,
                            suggestion: "Custom keyword flagged"
                        ))
                    }
                }
            }
        }

        // Sort by category order (allCases order)
        let categoryOrder = Dictionary(
            uniqueKeysWithValues: ComplianceCategory.allCases.enumerated().map { ($1, $0) }
        )
        return flags.sorted { (categoryOrder[$0.category] ?? 0) < (categoryOrder[$1.category] ?? 0) }
    }

    /// Convenience: scan using current UserDefaults settings.
    static func scanWithSettings(_ text: String) -> [ComplianceFlag] {
        let enabled = UserDefaults.standard.bool(forKey: "complianceCheckingEnabled")
        guard enabled else { return [] }

        var categories = Set<ComplianceCategory>()
        for cat in ComplianceCategory.allCases {
            // Default to true if key not set
            let isOn = UserDefaults.standard.object(forKey: cat.settingsKey) == nil
                ? true
                : UserDefaults.standard.bool(forKey: cat.settingsKey)
            if isOn { categories.insert(cat) }
        }

        let customStr = UserDefaults.standard.string(forKey: "complianceCustomKeywords") ?? ""
        let customKeywords = customStr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return scan(text, enabledCategories: categories, customKeywords: customKeywords)
    }

    // MARK: - Private

    private enum Pattern {
        case literal(String, String?)   // (phrase, suggestion)
        case regex(String, String?)     // (regex pattern, suggestion)
    }

    private static let phrasePatterns: [ComplianceCategory: [Pattern]] = [
        .guarantees: [
            .literal("guaranteed return", "Avoid implying guaranteed outcomes"),
            .literal("guaranteed income", "Avoid implying guaranteed outcomes"),
            .literal("guaranteed growth", "Avoid implying guaranteed outcomes"),
            .literal("no risk", "All investments carry some risk"),
            .literal("risk-free", "All investments carry some risk"),
            .literal("risk free", "All investments carry some risk"),
            .literal("safe investment", "Avoid implying investments are 'safe'"),
            .literal("protected principal", "Clarify any principal protection terms"),
            .literal("can't lose", "Avoid implying no loss is possible"),
            .literal("cannot lose", "Avoid implying no loss is possible"),
        ],
        .returns: [
            .literal("will earn", "Use 'may earn' or 'historically has earned'"),
            .literal("expect to gain", "Use 'may potentially gain'"),
            .literal("beat the market", "Avoid predicting market outperformance"),
            .literal("outperform", "Avoid predicting outperformance"),
            .literal("historical returns will", "Past performance doesn't guarantee future results"),
            .literal("annual return of", "Clarify this is not guaranteed"),
            .regex("earn \\d+%", "Avoid stating specific return percentages as certain"),
        ],
        .promises: [
            .literal("i promise", "Avoid making personal promises about outcomes"),
            .literal("i guarantee", "Avoid personal guarantees"),
            .literal("will ensure", "Use 'will work to' or 'aim to'"),
            .literal("will make sure", "Use 'will work to' or 'aim to'"),
            .literal("without doubt", "Avoid absolute certainty language"),
            .literal("definitely will", "Avoid absolute certainty language"),
            .literal("certainly will", "Avoid absolute certainty language"),
            .literal("absolutely guaranteed", "Avoid absolute guarantees"),
        ],
        .comparativeClaims: [
            .literal("better than", "Avoid unsubstantiated comparisons"),
            .literal("outperforms", "Avoid predicting outperformance"),
            .literal("unlike our competitors", "Avoid competitor comparisons"),
            .literal("superior to", "Avoid unsubstantiated superiority claims"),
            .literal("best in the industry", "Avoid unsubstantiated superlatives"),
            .literal("number one", "Avoid unsubstantiated ranking claims"),
            .literal("#1", "Avoid unsubstantiated ranking claims"),
        ],
        .suitability: [
            .literal("you should", "Use 'you may want to consider'"),
            .literal("you need to", "Use 'it may be beneficial to'"),
            .literal("best for you", "Avoid presuming suitability without analysis"),
            .literal("perfect for", "Avoid implying universal suitability"),
            .literal("ideal solution", "Avoid implying universal suitability"),
            .literal("right choice for you", "Avoid presuming suitability"),
            .literal("you must", "Use 'you may want to consider'"),
        ],
        .specificAdvice: [
            .literal("invest in", "Consider 'explore' or 'learn more about'"),
            .literal("buy this", "Avoid direct purchase instructions"),
            .literal("switch to", "Use 'consider reviewing' instead"),
            .literal("move your money", "Avoid directing fund transfers"),
            .literal("put your money in", "Avoid directing fund placement"),
            .literal("i recommend you", "Use 'you may want to consider'"),
        ],
    ]

    /// Check if a new range overlaps with any existing matched range.
    private static func overlaps(_ range: Range<String.Index>, with existing: [Range<String.Index>]) -> Bool {
        existing.contains { $0.overlaps(range) }
    }
}
