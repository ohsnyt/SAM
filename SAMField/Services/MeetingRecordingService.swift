//
//  MeetingRecordingService.swift
//  SAM Field
//
//  AVAudioEngine stereo capture for meeting recording.
//  Captures PCM audio, provides chunks to AudioStreamingService for
//  transmission to Mac, and maintains a local ring buffer on disk
//  for resilience against WiFi dropouts.
//

import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "MeetingRecordingService")

@MainActor
@Observable
final class MeetingRecordingService {

    // MARK: - State

    enum RecordingState: Sendable {
        case idle
        case recording
        case paused
        case stopping
    }

    private(set) var state: RecordingState = .idle

    /// Current audio level (0.0–1.0) for waveform display.
    private(set) var audioLevel: Float = 0

    /// Elapsed recording duration in seconds (excludes paused time).
    private(set) var elapsedTime: TimeInterval = 0

    /// Audio format in use (set after recording starts).
    private(set) var sampleRate: Double = 0
    private(set) var channelCount: UInt32 = 0

    /// Callback invoked on the audio thread with each chunk of PCM data.
    /// AudioStreamingService sets this to receive chunks for transmission.
    var onAudioChunk: (@Sendable (AudioChunk) -> Void)?

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var recordingStartTime: Date?
    private var accumulatedTime: TimeInterval = 0
    private var elapsedTimer: Timer?
    private var sequenceNumber: UInt64 = 0
    private var sessionStartTime: UInt64 = 0 // mach_absolute_time at session start

    // Ring buffer: circular file-backed buffer of recent audio for dropout recovery
    private var ringBufferFile: AVAudioFile?
    private var ringBufferURL: URL?
    private var ringBufferFramesWritten: Int64 = 0

    // Chunk accumulation
    private var chunkAccumulator = Data()
    private var framesPerChunk: Int = 0
    private var framesAccumulated: Int = 0

    /// Directory for temporary ring buffer files.
    private var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MeetingCapture", isDirectory: true)
    }

    // MARK: - Recording

    /// Start capturing audio from the microphone.
    func startRecording() throws {
        guard state == .idle else {
            logger.warning("Cannot start recording — not idle (state: \(String(describing: self.state)))")
            return
        }

        // Configure audio session for high-quality stereo capture
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)

        guard nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0 else {
            throw MeetingRecordingError.noAudioInput
        }

        self.sampleRate = nativeFormat.sampleRate
        self.channelCount = nativeFormat.channelCount

        // Calculate frames per 0.5s chunk
        framesPerChunk = Int(nativeFormat.sampleRate * AudioStreamingConstants.chunkDurationSeconds)

        logger.info("Recording format: \(nativeFormat.sampleRate)Hz, \(nativeFormat.channelCount) channels")

        // Set up ring buffer file
        try setupRingBuffer(format: nativeFormat)

        // Reset state
        sequenceNumber = 0
        sessionStartTime = mach_absolute_time()
        chunkAccumulator = Data()
        framesAccumulated = 0

        let sampleRate = UInt32(nativeFormat.sampleRate)
        let channels = UInt16(nativeFormat.channelCount)
        let framesPerChunk = self.framesPerChunk
        let bytesPerFrame = Int(nativeFormat.channelCount) * 2 // 16-bit PCM
        let chunkByteSize = framesPerChunk * bytesPerFrame
        let sessionStart = self.sessionStartTime
        let ringFile = self.ringBufferFile

        // Install audio tap
        input.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, time in
            guard let self else { return }

            // Convert float buffer to Int16 PCM
            let pcmData = self.convertToInt16PCM(buffer: buffer)

            // Write to ring buffer
            if let ringFile {
                self.writeToRingBuffer(buffer: buffer, file: ringFile)
            }

            // Accumulate into chunks
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chunkAccumulator.append(pcmData)
                self.framesAccumulated += Int(buffer.frameLength)

                // Compute audio level
                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<frameLength { sum += abs(channelData[i]) }
                    self.audioLevel = min(1.0, (sum / Float(max(frameLength, 1))) * 5)
                }

                // Emit chunk when we have enough frames
                if self.framesAccumulated >= framesPerChunk {
                    let chunkData = self.chunkAccumulator.prefix(chunkByteSize)
                    let remainder = self.chunkAccumulator.suffix(from: self.chunkAccumulator.startIndex.advanced(by: min(chunkByteSize, self.chunkAccumulator.count)))

                    // Calculate timestamp in microseconds from session start
                    let now = mach_absolute_time()
                    var info = mach_timebase_info_data_t()
                    mach_timebase_info(&info)
                    let elapsedNanos = (now - sessionStart) * UInt64(info.numer) / UInt64(info.denom)
                    let elapsedMicros = elapsedNanos / 1000

                    let chunk = AudioChunk(
                        sequenceNumber: self.sequenceNumber,
                        timestamp: elapsedMicros,
                        sampleRate: sampleRate,
                        channels: channels,
                        pcmData: Data(chunkData)
                    )
                    self.sequenceNumber += 1
                    self.chunkAccumulator = Data(remainder)
                    self.framesAccumulated = max(0, self.framesAccumulated - framesPerChunk)

                    self.onAudioChunk?(chunk)
                }
            }
        }

        try engine.start()

        self.audioEngine = engine
        self.inputNode = input
        self.recordingStartTime = Date()
        self.accumulatedTime = 0
        self.state = .recording

        startElapsedTimer()

        logger.info("Meeting recording started")
    }

    // MARK: - Pause / Resume

    func pauseRecording() {
        guard state == .recording else { return }

        audioEngine?.pause()

        if let start = recordingStartTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }
        recordingStartTime = nil
        state = .paused

        logger.info("Meeting recording paused")
    }

    func resumeRecording() throws {
        guard state == .paused, let engine = audioEngine else { return }

        try engine.start()
        recordingStartTime = Date()
        state = .recording

        logger.info("Meeting recording resumed")
    }

    // MARK: - Stop

    /// Stop recording and return the ring buffer URL (contains the full local backup).
    func stopRecording() -> URL? {
        guard state == .recording || state == .paused else { return nil }

        state = .stopping

        // Flush any remaining accumulated audio as a final chunk
        if !chunkAccumulator.isEmpty {
            let sampleRate = UInt32(self.sampleRate)
            let channels = UInt16(self.channelCount)
            let now = mach_absolute_time()
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let elapsedNanos = (now - sessionStartTime) * UInt64(info.numer) / UInt64(info.denom)
            let elapsedMicros = elapsedNanos / 1000

            let chunk = AudioChunk(
                sequenceNumber: sequenceNumber,
                timestamp: elapsedMicros,
                sampleRate: sampleRate,
                channels: channels,
                pcmData: chunkAccumulator
            )
            sequenceNumber += 1
            chunkAccumulator = Data()
            framesAccumulated = 0
            onAudioChunk?(chunk)
        }

        // Stop engine
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)

        // Accumulate final elapsed time
        if let start = recordingStartTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }
        elapsedTime = accumulatedTime

        // Stop timer
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        audioLevel = 0

        // Close ring buffer
        ringBufferFile = nil
        let savedURL = ringBufferURL

        // Clean up
        audioEngine = nil
        inputNode = nil
        onAudioChunk = nil

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        state = .idle
        logger.info("Meeting recording stopped. Duration: \(String(format: "%.1f", self.elapsedTime))s")

        return savedURL
    }

    /// Cancel recording and clean up all files.
    func cancelRecording() {
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)

        elapsedTimer?.invalidate()
        elapsedTimer = nil
        audioLevel = 0
        elapsedTime = 0

        audioEngine = nil
        inputNode = nil
        ringBufferFile = nil
        onAudioChunk = nil
        chunkAccumulator = Data()
        framesAccumulated = 0

        // Delete ring buffer
        if let url = ringBufferURL {
            try? FileManager.default.removeItem(at: url)
        }
        ringBufferURL = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        state = .idle
        logger.info("Meeting recording cancelled")
    }

    // MARK: - Ring Buffer

    private func setupRingBuffer(format: AVAudioFormat) throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let url = tempDirectory.appendingPathComponent("ring-\(UUID().uuidString).wav")

        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])

        self.ringBufferFile = file
        self.ringBufferURL = url
        self.ringBufferFramesWritten = 0

        logger.debug("Ring buffer created at \(url.lastPathComponent)")
    }

    private nonisolated func writeToRingBuffer(buffer: AVAudioPCMBuffer, file: AVAudioFile) {
        // Writing from the audio thread — AVAudioFile is thread-safe for writes
        do {
            try file.write(from: buffer)
        } catch {
            logger.error("Ring buffer write error: \(error.localizedDescription)")
        }
    }

    // MARK: - PCM Conversion

    /// Convert a float AVAudioPCMBuffer to Int16 PCM Data.
    private nonisolated func convertToInt16PCM(buffer: AVAudioPCMBuffer) -> Data {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let totalSamples = frameLength * channelCount

        var pcmData = Data(count: totalSamples * 2) // 2 bytes per Int16 sample

        pcmData.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            var sampleIndex = 0

            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    if let channelData = buffer.floatChannelData?[channel] {
                        // Clamp to [-1.0, 1.0] and convert to Int16
                        let clamped = max(-1.0, min(1.0, channelData[frame]))
                        int16Buffer[sampleIndex] = Int16(clamped * Float(Int16.max))
                    }
                    sampleIndex += 1
                }
            }
        }

        return pcmData
    }

    // MARK: - Timer

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = self.accumulatedTime + Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: - Errors

    enum MeetingRecordingError: LocalizedError {
        case noAudioInput

        var errorDescription: String? {
            switch self {
            case .noAudioInput: return "No audio input device found."
            }
        }
    }
}
