//
//  VoiceRecordingService.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F2: Voice Capture (rewritten for live streaming transcription)
//
//  Uses AVAudioEngine for recording + SFSpeechAudioBufferRecognitionRequest
//  for real-time on-device transcription. Audio is simultaneously saved to
//  an .m4a file. Supports pause/resume during recording.
//

import Foundation
import AVFoundation
import Speech
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAMField", category: "VoiceRecordingService")

@MainActor
@Observable
final class VoiceRecordingService {

    static let shared = VoiceRecordingService()

    // MARK: - State

    enum RecordingState: Sendable {
        case idle
        case recording
        case paused
        case stopping
    }

    private(set) var state: RecordingState = .idle

    /// Live transcript — updates in real time as the user speaks
    private(set) var liveTranscript: String = ""

    /// Accumulated finalized text from all completed recognition sessions
    private var accumulatedText: String = ""

    /// Current partial (in-progress) recognition text for the active session
    private var currentSessionText: String = ""

    /// When the last partial result was received — used to measure silence gaps
    private var lastPartialTime: Date = .now

    /// Silence gap threshold: gaps shorter than this get a dash, longer get a paragraph
    private let paragraphGapSeconds: TimeInterval = 5.0

    /// Current audio level (0.0–1.0) for waveform display
    private(set) var audioLevel: Float = 0

    /// Elapsed recording duration in seconds (excludes paused time)
    private(set) var elapsedTime: TimeInterval = 0

    /// URL of the saved audio file (available after stopping)
    private(set) var audioFileURL: URL?

    /// Selected audio mode for recording
    var audioMode: AudioMode = .standard

    /// Available audio inputs (external mics, etc.)
    var availableInputs: [AVAudioSessionPortDescription] {
        AVAudioSession.sharedInstance().availableInputs ?? []
    }

    /// Currently selected input (nil = system default)
    var preferredInput: AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().preferredInput
    }

    /// Select a specific audio input (external mic, etc.)
    func selectInput(_ input: AVAudioSessionPortDescription?) {
        try? AVAudioSession.sharedInstance().setPreferredInput(input)
    }

    // MARK: - Audio Modes

    enum AudioMode: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case voiceIsolation = "Voice Isolation"
        case wideSpectrum = "Wide Spectrum"

        var id: String { rawValue }

        var description: String {
            switch self {
            case .standard: return "Balanced audio with light noise reduction"
            case .voiceIsolation: return "Filters background noise, keeps only voices"
            case .wideSpectrum: return "Captures everything including ambient sound"
            }
        }
    }

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var audioFile: AVAudioFile?
    private var levelTimer: Timer?
    private var recordingStartTime: Date?
    private var accumulatedTime: TimeInterval = 0
    private var inputNode: AVAudioInputNode?

    /// Directory for storing voice capture audio files
    private var capturesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("VoiceCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {}

    // MARK: - Authorization

    enum Availability: Sendable {
        case available
        case notAuthorized
        case notAvailable
    }

    func checkAvailability() -> Availability {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            return .notAvailable
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .available
        case .notDetermined: return .notAuthorized
        default: return .notAuthorized
        }
    }

    func requestAuthorization() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else {
            logger.warning("Speech recognition authorization denied")
            return false
        }

        let micAuthorized: Bool
        if #available(iOS 17, *) {
            micAuthorized = await AVAudioApplication.requestRecordPermission()
        } else {
            micAuthorized = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        if !micAuthorized {
            logger.warning("Microphone access denied")
        }
        return micAuthorized
    }

    // MARK: - Recording with Live Transcription

    /// Start recording with simultaneous live transcription.
    func startRecording() throws {
        guard state == .idle else {
            logger.warning("Cannot start recording — not idle")
            return
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw RecordingError.speechNotAvailable
        }

        // Audio session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        // Configure voice processing mode based on user selection
        if #available(iOS 15.0, *) {
            switch audioMode {
            case .voiceIsolation:
                try? session.setPreferredInputOrientation(.portrait)
                if session.availableCategories.contains(.playAndRecord) {
                    try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
                }
            case .wideSpectrum:
                // Measurement mode with no voice processing — captures everything
                try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            case .standard:
                try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            }
        }

        // Audio engine
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let recordingFormat = input.outputFormat(forBus: 0)

        guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
            throw RecordingError.noAudioInput
        }

        let isStereo = recordingFormat.channelCount >= 2
        logger.info("Recording format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount) channels, stereo=\(isStereo)")

        // Audio file for saving
        let fileURL = capturesDirectory.appendingPathComponent("\(UUID().uuidString).wav")

        // Use a PCM format for the audio file (AAC encoding from tap is complex)
        let wavURL = fileURL.deletingPathExtension().appendingPathExtension("wav")
        let file = try AVAudioFile(forWriting: wavURL, settings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: recordingFormat.sampleRate,
            AVNumberOfChannelsKey: recordingFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])

        // Speech recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        // Start first recognition task
        self.recognitionRequest = request
        startRecognitionTask(with: request, recognizer: recognizer)

        // Install audio tap — sends buffers to the CURRENT recognition request and file.
        // recognitionRequest is swapped when recognition auto-restarts after vocal pauses.
        input.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            // Send to current speech recognizer request
            self?.recognitionRequest?.append(buffer)

            // Write to audio file
            do {
                try file.write(from: buffer)
            } catch {
                logger.error("Audio file write error: \(error.localizedDescription)")
            }

            // Compute audio level
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += abs(channelData[i])
            }
            let avg = sum / Float(max(frameLength, 1))
            let level = min(1.0, avg * 5) // Scale up for visibility

            Task { @MainActor in
                self?.audioLevel = level
            }
        }

        try engine.start()

        self.audioEngine = engine
        self.inputNode = input
        self.audioFile = file
        self.audioFileURL = wavURL
        self.accumulatedText = ""
        self.currentSessionText = ""
        self.liveTranscript = ""
        self.recordingStartTime = Date()
        self.accumulatedTime = 0
        self.state = .recording

        startElapsedTimer()

        logger.info("Started live recording + transcription to \(wavURL.lastPathComponent)")
    }

    // MARK: - Pause / Resume

    /// Pause recording and transcription.
    func pauseRecording() {
        guard state == .recording else { return }

        audioEngine?.pause()

        // Finalize current recognition segment — save whatever we have
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        // Commit current session text
        commitCurrentSession()

        // Accumulate elapsed time
        if let start = recordingStartTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }
        recordingStartTime = nil
        state = .paused

        logger.info("Recording paused")
    }

    /// Resume recording and transcription.
    func resumeRecording() throws {
        guard state == .paused, let engine = audioEngine,
              let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        // Start a new recognition request for this segment
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        self.recognitionRequest = request
        startRecognitionTask(with: request, recognizer: recognizer)

        // Update the tap to send to the new request
        // (tap is still installed on the input node, engine just needs to restart)
        inputNode?.removeTap(onBus: 0)
        let recordingFormat = engine.inputNode.outputFormat(forBus: 0)
        let file = self.audioFile

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            // Send to CURRENT recognition request (follows restarts)
            self?.recognitionRequest?.append(buffer)

            if let file {
                do { try file.write(from: buffer) } catch {
                    logger.error("Audio file write error: \(error.localizedDescription)")
                }
            }

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength { sum += abs(channelData[i]) }
            let avg = sum / Float(max(frameLength, 1))
            let level = min(1.0, avg * 5)
            Task { @MainActor in self?.audioLevel = level }
        }

        try engine.start()
        self.inputNode = engine.inputNode
        recordingStartTime = Date()
        state = .recording

        logger.info("Recording resumed — new recognition segment")
    }

    // MARK: - Stop

    /// Stop recording and finalize transcription.
    func stopRecording() {
        guard state == .recording || state == .paused else { return }

        state = .stopping

        // Stop the audio engine and tap
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)

        // End recognition
        recognitionRequest?.endAudio()

        // Accumulate final elapsed time
        if let start = recordingStartTime {
            accumulatedTime += Date().timeIntervalSince(start)
        }
        elapsedTime = accumulatedTime

        // Stop timer
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0

        // Finalize transcript — commit whatever we have
        commitCurrentSession()

        // Clean up
        audioEngine = nil
        inputNode = nil
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil

        // Deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        state = .idle
        logger.info("Stopped recording. Transcript: \(self.liveTranscript.prefix(100))...")
    }

    /// Cancel the current recording and delete the file.
    func cancelRecording() {
        let url = audioFileURL

        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
        elapsedTime = 0

        audioEngine = nil
        inputNode = nil
        recognitionRequest = nil
        recognitionTask = nil
        audioFile = nil

        if let url { try? FileManager.default.removeItem(at: url) }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        accumulatedText = ""
        currentSessionText = ""
        liveTranscript = ""
        audioFileURL = nil
        state = .idle

        logger.info("Recording cancelled")
    }

    /// Reset state for a new capture.
    func reset() {
        state = .idle
        liveTranscript = ""
        accumulatedText = ""
        currentSessionText = ""
        audioLevel = 0
        elapsedTime = 0
        audioFileURL = nil
    }

    // MARK: - Private Helpers

    /// Start a recognition task for the given request. Auto-restarts on `isFinal`
    /// so that vocal pauses don't kill transcription.
    private func startRecognitionTask(with request: SFSpeechAudioBufferRecognitionRequest, recognizer: SFSpeechRecognizer) {
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString

                    if result.isFinal {
                        self.currentSessionText = text
                        self.commitCurrentSession()
                        if self.state == .recording {
                            self.restartRecognition()
                        }
                        return
                    }

                    // Detect recognizer internal reset after silence:
                    // If new partial doesn't start with the beginning of our
                    // previous text, the recognizer started a new utterance.
                    let prev = self.currentSessionText
                    if !prev.isEmpty && !text.isEmpty {
                        let checkLen = min(prev.count, 20)
                        let prevPrefix = String(prev.prefix(checkLen))
                        if !text.hasPrefix(prevPrefix) {
                            // New utterance — save old text first
                            self.commitCurrentSession()
                        }
                    }

                    self.currentSessionText = text
                    self.lastPartialTime = Date()
                    self.updateLiveTranscript()
                }

                if error != nil {
                    self.commitCurrentSession()
                    if self.state == .recording {
                        self.restartRecognition()
                    }
                }
            }
        }
    }

    /// Create a new recognition request and task, replacing the current one.
    /// Called automatically when the recognizer finalizes a segment (vocal pause).
    private func restartRecognition() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.addsPunctuation = true
        newRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        self.recognitionRequest = newRequest
        startRecognitionTask(with: newRequest, recognizer: recognizer)

        logger.debug("Recognition auto-restarted — accumulated \(self.accumulatedText.count) chars")
    }

    /// Move current session text into the accumulated transcript.
    /// Short silence → dash separator. Long silence → paragraph break.
    private func commitCurrentSession() {
        if !currentSessionText.isEmpty {
            if accumulatedText.isEmpty {
                accumulatedText = currentSessionText
            } else {
                let gap = Date().timeIntervalSince(lastPartialTime)
                let separator = gap >= paragraphGapSeconds ? "\n\n" : " — "
                accumulatedText += separator + currentSessionText
            }
            currentSessionText = ""
            updateLiveTranscript()
        }
    }

    private func updateLiveTranscript() {
        if currentSessionText.isEmpty {
            liveTranscript = accumulatedText
        } else if accumulatedText.isEmpty {
            liveTranscript = currentSessionText
        } else {
            // Show current session joined with a dash for now
            // (will be finalized as dash or paragraph when committed)
            liveTranscript = accumulatedText + " — " + currentSessionText
        }
    }

    private func startElapsedTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = self.accumulatedTime + Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: - File Management

    /// Relative path from Documents directory for a voice capture URL.
    static func relativePath(for url: URL) -> String {
        "VoiceCaptures/\(url.lastPathComponent)"
    }

    /// Delete an audio file by its relative path.
    static func deleteRecording(relativePath: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Errors

    enum RecordingError: LocalizedError {
        case speechNotAvailable
        case noAudioInput

        var errorDescription: String? {
            switch self {
            case .speechNotAvailable: return "Speech recognition is not available on this device."
            case .noAudioInput: return "No audio input device found."
            }
        }
    }
}
