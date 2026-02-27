//
//  BestPracticesService.swift
//  SAM
//
//  Created on February 27, 2026.
//  Actor service for loading and querying the best practices knowledge base.
//

import Foundation
import os.log

/// Manages the best practices knowledge base — bundled entries plus user-contributed practices.
actor BestPracticesService {

    static let shared = BestPracticesService()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "BestPracticesService")

    private var bundledPractices: [BestPractice] = []
    private var userPractices: [BestPractice] = []
    private var isLoaded = false

    private init() {}

    // MARK: - Loading

    /// Load bundled practices from Resources/BestPractices.json and user practices from UserDefaults.
    func loadIfNeeded() {
        guard !isLoaded else { return }

        // Load bundled
        if let url = Bundle.main.url(forResource: "BestPractices", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([BestPractice].self, from: data) {
            bundledPractices = decoded
            logger.info("Loaded \(decoded.count) bundled best practices")
        } else {
            logger.warning("Could not load BestPractices.json from bundle")
        }

        // Load user-contributed from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "userBestPractices"),
           let decoded = try? JSONDecoder().decode([BestPractice].self, from: data) {
            userPractices = decoded
            logger.info("Loaded \(decoded.count) user best practices")
        }

        isLoaded = true
    }

    // MARK: - Querying

    /// Return up to `limit` practices matching the given category.
    /// Returns a mix of user-contributed (prioritized) + bundled practices,
    /// including `general` category entries as fallback.
    func practices(for category: String, limit: Int = 3) -> [BestPractice] {
        let allPractices = userPractices + bundledPractices
        let matching = allPractices.filter { $0.category == category || $0.category == "general" }
        // Prioritize category-specific over general
        let sorted = matching.sorted { lhs, rhs in
            if lhs.category == category && rhs.category != category { return true }
            if lhs.category != category && rhs.category == category { return false }
            return false
        }
        return Array(sorted.prefix(limit))
    }

    /// All practices (bundled + user) for display in Settings.
    func allPractices() -> [BestPractice] {
        return bundledPractices + userPractices
    }

    /// All user-contributed practices.
    func allUserPractices() -> [BestPractice] {
        return userPractices
    }

    // MARK: - User CRUD

    func addUserPractice(_ practice: BestPractice) {
        userPractices.append(practice)
        persistUserPractices()
    }

    func removeUserPractice(id: String) {
        userPractices.removeAll { $0.id == id }
        persistUserPractices()
    }

    func updateUserPractice(_ practice: BestPractice) {
        if let index = userPractices.firstIndex(where: { $0.id == practice.id }) {
            userPractices[index] = practice
            persistUserPractices()
        }
    }

    private func persistUserPractices() {
        if let data = try? JSONEncoder().encode(userPractices) {
            UserDefaults.standard.set(data, forKey: "userBestPractices")
        }
    }
}
