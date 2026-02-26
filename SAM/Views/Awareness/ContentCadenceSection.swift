//
//  ContentCadenceSection.swift
//  SAM
//
//  Created on February 26, 2026.
//  Phase W: Content Assist & Social Media Coaching
//
//  Review & Analytics section showing posting cadence per platform,
//  weekly streak, and inline post logging.
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "ContentCadenceSection")

struct ContentCadenceSection: View {

    @State private var platformStats: [ContentPlatform: PlatformStat] = [:]
    @State private var weeklyStreak: Int = 0
    @State private var logPlatform: ContentPlatform = .linkedin
    @State private var logTopic: String = ""
    @State private var isLoaded = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Image(systemName: "text.badge.star")
                    .foregroundStyle(.mint)
                Text("Content & Posting")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            // Platform cadence cards
            HStack(spacing: 12) {
                ForEach([ContentPlatform.linkedin, .facebook, .instagram], id: \.rawValue) { platform in
                    platformCard(for: platform)
                }
            }
            .padding()

            // Posting streak
            if weeklyStreak > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("\(weeklyStreak)-week posting streak")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            // Inline log-a-post row
            HStack(spacing: 8) {
                Picker("", selection: $logPlatform) {
                    ForEach([ContentPlatform.linkedin, .facebook, .instagram], id: \.rawValue) { platform in
                        Text(platform.rawValue).tag(platform)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                TextField("Topic...", text: $logTopic)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                Button("Log Post") {
                    logPost()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(logTopic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            guard !isLoaded else { return }
            loadStats()
            isLoaded = true
        }
    }

    // MARK: - Platform Card

    @ViewBuilder
    private func platformCard(for platform: ContentPlatform) -> some View {
        let stat = platformStats[platform] ?? PlatformStat(daysSince: nil, monthCount: 0)

        VStack(spacing: 6) {
            Image(systemName: platform.icon)
                .font(.title3)
                .foregroundStyle(platform.color)

            Text(platform.rawValue)
                .font(.caption)
                .fontWeight(.medium)

            if let days = stat.daysSince {
                Text("\(days)d ago")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(cadenceColor(days: days))
            } else {
                Text("—")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Text("\(stat.monthCount) this month")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(platform.color.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func cadenceColor(days: Int) -> Color {
        if days <= 7 { return .green }
        if days <= 14 { return .orange }
        return .red
    }

    private func loadStats() {
        let repo = ContentPostRepository.shared
        var stats: [ContentPlatform: PlatformStat] = [:]
        let counts = (try? repo.postCountByPlatform(days: 30)) ?? [:]

        for platform in [ContentPlatform.linkedin, .facebook, .instagram] {
            let days = try? repo.daysSinceLastPost(platform: platform)
            stats[platform] = PlatformStat(
                daysSince: days,
                monthCount: counts[platform] ?? 0
            )
        }

        platformStats = stats
        weeklyStreak = (try? repo.weeklyPostingStreak()) ?? 0
    }

    private func logPost() {
        let topic = logTopic.trimmingCharacters(in: .whitespaces)
        guard !topic.isEmpty else { return }

        do {
            try ContentPostRepository.shared.logPost(platform: logPlatform, topic: topic)
            logTopic = ""
            loadStats()
        } catch {
            logger.error("Failed to log post: \(error.localizedDescription)")
        }
    }
}

// MARK: - Supporting Types

private struct PlatformStat {
    let daysSince: Int?
    let monthCount: Int
}
