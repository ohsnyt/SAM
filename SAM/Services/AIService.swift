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

    // MARK: - MLX Circuit Breaker

    /// Set to true after any MLX inference failure to prevent retry crashes this session.
    /// MLX fatal errors from the C++ layer cannot be caught; this flag prevents reaching them.
    private var mlxCircuitOpen = false

    // MARK: - Active Generation Counter

    /// Number of generate() / generateNarrative() calls currently in flight
    /// at the Swift level (outer counter).
    private(set) var activeGenerationCount: Int = 0

    /// Number of MLX for-await stream iterations currently in progress.
    /// This is the inner counter that tracks the actual C++ mutex lifetime.
    /// The outer counter can reach zero while a stream is still exhausting —
    /// this one doesn't until the last token is consumed.
    private(set) var activeMLXStreamCount: Int = 0

    /// True when no generation work of any kind is in flight.
    var isFullyIdle: Bool { activeGenerationCount == 0 && activeMLXStreamCount == 0 }

    /// Suspends until both counters reach zero, polling every 100ms.
    func waitUntilIdle() async {
        while !isFullyIdle {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Emoji / Icon Guidance

    /// Returns a prompt clause instructing the model to omit emoji/icons when the user has disabled them.
    /// Read from UserDefaults on the caller's behalf (nonisolated so callers outside the actor can use it).
    nonisolated static var emojiGuidance: String {
        let allowed = UserDefaults.standard.bool(forKey: "sam.messages.allowEmoji")
        return allowed ? "" : " Do not use emoji, emoticons, or Unicode icons/symbols (e.g. 🎉, 📅, ⭐, 👋, ✅) in your response."
    }

    // MARK: - Signature / Closing Guidance

    /// Returns the user's first name, full name, and default closing from settings.
    nonisolated static var userFirstName: String {
        UserDefaults.standard.string(forKey: "sam.user.firstName") ?? ""
    }

    nonisolated static var userFullName: String {
        let first = UserDefaults.standard.string(forKey: "sam.user.firstName") ?? ""
        let last = UserDefaults.standard.string(forKey: "sam.user.lastName") ?? ""
        return [first, last].filter { !$0.isEmpty }.joined(separator: " ")
    }

    nonisolated static var userDefaultClosing: String {
        UserDefaults.standard.string(forKey: "sam.user.defaultClosing").flatMap { $0.isEmpty ? nil : $0 } ?? "Best,"
    }

    /// Returns the sender name appropriate for the relationship warmth.
    /// Warm relationships (3+ recent interactions in 90 days) use first name only.
    nonisolated static func senderName(forWarmRelationship isWarm: Bool) -> String {
        isWarm ? userFirstName : userFullName
    }

    /// Returns the preferred closing for a given message kind and relationship warmth.
    /// Checks learned preferences first, then falls back to the user's default.
    nonisolated static func closing(forMessageKind kind: String? = nil, isWarm: Bool = true) -> String {
        // Check learned closings: key format "sam.closing.<kind>.<warm|formal>"
        let warmth = isWarm ? "warm" : "formal"
        if let kind, !kind.isEmpty {
            let key = "sam.closing.\(kind).\(warmth)"
            if let learned = UserDefaults.standard.string(forKey: key), !learned.isEmpty {
                return learned
            }
        }
        // Fallback to warmth-level default
        let warmthKey = "sam.closing.default.\(warmth)"
        if let learned = UserDefaults.standard.string(forKey: warmthKey), !learned.isEmpty {
            return learned
        }
        return userDefaultClosing
    }

    /// Record a closing preference learned from user edits.
    nonisolated static func learnClosing(_ closing: String, forMessageKind kind: String?, isWarm: Bool) {
        let warmth = isWarm ? "warm" : "formal"
        if let kind, !kind.isEmpty {
            UserDefaults.standard.set(closing, forKey: "sam.closing.\(kind).\(warmth)")
        }
        // Also update the warmth-level default
        UserDefaults.standard.set(closing, forKey: "sam.closing.default.\(warmth)")
    }

    // MARK: - Backend Selection

    private let foundationModel = SystemLanguageModel.default

    /// Returns the user's preferred backend (from UserDefaults).
    func activeBackend() -> Backend {
        let raw = UserDefaults.standard.string(forKey: "aiBackend") ?? Backend.foundationModels.rawValue
        return Backend(rawValue: raw) ?? .foundationModels
    }

    /// Approximate context budget in characters for the active backend.
    /// FoundationModels ≈ 4K tokens (~12K chars); MLX models vary (Qwen 3 8B = 32K tokens ≈ 96K chars).
    /// Returns a conservative usable budget (leaving room for response generation).
    func contextBudgetChars() -> Int {
        switch activeBackend() {
        case .foundationModels:
            return 10_000   // ~3.3K tokens, leaving room for ~700 token response
        case .mlx, .hybrid:
            return 60_000   // ~20K tokens input, leaving ~12K for response in a 32K window
        }
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
        activeGenerationCount += 1
        defer { activeGenerationCount -= 1 }

        let emojiClause = Self.emojiGuidance
        let effectiveSystem = systemInstruction.map { $0 + emojiClause } ?? (emojiClause.isEmpty ? nil : String(emojiClause.dropFirst()))

        let backend = activeBackend()

        switch backend {
        case .foundationModels:
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem)

        case .mlx:
            // Try MLX first, fall back to FoundationModels on failure or if circuit is open
            let mlxReady = await MLXModelManager.shared.isSelectedModelReady()
            if mlxReady && !mlxCircuitOpen {
                do {
                    return try await generateWithMLX(prompt: prompt, systemInstruction: effectiveSystem, maxTokens: maxTokens)
                } catch {
                    mlxCircuitOpen = true
                    logger.warning("MLX generation failed (\(error.localizedDescription)) — circuit open, falling back to FoundationModels for this session")
                }
            } else if !mlxReady {
                logger.debug("MLX model not ready — falling back to FoundationModels")
            }
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem)

        case .hybrid:
            // Structured extraction always uses FoundationModels
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem)
        }
    }

    /// Generate a narrative (prose) response — summaries, dictation polish, coaching suggestions.
    /// In hybrid mode routes to MLX for deeper reasoning; falls back to FoundationModels if MLX unavailable.
    func generateNarrative(
        prompt: String,
        systemInstruction: String? = nil,
        maxTokens: Int? = nil
    ) async throws -> String {
        activeGenerationCount += 1
        defer { activeGenerationCount -= 1 }

        let emojiClause = Self.emojiGuidance
        let effectiveSystem = systemInstruction.map { $0 + emojiClause } ?? (emojiClause.isEmpty ? nil : String(emojiClause.dropFirst()))

        let backend = activeBackend()

        switch backend {
        case .foundationModels:
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem)

        case .mlx, .hybrid:
            // Prefer MLX for narrative tasks; fall back to FM if circuit is open or model not ready
            let mlxReady = await MLXModelManager.shared.isSelectedModelReady()
            if mlxReady && !mlxCircuitOpen {
                do {
                    return try await generateWithMLX(prompt: prompt, systemInstruction: effectiveSystem, maxTokens: maxTokens)
                } catch {
                    mlxCircuitOpen = true
                    logger.warning("MLX generation failed (\(error.localizedDescription)) — circuit open, falling back to FoundationModels for this session")
                }
            } else if mlxCircuitOpen {
                logger.debug("MLX circuit open — using FoundationModels")
            } else {
                logger.debug("MLX model not ready — narrative falling back to FoundationModels")
            }
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem)
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

    /// Generate using Apple Intelligence (FoundationModels) regardless of active backend setting.
    /// Used for lightweight tasks like dictation polish where speed is more important than reasoning depth.
    func generateWithFoundationModels(prompt: String, systemInstruction: String?) async throws -> String {
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
    /// Continuation-based lock: if non-nil, a load is already in progress and
    /// additional callers should wait on this continuation list rather than
    /// starting a second load.
    private var mlxLoadWaiters: [CheckedContinuation<Void, any Error>]?

    /// Hub API for loading models from local cache — same base as MLXModelManager.
    private lazy var hubApi: HubApi = {
        HubApi(downloadBase: MLXModelManager.hubDownloadBase)
    }()

    /// Ensure the selected MLX model is loaded into memory.
    /// Prevents duplicate loads when multiple callers race during actor suspension.
    private func ensureMLXModelLoaded() async throws {
        guard let selectedID = await MLXModelManager.shared.selectedModelID else {
            throw AIError.modelUnavailable("No MLX model selected")
        }

        // Already loaded
        if loadedModelID == selectedID, mlxModelContainer != nil {
            return
        }

        // Another caller is already loading — wait for it to finish
        if mlxLoadWaiters != nil {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                mlxLoadWaiters?.append(cont)
            }
            return
        }

        // We are the first caller — start loading
        mlxLoadWaiters = []

        do {
            logger.debug("Loading MLX model: \(selectedID)")
            MLX.Memory.cacheLimit = 20 * 1024 * 1024

            let configuration = await MLXModelManager.shared.modelConfiguration(for: selectedID)
            let container = try await LLMModelFactory.shared.loadContainer(
                hub: hubApi,
                configuration: configuration
            ) { _ in }

            mlxModelContainer = container
            loadedModelID = selectedID
            logger.debug("MLX model loaded: \(selectedID)")

            // Resume all waiters successfully
            let waiters = mlxLoadWaiters ?? []
            mlxLoadWaiters = nil
            for waiter in waiters {
                waiter.resume()
            }
        } catch {
            // Resume all waiters with the error
            let waiters = mlxLoadWaiters ?? []
            mlxLoadWaiters = nil
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
            throw error
        }
    }

    /// Generate text using the MLX backend.
    private func generateWithMLX(prompt: String, systemInstruction: String?, maxTokens: Int?) async throws -> String {
        // Track the entire call (including C++ destructor teardown) with a single
        // increment/decrement pair.  We use a local `decremented` flag to ensure
        // exactly one decrement regardless of exit path, always paired with a
        // Task.yield() so waitUntilIdle() gets one more polling cycle after the
        // MLX C++ objects finish tearing down before the counter reaches zero.
        activeMLXStreamCount += 1
        var decremented = false
        func release() async {
            guard !decremented else { return }
            decremented = true
            await Task.yield()  // let C++ destructor finish before count drops to 0
            activeMLXStreamCount -= 1
        }

        do {
            try await ensureMLXModelLoaded()

            guard let container = mlxModelContainer else {
                await release()
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
            // `stream` goes out of scope at the end of this do-block.
            // Its C++ destructor runs while activeMLXStreamCount is still > 0
            // because we call release() (with yield) after this point.

            var result = output.trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip Qwen3-style <think>...</think> reasoning blocks from responses
            while let thinkStart = result.range(of: "<think>", options: .caseInsensitive),
                  let thinkEnd = result.range(of: "</think>", options: .caseInsensitive,
                                              range: thinkStart.upperBound..<result.endIndex) {
                result.removeSubrange(thinkStart.lowerBound...thinkEnd.upperBound)
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Strip orphaned opening <think> with no closing tag
            if let orphanStart = result.range(of: "<think>", options: .caseInsensitive) {
                result = String(result[..<orphanStart.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            await release()

            if result.isEmpty {
                throw AIError.generationFailed("MLX model returned empty response")
            }
            return result

        } catch {
            await release()
            throw error
        }
    }

    /// Unload the cached MLX model to free memory. Call when switching back to FoundationModels.
    func unloadMLXModel() {
        mlxModelContainer = nil
        loadedModelID = nil
        logger.debug("MLX model unloaded")
    }

    /// Open the circuit breaker and release the MLX model container.
    /// Call before process termination to reduce the chance of MLX C++ mutex crashes
    /// caused by teardown racing with an in-flight generation stream.
    func prepareForTermination() {
        mlxCircuitOpen = true
        mlxModelContainer = nil
        loadedModelID = nil
        logger.debug("AIService: circuit open and MLX container released for termination")
    }
}

// JSONExtraction.extractJSON(from:) is defined in JSONExtractionUtility.swift
