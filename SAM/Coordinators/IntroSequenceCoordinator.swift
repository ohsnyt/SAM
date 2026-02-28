//
//  IntroSequenceCoordinator.swift
//  SAM
//
//  Phase AB: In-App Guidance — First-launch narrated intro sequence
//

import Foundation
import os.log

/// Manages the first-launch intro sequence: slide progression, narration sync, and completion state.
@MainActor
@Observable
final class IntroSequenceCoordinator {

    static let shared = IntroSequenceCoordinator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "IntroSequence")

    // MARK: - Observable State

    var showIntroSequence = false
    var currentSlide: IntroSlide = .welcome
    var isPlaying = false
    var isPaused = false

    // MARK: - UserDefaults Keys

    private static let hasSeenKey = "sam.intro.hasSeenIntroSequence"

    var hasSeenIntro: Bool {
        UserDefaults.standard.bool(forKey: Self.hasSeenKey)
    }

    // MARK: - Slide Definitions

    enum IntroSlide: Int, CaseIterable, Sendable {
        case welcome
        case relationships
        case coaching
        case business
        case privacy
        case getStarted

        var narrationText: String {
            switch self {
            case .welcome:
                return "Welcome to SAM. I'm your intelligent business coaching assistant, designed to help you build stronger relationships and grow your practice."
            case .relationships:
                return "I observe your interactions — calendar, email, messages — and help you stay on top of every relationship. I'll tell you who needs attention and why."
            case .coaching:
                return "Each day, I suggest specific actions — who to follow up with, what to prepare for, how to move your pipeline forward. Every suggestion connects to why it matters."
            case .business:
                return "Beyond individual relationships, I analyze your entire practice. I look at pipeline health, production trends, time allocation and more, all to guide your business strategy."
            case .privacy:
                return "Everything stays on your Apple devices. — All intelligence runs locally using Apple's on-device processing."
            case .getStarted:
                return "Your Today view is ready with your first briefing and coaching suggestions. — Let's build something great together."
            }
        }

        var headline: String {
            switch self {
            case .welcome:       return "Meet SAM"
            case .relationships: return "Relationship Intelligence"
            case .coaching:      return "Daily Coaching"
            case .business:      return "Business Strategy"
            case .privacy:       return "Private by Design"
            case .getStarted:    return "Ready to Go"
            }
        }

        var subtitle: String {
            switch self {
            case .welcome:       return "Your Business Coaching Assistant"
            case .relationships: return "Stay on top of every relationship"
            case .coaching:      return "Know what to do next — and why"
            case .business:      return "See the big picture"
            case .privacy:       return "100% on-device intelligence"
            case .getStarted:    return "Your Today view is waiting"
            }
        }

        var symbolName: String {
            switch self {
            case .welcome:       return "brain.head.profile"
            case .relationships: return "person.2.circle"
            case .coaching:      return "checkmark.circle"
            case .business:      return "chart.bar.horizontal.page"
            case .privacy:       return "lock.shield"
            case .getStarted:    return "sun.max"
            }
        }

        /// Fallback duration in seconds if speech synthesis silently fails.
        /// At rate 0.5 with pre/post delays, each slide takes ~12–18 seconds.
        /// These are generous — the fallback timer is a safety net, not the
        /// primary advance mechanism (that's the didFinish delegate callback).
        var fallbackDuration: Double {
            switch self {
            case .welcome:       return 20.0
            case .relationships: return 20.0
            case .coaching:      return 20.0
            case .business:      return 20.0
            case .privacy:       return 15.0
            case .getStarted:    return 20.0
            }
        }

        var next: IntroSlide? {
            let all = IntroSlide.allCases
            guard let currentIndex = all.firstIndex(of: self),
                  currentIndex + 1 < all.count else { return nil }
            return all[currentIndex + 1]
        }
    }

    // MARK: - Private

    private var fallbackTimer: Task<Void, Never>?

    /// The slide we're currently narrating. Used to prevent double-advance:
    /// both the didFinish callback and the fallback timer check this before advancing.
    /// Whichever fires first sets it to nil, blocking the other.
    private var narratingSlide: IntroSlide?

    // MARK: - Public API

    /// Check if the intro should be shown and trigger it.
    func checkAndShow() {
        guard !hasSeenIntro else {
            logger.info("Intro already seen — skipping")
            return
        }
        logger.info("First launch — showing intro sequence")
        showIntroSequence = true
    }

    /// Begin narrated playback from the current slide.
    func startPlayback() {
        guard !isPlaying else { return }
        isPlaying = true
        isPaused = false
        logger.info("Starting intro playback from slide: \(self.currentSlide.rawValue)")
        narrateCurrentSlide()
    }

    /// Pause narration.
    func pause() {
        isPaused = true
        NarrationService.shared.pause()
        fallbackTimer?.cancel()
        logger.info("Intro paused")
    }

    /// Resume narration.
    func resume() {
        isPaused = false
        if NarrationService.shared.isSpeaking {
            NarrationService.shared.resume()
        } else {
            // Narration was stopped; restart current slide
            narrateCurrentSlide()
        }
        logger.info("Intro resumed")
    }

    /// Skip the entire intro and mark as complete.
    func skip() {
        logger.info("Intro skipped by user")
        stopPlayback()
        markComplete()
    }

    /// Advance from the given slide to the next. Guarded by `narratingSlide` token
    /// to prevent double-advance when both didFinish and the fallback timer fire.
    /// Inter-slide pause in seconds. Applied by the coordinator between
    /// didFinish and the next slide's narration start.
    private static let interSlideDelay: TimeInterval = 0.75

    private func advanceFromSlide(_ slide: IntroSlide) {
        // Consume the token — only the first caller gets through
        guard narratingSlide == slide else {
            logger.info("Ignoring duplicate advance for slide \(slide.rawValue) (already advanced)")
            return
        }
        narratingSlide = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil

        guard let next = slide.next else {
            // Last slide finished
            logger.info("Intro sequence complete — all slides shown")
            stopPlayback()
            markComplete()
            return
        }

        currentSlide = next
        logger.info("Advancing to slide: \(next.rawValue)")

        if !isPaused {
            // Brief pause between slides for visual/auditory breathing room.
            // Handled here (not in AVSpeechUtterance delays) so we have
            // precise control and avoid synthesizer-internal timing quirks.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.interSlideDelay))
                guard let self, self.isPlaying, !self.isPaused else { return }
                self.narrateCurrentSlide()
            }
        }
    }

    /// Legacy entry point for external callers (pause/resume).
    func advanceToNextSlide() {
        advanceFromSlide(currentSlide)
    }

    /// Mark the intro as complete and dismiss.
    func markComplete() {
        UserDefaults.standard.set(true, forKey: Self.hasSeenKey)
        showIntroSequence = false
        currentSlide = .welcome
        isPlaying = false
        isPaused = false
    }

    // MARK: - Private

    private func narrateCurrentSlide() {
        let slide = currentSlide
        narratingSlide = slide

        NarrationService.shared.speak(slide.narrationText) { [weak self] in
            Task { @MainActor in
                self?.logger.info("onFinish callback for slide \(slide.rawValue)")
                self?.advanceFromSlide(slide)
            }
        }

        // Fallback timer in case speech synthesis silently fails (no didFinish).
        // Duration is generous — this is a safety net, not the primary advance mechanism.
        fallbackTimer?.cancel()
        fallbackTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(slide.fallbackDuration + 10.0))
            guard !Task.isCancelled else { return }
            if self?.narratingSlide == slide && self?.isPlaying == true {
                self?.logger.warning("Fallback timer fired for slide \(slide.rawValue) — force advancing")
                self?.advanceFromSlide(slide)
            }
        }
    }

    private func stopPlayback() {
        NarrationService.shared.stop()
        fallbackTimer?.cancel()
        fallbackTimer = nil
        narratingSlide = nil
        isPlaying = false
        isPaused = false
    }
}
