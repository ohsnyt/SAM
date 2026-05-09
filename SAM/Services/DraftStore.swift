//
//  DraftStore.swift
//  SAM
//
//  In-memory persistence for in-progress edit-form text. Lets sheets
//  recover their unsaved fields when re-presented after the app lock,
//  app deactivation, or any other transient teardown that didn't
//  represent the user committing or cancelling.
//
//  Drafts live for the app's lifetime only. They are NOT persisted to
//  disk in v1 — drafts may contain sensitive text (compose drafts,
//  notes, coaching corrections) and disk persistence requires
//  encryption work we haven't taken on yet.
//

import Foundation

@MainActor
@Observable
final class DraftStore {
    static let shared = DraftStore()

    private var drafts: [String: [String: [String: String]]] = [:]

    private init() {}

    func save(kind: String, id: String, fields: [String: String]) {
        if drafts[kind] == nil { drafts[kind] = [:] }
        drafts[kind]?[id] = fields
    }

    func load(kind: String, id: String) -> [String: String]? {
        drafts[kind]?[id]
    }

    func clear(kind: String, id: String) {
        drafts[kind]?[id] = nil
        if drafts[kind]?.isEmpty == true {
            drafts[kind] = nil
        }
    }

    func clearAll() {
        drafts.removeAll()
    }
}
