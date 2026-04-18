//
//  DiarizationService.swift
//  SAM
//
//  Speaker diarization: given a block of audio, find the voice regions,
//  extract per-region speaker embeddings, cluster them, and match the
//  agent cluster against an enrolled SpeakerProfile.
//
//  Architecture:
//    DiarizationEngine (actor) — owns SpeakerKit, runs all VAD, embedding,
//      clustering, and agent matching on its own executor (NOT main thread).
//    DiarizationService (@MainActor @Observable) — thin API-compatible
//      wrapper. Delegates all work to the engine.
//

import Foundation
import Accelerate
import os.log
import SpeakerKit
import ArgmaxCore

// MARK: - DiarizationEngine (background actor)

/// All diarization compute runs on this actor's executor — never on the main thread.
actor DiarizationEngine {

    static let shared = DiarizationEngine()

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DiarizationService")

    /// Own embedding provider so we never need to hop to @MainActor
    /// just to call nonisolated methods on SpeakerEmbeddingService.shared.
    private let embeddingProvider: any SpeakerEmbeddingProvider = MFCCSpeakerEmbeddingProvider()

    // MARK: - Tunables

    var vadEnergyThreshold: Float = 0.015
    var minSegmentDuration: TimeInterval = 0.5
    var minSilenceGap: TimeInterval = 0.3
    var clusterMergeThreshold: Float = 0.60
    var agentMatchThreshold: Float = 0.80
    var preferNeuralDiarization: Bool = true
    var expectedSpeakerCount: Int? = nil
    var neuralClusterDistanceThreshold: Float = 0.5

    // MARK: - SpeakerKit

    private var speakerKit: SpeakerKit?
    private var isSpeakerKitLoading = false
    private var speakerKitContinuations: [CheckedContinuation<Void, Error>] = []

    func loadSpeakerKit() async throws {
        if speakerKit != nil { return }
        if isSpeakerKitLoading {
            try await withCheckedThrowingContinuation { speakerKitContinuations.append($0) }
            return
        }

        isSpeakerKitLoading = true

        logger.notice("⏳ Loading SpeakerKit (Pyannote) models — first run will download ~50MB")
        let config = PyannoteConfig(
            download: true,
            load: true,
            verbose: false,
            logLevel: .error
        )
        do {
            let kit = try await SpeakerKit(config)
            speakerKit = kit
            isSpeakerKitLoading = false
            logger.notice("✅ SpeakerKit loaded — neural speaker diarization ready")
            let waiting = speakerKitContinuations
            speakerKitContinuations.removeAll()
            for c in waiting { c.resume() }
        } catch {
            isSpeakerKitLoading = false
            let waiting = speakerKitContinuations
            speakerKitContinuations.removeAll()
            for c in waiting { c.resume(throwing: error) }
            throw error
        }
    }

    // MARK: - SpeakerKit Diarization

    func diarizeWithSpeakerKit(
        samples: [Float],
        sampleRate: Double,
        startOffset: TimeInterval = 0,
        enrolledAgentEmbedding: [Float]? = nil
    ) async throws -> DiarizationResultDTO {
        try await loadSpeakerKit()
        guard let kit = speakerKit else {
            throw DiarizationErrorType.modelNotLoaded
        }

        // Resample to 16kHz for SpeakerKit
        let targetRate = 16000.0
        let inputSamples: [Float]
        if abs(sampleRate - targetRate) > 1 {
            let ratio = targetRate / sampleRate
            let outputCount = Int(Double(samples.count) * ratio)
            var output = [Float](repeating: 0, count: outputCount)
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

        // Convert SpeakerKit segments and extract MFCC embeddings for agent matching
        var voiceSegments: [DiarizationVoiceSegment] = []
        var speakerEmbeddings: [Int: [[Float]]] = [:]

        for skSeg in skResult.segments {
            let startTime = Double(skSeg.startFrame) / Double(skResult.frameRate) + startOffset
            let endTime = Double(skSeg.endFrame) / Double(skResult.frameRate) + startOffset
            let speakerID = skSeg.speaker.speakerId ?? 0
            let duration = endTime - startTime

            var embedding: [Float] = []
            if duration >= 2.0 {
                let startSample = Int(startTime * targetRate)
                let endSample = min(Int(endTime * targetRate), inputSamples.count)
                if startSample < endSample {
                    let chunk = Array(inputSamples[startSample..<endSample])
                    if let emb = embeddingProvider.embedding(for: chunk, sampleRate: targetRate) {
                        embedding = emb
                        speakerEmbeddings[speakerID, default: []].append(emb)
                    }
                }
            }

            voiceSegments.append(DiarizationVoiceSegment(
                start: startTime,
                end: endTime,
                embedding: embedding,
                clusterID: speakerID
            ))
        }

        var centroids: [Int: [Float]] = [:]
        for (speakerID, embeddings) in speakerEmbeddings {
            if let centroid = SpeakerEmbeddingService.centroid(of: embeddings) {
                centroids[speakerID] = centroid
            }
        }
        for seg in voiceSegments {
            if centroids[seg.clusterID] == nil {
                centroids[seg.clusterID] = []
            }
        }

        let agentClusterID = findAgentCluster(
            centroids: centroids,
            enrolledEmbedding: enrolledAgentEmbedding
        )

        logger.info("SpeakerKit diarization: \(voiceSegments.count) voice segments, \(centroids.count) clusters, agent=\(agentClusterID?.description ?? "none")")

        return DiarizationResultDTO(
            segments: voiceSegments,
            centroids: centroids,
            agentClusterID: agentClusterID
        )
    }

    // MARK: - MFCC Diarization

    func diarize(
        samples: [Float],
        sampleRate: Double,
        startOffset: TimeInterval = 0,
        enrolledAgentEmbedding: [Float]? = nil
    ) -> DiarizationResultDTO {
        let rawSegments = detectVoiceSegments(samples: samples, sampleRate: sampleRate)
        guard !rawSegments.isEmpty else {
            return DiarizationResultDTO(segments: [], centroids: [:], agentClusterID: nil)
        }

        var segments: [DiarizationVoiceSegment] = []
        for (startSample, endSample) in rawSegments {
            let chunk = Array(samples[startSample..<endSample])
            guard let embedding = embeddingProvider.embedding(for: chunk, sampleRate: sampleRate) else {
                continue
            }
            let startTime = Double(startSample) / sampleRate + startOffset
            let endTime = Double(endSample) / sampleRate + startOffset
            segments.append(DiarizationVoiceSegment(
                start: startTime,
                end: endTime,
                embedding: embedding,
                clusterID: -1
            ))
        }

        guard !segments.isEmpty else {
            return DiarizationResultDTO(segments: [], centroids: [:], agentClusterID: nil)
        }

        let clustered = clusterSegments(segments)

        var centroids: [Int: [Float]] = [:]
        let clusterGroups = Dictionary(grouping: clustered, by: { $0.clusterID })
        for (clusterID, group) in clusterGroups {
            let embeddings = group.map(\.embedding)
            if let centroid = SpeakerEmbeddingService.centroid(of: embeddings) {
                centroids[clusterID] = centroid
            }
        }

        let agentClusterID = findAgentCluster(
            centroids: centroids,
            enrolledEmbedding: enrolledAgentEmbedding
        )

        logger.info("Diarization: \(segments.count) voice segments, \(centroids.count) clusters, agent=\(agentClusterID?.description ?? "none")")

        return DiarizationResultDTO(
            segments: clustered,
            centroids: centroids,
            agentClusterID: agentClusterID
        )
    }

    // MARK: - VAD

    private func detectVoiceSegments(samples: [Float], sampleRate: Double) -> [(Int, Int)] {
        let frameSize = Int(sampleRate * 0.02)
        guard frameSize > 0, samples.count >= frameSize else { return [] }

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

        var sortedEnergies = energies
        sortedEnergies.sort()
        let median = sortedEnergies[sortedEnergies.count / 2]
        let threshold = max(vadEnergyThreshold, median * 1.5)

        var voicedFrames: [Bool] = energies.map { $0 >= threshold }

        let minSilenceFrames = max(1, Int(minSilenceGap / 0.02))
        voicedFrames = smoothVoicedFrames(voicedFrames, minSilenceFrames: minSilenceFrames)

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
                var j = i
                while j < result.count && !result[j] { j += 1 }
                let silenceLen = j - i
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

    private func clusterSegments(_ segments: [DiarizationVoiceSegment]) -> [DiarizationVoiceSegment] {
        guard !segments.isEmpty else { return segments }

        #if DEBUG
        dumpPairwiseSimilarities(segments)
        #endif

        var clusterOf = Array(0..<segments.count)
        var clusterEmbeddings: [[Float]] = segments.map(\.embedding)
        var clusterSizes = [Int](repeating: 1, count: segments.count)

        while true {
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

            guard let (a, b) = bestPair, bestSim >= clusterMergeThreshold else { break }

            let weightA = Float(clusterSizes[a])
            let weightB = Float(clusterSizes[b])
            let total = weightA + weightB
            var merged = [Float](repeating: 0, count: clusterEmbeddings[a].count)
            for i in 0..<merged.count {
                merged[i] = (clusterEmbeddings[a][i] * weightA + clusterEmbeddings[b][i] * weightB) / total
            }
            var norm: Float = 0
            vDSP_svesq(merged, 1, &norm, vDSP_Length(merged.count))
            norm = sqrt(norm)
            if norm > 1e-6 {
                var invNorm = 1.0 / norm
                vDSP_vsmul(merged, 1, &invNorm, &merged, 1, vDSP_Length(merged.count))
            }

            clusterEmbeddings[a] = merged
            clusterSizes[a] += clusterSizes[b]

            for i in 0..<clusterOf.count where clusterOf[i] == b {
                clusterOf[i] = a
            }
        }

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
    private func dumpPairwiseSimilarities(_ segments: [DiarizationVoiceSegment]) {
        guard segments.count >= 2 else { return }

        let testKitDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SAM-TestKit/diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: testKitDir, withIntermediateDirectories: true)

        struct SegmentInfo: Encodable {
            let index: Int; let start: Double; let end: Double; let duration: Double
        }
        struct PairSimilarity: Encodable {
            let segA: Int; let segB: Int; let similarity: Float
        }

        var segmentInfos: [SegmentInfo] = []
        var pairs: [PairSimilarity] = []

        for (i, seg) in segments.enumerated() {
            segmentInfos.append(SegmentInfo(index: i, start: seg.start, end: seg.end, duration: seg.end - seg.start))
        }

        var allSims: [Float] = []
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count {
                let sim = SpeakerEmbeddingService.cosineSimilarity(segments[i].embedding, segments[j].embedding)
                pairs.append(PairSimilarity(segA: i, segB: j, similarity: sim))
                allSims.append(sim)
            }
        }

        allSims.sort()
        let minSim = allSims.first ?? 0
        let maxSim = allSims.last ?? 0
        let medianSim = allSims.count > 0 ? allSims[allSims.count / 2] : Float(0)
        let meanSim = allSims.reduce(Float(0), +) / max(Float(allSims.count), 1)

        struct DiagnosticReport: Encodable {
            let segmentCount: Int; let pairCount: Int; let clusterMergeThreshold: Float
            let minSimilarity: Float; let maxSimilarity: Float
            let medianSimilarity: Float; let meanSimilarity: Float
            let segments: [SegmentInfo]; let pairs: [PairSimilarity]
        }

        let report = DiagnosticReport(
            segmentCount: segments.count, pairCount: pairs.count,
            clusterMergeThreshold: clusterMergeThreshold,
            minSimilarity: minSim, maxSimilarity: maxSim,
            medianSimilarity: medianSim, meanSimilarity: meanSim,
            segments: segmentInfos, pairs: pairs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            let url = testKitDir.appendingPathComponent("diarization-similarities.json")
            try? data.write(to: url)
            logger.notice("📊 Diarization diagnostic: \(segments.count) segments, similarity range [\(String(format: "%.3f", minSim))–\(String(format: "%.3f", maxSim))], mean=\(String(format: "%.3f", meanSim))")
        }
    }
    #endif
}

// MARK: - Diarization Value Types (file-level to avoid @MainActor inference)

/// A speaker-attributed voice segment from the diarization pipeline.
nonisolated struct DiarizationVoiceSegment: Sendable, Equatable, Codable {
    let start: TimeInterval
    let end: TimeInterval
    var embedding: [Float]
    var clusterID: Int

    nonisolated init(start: TimeInterval, end: TimeInterval, embedding: [Float], clusterID: Int) {
        self.start = start
        self.end = end
        self.embedding = embedding
        self.clusterID = clusterID
    }
}

/// The result of a complete diarization pass.
nonisolated struct DiarizationResultDTO: Sendable, Codable {
    let segments: [DiarizationVoiceSegment]
    let centroids: [Int: [Float]]
    let agentClusterID: Int?

    private enum CodingKeys: String, CodingKey {
        case segments, centroids, agentClusterID
    }

    nonisolated init(segments: [DiarizationVoiceSegment], centroids: [Int: [Float]], agentClusterID: Int?) {
        self.segments = segments
        self.centroids = centroids
        self.agentClusterID = agentClusterID
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decode([DiarizationVoiceSegment].self, forKey: .segments)
        agentClusterID = try c.decodeIfPresent(Int.self, forKey: .agentClusterID)
        let stringKeyed = try c.decode([String: [Float]].self, forKey: .centroids)
        var converted: [Int: [Float]] = [:]
        for (k, v) in stringKeyed {
            if let intKey = Int(k) { converted[intKey] = v }
        }
        centroids = converted
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(segments, forKey: .segments)
        try c.encodeIfPresent(agentClusterID, forKey: .agentClusterID)
        var stringKeyed: [String: [Float]] = [:]
        for (k, v) in centroids { stringKeyed[String(k)] = v }
        try c.encode(stringKeyed, forKey: .centroids)
    }

    var speakerCount: Int { centroids.count }

    func label(for clusterID: Int) -> String {
        if clusterID == agentClusterID { return "Agent" }
        let otherIDs = centroids.keys.filter { $0 != agentClusterID }.sorted()
        if let idx = otherIDs.firstIndex(of: clusterID) {
            return "Speaker \(idx + 1)"
        }
        return "Speaker"
    }
}

enum DiarizationErrorType: Error, LocalizedError {
    case modelNotLoaded
    var errorDescription: String? { "SpeakerKit model not loaded" }
}

// MARK: - DiarizationService (@MainActor API-compatible wrapper)

/// Thin @MainActor wrapper preserving the existing API. All heavy compute
/// is delegated to `DiarizationEngine` which runs on its own actor.
@MainActor
@Observable
final class DiarizationService {

    static let shared = DiarizationService()

    // MARK: - Types (typealiases to preserve existing API)

    typealias VoiceSegment = DiarizationVoiceSegment
    typealias DiarizationResult = DiarizationResultDTO
    typealias DiarizationError = DiarizationErrorType

    // MARK: - Tunable Access (read from engine for cache keys)

    var preferNeuralDiarization: Bool {
        get { _preferNeural }
        set { _preferNeural = newValue; Task { await DiarizationEngine.shared.setPreferNeural(newValue) } }
    }
    private var _preferNeural: Bool = true

    var expectedSpeakerCount: Int? {
        get { _expectedSpeakers }
        set { _expectedSpeakers = newValue; Task { await DiarizationEngine.shared.setExpectedSpeakers(newValue) } }
    }
    private var _expectedSpeakers: Int? = nil

    var neuralClusterDistanceThreshold: Float {
        get { _neuralThreshold }
        set { _neuralThreshold = newValue; Task { await DiarizationEngine.shared.setNeuralThreshold(newValue) } }
    }
    private var _neuralThreshold: Float = 0.5

    var vadEnergyThreshold: Float { 0.015 }
    var minSegmentDuration: TimeInterval { 0.5 }
    var minSilenceGap: TimeInterval { 0.3 }
    var clusterMergeThreshold: Float { 0.60 }
    var agentMatchThreshold: Float { 0.80 }

    private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "DiarizationService")

    private init() {}

    // MARK: - Delegated API

    func diarizeWithSpeakerKit(
        samples: [Float],
        sampleRate: Double,
        startOffset: TimeInterval = 0,
        enrolledAgentEmbedding: [Float]? = nil
    ) async throws -> DiarizationResult {
        try await DiarizationEngine.shared.diarizeWithSpeakerKit(
            samples: samples,
            sampleRate: sampleRate,
            startOffset: startOffset,
            enrolledAgentEmbedding: enrolledAgentEmbedding
        )
    }

    func diarize(
        samples: [Float],
        sampleRate: Double,
        startOffset: TimeInterval = 0,
        enrolledAgentEmbedding: [Float]? = nil
    ) -> DiarizationResult {
        // MFCC diarization is synchronous CPU work. For now it still
        // runs on the main actor when called from @MainActor context.
        // The SpeakerKit path (async) is the preferred path and runs
        // entirely off main thread via DiarizationEngine.
        // We can't call actor methods synchronously, so for the sync
        // MFCC path we run the computation inline. This is acceptable
        // because MFCC diarization is the fallback path and typically
        // takes <1s. The primary neural path is fully off-thread.
        let rawSegments = detectVoiceSegmentsLocal(samples: samples, sampleRate: sampleRate)
        guard !rawSegments.isEmpty else {
            return DiarizationResult(segments: [], centroids: [:], agentClusterID: nil)
        }

        var segments: [VoiceSegment] = []
        for (startSample, endSample) in rawSegments {
            let chunk = Array(samples[startSample..<endSample])
            guard let embedding = SpeakerEmbeddingService.shared.embedding(for: chunk, sampleRate: sampleRate) else {
                continue
            }
            segments.append(VoiceSegment(
                start: Double(startSample) / sampleRate + startOffset,
                end: Double(endSample) / sampleRate + startOffset,
                embedding: embedding,
                clusterID: -1
            ))
        }

        guard !segments.isEmpty else {
            return DiarizationResult(segments: [], centroids: [:], agentClusterID: nil)
        }

        let clustered = clusterSegmentsLocal(segments)
        var centroids: [Int: [Float]] = [:]
        let groups = Dictionary(grouping: clustered, by: { $0.clusterID })
        for (id, group) in groups {
            if let c = SpeakerEmbeddingService.centroid(of: group.map(\.embedding)) {
                centroids[id] = c
            }
        }

        let agentID = findAgentClusterLocal(centroids: centroids, enrolledEmbedding: enrolledAgentEmbedding)
        return DiarizationResult(segments: clustered, centroids: centroids, agentClusterID: agentID)
    }

    // MARK: - Local MFCC helpers (inline, avoid actor hop for sync path)

    private func detectVoiceSegmentsLocal(samples: [Float], sampleRate: Double) -> [(Int, Int)] {
        let frameSize = Int(sampleRate * 0.02)
        guard frameSize > 0, samples.count >= frameSize else { return [] }
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
        var sorted = energies; sorted.sort()
        let median = sorted[sorted.count / 2]
        let threshold = max(vadEnergyThreshold, median * 1.5)
        var voiced: [Bool] = energies.map { $0 >= threshold }
        let minSilFrames = max(1, Int(minSilenceGap / 0.02))
        // Smooth
        var i = 0
        while i < voiced.count {
            if !voiced[i] {
                var j = i; while j < voiced.count && !voiced[j] { j += 1 }
                if j - i < minSilFrames && i > 0 && j < voiced.count && voiced[i-1] && voiced[j] {
                    for k in i..<j { voiced[k] = true }
                }
                i = j
            } else { i += 1 }
        }
        var segs: [(Int, Int)] = []; var segStart: Int? = nil
        let minSegFrames = max(1, Int(minSegmentDuration / 0.02))
        for (i, v) in voiced.enumerated() {
            if v && segStart == nil { segStart = i }
            else if !v, let s = segStart {
                if i - s >= minSegFrames { segs.append((s * frameSize, min(i * frameSize, samples.count))) }
                segStart = nil
            }
        }
        if let s = segStart, voiced.count - s >= minSegFrames {
            segs.append((s * frameSize, min(voiced.count * frameSize, samples.count)))
        }
        return segs
    }

    private func clusterSegmentsLocal(_ segments: [VoiceSegment]) -> [VoiceSegment] {
        guard !segments.isEmpty else { return segments }
        var clusterOf = Array(0..<segments.count)
        var embeds: [[Float]] = segments.map(\.embedding)
        var sizes = [Int](repeating: 1, count: segments.count)
        while true {
            var bestSim: Float = -2; var bestPair: (Int, Int)? = nil
            let unique = Array(Set(clusterOf)).sorted()
            for i in 0..<unique.count { for j in (i+1)..<unique.count {
                let sim = SpeakerEmbeddingService.cosineSimilarity(embeds[unique[i]], embeds[unique[j]])
                if sim > bestSim { bestSim = sim; bestPair = (unique[i], unique[j]) }
            }}
            guard let (a, b) = bestPair, bestSim >= clusterMergeThreshold else { break }
            let wA = Float(sizes[a]); let wB = Float(sizes[b]); let tot = wA + wB
            var m = [Float](repeating: 0, count: embeds[a].count)
            for i in 0..<m.count { m[i] = (embeds[a][i] * wA + embeds[b][i] * wB) / tot }
            var n: Float = 0; vDSP_svesq(m, 1, &n, vDSP_Length(m.count)); n = sqrt(n)
            if n > 1e-6 { var inv = 1.0/n; vDSP_vsmul(m, 1, &inv, &m, 1, vDSP_Length(m.count)) }
            embeds[a] = m; sizes[a] += sizes[b]
            for i in 0..<clusterOf.count where clusterOf[i] == b { clusterOf[i] = a }
        }
        let ids = Array(Set(clusterOf)).sorted()
        var map: [Int: Int] = [:]
        for (new, old) in ids.enumerated() { map[old] = new }
        var result = segments
        for i in 0..<result.count { result[i].clusterID = map[clusterOf[i]] ?? 0 }
        return result
    }

    private func findAgentClusterLocal(centroids: [Int: [Float]], enrolledEmbedding: [Float]?) -> Int? {
        guard let enrolled = enrolledEmbedding, !enrolled.isEmpty else { return nil }
        var bestSim: Float = -2; var bestCluster: Int? = nil
        for (id, centroid) in centroids {
            let sim = SpeakerEmbeddingService.cosineSimilarity(centroid, enrolled)
            if sim > bestSim { bestSim = sim; bestCluster = id }
        }
        return bestSim >= agentMatchThreshold ? bestCluster : nil
    }
}

// MARK: - Engine tunable setters

extension DiarizationEngine {
    func setPreferNeural(_ value: Bool) { preferNeuralDiarization = value }
    func setExpectedSpeakers(_ value: Int?) { expectedSpeakerCount = value }
    func setNeuralThreshold(_ value: Float) { neuralClusterDistanceThreshold = value }
}
