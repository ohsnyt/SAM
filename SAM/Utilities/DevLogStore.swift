//
//  DevLogStore.swift
//  SAM_crm
//
//  Thread-safe log storage for developer logs.
//  Separated from UI code to avoid @MainActor inference.
//

import Foundation
import Combine

/// Thread-safe log storage for developer logs.
/// Uses actor isolation for proper Swift 6 concurrency safety.
actor DevLogStore {
    static let shared = DevLogStore()
    
    private var lines: [String] = []
    
    private init() {}
    
    func append(_ line: String) {
        lines.append(line)
    }
    
    func snapshot() -> String {
        lines.joined(separator: "\n")
    }
    
    func clear() {
        lines.removeAll()
    }
}
/// Developer logger - marked Sendable and nonisolated explicitly.
enum DevLogger: Sendable {
    nonisolated static func info(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[INFO] \(timestamp): \(message)"
        NSLog("[SAM] \(formatted)")
        Task {
            await DevLogStore.shared.append(formatted)
        }
    }
    
    nonisolated static func warning(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[WARNING] \(timestamp): \(message)"
        NSLog("[SAM] \(formatted)")
        Task {
            await DevLogStore.shared.append(formatted)
        }
    }
    
    nonisolated static func error(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[ERROR] \(timestamp): \(message)"
        NSLog("[SAM] \(formatted)")
        Task {
            await DevLogStore.shared.append(formatted)
        }
    }
    
    nonisolated static func log(_ message: String) {
        info(message)
    }
}

