//
//  MLXModelManager.swift
//  SAM
//
//  Created by Assistant on 2/22/26.
//  Phase N: Outcome-Focused Coaching Engine
//
//  Manages MLX model download, storage, and lifecycle.
//  Uses HuggingFace Hub for model file caching and MLXLLM for model loading.
//

import Foundation
import Hub
import MLXLLM
import MLXLMCommon
import os.log

/// Manages MLX model download, storage, and lifecycle.
actor MLXModelManager {

    // MARK: - Singleton

    static let shared = MLXModelManager()
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "MLXModelManager")

    private init() {
        // Restore download state from UserDefaults, verifying files on disk
        let savedIDs = UserDefaults.standard.stringArray(forKey: Self.downloadedModelsKey) ?? []
        let hub = HubApi(downloadBase: Self.hubDownloadBase)
        for id in savedIDs {
            let repo = Hub.Repo(id: id)
            let localDir = hub.localRepoLocation(repo)
            if FileManager.default.fileExists(atPath: localDir.path),
               let idx = availableModels.firstIndex(where: { $0.id == id }) {
                availableModels[idx] = ModelInfo(
                    id: availableModels[idx].id,
                    displayName: availableModels[idx].displayName,
                    sizeGB: availableModels[idx].sizeGB,
                    isDownloaded: true
                )
            }
        }
    }

    // MARK: - Types

    struct ModelInfo: Sendable, Identifiable {
        let id: String              // e.g., "mlx-community/Mistral-7B-Instruct-v0.3-4bit"
        let displayName: String
        let sizeGB: Double
        var isDownloaded: Bool
    }

    // MARK: - State

    /// Curated model list.
    var availableModels: [ModelInfo] = [
        ModelInfo(
            id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            displayName: "Mistral 7B Instruct (4-bit)",
            sizeGB: 4.0,
            isDownloaded: false
        ),
        ModelInfo(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B Instruct (4-bit)",
            sizeGB: 2.0,
            isDownloaded: false
        ),
    ]

    /// Currently selected model ID (UserDefaults-backed).
    var selectedModelID: String? {
        get { UserDefaults.standard.string(forKey: "mlxSelectedModelID") }
        set { UserDefaults.standard.set(newValue, forKey: "mlxSelectedModelID") }
    }

    /// Download progress (0–1) for active download, nil when idle.
    var downloadProgress: Double?

    /// Active download task for cancellation.
    private var activeDownloadTask: Task<Void, Error>?

    /// Shared download base for all MLX Hub operations.
    /// Both MLXModelManager and AIService must use the same path.
    static let hubDownloadBase: URL? = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
    ).first

    /// HubApi instance for downloading models.
    private lazy var hubApi: HubApi = {
        HubApi(downloadBase: Self.hubDownloadBase)
    }()

    // MARK: - Queries

    /// Whether the currently selected model is downloaded and ready to use.
    func isSelectedModelReady() -> Bool {
        guard let id = selectedModelID else { return false }
        return isModelReady(id: id)
    }

    /// Whether a specific model is downloaded and ready.
    func isModelReady(id: String) -> Bool {
        availableModels.first(where: { $0.id == id })?.isDownloaded ?? false
    }

    /// Whether a download is currently in progress.
    var isDownloading: Bool {
        activeDownloadTask != nil
    }

    // MARK: - Download

    /// Update download progress (called from progress callback).
    private func updateDownloadProgress(_ fraction: Double) {
        downloadProgress = fraction
    }

    /// Download a model by ID from HuggingFace.
    func downloadModel(id: String) async throws {
        guard activeDownloadTask == nil else {
            logger.warning("Download already in progress")
            return
        }

        logger.info("Starting MLX model download: \(id)")
        downloadProgress = 0

        let task = Task {
            let repo = Hub.Repo(id: id)
            try await hubApi.snapshot(from: repo, matching: ["*.safetensors", "*.json", "*.txt", "*.model"]) { [weak self] progress in
                guard let self else { return }
                Task { await self.updateDownloadProgress(progress.fractionCompleted) }
            }
        }
        activeDownloadTask = task

        do {
            try await task.value
            markDownloaded(id: id, downloaded: true)
            downloadProgress = nil
            activeDownloadTask = nil
            logger.info("MLX model download complete: \(id)")
        } catch {
            downloadProgress = nil
            activeDownloadTask = nil
            if Task.isCancelled || error is CancellationError {
                logger.info("MLX model download cancelled: \(id)")
                throw CancellationError()
            }
            logger.error("MLX model download failed: \(id) — \(error.localizedDescription)")
            throw error
        }
    }

    /// Cancel the active download.
    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadProgress = nil
        logger.info("Download cancelled by user")
    }

    // MARK: - Delete

    /// Delete a downloaded model's cached files.
    func deleteModel(id: String) throws {
        let repo = Hub.Repo(id: id)
        let localDir = hubApi.localRepoLocation(repo)

        if FileManager.default.fileExists(atPath: localDir.path) {
            try FileManager.default.removeItem(at: localDir)
            logger.info("Deleted MLX model files: \(id)")
        }

        markDownloaded(id: id, downloaded: false)

        // If this was the selected model, clear selection
        if selectedModelID == id {
            selectedModelID = nil
        }
    }

    // MARK: - Custom Models

    /// Add a custom model ID to the available list.
    func addCustomModel(id: String, displayName: String, sizeGB: Double) {
        guard !availableModels.contains(where: { $0.id == id }) else { return }
        availableModels.append(ModelInfo(id: id, displayName: displayName, sizeGB: sizeGB, isDownloaded: false))
        logger.info("Added custom MLX model: \(id)")
    }

    // MARK: - Model Configuration

    /// Create a ModelConfiguration for a given model ID.
    func modelConfiguration(for id: String) -> ModelConfiguration {
        ModelConfiguration(id: id)
    }

    // MARK: - Persistence

    private static let downloadedModelsKey = "mlxDownloadedModelIDs"

    /// Mark a model as downloaded/not-downloaded and persist to UserDefaults.
    private func markDownloaded(id: String, downloaded: Bool) {
        if let idx = availableModels.firstIndex(where: { $0.id == id }) {
            availableModels[idx] = ModelInfo(
                id: availableModels[idx].id,
                displayName: availableModels[idx].displayName,
                sizeGB: availableModels[idx].sizeGB,
                isDownloaded: downloaded
            )
        }
        persistDownloadState()
    }

    /// Save downloaded model IDs to UserDefaults.
    private func persistDownloadState() {
        let downloadedIDs = availableModels.filter(\.isDownloaded).map(\.id)
        UserDefaults.standard.set(downloadedIDs, forKey: Self.downloadedModelsKey)
    }

}
