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
import SpeakerKit
import ArgmaxCore

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
    /// Typical: 0.55–0.75 for MFCC features. Lowered from 0.65 → 0.60 to
    /// be more willing to split similar-sounding voices into separate
    /// clusters when the MFCC distance is ambiguous.
    var clusterMergeThreshold: Float = 0.60

    /// Cosine similarity threshold for labeling as "Agent" against enrolled
    /// profile. Raised from 0.55 → 0.80 after a test where a podcast played
    /// through a speaker was mis-labeled as the enrolled agent (MFCC is
    /// channel-sensitive, so any voice through the same mic/speaker path
    /// gets ~0.55–0.70 similarity regardless of who it is). A clean close-mic
    /// match of the enrolled speaker typically scores 0.90+, so 0.80 is a
    /// safe floor that keeps legitimate matches while rejecting channel noise.
    var agentMatchThreshold: Float = 0.80

    // MARK: - Types

    struct VoiceSegment: Sendable, Equatable, Codable {
        let start: TimeInterval  // relative to input buffer start
        let end: TimeInterval
        var embedding: [Float]
        var clusterID: Int       // assigned by clustering; -1 before
    }

    struct DiarizationResult: Sendable, Codable {
        /// Voice segments with speaker cluster IDs assigned.
        let segments: [VoiceSegment]

        /// Cluster centroids keyed by cluster ID. Stored as a string-keyed
        /// dictionary on the wire to satisfy JSON encoding rules.
        let centroids: [Int: [Float]]

        /// Which cluster ID is the agent (nil if none matched or no enrolled profile).
        let agentClusterID: Int?

        // MARK: - Codable

        private enum CodingKeys: String, CodingKey {
            case segments
            case centroids
            case agentClusterID
        }

        init(segments: [VoiceSegment], centroids: [Int: [Float]], agentClusterID: Int?) {
            self.segments = segments
            self.centroids = centroids
            self.agentClusterID = agentClusterID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            segments = try c.decode([VoiceSegment].self, forKey: .segments)
            agentClusterID = try c.decodeIfPresent(Int.self, forKey: .agentClusterID)
            // Centroids: encoded as [String: [Float]] for JSON compatibility
            let stringKeyed = try c.decode([String: [Float]].self, forKey: .centroids)
            var converted: [Int: [Float]] = [:]
            for (k, v) in stringKeyed {
                if let intKey = Int(k) { converted[intKey] = v }
            }
            centroids = converted
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(segments, forKey: .segments)
            try c.encodeIfPresent(agentClusterID, forKey: .agentClusterID)
            var stringKeyed: [String: [Float]] = [:]
            for (k, v) in centroids {
                stringKeyed[String(k)] = v
            }
            try c.encode(stringKeyed, forKey: .centroids)
        }

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

    // MARK: - SpeakerKit (Pyannote Neural Diarization)

    /// Shared SpeakerKit instance. Lazy-loaded on first use. The Pyannote
    /// CoreML models download from HuggingFace on first run (~50MB).
    private var speakerKit: SpeakerKit?
    private var speakerKitLoadTask: Task<Void, Error>?

    /// Whether to prefer SpeakerKit (neural) over MFCC for diarization.
    /// On by default. Falls back to MFCC if SpeakerKit fails to load.
    var preferNeuralDiarization: Bool = true

    /// Load SpeakerKit models. Safe to call multiple times — subsequent
    /// calls wait for the first. Called automatically by diarize() when
    /// preferNeuralDiarization is true.
    func loadSpeakerKit() async throws {
        if speakerKit != nil { return }
        if let existing = speakerKitLoadTask {
            try await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            logger.notice("⏳ Loading SpeakerKit (Pyannote) models — first run will download ~50MB")
            let config = PyannoteConfig(
                download: true,
                load: true,
                verbose: false,
                logLevel: .error
            )
            let kit = try await SpeakerKit(config)
            self.speakerKit = kit
            logger.notice("✅ SpeakerKit loaded — neural speaker diarization ready")
            self.speakerKitLoadTask = nil
        }
        speakerKitLoadTask = task
        try await task.value
    }

    /// Expected number of speakers, if known. Setting this avoids unreliable
    /// auto-detection on mono recordings. Nil = let SpeakerKit auto-detect.
    /// Most advisor calls are 2 people; set per-session when more are expected
    /// (e.g., from calendar event attendee count).
    var expectedSpeakerCount: Int? = nil

    /// Clustering distance threshold for SpeakerKit. Lower = more speakers
    /// detected (stricter separation). Default 0.5 (SpeakerKit's own default
    /// is 0.6, which over-merges on mono phone audio).
    var neuralClusterDistanceThreshold: Float = 0.5

    /// Diarize using SpeakerKit's Pyannote pipeline. Returns our
    /// `DiarizationResult` format adapted from SpeakerKit's output.
    func diarizeWithSpeakerKit(
        samples: [Float],
        sampleRate: Double,
        startOffset: TimeInterval = 0,
        enrolledAgentEmbedding: [Float]? = nil
    ) async throws -> DiarizationResult {
        try await loadSpeakerKit()
        guard let kit = speakerKit else {
            throw DiarizationError.modelNotLoaded
        }

        // SpeakerKit expects 16kHz mono audio (WhisperKit.sampleRate = 16000).
        // Resample if the input is at a different rate.
        let targetRate = 16000.0
        let inputSamples: [Float]
        if abs(sampleRate - targetRate) > 1 {
            let ratio = targetRate / sampleRate
            let outputCount = Int(Double(samples.count) * ratio)
            var output = [Float](repeating: 0, count: outputCount)
            // Linear interpolation resampling via Accelerate
            for i in 0..<outputCount {
                let srcIdx = Double(i) / ratio
                let lo = Int(srcIdx)
                let hi = min(lo + 1, samples.count - 1)
                let frac = Float(srcIdx - Double(lo))
                output[i] = samples[lo] * (1 - frac) + samples[hi] * frac
            }
            inputSamples = output
            logger.notice("Resampled \(samples.count) samples from \(Int(sampleRate))Hz to \(Int(targetRate))Hz (\(outputCount) samples)")
        } else {
            inputSamples = samples
        }

        let options = PyannoteDiarizationOptions(
            numberOfSpeakers: expectedSpeakerCount,
            clusterDistanceThreshold: neuralClusterDistanceThreshold,
            useExclusiveReconciliation: false
        )

        let speakerDesc = expectedSpeakerCount?.description ?? "auto"
        let threshDesc = String(format: "%.2f", neuralClusterDistanceThreshold)
        logger.notice("⏳ Running SpeakerKit neural diarization on \(inputSamples.count) samples at \(Int(targetRate))Hz (speakers=\(speakerDesc), threshold=\(threshDesc))...")
        let skResult = try await kit.diarize(audioArray: inputSamples, options: options)
        logger.notice("✅ SpeakerKit: \(skResult.speakerCount) speakers, \(skResult.segments.count) segments")

        // Convert SpeakerKit segments to our format and extract MFCC
        // embeddings from the longer segments for agent matching.
        var voiceSegments: [VoiceSegment] = []
        // Group segments by speaker for centroid computation
        var speakerEmbeddings: [Int: [[Float]]] = [:]

        for skSeg in skResult.segments {
            let startTime = Double(skSeg.startFrame) / Double(skResult.frameRate) + startOffset
            let endTime = Double(skSeg.endFrame) / Double(skResult.frameRate) + startOffset
            let speakerID = skSeg.speaker.speakerId ?? 0
            let duration = endTime - startTime

            // Extract MFCC embedding from longer segments (≥2s) for
            // agent matching. Short backchannels ("yeah", "right") are
            // poor identification material — skip them (per Grok).
            var embedding: [Float] = []
            if duration >= 2.0 {
                let startSample = Int(startTime * targetRate)
                let endSample = min(Int(endTime * targetRate), inputSamples.count)
                if startSample < endSample {
                    let chunk = Array(inputSamples[startSample..<endSample])
                    if let emb = SpeakerEmbeddingService.shared.embedding(for: chunk, sampleRate: targetRate) {
                        embedding = emb
                        speakerEmbeddings[speakerID, default: []].append(emb)
                    }
                }
            }

            voiceSegments.append(VoiceSegment(
                start: startTime,
                end: endTime,
                embedding: embedding,
                clusterID: speakerID
            ))
        }

        // Build centroids from the per-speaker embeddings
        var centroids: [Int: [Float]] = [:]
        for (speakerID, embeddings) in speakerEmbeddings {
            if let centroid = SpeakerEmbeddingService.centroid(of: embeddings) {
                centroids[speakerID] = centroid
            }
        }
        // Ensure all speakers appear in centroids even if no long segments
        for seg in voiceSegments {
            if centroids[seg.clusterID] == nil {
                centroids[seg.clusterID] = []
            }
        }

        // Agent matching using MFCC centroids against enrolled profile
        let agentClusterID = findAgentCluster(
            centroids: centroids,
            enrolledEmbedding: enrolledAgentEmbedding
        )

        logger.info("SpeakerKit diarization: \(voiceSegments.count) voice segments, \(centroids.count) clusters, agent=\(agentClusterID?.description ?? "none")")

        return DiarizationResult(
            segments: voiceSegments,
            centroids: centroids,
            agentClusterID: agentClusterID
        )
    }

    enum DiarizationError: Error, LocalizedError {
        case modelNotLoaded
        var errorDescription: String? { "SpeakerKit model not loaded" }
    }

    // MARK: - Main Entry Point

    /// Diarize a block of audio. `samples` must be mono Float PCM at `sampleRate`.
    /// `startOffset` is the time (in seconds) of the first sample relative to session start,
    /// used to preserve absolute timestamps in the returned segments.
    ///
    /// When `preferNeuralDiarization` is true and SpeakerKit is available,
    /// uses the Pyannote neural pipeline. Falls back to MFCC-based
    /// clustering if SpeakerKit isn't loaded or fails.
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

        #if DEBUG
        dumpPairwiseSimilarities(segments)
        #endif

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

        // Compute similarity to every cluster, log all of them so the
        // user can diagnose why diarization is or isn't labeling the
        // agent. Useful for threshold tuning.
        var bestSim: Float = -2
        var bestCluster: Int? = nil
        var allSims: [(clusterID: Int, sim: Float)] = []
        for (clusterID, centroid) in centroids {
            let sim = SpeakerEmbeddingService.cosineSimilarity(centroid, enrolled)
            allSims.append((clusterID, sim))
            if sim > bestSim {
                bestSim = sim
                bestCluster = clusterID
            }
        }

        let simSummary = allSims
            .sorted { $0.clusterID < $1.clusterID }
            .map { "cluster \($0.clusterID)=\(String(format: "%.3f", $0.sim))" }
            .joined(separator: ", ")
        logger.info("Agent similarities: \(simSummary) (threshold=\(String(format: "%.2f", self.agentMatchThreshold)))")

        if bestSim >= agentMatchThreshold {
            logger.info("✅ Agent matched: cluster \(bestCluster ?? -1) sim=\(String(format: "%.3f", bestSim))")
            return bestCluster
        }
        logger.info("❌ No agent match: best sim=\(String(format: "%.3f", bestSim)) < threshold \(String(format: "%.2f", self.agentMatchThreshold))")
        return nil
    }

    // MARK: - Diagnostics

    #if DEBUG
    /// Write a pairwise cosine similarity matrix for all voice segments
    /// to a JSON file. This is the key diagnostic for understanding why
    /// clustering over-merges: if same-speaker pairs are at 0.90+ and
    /// cross-speaker pairs are at 0.50-0.60, the threshold just needs
    /// adjusting. If all pairs are at 0.70-0.85, MFCC can't distinguish
    /// the speakers and we need a better embedding model.
    private func dumpPairwiseSimilarities(_ segments: [VoiceSegment]) {
        guard segments.count >= 2 else { return }

        let testKitDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SAM-TestKit/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: testKitDir, withIntermediateDirectories: true)

        struct SegmentInfo: Encodable {
            let index: Int
            let start: Double
            let end: Double
            let duration: Double
        }

        struct PairSimilarity: Encodable {
            let segA: Int
            let segB: Int
            let similarity: Float
        }

        var segmentInfos: [SegmentInfo] = []
        var pairs: [PairSimilarity] = []

        for (i, seg) in segments.enumerated() {
            segmentInfos.append(SegmentInfo(
                index: i,
                start: seg.start,
                end: seg.end,
                duration: seg.end - seg.start
            ))
        }

        // Compute all pairwise similarities
        var allSims: [Float] = []
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count {
                let sim = SpeakerEmbeddingService.cosineSimilarity(
                    segments[i].embedding,
                    segments[j].embedding
                )
                pairs.append(PairSimilarity(segA: i, segB: j, similarity: sim))
                allSims.append(sim)
            }
        }

        // Summary stats
        allSims.sort()
        let minSim = allSims.first ?? 0
        let maxSim = allSims.last ?? 0
        let medianSim = allSims.count > 0 ? allSims[allSims.count / 2] : Float(0)
        let meanSim = allSims.reduce(Float(0), +) / max(Float(allSims.count), 1)

        struct DiagnosticReport: Encodable {
            let segmentCount: Int
            let pairCount: Int
            let clusterMergeThreshold: Float
            let minSimilarity: Float
            let maxSimilarity: Float
            let medianSimilarity: Float
            let meanSimilarity: Float
            let segments: [SegmentInfo]
            let pairs: [PairSimilarity]
        }

        let report = DiagnosticReport(
            segmentCount: segments.count,
            pairCount: pairs.count,
            clusterMergeThreshold: clusterMergeThreshold,
            minSimilarity: minSim,
            maxSimilarity: maxSim,
            medianSimilarity: medianSim,
            meanSimilarity: meanSim,
            segments: segmentInfos,
            pairs: pairs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            let url = testKitDir.appendingPathComponent("diarization-similarities.json")
            try? data.write(to: url)
            logger.notice("📊 Diarization diagnostic: \(segments.count) segments, similarity range [\(String(format: "%.3f", minSim))–\(String(format: "%.3f", maxSim))], mean=\(String(format: "%.3f", meanSim)), median=\(String(format: "%.3f", medianSim)), threshold=\(String(format: "%.2f", self.clusterMergeThreshold))")
            logger.notice("📊 Diagnostic written to: \(url.path)")
        }
    }
    #endif
}
