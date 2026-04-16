//
//  SpeakerEmbeddingService.swift
//  SAM
//
//  Extracts speaker embeddings from audio buffers for voice identification
//  and diarization. Uses MFCC features + statistical pooling as a pragmatic
//  baseline that runs in pure Swift + Accelerate/vDSP.
//
//  The `SpeakerEmbeddingProvider` protocol lets us swap in a stronger
//  ECAPA-TDNN CoreML model later without touching call sites.
//
//  Algorithm (current baseline):
//    1. Pre-emphasis filter (high-pass)
//    2. Frame audio into 25ms windows with 10ms hop
//    3. Hamming window + FFT (via vDSP)
//    4. Mel filterbank (40 bands, 0–8kHz)
//    5. Log + DCT → 13 MFCC coefficients per frame
//    6. Append delta + delta-delta → 39 coefficients
//    7. Statistical pooling (mean + std per dim) → 78-dim embedding
//    8. L2 normalize
//
//  This gives a reasonable agent-vs-not-agent discriminator for quiet
//  1-on-1 meetings. Close-mic setups (headset, handheld phone) do best.
//

import Foundation
import Accelerate
import os.log

private let logger = Logger(subsystem: "com.matthewsessions.SAM", category: "SpeakerEmbeddingService")

// MARK: - Protocol

/// Abstract interface for a speaker embedding model.
protocol SpeakerEmbeddingProvider: Sendable {
    /// Dimension of the embedding vector this provider produces.
    var embeddingDimension: Int { get }

    /// Extract a normalized embedding from a mono PCM audio buffer at `sampleRate`.
    /// Returns nil if the input is too short or silent.
    func embedding(for samples: [Float], sampleRate: Double) -> [Float]?
}

// MARK: - MFCC Implementation

/// Default embedding provider built on MFCC features + statistical pooling.
/// All DSP runs on the CPU via vDSP — no model file required.
final class MFCCSpeakerEmbeddingProvider: SpeakerEmbeddingProvider, @unchecked Sendable {

    // Feature configuration
    private let targetSampleRate: Double = 16_000
    private let frameLength: Int = 400    // 25ms @ 16kHz
    private let hopLength: Int = 160      // 10ms @ 16kHz
    private let fftSize: Int = 512
    private let melBands: Int = 40
    private let mfccCoefficients: Int = 13
    private let preEmphasis: Float = 0.97

    let embeddingDimension: Int

    // Cached state
    private let melFilters: [[Float]]
    private let dctMatrix: [[Float]]
    private let window: [Float]
    private let fftSetup: vDSP.FFT<DSPSplitComplex>

    init() {
        // MFCC coefficients + deltas + double-deltas = 39
        // Statistical pooling doubles it → 78
        self.embeddingDimension = 13 * 3 * 2

        self.melFilters = Self.buildMelFilterbank(
            bands: melBands,
            fftSize: fftSize,
            sampleRate: targetSampleRate,
            minFreq: 20,
            maxFreq: 8_000
        )

        self.dctMatrix = Self.buildDCTMatrix(rows: mfccCoefficients, cols: melBands)
        self.window = vDSP.window(ofType: Float.self, usingSequence: .hamming, count: frameLength, isHalfWindow: false)

        let log2N = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP.FFT(log2n: log2N, radix: .radix2, ofType: DSPSplitComplex.self)!
    }

    // MARK: - Public

    func embedding(for samples: [Float], sampleRate: Double) -> [Float]? {
        guard samples.count > Int(sampleRate * 0.5) else {
            logger.debug("Sample buffer too short (\(samples.count) samples)")
            return nil
        }

        // Resample to 16 kHz
        let resampled = resample(samples: samples, from: sampleRate, to: targetSampleRate)
        guard resampled.count >= frameLength else { return nil }

        // Energy sanity check — reject pure silence
        var meanSquare: Float = 0
        vDSP_measqv(resampled, 1, &meanSquare, vDSP_Length(resampled.count))
        let rms = sqrt(meanSquare)
        guard rms > 0.001 else {
            logger.debug("Audio too quiet for embedding (rms=\(rms))")
            return nil
        }

        // Pre-emphasis
        let emphasized = preEmphasize(samples: resampled)

        // Frame + MFCC per frame
        var mfccFrames: [[Float]] = []
        var frameStart = 0
        while frameStart + frameLength <= emphasized.count {
            let frame = Array(emphasized[frameStart..<(frameStart + frameLength)])
            if let coeffs = mfcc(frame: frame) {
                mfccFrames.append(coeffs)
            }
            frameStart += hopLength
        }

        guard mfccFrames.count >= 10 else {
            logger.debug("Not enough frames for embedding (\(mfccFrames.count))")
            return nil
        }

        // Compute delta and delta-delta
        let deltas = computeDeltas(frames: mfccFrames)
        let deltaDeltas = computeDeltas(frames: deltas)

        // Concatenate: [mfcc(13) | delta(13) | delta-delta(13)] per frame
        let featureDim = mfccCoefficients * 3
        var features = [[Float]](repeating: [Float](repeating: 0, count: featureDim), count: mfccFrames.count)
        for i in 0..<mfccFrames.count {
            for j in 0..<mfccCoefficients {
                features[i][j] = mfccFrames[i][j]
                features[i][mfccCoefficients + j] = deltas[i][j]
                features[i][2 * mfccCoefficients + j] = deltaDeltas[i][j]
            }
        }

        // Statistical pooling: mean + std per dimension
        var embedding = [Float](repeating: 0, count: embeddingDimension)
        for dim in 0..<featureDim {
            var values = [Float](repeating: 0, count: features.count)
            for i in 0..<features.count { values[i] = features[i][dim] }

            var mean: Float = 0
            vDSP_meanv(values, 1, &mean, vDSP_Length(values.count))

            var variance: Float = 0
            var centered = values
            var negMean = -mean
            vDSP_vsadd(values, 1, &negMean, &centered, 1, vDSP_Length(values.count))
            vDSP_measqv(centered, 1, &variance, vDSP_Length(centered.count))
            let std = sqrt(variance)

            embedding[dim] = mean
            embedding[featureDim + dim] = std
        }

        // L2 normalize
        var norm: Float = 0
        vDSP_svesq(embedding, 1, &norm, vDSP_Length(embedding.count))
        norm = sqrt(norm)
        guard norm > 1e-6 else { return nil }
        var invNorm = 1.0 / norm
        vDSP_vsmul(embedding, 1, &invNorm, &embedding, 1, vDSP_Length(embedding.count))

        return embedding
    }

    // MARK: - Pre-emphasis

    private func preEmphasize(samples: [Float]) -> [Float] {
        guard samples.count > 1 else { return samples }
        var result = [Float](repeating: 0, count: samples.count)
        result[0] = samples[0]
        for i in 1..<samples.count {
            result[i] = samples[i] - preEmphasis * samples[i - 1]
        }
        return result
    }

    // MARK: - MFCC Per Frame

    private func mfcc(frame: [Float]) -> [Float]? {
        // Apply Hamming window
        var windowed = [Float](repeating: 0, count: frameLength)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(frameLength))

        // Zero-pad to FFT size
        var padded = [Float](repeating: 0, count: fftSize)
        for i in 0..<frameLength { padded[i] = windowed[i] }

        // FFT
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)

        let powerSpectrum: [Float] = real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                padded.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }

                fftSetup.forward(input: splitComplex, output: &splitComplex)

                var power = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&splitComplex, 1, &power, 1, vDSP_Length(fftSize / 2))
                return power
            }
        }

        // Apply mel filterbank
        var melEnergies = [Float](repeating: 0, count: melBands)
        for bandIdx in 0..<melBands {
            let filter = melFilters[bandIdx]
            var energy: Float = 0
            vDSP_dotpr(powerSpectrum, 1, filter, 1, &energy, vDSP_Length(min(powerSpectrum.count, filter.count)))
            melEnergies[bandIdx] = energy
        }

        // Log
        var logMel = [Float](repeating: 0, count: melBands)
        let floorValue: Float = 1e-10
        var floorVec = [Float](repeating: floorValue, count: melBands)
        vDSP_vmax(melEnergies, 1, &floorVec, 1, &logMel, 1, vDSP_Length(melBands))
        var count = Int32(melBands)
        vvlogf(&logMel, logMel, &count)

        // DCT → MFCC coefficients
        var coeffs = [Float](repeating: 0, count: mfccCoefficients)
        for k in 0..<mfccCoefficients {
            var sum: Float = 0
            vDSP_dotpr(logMel, 1, dctMatrix[k], 1, &sum, vDSP_Length(melBands))
            coeffs[k] = sum
        }

        return coeffs
    }

    // MARK: - Deltas

    private func computeDeltas(frames: [[Float]]) -> [[Float]] {
        guard frames.count > 2 else { return frames }
        let dim = frames[0].count
        var result = [[Float]](repeating: [Float](repeating: 0, count: dim), count: frames.count)
        let N = 2 // delta window
        let denom: Float = 2 * (1 * 1 + 2 * 2) // 10

        for t in 0..<frames.count {
            for j in 0..<dim {
                var num: Float = 0
                for n in 1...N {
                    let tBefore = max(0, t - n)
                    let tAfter = min(frames.count - 1, t + n)
                    num += Float(n) * (frames[tAfter][j] - frames[tBefore][j])
                }
                result[t][j] = num / denom
            }
        }
        return result
    }

    // MARK: - Resampling

    /// Linear resampling — good enough for feature extraction.
    /// For bit-accurate resampling use AVAudioConverter, but that's overkill here.
    private func resample(samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard sourceRate != targetRate else { return samples }
        let ratio = targetRate / sourceRate
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIdx = Double(i) / ratio
            let idx0 = Int(srcIdx)
            let idx1 = min(idx0 + 1, samples.count - 1)
            let frac = Float(srcIdx - Double(idx0))
            output[i] = samples[idx0] * (1 - frac) + samples[idx1] * frac
        }
        return output
    }

    // MARK: - Mel Filterbank

    private static func buildMelFilterbank(bands: Int, fftSize: Int, sampleRate: Double, minFreq: Double, maxFreq: Double) -> [[Float]] {
        let bins = fftSize / 2
        let minMel = 2595 * log10(1 + minFreq / 700)
        let maxMel = 2595 * log10(1 + maxFreq / 700)
        let melStep = (maxMel - minMel) / Double(bands + 1)

        var centers = [Int](repeating: 0, count: bands + 2)
        for i in 0..<centers.count {
            let mel = minMel + Double(i) * melStep
            let freq = 700 * (pow(10, mel / 2595) - 1)
            centers[i] = Int(round(freq * Double(fftSize) / sampleRate))
        }

        var filters = [[Float]](repeating: [Float](repeating: 0, count: bins), count: bands)
        for band in 0..<bands {
            let left = centers[band]
            let center = centers[band + 1]
            let right = centers[band + 2]

            for k in left..<center where k < bins && center != left {
                filters[band][k] = Float(k - left) / Float(center - left)
            }
            for k in center..<right where k < bins && right != center {
                filters[band][k] = Float(right - k) / Float(right - center)
            }
        }
        return filters
    }

    // MARK: - DCT Matrix

    private static func buildDCTMatrix(rows: Int, cols: Int) -> [[Float]] {
        var matrix = [[Float]](repeating: [Float](repeating: 0, count: cols), count: rows)
        let scale = sqrt(2.0 / Double(cols))
        for k in 0..<rows {
            for n in 0..<cols {
                matrix[k][n] = Float(scale * cos(Double.pi * Double(k) * (Double(n) + 0.5) / Double(cols)))
            }
        }
        return matrix
    }
}

// MARK: - Service Facade

/// Main-actor facade that exposes the embedding provider to UI and coordinators.
/// Holds a shared instance + helper methods for similarity calculations.
@MainActor
@Observable
final class SpeakerEmbeddingService {

    static let shared = SpeakerEmbeddingService()

    private let provider: SpeakerEmbeddingProvider

    init(provider: SpeakerEmbeddingProvider = MFCCSpeakerEmbeddingProvider()) {
        self.provider = provider
    }

    var embeddingDimension: Int { provider.embeddingDimension }

    /// Extract an embedding for a PCM buffer. Returns nil for silent/short input.
    /// Pure CPU DSP via vDSP — safe to call from any actor.
    nonisolated func embedding(for samples: [Float], sampleRate: Double) -> [Float]? {
        provider.embedding(for: samples, sampleRate: sampleRate)
    }

    /// Cosine similarity between two L2-normalized embeddings (range -1…1).
    /// Pure math — safe to call from any actor.
    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    /// Average a set of L2-normalized embeddings into a single centroid, re-normalized.
    /// Pure math — safe to call from any actor.
    nonisolated static func centroid(of embeddings: [[Float]]) -> [Float]? {
        guard let first = embeddings.first, !embeddings.isEmpty else { return nil }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            guard emb.count == dim else { continue }
            vDSP_vadd(sum, 1, emb, 1, &sum, 1, vDSP_Length(dim))
        }
        var scale = 1.0 / Float(embeddings.count)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(dim))

        // Re-normalize
        var norm: Float = 0
        vDSP_svesq(sum, 1, &norm, vDSP_Length(sum.count))
        norm = sqrt(norm)
        guard norm > 1e-6 else { return nil }
        var invNorm = 1.0 / norm
        vDSP_vsmul(sum, 1, &invNorm, &sum, 1, vDSP_Length(sum.count))
        return sum
    }

    /// Serialize an embedding to `Data` for SwiftData storage.
    nonisolated static func encode(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }

    /// Deserialize an embedding from `Data`.
    nonisolated static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw -> [Float] in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }
}
