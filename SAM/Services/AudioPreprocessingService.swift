//
//  AudioPreprocessingService.swift
//  SAM
//
//  On-device audio cleanup for meeting recordings before STT and
//  diarization. iPhone recordings from across a table are typically
//  noisy (HVAC, traffic, keyboard), have uneven volume (near speaker
//  loud, far speaker quiet), and carry room reverb that smears the
//  spectral envelope.
//
//  This service applies three lightweight passes using Accelerate/vDSP:
//
//    1. High-pass filter at 80 Hz — removes DC offset, rumble, and
//       low-frequency HVAC drone that eats up dynamic range.
//
//    2. Spectral noise gate — estimates the noise floor from the
//       quietest 10% of frames, then attenuates frequency bins where
//       energy is close to the noise floor. Preserves speech harmonics
//       while suppressing broadband noise.
//
//    3. Automatic gain control (AGC) — sliding-window RMS normalization
//       brings quiet speech up and attenuates loud peaks, so Whisper
//       and the speaker embedding model see consistent levels across
//       the recording.
//
//  None of these passes remove signal that downstream models need:
//    - Whisper wants clean speech, not noise.
//    - ECAPA-TDNN / MFCC want vocal characteristics, not room reverb.
//    - Both benefit from consistent volume.
//
//  Performance: the three passes together process 1 minute of 16kHz
//  audio in <100ms on Apple Silicon. Safe to run synchronously before
//  the pipeline.
//

import Foundation
import Accelerate
import os.log

/// Explicit Sendable wrappers for raw pointers passed into
/// `DispatchQueue.concurrentPerform`'s `@Sendable` worker closures. Each
/// worker reads/writes disjoint slices, so no synchronization is needed
/// — the wrappers just declare that intent to the compiler.
private struct SendablePtr<T>: @unchecked Sendable {
    let ptr: UnsafeMutablePointer<T>
}
private struct SendableConstPtr<T>: @unchecked Sendable {
    let ptr: UnsafePointer<T>
}

nonisolated struct AudioPreprocessingService {

    private nonisolated static var logger: Logger {
        Logger(subsystem: "com.matthewsessions.SAM", category: "AudioPreprocessing")
    }

    // MARK: - Configuration

    /// Cutoff frequency for the high-pass filter (Hz).
    static let highPassCutoff: Float = 80

    /// Target RMS level for AGC output (0.0–1.0 range, where 1.0 is full scale).
    static let targetRMS: Float = 0.10

    /// AGC window size in seconds. Shorter = more responsive to volume changes,
    /// longer = smoother. 0.5s is a good balance for conversational speech.
    static let agcWindowSeconds: Float = 0.5

    /// How aggressively the noise gate attenuates. 1.0 = full suppression
    /// of noise-floor bins, 0.5 = half suppression (gentler, fewer artifacts).
    static let noiseGateStrength: Float = 0.85

    /// Percentile of frame energies used to estimate the noise floor.
    /// 0.10 = quietest 10% of frames define "noise".
    static let noiseFloorPercentile: Float = 0.10

    // MARK: - Public API

    /// Apply the full preprocessing pipeline to a mono PCM buffer.
    /// Returns the cleaned buffer at the same sample rate.
    nonisolated static func preprocess(
        samples: [Float],
        sampleRate: Float
    ) -> [Float] {
        guard samples.count > Int(sampleRate * 0.1) else {
            // Too short to meaningfully preprocess
            return samples
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. High-pass filter — remove rumble and DC offset
        var filtered = highPassFilter(samples, sampleRate: sampleRate, cutoff: highPassCutoff)

        // 2. Spectral noise gate — suppress broadband noise
        filtered = spectralNoiseGate(filtered, sampleRate: sampleRate)

        // 3. AGC — normalize volume across the recording
        filtered = automaticGainControl(filtered, sampleRate: sampleRate)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        logger.info("Audio preprocessing: \(samples.count) samples in \(String(format: "%.1f", elapsed * 1000))ms")

        return filtered
    }

    // MARK: - High-Pass Filter

    /// Single-pole IIR high-pass filter. Removes energy below `cutoff` Hz.
    /// Efficient and introduces minimal phase distortion in the speech band.
    static func highPassFilter(
        _ samples: [Float],
        sampleRate: Float,
        cutoff: Float
    ) -> [Float] {
        let rc = 1.0 / (2.0 * Float.pi * cutoff)
        let dt = 1.0 / sampleRate
        let alpha = rc / (rc + dt)

        var output = [Float](repeating: 0, count: samples.count)
        output[0] = samples[0]
        for i in 1..<samples.count {
            output[i] = alpha * (output[i - 1] + samples[i] - samples[i - 1])
        }
        return output
    }

    // MARK: - Spectral Noise Gate

    /// Estimate the noise floor from quiet frames, then suppress frequency
    /// bins that are close to the noise floor. Works in the frequency domain
    /// using overlapping STFT frames.
    ///
    /// On long recordings (60+ minutes) the frame loops are the dominant
    /// cost of the reprocess pipeline, so both passes are parallelized
    /// across cores via `DispatchQueue.concurrentPerform`:
    ///
    ///   Pass 1 is fully data-parallel — each frame independently writes
    ///   its magnitude spectrum and energy scalar to a distinct slot in
    ///   flat output arrays.
    ///
    ///   Pass 2's overlap-add writes to a shared output buffer, so we
    ///   parallelize with a 2-coloring: even-indexed frames are processed
    ///   in parallel first (each touches [k*frameSize, (k+1)*frameSize),
    ///   all disjoint), then odd-indexed frames in a second pass.
    ///
    /// Each worker keeps its own FFT setup and scratch buffers, so the
    /// inner loops reuse memory across all frames in that worker's chunk
    /// instead of allocating per-frame.
    static func spectralNoiseGate(
        _ samples: [Float],
        sampleRate: Float
    ) -> [Float] {
        let frameSize = 1024
        let hopSize = frameSize / 2
        guard samples.count >= frameSize else { return samples }

        let frameCount = (samples.count - frameSize) / hopSize + 1
        guard frameCount > 0 else { return samples }

        // Build Hamming window
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hamm_window(&window, vDSP_Length(frameSize), 0)

        let log2n = vDSP_Length(log2(Float(frameSize)))
        let halfN = frameSize / 2

        // Reserve ~25% of cores (floor 2) so the OS scheduler, UI thread,
        // and FoundationModels dispatch always have headroom. With all
        // cores pinned, FoundationModels calls in other coordinators can
        // blow past their 30s timeout waiting for CPU. Scales across
        // machines: an 8-core MacBook Air yields 6 workers, a 24-core
        // Mac Studio yields 18.
        let totalCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let reservedCores = max(2, totalCores / 4)
        let coreCount = max(1, totalCores - reservedCores)

        // Flat storage so workers write to disjoint slices without any
        // ARC overhead. frameMagnitudesFlat[frameIdx*halfN + bin] = magnitude.
        var frameMagnitudesFlat = [Float](repeating: 0, count: frameCount * halfN)
        var frameEnergies = [Float](repeating: 0, count: frameCount)

        // ==== Pass 1: magnitudes + energies (fully data-parallel) ====
        samples.withUnsafeBufferPointer { samplesPtr in
            window.withUnsafeBufferPointer { windowPtr in
                frameMagnitudesFlat.withUnsafeMutableBufferPointer { magPtr in
                    frameEnergies.withUnsafeMutableBufferPointer { energyPtr in
                        let sampleBase = SendableConstPtr(ptr: samplesPtr.baseAddress!)
                        let sampleCount = samplesPtr.count
                        let windowBase = SendableConstPtr(ptr: windowPtr.baseAddress!)
                        let magBase = SendablePtr(ptr: magPtr.baseAddress!)
                        let energyBase = SendablePtr(ptr: energyPtr.baseAddress!)

                        DispatchQueue.concurrentPerform(iterations: coreCount) { workerIdx in
                            guard let localSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
                            defer { vDSP_destroy_fftsetup(localSetup) }

                            var frame = [Float](repeating: 0, count: frameSize)
                            var realPart = [Float](repeating: 0, count: halfN)
                            var imagPart = [Float](repeating: 0, count: halfN)

                            var frameIdx = workerIdx
                            while frameIdx < frameCount {
                                let start = frameIdx * hopSize
                                let copyLen = min(frameSize, sampleCount - start)

                                for i in 0..<frameSize { frame[i] = 0 }
                                for i in 0..<copyLen { frame[i] = sampleBase.ptr[start + i] }

                                vDSP_vmul(frame, 1, windowBase.ptr, 1, &frame, 1, vDSP_Length(frameSize))

                                frame.withUnsafeBufferPointer { framePtr in
                                    realPart.withUnsafeMutableBufferPointer { realP in
                                        imagPart.withUnsafeMutableBufferPointer { imagP in
                                            var sc = DSPSplitComplex(realp: realP.baseAddress!, imagp: imagP.baseAddress!)
                                            framePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                                                vDSP_ctoz(cPtr, 2, &sc, 1, vDSP_Length(halfN))
                                            }
                                            vDSP_fft_zrip(localSetup, &sc, 1, log2n, FFTDirection(kFFTDirection_Forward))
                                        }
                                    }
                                }

                                let outSlot = magBase.ptr.advanced(by: frameIdx * halfN)
                                realPart.withUnsafeBufferPointer { rp in
                                    imagPart.withUnsafeBufferPointer { ip in
                                        var sc = DSPSplitComplex(
                                            realp: UnsafeMutablePointer(mutating: rp.baseAddress!),
                                            imagp: UnsafeMutablePointer(mutating: ip.baseAddress!)
                                        )
                                        vDSP_zvabs(&sc, 1, outSlot, 1, vDSP_Length(halfN))
                                    }
                                }

                                var energy: Float = 0
                                vDSP_sve(outSlot, 1, &energy, vDSP_Length(halfN))
                                energyBase.ptr[frameIdx] = energy

                                frameIdx += coreCount
                            }
                        }
                    }
                }
            }
        }

        // Noise floor estimation — serial, cheap compared to the FFT passes.
        var sortedEnergies = frameEnergies
        sortedEnergies.sort()
        let noiseFrameCount = max(1, Int(Float(frameCount) * noiseFloorPercentile))
        let energyThreshold = sortedEnergies[min(noiseFrameCount, sortedEnergies.count - 1)]

        var noiseSpectrum = [Float](repeating: 0, count: halfN)
        var noiseCount: Float = 0
        frameMagnitudesFlat.withUnsafeBufferPointer { magPtr in
            let magBase = magPtr.baseAddress!
            for i in 0..<frameCount where frameEnergies[i] <= energyThreshold {
                let src = magBase.advanced(by: i * halfN)
                vDSP_vadd(noiseSpectrum, 1, src, 1, &noiseSpectrum, 1, vDSP_Length(halfN))
                noiseCount += 1
            }
        }
        if noiseCount > 0 {
            var scale = 1.0 / noiseCount
            vDSP_vsmul(noiseSpectrum, 1, &scale, &noiseSpectrum, 1, vDSP_Length(halfN))
        }

        // ==== Pass 2: FFT + gain mask + IFFT + overlap-add ====
        var output = [Float](repeating: 0, count: samples.count)
        var windowSum = [Float](repeating: 0, count: samples.count)

        // 2-coloring: within one color, frame ranges [k*frameSize, (k+1)*frameSize)
        // are disjoint, so overlap-add writes from different workers never
        // collide. Color 0 = even-indexed frames, color 1 = odd-indexed.
        func runPass2(color: Int) {
            samples.withUnsafeBufferPointer { samplesPtr in
                window.withUnsafeBufferPointer { windowPtr in
                    noiseSpectrum.withUnsafeBufferPointer { noisePtr in
                        frameMagnitudesFlat.withUnsafeBufferPointer { magPtr in
                            output.withUnsafeMutableBufferPointer { outPtr in
                                windowSum.withUnsafeMutableBufferPointer { wsumPtr in
                                    let sampleBase = SendableConstPtr(ptr: samplesPtr.baseAddress!)
                                    let sampleCount = samplesPtr.count
                                    let windowBase = SendableConstPtr(ptr: windowPtr.baseAddress!)
                                    let noiseBase = SendableConstPtr(ptr: noisePtr.baseAddress!)
                                    let magBase = SendableConstPtr(ptr: magPtr.baseAddress!)
                                    let outBase = SendablePtr(ptr: outPtr.baseAddress!)
                                    let wsumBase = SendablePtr(ptr: wsumPtr.baseAddress!)

                                    DispatchQueue.concurrentPerform(iterations: coreCount) { workerIdx in
                                        guard let localSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
                                        defer { vDSP_destroy_fftsetup(localSetup) }

                                        var frame = [Float](repeating: 0, count: frameSize)
                                        var realPart = [Float](repeating: 0, count: halfN)
                                        var imagPart = [Float](repeating: 0, count: halfN)
                                        var reconstructed = [Float](repeating: 0, count: frameSize)

                                        var frameIdx = workerIdx * 2 + color
                                        while frameIdx < frameCount {
                                            let start = frameIdx * hopSize
                                            let copyLen = min(frameSize, sampleCount - start)

                                            for i in 0..<frameSize { frame[i] = 0 }
                                            for i in 0..<copyLen { frame[i] = sampleBase.ptr[start + i] }
                                            vDSP_vmul(frame, 1, windowBase.ptr, 1, &frame, 1, vDSP_Length(frameSize))

                                            frame.withUnsafeBufferPointer { framePtr in
                                                realPart.withUnsafeMutableBufferPointer { realP in
                                                    imagPart.withUnsafeMutableBufferPointer { imagP in
                                                        var sc = DSPSplitComplex(realp: realP.baseAddress!, imagp: imagP.baseAddress!)
                                                        framePtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                                                            vDSP_ctoz(cPtr, 2, &sc, 1, vDSP_Length(halfN))
                                                        }
                                                        vDSP_fft_zrip(localSetup, &sc, 1, log2n, FFTDirection(kFFTDirection_Forward))
                                                    }
                                                }
                                            }

                                            let magSlot = magBase.ptr.advanced(by: frameIdx * halfN)
                                            for bin in 0..<halfN {
                                                let noiseMag = noiseBase.ptr[bin]
                                                let sigMag = magSlot[bin]
                                                var gain: Float = 1.0
                                                if sigMag > 1e-10 {
                                                    gain = max(0, 1.0 - noiseGateStrength * (noiseMag / sigMag))
                                                } else {
                                                    gain = 0
                                                }
                                                realPart[bin] *= gain
                                                imagPart[bin] *= gain
                                            }

                                            realPart.withUnsafeMutableBufferPointer { realP in
                                                imagPart.withUnsafeMutableBufferPointer { imagP in
                                                    var sc = DSPSplitComplex(realp: realP.baseAddress!, imagp: imagP.baseAddress!)
                                                    vDSP_fft_zrip(localSetup, &sc, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                                                    reconstructed.withUnsafeMutableBufferPointer { outB in
                                                        outB.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cPtr in
                                                            vDSP_ztoc(&sc, 1, cPtr, 2, vDSP_Length(halfN))
                                                        }
                                                    }
                                                }
                                            }

                                            var fftScale = 1.0 / Float(2 * frameSize)
                                            vDSP_vsmul(reconstructed, 1, &fftScale, &reconstructed, 1, vDSP_Length(frameSize))

                                            for i in 0..<frameSize where start + i < sampleCount {
                                                outBase.ptr[start + i] += reconstructed[i] * windowBase.ptr[i]
                                                wsumBase.ptr[start + i] += windowBase.ptr[i] * windowBase.ptr[i]
                                            }

                                            frameIdx += coreCount * 2
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        runPass2(color: 0)
        runPass2(color: 1)

        // Normalize by window sum to complete overlap-add
        for i in 0..<output.count {
            if windowSum[i] > 1e-6 {
                output[i] /= windowSum[i]
            }
        }

        return output
    }

    // MARK: - Automatic Gain Control

    /// Sliding-window RMS normalization. Measures the RMS energy in a
    /// window around each sample and scales to reach `targetRMS`.
    /// Uses a smooth gain envelope to avoid clicks/pops.
    static func automaticGainControl(
        _ samples: [Float],
        sampleRate: Float
    ) -> [Float] {
        let windowSamples = Int(agcWindowSeconds * sampleRate)
        guard windowSamples > 0, samples.count > windowSamples else { return samples }

        // Compute per-sample squared values for efficient RMS
        var squared = [Float](repeating: 0, count: samples.count)
        vDSP_vsq(samples, 1, &squared, 1, vDSP_Length(samples.count))

        var output = [Float](repeating: 0, count: samples.count)
        let halfWindow = windowSamples / 2

        // Running sum for efficient sliding window
        var runningSum: Float = 0
        for i in 0..<min(windowSamples, samples.count) {
            runningSum += squared[i]
        }

        var prevGain: Float = 1.0
        let smoothingAlpha: Float = 0.01 // Gain smoothing to avoid clicks

        for i in 0..<samples.count {
            // Maintain the sliding window
            let windowStart = max(0, i - halfWindow)
            let windowEnd = min(samples.count - 1, i + halfWindow)
            let windowLen = windowEnd - windowStart + 1

            // Compute local RMS
            // (Recompute periodically for accuracy; running sum drifts)
            if i % 1000 == 0 || i == 0 {
                runningSum = 0
                for j in windowStart...windowEnd {
                    runningSum += squared[j]
                }
            } else {
                // Incremental update
                if i + halfWindow < samples.count {
                    runningSum += squared[i + halfWindow]
                }
                if i - halfWindow - 1 >= 0 {
                    runningSum -= squared[i - halfWindow - 1]
                }
            }

            let rms = sqrt(max(runningSum / Float(windowLen), 1e-10))

            // Compute desired gain, clamped to avoid extreme amplification
            let desiredGain = min(targetRMS / rms, 10.0) // Max 10x boost

            // Smooth the gain to prevent clicks
            let gain = prevGain + smoothingAlpha * (desiredGain - prevGain)
            prevGain = gain

            output[i] = samples[i] * gain
        }

        // Final clipping guard — prevent any samples from exceeding ±1.0
        var minVal: Float = -1.0
        var maxVal: Float = 1.0
        vDSP_vclip(output, 1, &minVal, &maxVal, &output, 1, vDSP_Length(output.count))

        return output
    }
}
