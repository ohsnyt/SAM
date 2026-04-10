//
//  DiarizationService.swift
//  SAM
//
//  Speaker diarization: given a block of audio, find the voice regions,
//  extract per-region speaker embeddings, cluster them, and match the
//  agent cluster against an enrolled SpeakerProfile.
//
//  Pipeline:
//    1. VAD — energy-based voice activity detection
//    2. Embedding — SpeakerEmbeddingService per voice segment
//    3. Clustering — greedy agglomerative by cosine distance
//    4. Agent matching — compare cluster centroids to enrolled profile
//

import Foundation
import Accelerate
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DiarizationService")

@MainActor
@Observable
final class DiarizationService {

    static let shared = DiarizationService()

    // MARK: - Tunables

    /// Energy threshold relative to window mean for VAD (higher = more strict).
    var vadEnergyThreshold: Float = 0.015

    /// Minimum voice segment length in seconds — shorter segments are discarded.
    var minSegmentDuration: TimeInterval = 0.5

    /// Minimum silence between segments to split them.
    var minSilenceGap: TimeInterval = 0.3

    /// Cosine similarity threshold for merging clusters (higher = more strict / more speakers).
    /// Typical: 0.55–0.75 for MFCC features. Tuning will come from real-world testing.
    var clusterMergeThreshold: Float = 0.65

    /// Cosine similarity threshold for labeling as "Agent" against enrolled profile.
    var agentMatchThreshold: Float = 0.55

    // MARK: - Types

    struct VoiceSegment: Sendable, Equatable {
        let start: TimeInterval  // relative to input buffer start
        let end: TimeInterval
        var embedding: [Float]
        var clusterID: Int       // assigned by clustering; -1 before
    }

    struct DiarizationResult: Sendable {
        /// Voice segments with speaker cluster IDs assigned.
        let segments: [VoiceSegment]

        /// Cluster centroids keyed by cluster ID.
        let centroids: [Int: [Float]]

        /// Which cluster ID is the agent (nil if none matched or no enrolled profile).
        let agentClusterID: Int?

        /// Number of distinct speaker clusters detected.
        var speakerCount: Int { centroids.count }

        /// Get a display label for a cluster ID.
        func label(for clusterID: Int) -> String {
            if clusterID == agentClusterID { return "Agent" }
            // Other speakers numbered starting at 1
            let otherIDs = centroids.keys
                .filter { $0 != agentClusterID }
                .sorted()
            if let idx = otherIDs.firstIndex(of: clusterID) {
                return "Speaker \(idx + 1)"
            }
            return "Speaker"
        }
    }

    // MARK: - Main Entry Point

    /// Diarize a block of audio. `samples` must be mono Float PCM at `sampleRate`.
    /// `startOffset` is the time (in seconds) of the first sample relative to session start,
    /// used to preserve absolute timestamps in the returned segments.
    func diarize(
        samples: [Float],
        sampleRate: Double,
        startOffset: TimeInterval = 0,
        enrolledAgentEmbedding: [Float]? = nil
    ) -> DiarizationResult {
        // 1. VAD — find voice segments
        let rawSegments = detectVoiceSegments(samples: samples, sampleRate: sampleRate)
        guard !rawSegments.isEmpty else {
            return DiarizationResult(segments: [], centroids: [:], agentClusterID: nil)
        }

        // 2. Extract embeddings for each voice segment
        var segments: [VoiceSegment] = []
        for (startSample, endSample) in rawSegments {
            let chunk = Array(samples[startSample..<endSample])
            guard let embedding = SpeakerEmbeddingService.shared.embedding(for: chunk, sampleRate: sampleRate) else {
                continue
            }
            let startTime = Double(startSample) / sampleRate + startOffset
            let endTime = Double(endSample) / sampleRate + startOffset
            segments.append(VoiceSegment(
                start: startTime,
                end: endTime,
                embedding: embedding,
                clusterID: -1
            ))
        }

        guard !segments.isEmpty else {
            return DiarizationResult(segments: [], centroids: [:], agentClusterID: nil)
        }

        // 3. Cluster segments
        let clustered = clusterSegments(segments)

        // 4. Compute cluster centroids
        var centroids: [Int: [Float]] = [:]
        let clusterGroups = Dictionary(grouping: clustered, by: { $0.clusterID })
        for (clusterID, group) in clusterGroups {
            let embeddings = group.map(\.embedding)
            if let centroid = SpeakerEmbeddingService.centroid(of: embeddings) {
                centroids[clusterID] = centroid
            }
        }

        // 5. Match agent
        let agentClusterID = findAgentCluster(
            centroids: centroids,
            enrolledEmbedding: enrolledAgentEmbedding
        )

        logger.info("Diarization: \(segments.count) voice segments, \(centroids.count) clusters, agent=\(agentClusterID?.description ?? "none")")

        return DiarizationResult(
            segments: clustered,
            centroids: centroids,
            agentClusterID: agentClusterID
        )
    }

    // MARK: - VAD

    /// Energy-based voice activity detection. Returns (startSample, endSample) pairs.
    private func detectVoiceSegments(samples: [Float], sampleRate: Double) -> [(Int, Int)] {
        let frameSize = Int(sampleRate * 0.02) // 20ms frames
        guard frameSize > 0, samples.count >= frameSize else { return [] }

        // Compute per-frame RMS energy
        var energies: [Float] = []
        var idx = 0
        while idx + frameSize <= samples.count {
            let frame = samples[idx..<(idx + frameSize)]
            var ms: Float = 0
            frame.withContiguousStorageIfAvailable { ptr in
                vDSP_measqv(ptr.baseAddress!, 1, &ms, vDSP_Length(frameSize))
            }
            energies.append(sqrt(ms))
            idx += frameSize
        }

        guard !energies.isEmpty else { return [] }

        // Dynamic threshold: max(configured, 1.5x median)
        var sortedEnergies = energies
        sortedEnergies.sort()
        let median = sortedEnergies[sortedEnergies.count / 2]
        let threshold = max(vadEnergyThreshold, median * 1.5)

        // Find contiguous voiced frames
        var voicedFrames: [Bool] = energies.map { $0 >= threshold }

        // Smooth: fill small silences
        let minSilenceFrames = max(1, Int(minSilenceGap / 0.02))
        voicedFrames = smoothVoicedFrames(voicedFrames, minSilenceFrames: minSilenceFrames)

        // Extract segments
        var segments: [(Int, Int)] = []
        var segStart: Int? = nil
        let minSegmentFrames = max(1, Int(minSegmentDuration / 0.02))

        for (i, voiced) in voicedFrames.enumerated() {
            if voiced && segStart == nil {
                segStart = i
            } else if !voiced, let start = segStart {
                if i - start >= minSegmentFrames {
                    segments.append((start * frameSize, min(i * frameSize, samples.count)))
                }
                segStart = nil
            }
        }
        if let start = segStart, voicedFrames.count - start >= minSegmentFrames {
            segments.append((start * frameSize, min(voicedFrames.count * frameSize, samples.count)))
        }

        return segments
    }

    private func smoothVoicedFrames(_ frames: [Bool], minSilenceFrames: Int) -> [Bool] {
        guard minSilenceFrames > 0 else { return frames }
        var result = frames
        var i = 0
        while i < result.count {
            if !result[i] {
                // Count silence run
                var j = i
                while j < result.count && !result[j] { j += 1 }
                let silenceLen = j - i
                // If silence is shorter than min and has voice on both sides, fill it
                if silenceLen < minSilenceFrames && i > 0 && j < result.count && result[i - 1] && result[j] {
                    for k in i..<j { result[k] = true }
                }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: - Clustering

    /// Greedy agglomerative clustering by cosine similarity.
    /// Starts with each segment as its own cluster, merges the closest pair
    /// until no pair exceeds the merge threshold.
    private func clusterSegments(_ segments: [VoiceSegment]) -> [VoiceSegment] {
        guard !segments.isEmpty else { return segments }

        // Each segment starts in its own cluster
        var clusterOf = Array(0..<segments.count)
        var clusterEmbeddings: [[Float]] = segments.map(\.embedding)
        var clusterSizes = [Int](repeating: 1, count: segments.count)

        // Greedy merge loop
        while true {
            // Find the closest pair of clusters that exceed threshold
            var bestSim: Float = -2
            var bestPair: (Int, Int)? = nil

            let uniqueClusters = Array(Set(clusterOf)).sorted()
            for i in 0..<uniqueClusters.count {
                for j in (i + 1)..<uniqueClusters.count {
                    let a = uniqueClusters[i]
                    let b = uniqueClusters[j]
                    let sim = SpeakerEmbeddingService.cosineSimilarity(clusterEmbeddings[a], clusterEmbeddings[b])
                    if sim > bestSim {
                        bestSim = sim
                        bestPair = (a, b)
                    }
                }
            }

            // Stop if nothing exceeds threshold
            guard let (a, b) = bestPair, bestSim >= clusterMergeThreshold else { break }

            // Merge b into a — weighted average
            let weightA = Float(clusterSizes[a])
            let weightB = Float(clusterSizes[b])
            let total = weightA + weightB
            var merged = [Float](repeating: 0, count: clusterEmbeddings[a].count)
            for i in 0..<merged.count {
                merged[i] = (clusterEmbeddings[a][i] * weightA + clusterEmbeddings[b][i] * weightB) / total
            }
            // Re-normalize
            var norm: Float = 0
            vDSP_svesq(merged, 1, &norm, vDSP_Length(merged.count))
            norm = sqrt(norm)
            if norm > 1e-6 {
                var invNorm = 1.0 / norm
                vDSP_vsmul(merged, 1, &invNorm, &merged, 1, vDSP_Length(merged.count))
            }

            clusterEmbeddings[a] = merged
            clusterSizes[a] += clusterSizes[b]

            // Reassign all members of b → a
            for i in 0..<clusterOf.count where clusterOf[i] == b {
                clusterOf[i] = a
            }
        }

        // Compact cluster IDs to 0, 1, 2…
        let uniqueIDs = Array(Set(clusterOf)).sorted()
        var idMap: [Int: Int] = [:]
        for (newID, oldID) in uniqueIDs.enumerated() {
            idMap[oldID] = newID
        }

        var result = segments
        for i in 0..<result.count {
            result[i].clusterID = idMap[clusterOf[i]] ?? 0
        }
        return result
    }

    // MARK: - Agent Matching

    private func findAgentCluster(centroids: [Int: [Float]], enrolledEmbedding: [Float]?) -> Int? {
        guard let enrolled = enrolledEmbedding, !enrolled.isEmpty else { return nil }

        var bestSim: Float = -2
        var bestCluster: Int? = nil
        for (clusterID, centroid) in centroids {
            let sim = SpeakerEmbeddingService.cosineSimilarity(centroid, enrolled)
            if sim > bestSim {
                bestSim = sim
                bestCluster = clusterID
            }
        }

        if bestSim >= agentMatchThreshold {
            logger.info("Agent match: cluster \(bestCluster ?? -1) sim=\(bestSim)")
            return bestCluster
        }
        logger.debug("No agent match above threshold (best sim=\(bestSim))")
        return nil
    }
}
