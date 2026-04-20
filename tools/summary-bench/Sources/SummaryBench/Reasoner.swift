import Foundation
import FoundationModels

// MARK: - Reasoner pass DTO
//
// After per-chunk extraction, the reasoner sees a compact view of every
// chunk's thesis + recurring markers + top entities + citations. It
// produces the organizing scaffold — the frame and ordered points the
// speaker is actually using. This output seeds the synthesis passes.

@Generable
struct ReasonedScaffold: Sendable, Codable {
    @Guide(description: "The overarching story, framework, metaphor, or illustration the speaker used to organize the whole lecture. If the lecture references a specific story, text passage, or named framework throughout, name it. Examples of frames: a scripture story told across the whole talk, a named model like 'Six Pillars', a recurring case study. If the lecture has no single organizing frame, use an empty string.")
    var narrativeFrame: String

    @Guide(description: "The single central message or thesis of the ENTIRE lecture — one sentence. What does the speaker want the audience to walk away believing or doing? Ground this in the per-chunk theses you were shown.")
    var centralThesis: String

    @Guide(description: "If the speaker has an explicit multi-point outline (e.g. three points, six pillars, four principles), list each point as one short phrase IN THE ORDER the speaker presented them. MAXIMUM 8 entries. One entry per DISTINCT position in the outline — if multiple cues refer to the same point (e.g. pillar two), emit it once using the fullest/clearest naming. Points are short labels (1-6 words), not sentences. If there is no explicit numbered/named outline, return an empty array.")
    var orderedPoints: [String]

    @Guide(description: "The primary illustration or story the speaker used most prominently — often the opening hook or the story they return to. Ground this in the chunk extracts' anecdotes AND structure markers. If none stands out, use an empty string.")
    var primaryIllustration: String
}
