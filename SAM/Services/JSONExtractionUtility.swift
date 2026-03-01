//
//  JSONExtractionUtility.swift
//  SAM
//
//  Utility for extracting JSON from LLM responses. Kept in its own file
//  to avoid actor isolation inference from actor types in other files.
//  Defined as a static method on a plain enum to prevent @MainActor inference
//  that Swift 6 applies to global free functions.
//

import Foundation

enum JSONExtraction {
    /// Extract a JSON object from an LLM response that may contain prose, markdown, or other wrapping.
    /// Handles: raw JSON, markdown code blocks, JSON embedded in explanatory text.
    nonisolated static func extractJSON(from rawResponse: String) -> String {
        var text = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        // Sanitize common Unicode characters that break JSON parsing
        text = text
            .replacingOccurrences(of: "\u{2013}", with: "-")  // en-dash
            .replacingOccurrences(of: "\u{2014}", with: "-")  // em-dash
            .replacingOccurrences(of: "\u{2018}", with: "'")  // left single curly quote
            .replacingOccurrences(of: "\u{2019}", with: "'")  // right single curly quote
            .replacingOccurrences(of: "\u{201C}", with: "\"") // left double curly quote
            .replacingOccurrences(of: "\u{201D}", with: "\"") // right double curly quote
            .replacingOccurrences(of: "\u{2026}", with: "...") // ellipsis

        // Strip markdown code blocks
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if text.hasSuffix("```") {
                text = String(text.dropLast(3))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If it already starts with { or [, return as-is
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return text
        }

        // Find the first { and last } to extract a JSON object
        if let openBrace = text.firstIndex(of: "{"),
           let closeBrace = text.lastIndex(of: "}") {
            return String(text[openBrace...closeBrace])
        }

        // Find the first [ and last ] for a JSON array
        if let openBracket = text.firstIndex(of: "["),
           let closeBracket = text.lastIndex(of: "]") {
            return String(text[openBracket...closeBracket])
        }

        // Nothing found — return original for error reporting
        return text
    }
}
