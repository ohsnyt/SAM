//
//  IntroSequenceCoordinator.swift
//  SAM
//
//  In-App Guidance — Welcome sequence and intro video
//

import Foundation
import os.log

/// Manages the first-launch welcome sequence: 4-page onboarding + optional intro video replay.
@MainActor
@Observable
final class IntroSequenceCoordinator {

    static let shared = IntroSequenceCoordinator()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "IntroSequence")

    // MARK: - Observable State

    var showIntroSequence = false
    var currentPage = 0

    /// Total number of welcome pages
    let pageCount = 4

    // MARK: - UserDefaults Keys

    private static let hasSeenKey = "sam.intro.hasSeenIntroSequence"

    var hasSeenIntro: Bool {
        UserDefaults.standard.bool(forKey: Self.hasSeenKey)
    }

    // MARK: - Public API

    /// Check if the intro should be shown and trigger it.
    func checkAndShow() {
        guard !hasSeenIntro else {
            logger.debug("Intro already seen — skipping")
            return
        }
        logger.debug("First launch — showing welcome sequence")
        currentPage = 0
        showIntroSequence = true

        // Ensure tips are on — the intro directs the user to them.
        SAMTipState.enableTips()
    }

    /// Show the welcome sequence again (e.g., from Settings "Replay Welcome").
    func replay() {
        logger.debug("Replaying welcome sequence")
        currentPage = 0
        UserDefaults.standard.set(false, forKey: Self.hasSeenKey)
        showIntroSequence = true
    }

    /// Advance to the next page, or complete if on the last page.
    func nextPage() {
        if currentPage < pageCount - 1 {
            currentPage += 1
        } else {
            markComplete()
        }
    }

    /// Go back one page.
    func previousPage() {
        if currentPage > 0 {
            currentPage -= 1
        }
    }

    /// Skip the welcome sequence and mark as complete.
    func skip() {
        logger.debug("Welcome skipped by user")
        markComplete()
    }

    /// Mark the intro as complete and dismiss.
    func markComplete() {
        UserDefaults.standard.set(true, forKey: Self.hasSeenKey)
        showIntroSequence = false
        currentPage = 0
    }
}
