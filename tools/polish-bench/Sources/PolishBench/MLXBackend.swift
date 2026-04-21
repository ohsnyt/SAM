//
//  MLXBackend.swift
//  polish-bench
//
//  Thin wrapper around `LLMModelFactory.shared.loadContainer` so the bench
//  can load a Hugging Face model by ID, stream a chat completion, and
//  unload on the way out. Mirrors the MLX code path in
//  `AIService.generateWithMLX` so the bench exercises the same generation
//  loop the production app uses.
//

import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

actor MLXBackend {
    private let modelID: String
    private var container: ModelContainer?

    private init(modelID: String) {
        self.modelID = modelID
    }

    /// Load (or verify cache for) a model by Hugging Face repo ID. Blocks
    /// until the container reports ready. Throws if the weights aren't on
    /// disk — the bench does not download models itself.
    static func load(modelID: String) async throws -> MLXBackend {
        let backend = MLXBackend(modelID: modelID)
        let cfg = ModelConfiguration(id: modelID)
        let container = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: cfg
        )
        await backend.setContainer(container)
        return backend
    }

    private func setContainer(_ c: ModelContainer) { self.container = c }

    /// Single-shot text generation. Applies the chat template, streams the
    /// response, joins chunks, strips `<think>…</think>` reasoning blocks
    /// (same post-processing as `AIService.generateWithMLX`), and returns
    /// the trimmed result.
    func generate(systemInstruction: String?, prompt: String, maxTokens: Int = 4096) async throws -> String {
        guard let container else {
            throw BackendError.notLoaded
        }

        var chat: [Chat.Message] = []
        if let sys = systemInstruction {
            chat.append(.system(sys))
        }
        chat.append(.user(prompt))

        let userInput = UserInput(chat: chat)
        let lmInput = try await container.prepare(input: userInput)

        var parameters = GenerateParameters()
        parameters.temperature = 0.6
        parameters.maxTokens = maxTokens

        let stream = try await container.generate(input: lmInput, parameters: parameters)
        var output = ""
        for await generation in stream {
            if let chunk = generation.chunk {
                output += chunk
            }
        }

        return stripThinkBlocks(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        container = nil
    }

    /// Strip `<think>…</think>` blocks (Qwen3-family reasoning leakage)
    /// plus any orphaned opening `<think>` with no matching close.
    private func stripThinkBlocks(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>", options: .caseInsensitive),
              let end = result.range(of: "</think>", options: .caseInsensitive,
                                     range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound...end.upperBound)
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let orphan = result.range(of: "<think>", options: .caseInsensitive) {
            result = String(result[..<orphan.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    enum BackendError: LocalizedError {
        case notLoaded
        var errorDescription: String? {
            switch self {
            case .notLoaded: return "MLX model container not loaded"
            }
        }
    }
}
