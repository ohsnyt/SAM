import Foundation
import FoundationModels

// MARK: - Per-chunk extraction DTO
//
// Each chunk produces a structured snapshot of its raw material — not a
// summary. The synthesis pass reads across all extracts to build the final
// output. Keeping each field tight and specific minimizes hallucination
// inside a 3,500-char chunk.

@Generable
struct ChunkExtraction: Sendable, Codable {
    @Guide(description: "ONE SENTENCE stating the central point the speaker argues in this slice — the claim, not the topic. Use the speaker's vocabulary. Concrete, not abstract.")
    var thesis: String

    @Guide(description: "Proper-noun entities named in the slice: PEOPLE (named individuals), PLACES (cities, geographical locations — include place names from retold stories like 'Emmaus', 'Jericho'), companies, book titles, scripture references, cited authors. Exact spelling from the slice. Up to 8. Empty if none.")
    var entities: [String]

    @Guide(description: "Verbatim phrases from the slice that signal outline structure (another point, the second pillar, a new section). Up to 4. Empty if none.")
    var structureMarkers: [String]

    @Guide(description: "Short labels for stories, illustrations, extended anecdotes, OR retold scripture narratives IN THIS SLICE. If the speaker is retelling a biblical story, label it by location + characters (e.g., 'Road to Emmaus - two disciples'). For secular illustrations, name concretely (e.g., 'facility manager 12,000 steps'). Up to 3. Empty if none.")
    var anecdotes: [String]

    @Guide(description: "Concrete numbers, dates, amounts, percentages, years, DISTANCES, durations, statistics mentioned IN THIS SLICE. Exact value plus short phrase of what it refers to (e.g., 'seven-mile journey to Emmaus', '12,000 steps in a day'). Up to 6. Empty if none.")
    var dataPoints: [String]

    @Guide(description: "Specific claims or assertions the speaker makes in this slice, in the speaker's terms. Up to 4. Empty if none.")
    var claims: [String]

    @Guide(description: "Questions the speaker actually asked aloud in the slice — the slice contains the question ending in '?'. Up to 3. Empty if none.")
    var questionsRaised: [String]

    @Guide(description: "Scripture passages, books, or research sources the speaker cites BY NAME in this slice. Do NOT include liturgical greetings or responses (e.g. 'Christ is risen') — those are not citations. Up to 3. Empty if none.")
    var citations: [String]
}
