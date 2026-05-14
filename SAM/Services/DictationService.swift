//
//  DictationService.swift
//  SAM
//
//  Phase L: Notes Pro — On-device speech recognition for voice note entries
//

import Foundation
import Speech
import AVFoundation
import AVFAudio
import os.log

/// On-device speech recognition for voice note entries (Phase L)
///
/// Uses @MainActor because AVAudioEngine and SFSpeechRecognizer
/// require main-thread operations for reliable callback delivery.
@MainActor
@Observable
final class DictationService {

    static let shared = DictationService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DictationService")

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Silence Detection

    /// Amplitude below which a buffer counts as "silent"
    private let silenceAmplitudeThreshold: Float = 0.01

    /// Seconds of silence before auto-stopping (UserDefaults-backed).
    /// Default raised to 4.0s so a short thinking pause doesn't end the session;
    /// shorter pauses now insert paragraph breaks instead (see paragraphPauseSeconds).
    @ObservationIgnored
    var silenceTimeoutSeconds: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "sam.dictation.silenceTimeout")
            return stored > 0 ? stored : 4.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "sam.dictation.silenceTimeout") }
    }

    /// Seconds of silence that trigger a mid-stream paragraph break event.
    /// Must be < silenceTimeoutSeconds. Default 2.0s.
    @ObservationIgnored
    var paragraphPauseSeconds: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "sam.dictation.paragraphPause")
            return stored > 0 ? stored : 2.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "sam.dictation.paragraphPause") }
    }

    // MARK: - Types

    enum DictationAvailability: Sendable {
        case available
        case notAuthorized
        case notAvailable
        case restricted
    }

    struct DictationResult: Sendable {
        let text: String
        let isFinal: Bool
        let confidence: Float?
        /// True when this event is a mid-stream paragraph break (text is empty,
        /// the consumer should bake the current segment and insert "\n\n").
        let isParagraphBreak: Bool

        init(text: String, isFinal: Bool, confidence: Float?, isParagraphBreak: Bool = false) {
            self.text = text
            self.isFinal = isFinal
            self.confidence = confidence
            self.isParagraphBreak = isParagraphBreak
        }
    }

    // MARK: - Authorization

    func checkAvailability() -> DictationAvailability {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            logger.warning("Speech recognizer not available")
            return .notAvailable
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return .available
        case .denied:
            return .notAuthorized
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notAuthorized
        @unknown default:
            return .notAvailable
        }
    }

    func requestAuthorization() async -> Bool {
        // Request speech recognition permission
        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        guard speechAuthorized else {
            logger.warning("Speech recognition authorization denied")
            return false
        }

        // Request microphone permission (required separately on macOS sandbox)
        let micAuthorized = await AVCaptureDevice.requestAccess(for: .audio)
        if !micAuthorized {
            logger.warning("Microphone access denied")
        }

        return micAuthorized
    }

    // MARK: - Recognition

    func startRecognition() async throws -> AsyncStream<DictationResult> {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            logger.error("Speech recognizer not available or nil")
            throw DictationError.notAvailable
        }

        // Log speech recognition auth status
        let speechAuthStatus = SFSpeechRecognizer.authorizationStatus()
        logger.debug("Speech recognition auth status: \(String(describing: speechAuthStatus))")

        // Check and request microphone permission if needed
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.debug("Microphone permission status: \(String(describing: micStatus))")

        switch micStatus {
        case .notDetermined:
            logger.debug("Requesting microphone permission...")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                logger.error("Microphone permission denied by user")
                throw DictationError.notAuthorized
            }
            logger.info("Microphone permission granted")
        case .authorized:
            logger.debug("Microphone permission: authorized")
        case .denied:
            logger.error("Microphone permission: DENIED — user must enable in System Settings")
            throw DictationError.notAuthorized
        case .restricted:
            logger.error("Microphone permission: restricted")
            throw DictationError.notAuthorized
        @unknown default:
            logger.warning("Microphone permission: unknown status")
        }

        // Stop any existing recognition
        stopRecognition()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        logger.debug("On-device recognition supported: \(recognizer.supportsOnDeviceRecognition)")

        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        // Log detailed audio format info
        logger.debug("Native input format — sampleRate: \(nativeFormat.sampleRate), channels: \(nativeFormat.channelCount), interleaved: \(nativeFormat.isInterleaved)")

        // Validate format — zero channels or zero sample rate means no input device
        guard nativeFormat.channelCount > 0, nativeFormat.sampleRate > 0 else {
            logger.error("Invalid audio format: channels=\(nativeFormat.channelCount), sampleRate=\(nativeFormat.sampleRate) — no input device?")
            throw DictationError.audioEngineError("No audio input device available")
        }

        // Use a known-good format for speech recognition: mono, native sample rate
        // SFSpeechRecognizer works best with single-channel audio
        let recordingFormat: AVAudioFormat
        if nativeFormat.channelCount > 1 {
            if let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1) {
                logger.debug("Converting from \(nativeFormat.channelCount) channels to mono for speech recognition")
                recordingFormat = monoFormat
            } else {
                logger.warning("Could not create mono format, using native format")
                recordingFormat = nativeFormat
            }
        } else {
            recordingFormat = nativeFormat
        }

        logger.debug("Recording format — sampleRate: \(recordingFormat.sampleRate), channels: \(recordingFormat.channelCount)")

        let logger = self.logger
        var bufferCount = 0
        var consecutiveSilentBuffers = 0
        var hasReceivedSpeech = false
        var didEndAudio = false
        var paragraphBreakEmittedThisSilence = false
        let silenceThreshold = self.silenceAmplitudeThreshold
        let sampleRate = recordingFormat.sampleRate
        let silenceTimeout = self.silenceTimeoutSeconds
        let paragraphPause = min(self.paragraphPauseSeconds, max(silenceTimeout - 0.5, 0.5))

        // Calculate how many consecutive silent buffers = silence timeout
        // Each buffer is ~4800 frames at 48kHz = 0.1s
        let framesPerBuffer: Double = 4800
        let secondsPerBuffer = framesPerBuffer / sampleRate
        let silentBuffersForTimeout = Int(silenceTimeout / secondsPerBuffer)
        let silentBuffersForParagraphBreak = Int(paragraphPause / secondsPerBuffer)
        logger.debug("Silence: paragraph-break at \(paragraphPause)s (\(silentBuffersForParagraphBreak) buffers), end at \(silenceTimeout)s (\(silentBuffersForTimeout) buffers)")

        return AsyncStream { continuation in
            self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result = result {
                    let bestTranscription = result.bestTranscription
                    let confidence: Float? = bestTranscription.segments.isEmpty
                        ? nil
                        : bestTranscription.segments.map(\.confidence).reduce(0, +) / Float(bestTranscription.segments.count)

                    logger.debug("Transcription result (isFinal=\(result.isFinal)): \"\(bestTranscription.formattedString)\"")

                    continuation.yield(DictationResult(
                        text: bestTranscription.formattedString,
                        isFinal: result.isFinal,
                        confidence: confidence
                    ))

                    if result.isFinal {
                        continuation.finish()
                    }
                }

                if let error {
                    logger.error("Recognition error: \(error.localizedDescription) (domain: \(error._domain), code: \(error._code))")
                    continuation.finish()
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { buffer, time in
                // Stop processing once endAudio has been called
                guard !didEndAudio else { return }

                bufferCount += 1

                // Compute max amplitude for this buffer
                let frameLength = buffer.frameLength
                var maxAmplitude: Float = 0
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<Int(frameLength) {
                        maxAmplitude = max(maxAmplitude, abs(data[i]))
                    }
                }

                // Log first few buffers
                if bufferCount <= 3 {
                    logger.debug("Audio buffer #\(bufferCount): frames=\(frameLength), maxAmplitude=\(maxAmplitude), time=\(time.sampleTime)")
                }

                // Silence detection
                if maxAmplitude < silenceThreshold {
                    consecutiveSilentBuffers += 1
                } else {
                    consecutiveSilentBuffers = 0
                    paragraphBreakEmittedThisSilence = false
                    hasReceivedSpeech = true
                }

                // Mid-stream paragraph break: shorter pause, doesn't end the session.
                // Fires once per silence window so consecutive silent buffers past the
                // threshold don't spam the consumer.
                if hasReceivedSpeech
                    && !paragraphBreakEmittedThisSilence
                    && consecutiveSilentBuffers >= silentBuffersForParagraphBreak
                    && consecutiveSilentBuffers < silentBuffersForTimeout {
                    paragraphBreakEmittedThisSilence = true
                    continuation.yield(DictationResult(
                        text: "",
                        isFinal: false,
                        confidence: nil,
                        isParagraphBreak: true
                    ))
                }

                // Auto-stop after silence timeout (only if we've received some speech first)
                if hasReceivedSpeech && consecutiveSilentBuffers >= silentBuffersForTimeout {
                    logger.debug("Auto-stopping after \(String(format: "%.1f", Double(consecutiveSilentBuffers) * secondsPerBuffer))s of silence")
                    didEndAudio = true
                    request.endAudio()
                    return
                }

                request.append(buffer)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
                logger.debug("Audio engine started for dictation (bufferSize=4096, format=\(recordingFormat.sampleRate)Hz/\(recordingFormat.channelCount)ch)")
            } catch {
                logger.error("Audio engine failed to start: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    func stopRecognition() {
        logger.debug("Stopping recognition — engine running: \(self.audioEngine.isRunning)")
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        logger.debug("Recognition stopped and cleaned up")
    }

    // MARK: - Accumulator

    /// Builds the displayed dictation text from a stream of DictationResult events.
    /// Encapsulates segment-collapse detection (utterance breaks within a phrase)
    /// and paragraph-break handling (longer pauses), and strips the trailing
    /// "new paragraph" voice command when it precedes a break.
    ///
    /// Lifecycle: call `reset(initialText:)` when starting a new dictation,
    /// then feed each DictationResult through `process(_:)` and assign the
    /// returned String to your bound text.
    @MainActor
    struct Accumulator {
        /// Completed text including all baked-in segment/paragraph separators.
        private(set) var completedText: String = ""
        private var lastSegmentPeakLength: Int = 0
        private var currentSegmentText: String = ""

        mutating func reset(initialText: String = "") {
            let trimmed = initialText.trimmingCharacters(in: .whitespacesAndNewlines)
            completedText = trimmed.isEmpty ? "" : trimmed + " "
            lastSegmentPeakLength = 0
            currentSegmentText = ""
        }

        /// Process a result and return the new full display text.
        mutating func process(_ result: DictationResult) -> String {
            if result.isParagraphBreak {
                let cleaned = Self.stripTrailingNewParagraphCommand(currentSegmentText)
                if !cleaned.isEmpty {
                    completedText += cleaned + "\n\n"
                } else if !completedText.isEmpty && !completedText.hasSuffix("\n\n") {
                    // Convert any trailing whitespace into a paragraph break.
                    completedText = completedText
                        .trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
                }
                currentSegmentText = ""
                lastSegmentPeakLength = 0
                return completedText
            }

            let text = result.text

            // Detect a fresh utterance via text length collapse — SFSpeechRecognizer
            // returns a cumulative formattedString for the current utterance, then
            // restarts shorter when a new one begins.
            if text.count < lastSegmentPeakLength / 2 && lastSegmentPeakLength > 5 {
                if !currentSegmentText.isEmpty {
                    completedText += currentSegmentText + " "
                }
                lastSegmentPeakLength = 0
            }

            lastSegmentPeakLength = max(lastSegmentPeakLength, text.count)
            currentSegmentText = text

            return completedText + text
        }

        /// Strip a trailing "new paragraph" voice command (with optional punctuation).
        /// Only applied at paragraph-break boundaries so a sentence like
        /// "this is a new paragraph in my essay" — which never pauses — is preserved.
        private static func stripTrailingNewParagraphCommand(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let pattern = #"(?i)\bnew\s+paragraph[\.,!?]*$"#
            if let range = trimmed.range(of: pattern, options: .regularExpression) {
                return String(trimmed[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }
    }

    // MARK: - Errors

    enum DictationError: Error, LocalizedError {
        case notAvailable
        case notAuthorized
        case audioEngineError(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                return "Speech recognition is not available on this device"
            case .notAuthorized:
                return "Speech recognition permission not granted"
            case .audioEngineError(let message):
                return "Audio error: \(message)"
            }
        }
    }
}
