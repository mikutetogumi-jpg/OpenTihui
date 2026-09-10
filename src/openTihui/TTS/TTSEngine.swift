//
//  TTSEngine.swift
//  openTihui
//
//  Provider-neutral boundary for local text-to-speech. The llama.cpp chat
//  engine deliberately does not know about this module.
//

import Foundation

enum TTSLanguage: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case chinese = "Chinese"
    case english = "English"
    case japanese = "Japanese"

    var id: String { rawValue }
}

struct TTSSynthesisRequest: Sendable {
    let text: String
    let language: TTSLanguage
    let speaker: String
    let speakerEmbedding: [Float]?
    let referenceTranscript: String?
    let referenceAudioCodes: [[Int32]]?
    let temperature: Float
}

struct TTSLoadResult: Sendable {
    let elapsed: TimeInterval
    let availableSpeakers: [String]
    let supportsVoiceCloning: Bool
    let supportsICL: Bool
}

struct TTSSynthesisResult: Sendable {
    let outputURL: URL
    let elapsed: TimeInterval
    let sampleCount: Int
    let sampleRate: Double

    var audioDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / sampleRate
    }

    var realTimeFactor: Double {
        guard audioDuration > 0 else { return 0 }
        return elapsed / audioDuration
    }
}

protocol TTSEngine: AnyObject {
    var isLoaded: Bool { get }

    func loadModel(at directory: URL) async throws -> TTSLoadResult
    func synthesize(
        _ request: TTSSynthesisRequest,
        to outputURL: URL,
        onProgress: @escaping @Sendable (Int) -> Void
    ) async throws -> TTSSynthesisResult
    func encodeReferenceAudio(audioSamples: [Float]) async throws -> [[Int32]]
    func stop()
    func clearCache() async
    func unload() async
}
