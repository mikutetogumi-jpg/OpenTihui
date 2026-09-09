//
//  ReferenceAudioLoader.swift
//  openTihui
//

import AVFoundation
import Foundation

struct ReferenceAudioData: Sendable {
    let samples: [Float]
    let duration: TimeInterval
}

enum ReferenceAudioError: LocalizedError {
    case empty
    case tooLong
    case unsupportedFormat
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The reference WAV contains no audio."
        case .tooLong:
            return "Keep the reference WAV under 30 seconds for this device test."
        case .unsupportedFormat:
            return "The reference audio could not be converted to mono PCM. Use a normal WAV file."
        case .conversionFailed(let message):
            return "Reference audio conversion failed: \(message)"
        }
    }
}

enum ReferenceAudioLoader {
    /// The package's speaker encoder expects raw samples and recommends 16 kHz.
    static func loadForSpeakerEmbedding(from url: URL) async throws -> ReferenceAudioData {
        try await Task.detached(priority: .userInitiated) {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            let file = try AVAudioFile(forReading: url)
            let sourceFormat = file.processingFormat
            guard file.length > 0, sourceFormat.sampleRate > 0 else {
                throw ReferenceAudioError.empty
            }
            let duration = Double(file.length) / sourceFormat.sampleRate
            guard duration <= 30 else { throw ReferenceAudioError.tooLong }

            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { throw ReferenceAudioError.unsupportedFormat }
            try file.read(into: sourceBuffer)

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw ReferenceAudioError.unsupportedFormat
            }

            let targetCapacity = AVAudioFrameCount(ceil(duration * targetFormat.sampleRate)) + 1
            guard let targetBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: targetCapacity
            ) else { throw ReferenceAudioError.unsupportedFormat }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: targetBuffer, error: &conversionError) { _, outputStatus in
                if suppliedInput {
                    outputStatus.pointee = .endOfStream
                    return nil
                }
                suppliedInput = true
                outputStatus.pointee = .haveData
                return sourceBuffer
            }
            if status == .error {
                throw ReferenceAudioError.conversionFailed(
                    conversionError?.localizedDescription ?? "unknown AVFoundation error"
                )
            }
            guard targetBuffer.frameLength > 0,
                  let channel = targetBuffer.floatChannelData?[0] else {
                throw ReferenceAudioError.empty
            }
            let samples = Array(UnsafeBufferPointer(
                start: channel,
                count: Int(targetBuffer.frameLength)
            ))
            guard !samples.isEmpty else { throw ReferenceAudioError.empty }
            return ReferenceAudioData(samples: samples, duration: duration)
        }.value
    }
}
