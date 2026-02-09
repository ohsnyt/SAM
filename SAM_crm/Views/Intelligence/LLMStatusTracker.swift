//
//  LLMStatusTracker.swift
//  SAM_crm
//
//  Created by David Snyder on 2/7/26.
//
//  Tracks LLM analysis activity for display in the UI status bar.
//

import Foundation

/// Observable state tracker for LLM analysis operations.
/// Use this to show "AI is thinking..." status in the UI.
@MainActor
@Observable
public final class LLMStatusTracker {
    public static let shared = LLMStatusTracker()
    
    /// Whether an LLM analysis is currently in progress
    public private(set) var isAnalyzing: Bool = false
    
    /// Human-readable status message (e.g., "Analyzing note...", "Idle")
    public private(set) var statusMessage: String = "Idle"
    
    /// Number of active analysis tasks (supports concurrent operations)
    private var activeTaskCount: Int = 0
    
    private init() {}
    
    /// Call this when starting an LLM analysis operation
    public func beginAnalysis(message: String = "Analyzing...") {
        activeTaskCount += 1
        isAnalyzing = true
        statusMessage = message
        
        print("🔄 [LLMStatusTracker] Analysis started: \(message) (active tasks: \(activeTaskCount))")
    }
    
    /// Call this when an LLM analysis operation completes (success or error)
    public func endAnalysis() {
        activeTaskCount = max(0, activeTaskCount - 1)
        
        if activeTaskCount == 0 {
            isAnalyzing = false
            statusMessage = "Idle"
            print("✅ [LLMStatusTracker] All analysis tasks complete")
        } else {
            print("🔄 [LLMStatusTracker] Analysis task ended (remaining: \(activeTaskCount))")
        }
    }
    
    /// Convenience method to wrap an async operation with status tracking
    public func track<T>(
        message: String = "Analyzing...",
        operation: @escaping () async throws -> T
    ) async throws -> T {
        beginAnalysis(message: message)
        defer { endAnalysis() }
        return try await operation()
    }
}
