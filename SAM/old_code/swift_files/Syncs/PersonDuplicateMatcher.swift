//
//  PersonDuplicateMatcher.swift
//  SAM_crm
//
//  Shared duplicate-detection logic, extracted so that both
//  NewPersonSheet (creation-time warning) and LinkContactSheet
//  (link-time duplicate check) use the exact same algorithm.
//
//  Algorithm summary
//  ─────────────────
//    1. Canonicalise both names: lowercase, strip punctuation,
//       collapse whitespace, drop single-letter middle initials.
//    2. Map the first token through a nickname table
//       (Bob→Robert, etc.).
//    3. Compute Jaccard similarity over the resulting token sets.
//    4. Boost by +0.25 when last tokens (surnames) match exactly.
//    5. Force score to 1.0 when both first and last tokens match
//       after nickname normalisation (catches "Bob Smith" vs
//       "Robert Smith").
//

import Foundation

/// A single duplicate-detection hit.
struct DuplicateMatch {
    let candidate: PersonDuplicateCandidate
    let score:     Double   // 0…1
}

enum PersonDuplicateMatcher {

    /// Returns scored matches above `threshold` (default 0.60),
    /// sorted descending by score.  Caller can slice `.prefix(N)`
    /// for display.
    static func findMatches(
        for name:       String,
        among existing: [PersonDuplicateCandidate],
        threshold:      Double = 0.60
    ) -> [DuplicateMatch] {
        let candidateTokens = normalizedTokens(name)
        guard !candidateTokens.isEmpty else { return [] }

        return existing
            .map { c in
                DuplicateMatch(
                    candidate: c,
                    score:     score(candidateTokens, normalizedTokens(c.displayName))
                )
            }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
    }

    // ── Core scoring ──────────────────────────────────────────────

    private static func score(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        let sa = Set(a)
        let sb = Set(b)
        let inter = sa.intersection(sb).count
        let uni   = sa.union(sb).count
        var s = Double(inter) / Double(uni)

        // Surname-match boost
        if let la = a.last, let lb = b.last, la == lb {
            s = min(1.0, s + 0.25)
        }

        // First + last match after nickname normalisation → exact
        if a.count >= 2, b.count >= 2,
           a.first == b.first, a.last == b.last {
            s = 1.0
        }

        return s
    }

    // ── Tokenisation ──────────────────────────────────────────────

    private static func normalizedTokens(_ s: String) -> [String] {
        let c = canonicalName(s)
        guard !c.isEmpty else { return [] }

        var parts = c.split(separator: " ").map(String.init)

        // Drop single-letter middle initials when there are ≥ 3 tokens
        if parts.count >= 3 {
            parts.removeAll { $0.count == 1 }
        }

        // Nickname normalisation on the first token only
        if let first = parts.first {
            parts[0] = canonicalFirstName(first)
        }

        return parts
    }

    private static func canonicalName(_ s: String) -> String {
        var t = s
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: "+", with: " and ")

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        t = String(t.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") })

        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }

    // ── Nickname table ────────────────────────────────────────────

    private static let nicknameMap: [String: String] = [
        "bob": "robert", "bobby": "robert", "rob": "robert", "robbie": "robert",
        "beth": "elizabeth", "liz": "elizabeth", "lizzy": "elizabeth", "eliza": "elizabeth",
        "bill": "william", "billy": "william", "will": "william", "willy": "william",
        "jim": "james", "jimmy": "james",
        "mike": "michael", "mikey": "michael",
        "kate": "katherine", "katie": "katherine",
        "cathy": "catherine", "catie": "catherine",
        "rick": "richard", "ricky": "richard", "dick": "richard",
        "dave": "david",
        "steve": "steven", "stephen": "steven",
        "tony": "anthony",
        "andy": "andrew",
        "ben": "benjamin",
        "jen": "jennifer", "jenny": "jennifer",
        "chris": "christopher",
        "alex": "alexander",
        "sue": "susan", "susie": "susan"
    ]

    private static func canonicalFirstName(_ first: String) -> String {
        nicknameMap[first] ?? first
    }
}
