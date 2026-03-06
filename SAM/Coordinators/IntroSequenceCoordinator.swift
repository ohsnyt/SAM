//
//  IntroSequenceCoordinator.swift
//  SAM
//
//  Phase AB: In-App Guidance — First-launch intro video
//

import Foundation
import os.log

/// Manages the first-launch intro video: presentation state and completion tracking.
@MainActor
@Observable
final class IntroSequenceCoordinator {

    static let shared = IntroSequenceCoordinator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "IntroSequence")

    // MARK: - Observable State

    var showIntroSequence = false
    var videoFinished = false

    // MARK: - UserDefaults Keys

    private static let hasSeenKey = "sam.intro.hasSeenIntroSequence"

    var hasSeenIntro: Bool {
        UserDefaults.standard.bool(forKey: Self.hasSeenKey)
    }

    // MARK: - Public API

    /// Check if the intro should be shown and trigger it.
    func checkAndShow() {
        guard !hasSeenIntro else {
            logger.info("Intro already seen — skipping")
            return
        }
        logger.info("First launch — showing intro video")
        videoFinished = false
        showIntroSequence = true

        // Ensure tips are on — the intro directs the user to them.
        SAMTipState.enableTips()
    }

    /// Called when the video reaches the end.
    func videoDidFinish() {
        logger.info("Intro video finished playing")
        videoFinished = true
    }

    /// Skip the intro video and mark as complete.
    func skip() {
        logger.info("Intro skipped by user")
        markComplete()
    }

    /// Mark the intro as complete and dismiss.
    func markComplete() {
        UserDefaults.standard.set(true, forKey: Self.hasSeenKey)
        showIntroSequence = false
        videoFinished = false
    }
}
