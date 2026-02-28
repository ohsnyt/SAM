//
//  NarrationService.swift
//  SAM
//
//  Phase AB: In-App Guidance — Direct speech synthesis for narrated intros and future TTS
//

import Foundation
import AVFoundation
import os.log

let RATE: Float = 0.5
let PITCH_MULTIPLIER: Float = 1.05

/// On-device speech synthesis using a persistent AVSpeechSynthesizer for
/// natural-sounding narration with proper pauses and intonation.
///
/// Uses a single long-lived synthesizer to avoid audio session teardown/setup
/// between utterances, which causes `AUCrashHandler` errors and empty buffers.
@MainActor
@Observable
final class NarrationService {

    static let shared = NarrationService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "NarrationService")

    // MARK: - Observable State

    var isSpeaking = false

    // MARK: - Private

    /// Single long-lived synthesizer — reused across all utterances to avoid
    /// audio session churn (AUCrashHandler errors, empty AVAudioBuffers).
    private let synthesizer = AVSpeechSynthesizer()
    private let speechDelegate = SpeechDelegate()
    private var onFinishCallback: (@Sendable () -> Void)?

    /// Best available Samantha voice (American English), resolved once at init.
    /// Premium voices are Siri-optimized and produce empty audio buffers with
    /// AVSpeechSynthesizer on macOS, so we prefer enhanced quality instead.
    static let preferredVoice: AVSpeechSynthesisVoice? = {
        // Samantha — the classic macOS voice
        let samanthaIDs = [
            "com.apple.voice.enhanced.en-US.Samantha",
            "com.apple.voice.compact.en-US.Samantha",
            "com.apple.voice.super-compact.en-US.Samantha",
            "com.apple.voice.premium.en-US.Samantha",  // last resort — may stutter
        ]
        for id in samanthaIDs {
            if let voice = AVSpeechSynthesisVoice(identifier: id) {
                return voice
            }
        }
        // Try best available en-US voice by quality (skip premium tier)
        let usVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-US" }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        if let best = usVoices.first(where: { $0.quality.rawValue < 3 }) ?? usVoices.first {
            return best
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }()

    private init() {
        synthesizer.delegate = speechDelegate
        if let v = Self.preferredVoice {
            logger.info("Narration voice: \(v.name) (\(v.identifier), quality \(v.quality.rawValue))")
        }
    }

    // MARK: - Public API

    /// Speak the given text using the persistent AVSpeechSynthesizer.
    /// Natural pauses from punctuation (periods, commas, em-dashes) are preserved.
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - onFinish: Called on @MainActor when the utterance finishes naturally.
    ///              NOT called if the utterance is stopped/cancelled by a subsequent
    ///              call to `speak()` or `stop()`.
    func speak(_ text: String, onFinish: @escaping @Sendable () -> Void) {
        // Silence any in-progress speech WITHOUT triggering the old callback.
        // Detach the delegate callback first so didCancel doesn't fire the old onFinish.
        speechDelegate.onFinish = nil
        onFinishCallback = nil

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = RATE
        utterance.pitchMultiplier = PITCH_MULTIPLIER
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        utterance.voice = Self.preferredVoice

        // Wire up the new callback
        self.onFinishCallback = onFinish
        speechDelegate.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logger.info("Delegate: didFinish fired")
                self.isSpeaking = false
                let cb = self.onFinishCallback
                self.onFinishCallback = nil
                self.speechDelegate.onFinish = nil
                cb?()
            }
        }

        self.isSpeaking = true
        synthesizer.speak(utterance)
        logger.info("Speaking: \"\(text.prefix(50))...\"")
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
        logger.info("Narration paused")
    }

    func resume() {
        synthesizer.continueSpeaking()
        logger.info("Narration resumed")
    }

    func stop() {
        speechDelegate.onFinish = nil
        onFinishCallback = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
}

// MARK: - AVSpeechSynthesizerDelegate

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: (() -> Void)?
    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SpeechDelegate")

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        logger.info("didStart: \"\(utterance.speechString.prefix(40))...\"")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        logger.info("didFinish: \"\(utterance.speechString.prefix(40))...\"")
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Intentionally NOT calling onFinish here.
        // When we cancel speech (via stop() or starting a new utterance),
        // we've already cleared onFinish to prevent double-advance.
        logger.info("didCancel: \"\(utterance.speechString.prefix(40))...\"")
    }
}

