//
//  InteractionKindClassifier.swift
//  SAM
//
//  Phase 7c of the relationship-model refactor (May 2026).
//
//  Cheap, rule-based classifier that tags a note's content as `give`,
//  `neutral`, or `ask` based on the user's posture toward the linked person.
//  Runs synchronously inside note analysis — no LLM call, no async work.
//
//  The plan's mitigation note is explicit: "simple rule-based first" — the
//  goal is to seed the give/ask ratio with reasonable signal. If accuracy
//  ever becomes a problem in real use, swap this for a classifier head on
//  the same on-device LLM call that's already running.
//
//  Heuristic order:
//    1. Strong ask cues (the user is requesting something) win first —
//       false positives on "give" would be worse for the user (they'd think
//       their ratio is healthier than it is).
//    2. Strong give cues (the user is offering / providing).
//    3. Neutral fallback for catch-ups, summaries, status updates.
//

import Foundation

enum InteractionKindClassifier {

    /// Classify the user's posture in a note. Cheap, deterministic, no I/O.
    static func classify(_ content: String) -> InteractionKind {
        let lowered = content.lowercased()
        guard !lowered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .neutral
        }

        if containsAny(lowered, askCues) {
            return .ask
        }
        if containsAny(lowered, giveCues) {
            return .give
        }
        return .neutral
    }

    // MARK: - Cues
    //
    // Phrasing patterns from the user's first-person perspective in their
    // own meeting/interaction notes. Tuned conservatively — only fire on
    // unambiguous markers to avoid mis-categorizing routine catch-ups.

    private static let askCues: [String] = [
        // direct request verbs
        "i asked ", "i'll ask ", "ill ask ",
        "asked them ", "asked him ", "asked her ",
        "asked for ", "i'm asking ", "im asking ",
        "i requested ", "requested that ",
        // need / want framing
        "i need ", "i needed ", "i'll need ",
        "i want ", "i wanted to ask ",
        "could you ", "would you mind ",
        "can you ",
        // referral / introduction requests
        "intro me ", "introduce me ", "intro to ", "introduction to ",
        "referral to ", "refer me ",
        // favor framing
        "favor ", "a favor",
        // follow-up framing where user is the one being chased
        "they're going to send ", "they'll send me ", "she'll send me ", "he'll send me ",
    ]

    private static let giveCues: [String] = [
        // user offering value
        "i sent ", "i'll send ", "ill send ", "sent them ", "sent her ", "sent him ",
        "i shared ", "shared with ", "i'll share ", "ill share ",
        "i introduced ", "introduced them ", "introduced him ", "introduced her ",
        "i offered ", "offered to ",
        "i gave ", "i'll give ",
        "i helped ", "i'll help ", "helped them ", "helped her ", "helped him ",
        // check-in / care framing
        "checked in on ", "checking in on ", "checked in with ",
        "thinking of you", "thinking of them",
        "wanted to make sure ", "just wanted to ",
        // value delivery
        "i recommended ", "recommended that ",
        "i passed along ", "passed along ", "passed to ",
        "i connected ", "i'll connect ", "connected them ", "connected her ", "connected him ",
        "i followed up ", "i'll follow up ", "followed up with ",
    ]

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        for needle in needles where haystack.contains(needle) {
            return true
        }
        return false
    }
}
