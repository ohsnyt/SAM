import Foundation
import FoundationModels

// MARK: - Two-pass synthesis DTOs
//
// The synthesis step is split so each call has a tractable output budget.
// Pass A produces the narrative core (title, opening, reviewNotes) grounded
// in the scaffold + extracts. Pass B produces the supporting lists,
// grounded in Pass A's reviewNotes plus the extracts.

@Generable
struct LectureCore: Sendable, Codable {
    @Guide(description: "2-5 word title for the whole lecture. Name the specific topic. Title case, no trailing punctuation.")
    var title: String

    @Guide(description: "2-3 sentences that name the speaker's organizing scaffold (central story, text, framework, or illustration) AND the core message it was used to make. Reference the primary anecdote and any citations from the scaffold by their actual names. Do not abstract the scaffold away.")
    var opening: String

    @Guide(description: "Study notes, 2-3 short paragraphs. Follow the speaker's argument arc in the order the chunk theses appear. Name the specific illustrations and data points the speaker used. Keep specifics; do not collapse to abstract themes.")
    var reviewNotes: String
}

@Generable
struct LectureDetails: Sendable, Codable {
    @Guide(description: "5-7 short topic tags (1-4 words each). Specific subjects from this lecture. No duplicates.")
    var topics: [String]

    @Guide(description: "4-6 single-sentence learning objectives grounded in the speaker's content.")
    var learningObjectives: [String]

    @Guide(description: "6-8 single-sentence takeaways. Each captures a concrete insight the speaker made, naming the specific illustration, number, or entity used.")
    var keyPoints: [String]

    @Guide(description: "Questions the speaker actually raised in the talk. Only include questions that appear in the extracts' questionsRaised list. If none, return an empty array.")
    var openQuestions: [String]
}

// MARK: - Final combined value

struct LectureSummary: Sendable, Codable {
    var title: String
    var opening: String
    var reviewNotes: String
    var topics: [String]
    var learningObjectives: [String]
    var keyPoints: [String]
    var openQuestions: [String]

    init(core: LectureCore, details: LectureDetails) {
        self.title = core.title
        self.opening = core.opening
        self.reviewNotes = core.reviewNotes
        self.topics = details.topics
        self.learningObjectives = details.learningObjectives
        self.keyPoints = details.keyPoints
        self.openQuestions = details.openQuestions
    }
}
