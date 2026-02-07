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

    func append(_ line: String) {
        queue.async { [weak self] in
            self?.lines.append(line)
        }
    }

    func snapshot() -> String {
        var snapshot: String = ""
        queue.sync {
            snapshot = lines.joined(separator: "\n")
        }
        return snapshot
    }

    func clear() {
        queue.async { [weak self] in
            self?.lines.removeAll()
        }
    }
}
/// Developer logger - marked Sendable and nonisolated explicitly.
enum DevLogger: Sendable {
    nonisolated static func info(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[INFO] \(timestamp): \(message)"
        NSLog("[SAM] \(formatted)")
        Task { @MainActor in
            DevLogStore.shared.append(formatted)
        }
    }
    
    nonisolated static func warning(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[WARNING] \(timestamp): \(message)"
        NSLog("[SAM] \(formatted)")
        Task { @MainActor in
            DevLogStore.shared.append(formatted)
        }
    }
    
    nonisolated static func error(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[ERROR] \(timestamp): \(message)"
        NSLog("[SAM] \(formatted)")
        Task { @MainActor in
            DevLogStore.shared.append(formatted)
        }
    }
    
    nonisolated static func log(_ message: String) {
        info(message)
    }
}

