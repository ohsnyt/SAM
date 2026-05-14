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

    /// Inference priority. Interactive work (briefing narrative, draft messages,
    /// dictation polish) jumps ahead of background work (relationship summaries,
    /// strategic specialists, conversation analysis) in the SerialGate queue.
    /// Default is `.background` so existing call sites stay conservative;
    /// foreground call sites must opt in to `.interactive`.
    enum Priority: Sendable {
        case interactive
        case background
    }

    enum AIError: Error, LocalizedError {
        case modelUnavailable(String)
        case generationFailed(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let reason): return "AI model unavailable: \(reason)"
            case .generationFailed(let reason): return "AI generation failed: \(reason)"
            case .timeout(let reason): return "AI generation timed out: \(reason)"
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

    // MARK: - Serial Inference Gate
    //
    // AIService is already an `actor`, but Swift actors are reentrant on
    // suspension — once a generation call awaits `session.respond(...)` or the
    // MLX stream, another caller can grab the actor and start its own
    // inference in parallel. On unified-memory Macs that produces beachballs
    // (parallel FoundationModels + MLX both touching the Neural Engine and
    // shared memory). This gate enforces FIFO one-at-a-time across both
    // backends. Pure-compute methods (activeBackend, contextBudgetChars) stay
    // unwrapped; only actual model invocations route through the gate.

    private let inferenceGate = SerialGate()

    /// Runs `body` with the inference gate held. Releases the slot whether
    /// `body` returns or throws. The release runs in a detached Task so it
    /// happens immediately on the gate's actor without waiting for the
    /// caller's actor. Interactive work bypasses any pending background
    /// callers; background work waits at the tail.
    ///
    /// Also publishes the task to `InferenceRegistry` so the sidebar footer
    /// (and any future activity surface) reflects the current and queued
    /// work without each caller having to wire its own visibility flag.
    private func runSerialized<T>(task: InferenceTask, _ body: () async throws -> T) async throws -> T {
        await MainActor.run { InferenceRegistry.shared.enqueue(task) }
        await inferenceGate.enter(priority: task.priority)
        await MainActor.run { InferenceRegistry.shared.markRunning(task) }
        defer {
            Task { await inferenceGate.leave() }
            Task { @MainActor in InferenceRegistry.shared.remove(task) }
        }
        return try await body()
    }

    /// Backward-compat overload for callers that haven't moved to the
    /// labeled API yet. Synthesizes a generic "AI" task. Once Phase B
    /// migration is done this overload can be removed.
    private func runSerialized<T>(priority: Priority = .background, _ body: () async throws -> T) async throws -> T {
        try await runSerialized(task: .generic(priority: priority), body)
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

    /// Returns the active backend. Always hybrid: structured→FM, narrative→MLX.
    func activeBackend() -> Backend {
        .hybrid
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
        maxTokens: Int? = nil,
        priority: Priority = .background,
        task: InferenceTask? = nil
    ) async throws -> String {
        activeGenerationCount += 1
        defer { activeGenerationCount -= 1 }

        let effectiveTask = task ?? .generic(priority: priority)
        let emojiClause = Self.emojiGuidance
        let effectiveSystem = systemInstruction.map { $0 + emojiClause } ?? (emojiClause.isEmpty ? nil : String(emojiClause.dropFirst()))

        let backend = activeBackend()

        switch backend {
        case .foundationModels:
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem, task: effectiveTask)

        case .mlx:
            // Try MLX first, fall back to FoundationModels on failure or if circuit is open
            let mlxReady = await MLXModelManager.shared.isSelectedModelReady()
            if mlxReady && !mlxCircuitOpen {
                do {
                    return try await generateWithMLX(prompt: prompt, systemInstruction: effectiveSystem, maxTokens: maxTokens, task: effectiveTask)
                } catch {
                    mlxCircuitOpen = true
                    logger.warning("MLX generation failed (\(error.localizedDescription)) — circuit open, falling back to FoundationModels for this session")
                }
            } else if !mlxReady {
                logger.debug("MLX model not ready — falling back to FoundationModels")
            }
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem, task: effectiveTask)

        case .hybrid:
            // Structured extraction always uses FoundationModels
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem, task: effectiveTask)
        }
    }

    /// Generate a narrative (prose) response — summaries, dictation polish, coaching suggestions.
    /// In hybrid mode routes to MLX for deeper reasoning; falls back to FoundationModels if MLX unavailable.
    func generateNarrative(
        prompt: String,
        systemInstruction: String? = nil,
        maxTokens: Int? = nil,
        priority: Priority = .background,
        task: InferenceTask? = nil
    ) async throws -> String {
        activeGenerationCount += 1
        defer { activeGenerationCount -= 1 }

        let effectiveTask = task ?? .generic(priority: priority)
        let emojiClause = Self.emojiGuidance
        let effectiveSystem = systemInstruction.map { $0 + emojiClause } ?? (emojiClause.isEmpty ? nil : String(emojiClause.dropFirst()))

        let backend = activeBackend()

        switch backend {
        case .foundationModels:
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem, task: effectiveTask)

        case .mlx, .hybrid:
            // Prefer MLX for narrative tasks; fall back to FM if circuit is open or model not ready
            let mlxReady = await MLXModelManager.shared.isSelectedModelReady()
            if mlxReady && !mlxCircuitOpen {
                do {
                    return try await generateWithMLX(prompt: prompt, systemInstruction: effectiveSystem, maxTokens: maxTokens, task: effectiveTask)
                } catch {
                    mlxCircuitOpen = true
                    logger.warning("MLX generation failed (\(error.localizedDescription)) — circuit open, falling back to FoundationModels for this session")
                }
            } else if mlxCircuitOpen {
                logger.debug("MLX circuit open — using FoundationModels")
            } else {
                logger.debug("MLX model not ready — narrative falling back to FoundationModels")
            }
            return try await generateWithFoundationModels(prompt: prompt, systemInstruction: effectiveSystem, task: effectiveTask)
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
    func generateWithFoundationModels(
        prompt: String,
        systemInstruction: String?,
        priority: Priority = .background,
        task: InferenceTask? = nil
    ) async throws -> String {
        guard case .available = foundationModelsAvailability() else {
            throw AIError.modelUnavailable("FoundationModels not available")
        }

        let effectiveTask = task ?? .generic(priority: priority)
        let session: LanguageModelSession
        if let instruction = systemInstruction {
            session = LanguageModelSession(instructions: instruction)
        } else {
            session = LanguageModelSession()
        }

        // 30-second hard timeout. FoundationModels can hang for 60+ seconds
        // when hitting context-window or resource issues before returning an
        // error — this ensures the polish stage never blocks the pipeline for
        // more than half a minute regardless of the model's behaviour.
        // Serialised via inferenceGate so this never runs concurrently with
        // another FM/MLX call.
        return try await runSerialized(task: effectiveTask) {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let response = try await session.respond(to: prompt)
                    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw AIError.timeout("FoundationModels did not respond within 30s")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }
    }

    /// Generate a `@Generable` structured value using Apple FoundationModels'
    /// constrained decoding. Returns `T` directly — the framework enforces
    /// schema conformance, so there is no JSON parse step to fail.
    ///
    /// - Parameters:
    ///   - type: The Generable type to produce.
    ///   - prompt: The user prompt.
    ///   - systemInstruction: Optional system instructions for the session.
    ///   - timeout: Hard timeout in seconds. Defaults to 30s.
    func generateStructured<T: Generable>(
        _ type: T.Type,
        prompt: String,
        systemInstruction: String? = nil,
        timeout: TimeInterval = 30,
        priority: Priority = .background,
        task: InferenceTask? = nil
    ) async throws -> T {
        guard case .available = foundationModelsAvailability() else {
            throw AIError.modelUnavailable("FoundationModels not available")
        }

        let effectiveTask = task ?? .generic(priority: priority)
        let session: LanguageModelSession
        if let instruction = systemInstruction {
            session = LanguageModelSession(instructions: instruction)
        } else {
            session = LanguageModelSession()
        }

        // Serialised via inferenceGate so this never runs concurrently with
        // another FM/MLX call.
        return try await runSerialized(task: effectiveTask) {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    let response = try await session.respond(to: prompt, generating: T.self)
                    return response.content
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw AIError.timeout("FoundationModels structured generation did not respond within \(Int(timeout))s")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }
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
    private func generateWithMLX(
        prompt: String,
        systemInstruction: String?,
        maxTokens: Int?,
        priority: Priority = .background,
        task: InferenceTask? = nil
    ) async throws -> String {
        let effectiveTask = task ?? .generic(priority: priority)
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
            // Serialised via inferenceGate so MLX never races with FoundationModels
            // or another MLX call. Model load + stream consumption all run inside
            // the gate; `stream` goes out of scope at end of closure so its C++
            // destructor runs while the slot is still held.
            let rawOutput = try await runSerialized(task: effectiveTask) { () -> String in
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
                return output
            }

            var result = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)

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

// MARK: - SerialGate

/// One-slot priority gate. Used by AIService to prevent reentrant parallel
/// inference across FoundationModels and MLX. See AIService.runSerialized.
///
/// Two-lane queue: interactive callers (briefing narrative, draft messages,
/// dictation polish) jump ahead of background callers (relationship summary
/// refresh, strategic specialists, conversation analysis). The in-flight
/// inference is never preempted — interactive callers wait one slot at most.
private actor SerialGate {
    private var isBusy = false
    private var interactiveQueue: [CheckedContinuation<Void, Never>] = []
    private var backgroundQueue: [CheckedContinuation<Void, Never>] = []

    func enter(priority: AIService.Priority) async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            switch priority {
            case .interactive: interactiveQueue.append(cont)
            case .background: backgroundQueue.append(cont)
            }
        }
    }

    func leave() {
        // Drain interactive lane first; only fall through to background when empty.
        if !interactiveQueue.isEmpty {
            let next = interactiveQueue.removeFirst()
            next.resume()
        } else if !backgroundQueue.isEmpty {
            let next = backgroundQueue.removeFirst()
            next.resume()
        } else {
            isBusy = false
        }
    }
}
