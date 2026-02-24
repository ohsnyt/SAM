//
//  AIService.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  Unified AI interface abstracting FoundationModels and MLX backends.
//  Default backend is Apple FoundationModels (always available on eligible devices).
//  MLX backend is optional — user-configured via Settings.
//

import Foundation
import FoundationModels
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import os.log

/// Unified AI interface abstracting FoundationModels and MLX backends.
actor AIService {

    // MARK: - Singleton

    static let shared = AIService()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "AIService")

    private init() {}

    // MARK: - Types

    enum Backend: String, Sendable {
        case foundationModels   // Apple on-device (default, always available)
        case mlx                // MLX local model (optional, user-configured)
        case hybrid             // Structured→FM, narrative→MLX (with FM fallback)
    }

    enum ModelAvailability: Sendable {
        case available
        case downloading(progress: Double)
        case unavailable(reason: String)
    }

    enum AIError: Error, LocalizedError {
        case modelUnavailable(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let reason): return "AI model unavailable: \(reason)"
            case .generationFailed(let reason): return "AI generation failed: \(reason)"
            }
        }
    }

    // MARK: - Backend Selection

    private let foundationModel = SystemLanguageModel.default

    /// Returns the user's preferred backend (from UserDefaults).
    func activeBackend() -> Backend {
        let raw = UserDefaults.standard.string(forKey: "aiBackend") ?? Backend.foundationModels.rawValue
        return Backend(rawValue: raw) ?? .foundationModels
    }

    /// Check availability of the active backend.
    func checkAvailability() async -> ModelAvailability {
        let backend = activeBackend()

        switch backend {
        case .foundationModels:
            return foundationModelsAvailability()

        case .mlx:
            let mlxReady = await MLXModelManager.shared.isSelectedModelReady()
            if mlxReady {
                return .available
            }
            // MLX not ready — generate() falls back to FoundationModels,
            // so report available if FoundationModels works
            let fallback = foundationModelsAvailability()
            if case .available = fallback {
                return .available
            }
            // Neither backend ready — report downloading if in progress
            if let progress = await MLXModelManager.shared.downloadProgress {
                return .downloading(progress: progress)
            }
            return fallback

        case .hybrid:
            let fmAvail = foundationModelsAvailability()
            if case .available = fmAvail { return .available }
            return fmAvail
        }
    }

    // MARK: - Generation

    /// Generate a text response from a prompt.
    /// - Parameters:
    ///   - prompt: The user/system prompt to send.
    ///   - systemInstruction: Optional system-level instruction context.
    ///   - maxTokens: Optional limit on response length (MLX only; ignored for FoundationModels).
    /// - Returns: The generated text response.
    func generate(
        prompt: String,
        systemInstruction: String? = nil,
        maxTokens: Int? = nil
    ) async throws -> String {
        let backend = activeBackend()

        switch backend {
        case .foundationModels:
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: systemInstruction)

        case .mlx:
            // Try MLX first, fall back to FoundationModels
            let mlxReady = await MLXModelManager.shared.isSelectedModelReady()
            if mlxReady {
                return try await generateWithMLX(prompt: prompt, systemInstruction: systemInstruction, maxTokens: maxTokens)
            }
            logger.info("MLX model not ready — falling back to FoundationModels")
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: systemInstruction)

        case .hybrid:
            // Structured extraction always uses FoundationModels
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: systemInstruction)
        }
    }

    /// Generate a narrative (prose) response — summaries, dictation polish, coaching suggestions.
    /// In hybrid mode routes to MLX for deeper reasoning; falls back to FoundationModels if MLX unavailable.
    func generateNarrative(
        prompt: String,
        systemInstruction: String? = nil,
        maxTokens: Int? = nil
    ) async throws -> String {
        let backend = activeBackend()

        switch backend {
        case .foundationModels:
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: systemInstruction)

        case .mlx, .hybrid:
            // Prefer MLX for narrative tasks; fall back to FM
            let mlxReady = await MLXModelManager.shared.isSelectedModelReady()
            if mlxReady {
                return try await generateWithMLX(prompt: prompt, systemInstruction: systemInstruction, maxTokens: maxTokens)
            }
            logger.info("MLX model not ready — narrative falling back to FoundationModels")
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: systemInstruction)
        }
    }

    // MARK: - FoundationModels Backend

    private func foundationModelsAvailability() -> ModelAvailability {
        switch foundationModel.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "Device not eligible for Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Apple Intelligence not enabled")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "Model is downloading or not ready")
        case .unavailable(let other):
            return .unavailable(reason: "Model unavailable: \(other)")
        }
    }

    private func generateWithFoundationModels(prompt: String, systemInstruction: String?) async throws -> String {
        guard case .available = foundationModelsAvailability() else {
            throw AIError.modelUnavailable("FoundationModels not available")
        }

        let session: LanguageModelSession
        if let instruction = systemInstruction {
            session = LanguageModelSession(instructions: instruction)
        } else {
            session = LanguageModelSession()
        }

        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - MLX Backend

    /// Cached MLX model container for inference.
    private var mlxModelContainer: ModelContainer?
    private var loadedModelID: String?

    /// Hub API for loading models from local cache — same base as MLXModelManager.
    private lazy var hubApi: HubApi = {
        HubApi(downloadBase: MLXModelManager.hubDownloadBase)
    }()

    /// Ensure the selected MLX model is loaded into memory.
    private func ensureMLXModelLoaded() async throws {
        guard let selectedID = await MLXModelManager.shared.selectedModelID else {
            throw AIError.modelUnavailable("No MLX model selected")
        }

        // Already loaded
        if loadedModelID == selectedID, mlxModelContainer != nil {
            return
        }

        logger.info("Loading MLX model: \(selectedID)")
        MLX.Memory.cacheLimit = 20 * 1024 * 1024

        let configuration = await MLXModelManager.shared.modelConfiguration(for: selectedID)
        let container = try await LLMModelFactory.shared.loadContainer(
            hub: hubApi,
            configuration: configuration
        ) { _ in }

        mlxModelContainer = container
        loadedModelID = selectedID
        logger.info("MLX model loaded: \(selectedID)")
    }

    /// Generate text using the MLX backend.
    private func generateWithMLX(prompt: String, systemInstruction: String?, maxTokens: Int?) async throws -> String {
        try await ensureMLXModelLoaded()

        guard let container = mlxModelContainer else {
            throw AIError.modelUnavailable("MLX model container not loaded")
        }

        var chat: [Chat.Message] = []
        if let system = systemInstruction {
            chat.append(.system(system))
        }
        chat.append(.user(prompt))

        let userInput = UserInput(chat: chat)
        let lmInput = try await container.prepare(input: userInput)

        var parameters = GenerateParameters()
        parameters.temperature = 0.6
        parameters.maxTokens = maxTokens ?? 4096

        let stream = try await container.generate(input: lmInput, parameters: parameters)
        var output = ""

        for await generation in stream {
            if let chunk = generation.chunk {
                output += chunk
            }
        }

        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            throw AIError.generationFailed("MLX model returned empty response")
        }

        return result
    }

    /// Unload the cached MLX model to free memory. Call when switching back to FoundationModels.
    func unloadMLXModel() {
        mlxModelContainer = nil
        loadedModelID = nil
        logger.info("MLX model unloaded")
    }
}

// MARK: - JSON Extraction Utility

/// Extract a JSON object from an LLM response that may contain prose, markdown, or other wrapping.
/// Handles: raw JSON, markdown code blocks, JSON embedded in explanatory text.
func extractJSON(from rawResponse: String) -> String {
    var text = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)

    // Strip markdown code blocks
    if text.hasPrefix("```") {
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // If it already starts with { or [, return as-is
    if text.hasPrefix("{") || text.hasPrefix("[") {
        return text
    }

    // Find the first { and last } to extract a JSON object
    if let openBrace = text.firstIndex(of: "{"),
       let closeBrace = text.lastIndex(of: "}") {
        return String(text[openBrace...closeBrace])
    }

    // Find the first [ and last ] for a JSON array
    if let openBracket = text.firstIndex(of: "["),
       let closeBracket = text.lastIndex(of: "]") {
        return String(text[openBracket...closeBracket])
    }

    // Nothing found — return original for error reporting
    return text
}
