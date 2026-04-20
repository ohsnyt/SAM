import Foundation

/// A must-contain ground-truth anchor for a known test transcript.
struct Anchor: Codable {
    let label: String
    /// Any of these case-insensitive substrings satisfy the anchor.
    let mustMatchAny: [String]
    /// Optional fields to restrict search to — nil means "any field".
    /// Valid values: "opening", "reviewNotes", "topics", "keyPoints",
    /// "learningObjectives", "openQuestions", "title".
    let fields: [String]?
}

/// Ground-truth anchors per transcript, keyed by filename stem.
enum AnchorLibrary {
    static func anchors(for stem: String) -> [Anchor] {
        switch stem {
        case "AspectsofExhaustion":
            return aspectsOfExhaustion
        case "Military_Transition":
            return militaryTransition
        default:
            return []
        }
    }

    /// Anti-anchors: strings that MUST NOT appear. Transcription corruption.
    static func antiAnchors(for stem: String) -> [Anchor] {
        switch stem {
        case "Military_Transition":
            return [
                Anchor(label: "Wrong pillar name 'combat' (should be 'compensation')",
                       mustMatchAny: ["combat"], fields: nil),
                Anchor(label: "Wrong company name 'WFT' (should be 'WFG')",
                       mustMatchAny: ["WFT"], fields: nil),
                Anchor(label: "Wrong carrier name 'A-Gon' (should be 'Aegon')",
                       mustMatchAny: ["A-Gon", "A Gon"], fields: nil),
            ]
        default:
            return []
        }
    }

    // MARK: AspectsofExhaustion (Easter sermon, Luke 24 Road to Emmaus)

    private static let aspectsOfExhaustion: [Anchor] = [
        Anchor(label: "Emmaus named (central narrative frame)",
               mustMatchAny: ["Emmaus"], fields: nil),
        Anchor(label: "Two disciples on the road",
               mustMatchAny: ["two disciples", "disciples", "Cleopas"], fields: nil),
        Anchor(label: "Seven mile / distance cited",
               mustMatchAny: ["seven mile", "7 mile", "seven-mile", "7-mile"], fields: nil),
        Anchor(label: "Luke 24 Road-to-Emmaus narrative cues",
               mustMatchAny: ["Luke 24", "Luke twenty-four", "broke the bread", "Moses and the prophets", "road to Emmaus"], fields: nil),
        Anchor(label: "Three-point structure — Jesus listens",
               mustMatchAny: ["listen"], fields: ["reviewNotes", "keyPoints"]),
        Anchor(label: "Three-point structure — Jesus brings good news / truth",
               mustMatchAny: ["good news", "truth", "gospel"], fields: ["reviewNotes", "keyPoints"]),
        Anchor(label: "Three-point structure — Jesus transforms / transformation",
               mustMatchAny: ["transform"], fields: ["reviewNotes", "keyPoints"]),
        Anchor(label: "Resurrection / Easter context",
               mustMatchAny: ["resurrection", "risen", "Easter"], fields: nil),
    ]

    // MARK: Military_Transition (WFG training session)

    private static let militaryTransition: [Anchor] = [
        Anchor(label: "Six Pillars framework named",
               mustMatchAny: ["six pillars", "6 pillars"], fields: nil),
        Anchor(label: "Pillar: Ownership",
               mustMatchAny: ["ownership"], fields: ["reviewNotes", "keyPoints", "topics"]),
        Anchor(label: "Pillar: Compensation (NOT 'combat')",
               mustMatchAny: ["compensation"], fields: ["reviewNotes", "keyPoints", "topics"]),
        Anchor(label: "Pillar: Stability",
               mustMatchAny: ["stability"], fields: ["reviewNotes", "keyPoints", "topics"]),
        Anchor(label: "Pillar: Client Solutions",
               mustMatchAny: ["client solutions"], fields: ["reviewNotes", "keyPoints", "topics"]),
        Anchor(label: "Pillar: System",
               mustMatchAny: ["system"], fields: ["reviewNotes", "keyPoints", "topics"]),
        Anchor(label: "Pillar: Technology",
               mustMatchAny: ["technology"], fields: ["reviewNotes", "keyPoints", "topics"]),
        Anchor(label: "Company name WFG (not WFT)",
               mustMatchAny: ["WFG", "World Financial Group"], fields: nil),
        Anchor(label: "Aegon named correctly (not A-Gon)",
               mustMatchAny: ["Aegon"], fields: nil),
        Anchor(label: "Mother's 2008 real estate story",
               mustMatchAny: ["mother", "mom"], fields: ["reviewNotes", "keyPoints"]),
        Anchor(label: "Rob Day anecdote (doubled during 2008)",
               mustMatchAny: ["Rob Day"], fields: nil),
        Anchor(label: "Target premium concept (125% vs 101%)",
               mustMatchAny: ["target premium"], fields: nil),
    ]
}
