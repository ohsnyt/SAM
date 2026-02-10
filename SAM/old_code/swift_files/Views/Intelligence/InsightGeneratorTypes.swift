import Foundation

/// Dictionary key for grouping evidence into insights.
/// Kept outside InsightGenerator actor/file to avoid MainActor isolation inference in Swift 6.
struct InsightGroupKey: Sendable, Hashable {
    let personID: UUID?
    let contextID: UUID?
    let kindRaw: String

    init(personID: UUID?, contextID: UUID?, kind: InsightKind) {
        self.personID = personID
        self.contextID = contextID
        self.kindRaw = kind.rawValue
    }
}

/// Dictionary key for deduplicating existing insights.
/// Kept outside InsightGenerator actor/file to avoid MainActor isolation inference in Swift 6.
struct InsightDedupeKey: Sendable, Hashable {
    let personID: UUID?
    let contextID: UUID?
    let kindRaw: String

    init(personID: UUID?, contextID: UUID?, kind: InsightKind) {
        self.personID = personID
        self.contextID = contextID
        self.kindRaw = kind.rawValue
    }
}
