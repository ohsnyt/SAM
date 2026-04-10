//
//  SpeakerEnrollmentCoordinator.swift
//  SAM
//
//  Agent voice enrollment flow. Records a short passage from the Mac
//  microphone, splits it into sub-segments, extracts per-segment embeddings,
//  averages them into a centroid, and persists as a SpeakerProfile with
//  isAgent = true. Used by SAM to auto-label the agent in meeting transcripts.
//
//  Flow:
//    idle → recording → processing → saved
//

import Foundation
import AVFoundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SpeakerEnrollmentCoordinator")

@MainActor
@Observable
final class SpeakerEnrollmentCoordinator {

    // MARK: - State

    enum EnrollmentState: Sendable, Equatable {
        case idle
        case recording
        case processing
        case saved
        case error(String)
    }

    private(set) var state: EnrollmentState = .idle

    /// Elapsed recording time in seconds.
    private(set) var elapsedTime: TimeInterval = 0

    /// Target recording duration.
    let targetDuration: TimeInterval = 30.0

    /// Current audio level (0-1) for waveform display.
    private(set) var audioLevel: Float = 0

    /// Progress 0-1 towards target duration.
    var recordingProgress: Double {
        min(1.0, elapsedTime / targetDuration)
    }

    /// Whether an agent profile is already enrolled (from the current SwiftData state).
    private(set) var existingAgentProfileID: UUID?

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var audioBuffer = [Float]()
    private var sampleRate: Double = 0
    private var elapsedTimer: Timer?
    private var recordingStartTime: Date?
    private var modelContainer: ModelContainer?

    // MARK: - Configuration

    func configure(container: ModelContainer) {
        self.modelContainer = container
        checkExistingProfile()
    }

    // MARK: - Recording

    /// Start recording for enrollment.
    func startRecording() throws {
        // Allow starting from idle, saved (re-enroll), or any error state.
        switch state {
        case .idle, .saved, .error:
            break
        case .recording, .processing:
            return
        }

        // Reset
        audioBuffer = []
        elapsedTime = 0
        audioLevel = 0
        recordingStartTime = Date()

        // Permission check
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: break
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if granted {
                    try? self.performStartRecording()
                } else {
                    self.state = .error("Microphone permission denied")
                }
            }
            return
        case .denied, .restricted:
            state = .error("Microphone permission denied — enable in System Settings")
            return
        @unknown default:
            state = .error("Unknown microphone permission status")
            return
        }

        try performStartRecording()
    }

    private func performStartRecording() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw EnrollmentError.noAudioInput
        }

        self.sampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // Compute level for visualization
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += abs(channelData[i])
            }
            let level = min(1.0, (sum / Float(max(frameLength, 1))) * 5)

            // Copy samples into buffer
            var newSamples = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength {
                newSamples[i] = channelData[i]
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioBuffer.append(contentsOf: newSamples)
                self.audioLevel = level
            }
        }

        try engine.start()
        self.audioEngine = engine
        state = .recording

        startElapsedTimer()

        logger.info("Enrollment recording started: \(format.sampleRate)Hz \(format.channelCount)ch")
    }

    /// Stop recording early and process what we have (if enough).
    func stopRecording() {
        guard state == .recording else { return }

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        elapsedTimer?.invalidate()
        elapsedTimer = nil
        audioLevel = 0

        if elapsedTime >= 10 {
            // Process what we have
            processRecording()
        } else {
            state = .error("Recording too short — need at least 10 seconds")
        }
    }

    /// Cancel and discard.
    func cancel() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        audioBuffer = []
        elapsedTime = 0
        audioLevel = 0
        state = .idle
    }

    // MARK: - Processing

    private func startElapsedTimer() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)

                // Auto-stop at target duration
                if self.elapsedTime >= self.targetDuration {
                    self.stopRecording()
                }
            }
        }
    }

    private func processRecording() {
        state = .processing
        let buffer = audioBuffer
        let rate = sampleRate

        Task { [weak self] in
            guard let self else { return }
            await self.extractAndSaveEmbedding(from: buffer, sampleRate: rate)
        }
    }

    private func extractAndSaveEmbedding(from samples: [Float], sampleRate: Double) async {
        // Split into 5-second chunks for multiple embeddings
        let chunkDuration: Double = 5.0
        let chunkSize = Int(sampleRate * chunkDuration)

        var embeddings: [[Float]] = []
        var idx = 0
        while idx + chunkSize <= samples.count {
            let chunk = Array(samples[idx..<(idx + chunkSize)])
            if let emb = SpeakerEmbeddingService.shared.embedding(for: chunk, sampleRate: sampleRate) {
                embeddings.append(emb)
            }
            idx += chunkSize
        }

        // Process any tail if it's at least 2 seconds
        if samples.count - idx >= Int(sampleRate * 2) {
            let tail = Array(samples[idx..<samples.count])
            if let emb = SpeakerEmbeddingService.shared.embedding(for: tail, sampleRate: sampleRate) {
                embeddings.append(emb)
            }
        }

        guard !embeddings.isEmpty else {
            state = .error("Could not extract voice features — try again in a quieter environment")
            return
        }

        logger.info("Enrollment: extracted \(embeddings.count) embeddings from \(samples.count) samples")

        // Average into centroid
        guard let centroid = SpeakerEmbeddingService.centroid(of: embeddings) else {
            state = .error("Could not build voice profile from recording")
            return
        }

        // Save to SwiftData
        guard let container = modelContainer else {
            state = .error("No database connection")
            return
        }

        let context = ModelContext(container)
        do {
            // Remove any existing agent profile (re-enrollment)
            let descriptor = FetchDescriptor<SpeakerProfile>(
                predicate: #Predicate { $0.isAgent == true }
            )
            let existing = try context.fetch(descriptor)
            for profile in existing {
                context.delete(profile)
            }

            // Create new profile
            let embeddingData = SpeakerEmbeddingService.encode(centroid)
            let profile = SpeakerProfile(
                label: "Agent",
                isAgent: true,
                embeddingData: embeddingData,
                enrollmentSampleCount: embeddings.count,
                enrolledAt: .now,
                updatedAt: .now
            )
            context.insert(profile)
            try context.save()

            existingAgentProfileID = profile.id
            state = .saved
            logger.info("Agent voice profile saved: \(profile.id.uuidString)")
        } catch {
            logger.error("Failed to save enrollment: \(error.localizedDescription)")
            state = .error("Failed to save profile: \(error.localizedDescription)")
        }
    }

    // MARK: - Existing Profile

    private func checkExistingProfile() {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        do {
            let descriptor = FetchDescriptor<SpeakerProfile>(
                predicate: #Predicate { $0.isAgent == true }
            )
            existingAgentProfileID = try context.fetch(descriptor).first?.id
        } catch {
            logger.error("Failed to check existing profile: \(error.localizedDescription)")
        }
    }

    /// Delete the existing agent profile.
    func deleteExistingProfile() {
        guard let container = modelContainer else { return }
        let context = ModelContext(container)
        do {
            let descriptor = FetchDescriptor<SpeakerProfile>(
                predicate: #Predicate { $0.isAgent == true }
            )
            let profiles = try context.fetch(descriptor)
            for profile in profiles {
                context.delete(profile)
            }
            try context.save()
            existingAgentProfileID = nil
            state = .idle
            logger.info("Deleted existing agent profile(s): \(profiles.count)")
        } catch {
            logger.error("Failed to delete profile: \(error.localizedDescription)")
        }
    }

    /// Reset state to idle (e.g., after saved to enroll again).
    func reset() {
        audioBuffer = []
        elapsedTime = 0
        audioLevel = 0
        state = .idle
    }

    // MARK: - Errors

    enum EnrollmentError: LocalizedError {
        case noAudioInput

        var errorDescription: String? {
            switch self {
            case .noAudioInput: return "No audio input device available."
            }
        }
    }
}
