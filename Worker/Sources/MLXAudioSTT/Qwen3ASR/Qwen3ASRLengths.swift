//
//  Qwen3ASRLengths.swift
//  MLXAudioSTT
//
// Created by Prince Canuma on 06/02/2026.
//

import Foundation
import MLX
import MLXNN
import MLXAudioCore
import MLXLMCommon
import Tokenizers

// MARK: - Helper Functions

private func floorDiv(_ a: MLXArray, _ b: Int) -> MLXArray {
    return floor(a.asType(.float32) / Float(b)).asType(.int32)
}

/// Conv output lengths per chunk. `inputLengths / 100` is the port's Float32 true division (the Python reference
/// floors it), so a partial last chunk keeps up to 12 extra audio tokens over its zero padding; Vella's parity
/// reference is this stock behaviour.
func getFeatExtractOutputLengths(_ inputLengths: MLXArray) -> MLXArray {
    let inputLengthsLeave = inputLengths % 100
    let featLengths = floorDiv(inputLengthsLeave - 1, 2) + 1
    let outputLengths = (
        floorDiv(floorDiv(featLengths - 1, 2) + 1 - 1, 2)
        + 1
        + inputLengths / 100 * 13
    )
    return outputLengths
}

/// `getFeatExtractOutputLengths` for one length, on the host, so the optimized encoder needs no device round trip per
/// conv chunk. Replays the device arithmetic exactly: `inputLengths / 100` is a Float32 true division there (the
/// Python reference floors it), so a partial chunk's length gains a fraction that `item(Int32)` truncates.
func featExtractOutputLength(_ inputLength: Int) -> Int {
    func floorDiv(_ a: Int, _ b: Int) -> Int { Int((Double(a) / Double(b)).rounded(.down)) }
    let featLength = floorDiv(inputLength % 100 - 1, 2) + 1
    let integerPart = floorDiv(floorDiv(featLength - 1, 2) + 1 - 1, 2) + 1
    let fraction: Float = Float(inputLength) / Float(100) * Float(13)
    return Int(Float(integerPart) + fraction)
}

func computeChunkedEncoderWindowLengths(
    chunkFeatureLengthsAfterCnn: [Int],
    chunkCountsPerInput: [Int],
    chunksPerWindow: Int
) -> [Int] {
    let clampedChunksPerWindow = max(1, chunksPerWindow)
    var windowLengths: [Int] = []
    var chunkOffset = 0

    for chunkCount in chunkCountsPerInput {
        var remaining = chunkCount
        while remaining > 0 {
            let take = min(clampedChunksPerWindow, remaining)
            let end = min(chunkOffset + take, chunkFeatureLengthsAfterCnn.count)
            guard chunkOffset < end else { break }

            let windowLen = chunkFeatureLengthsAfterCnn[chunkOffset..<end].reduce(0, +)
            if windowLen > 0 {
                windowLengths.append(windowLen)
            }

            chunkOffset = end
            remaining -= take
        }
    }

    if chunkOffset < chunkFeatureLengthsAfterCnn.count {
        windowLengths.append(chunkFeatureLengthsAfterCnn[chunkOffset...].reduce(0, +))
    }

    return windowLengths
}

// MARK: - Audio Chunking

/// Split long audio into chunks at low-energy boundaries.
///
/// - Parameters:
///   - audio: 1D audio waveform as MLXArray
///   - sampleRate: Sample rate of the audio
///   - chunkDuration: Maximum chunk duration in seconds (default: 1200 = 20 min)
///   - minChunkDuration: Minimum chunk duration in seconds (default: 1.0)
///   - searchExpandSec: Window to search for silence around cut point (default: 5.0)
///   - minWindowMs: Minimum window size for energy calculation in ms (default: 100.0)
/// - Returns: Array of (chunk waveform, offset in seconds) tuples
public func splitAudioIntoChunks(
    _ audio: MLXArray,
    sampleRate: Int,
    chunkDuration: Float = 1200.0,
    minChunkDuration: Float = 1.0,
    searchExpandSec: Float = 5.0,
    minWindowMs: Float = 100.0
) -> [(MLXArray, Float)] {
    // Ensure 1D
    let wav: MLXArray
    if audio.ndim > 1 {
        wav = audio.mean(axis: -1)
    } else {
        wav = audio
    }

    let totalSamples = wav.dim(0)
    let totalSec = Float(totalSamples) / Float(sampleRate)

    if totalSec <= chunkDuration {
        if totalSec < minChunkDuration {
            let minSamples = Int(minChunkDuration * Float(sampleRate))
            let padWidth = minSamples - totalSamples
            if padWidth > 0 {
                let padded = MLX.padded(wav, widths: [IntOrPair((0, padWidth))])
                return [(padded, 0.0)]
            }
        }
        return [(wav, 0.0)]
    }

    var chunks: [(MLXArray, Float)] = []
    var startSample = 0
    let maxChunkSamples = Int(chunkDuration * Float(sampleRate))
    let searchSamples = Int(searchExpandSec * Float(sampleRate))
    let minWindowSamples = Int(minWindowMs * Float(sampleRate) / 1000.0)
    let minSamples = Int(minChunkDuration * Float(sampleRate))

    while startSample < totalSamples {
        let endSample = min(startSample + maxChunkSamples, totalSamples)

        if endSample >= totalSamples {
            let chunkLen = totalSamples - startSample
            var chunk = wav[startSample..<totalSamples]
            let offsetSec = Float(startSample) / Float(sampleRate)
            if chunkLen < minSamples {
                let padWidth = minSamples - chunkLen
                chunk = MLX.padded(chunk, widths: [IntOrPair((0, padWidth))])
            }
            chunks.append((chunk, offsetSec))
            break
        }

        // Search for low-energy point around the cut
        let searchStart = max(startSample, endSample - searchSamples)
        let searchEnd = min(totalSamples, endSample + searchSamples)

        var cutSample: Int
        let searchLen = searchEnd - searchStart
        if searchLen > minWindowSamples {
            // Only pull the search region to CPU for energy calculation
            let searchRegion = wav[searchStart..<searchEnd].asArray(Float.self)

            let energyLen = searchRegion.count - minWindowSamples + 1
            var energy = [Float](repeating: 0, count: energyLen)
            let invWindow = 1.0 / Float(minWindowSamples)

            var windowSum: Float = 0
            for i in 0..<minWindowSamples {
                windowSum += searchRegion[i] * searchRegion[i]
            }
            energy[0] = windowSum * invWindow

            for i in 1..<energyLen {
                let oldVal = searchRegion[i - 1]
                let newVal = searchRegion[i + minWindowSamples - 1]
                windowSum += newVal * newVal - oldVal * oldVal
                energy[i] = windowSum * invWindow
            }

            // Find minimum energy point
            var minIdx = 0
            var minEnergy = energy[0]
            for i in 1..<energyLen {
                if energy[i] < minEnergy {
                    minEnergy = energy[i]
                    minIdx = i
                }
            }
            minIdx += minWindowSamples / 2
            cutSample = searchStart + minIdx
        } else {
            cutSample = endSample
        }

        cutSample = max(cutSample, startSample + sampleRate)

        let actualEnd = min(cutSample, totalSamples)
        let chunkLen = actualEnd - startSample
        var chunk = wav[startSample..<actualEnd]
        let offsetSec = Float(startSample) / Float(sampleRate)

        if chunkLen < minSamples {
            let padWidth = minSamples - chunkLen
            chunk = MLX.padded(chunk, widths: [IntOrPair((0, padWidth))])
        }

        chunks.append((chunk, offsetSec))
        startSample = cutSample
    }

    return chunks
}
