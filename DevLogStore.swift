//
//  DevLogStore.swift
//  SAM_crm
//
//  Thread-safe log storage for developer logs.
//  Separated from UI code to avoid @MainActor inference.
//

import Foundation

/// Thread-safe log storage for developer logs.
/// Explicitly nonisolated to allow access from any context.
final class DevLogStore: @unchecked Sendable {
    static let shared = DevLogStore()
    private let queue = DispatchQueue(label: "com.sam-crm.devlogs", qos: .utility)
    private var lines: [String] = []

    private init() {}

    nonisolated func append(_ line: String) {
        queue.async { [weak self] in
            self?.lines.append(line)
        }
    }

    nonisolated func snapshot() -> String {
        var snapshot: String = ""
        queue.sync {
            snapshot = lines.joined(separator: "\n")
        }
        return snapshot
    }

    nonisolated func clear() {
        queue.async { [weak self] in
            self?.lines.removeAll()
        }
    }
}
