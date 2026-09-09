//
//  Qwen3TTSEngine.swift
//  openTihui
//

import Foundation
import Qwen3TTS

enum Qwen3TTSError: LocalizedError {
    case notLoaded
    case emptyText

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Load a Qwen3-TTS model first."
        case .emptyText: return "Enter text to synthesize."
        }
    }
}

final class Qwen3TTSEngine: TTSEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: Qwen3TTSPipeline?
    private var generationTask: Task<Int, Error>?

    var isLoaded: Bool {
        locked { pipeline != nil }
    }

    func loadModel(at directory: URL) async throws -> TTSLoadResult {
        await unload()
        let started = Date()
        LlamaBridge.appendLogNote("openTihui TTS: load started — \(directory.lastPathComponent)")
        let loaded = try await Task.detached(priority: .userInitiated) {
            try Qwen3TTSPipeline(modelPath: directory)
        }.value
        let result = TTSLoadResult(
            elapsed: Date().timeIntervalSince(started),
            availableSpeakers: loaded.availableSpeakers.sorted(),
            supportsVoiceCloning: loaded.supportsVoiceCloning
        )
        locked { pipeline = loaded }
        LlamaBridge.appendLogNote(
            "openTihui TTS: load completed — \(String(format: "%.2f", result.elapsed)) s, " +
            "speakers = \(result.availableSpeakers.count), voice clone = \(result.supportsVoiceCloning)"
        )
        return result
    }

    func synthesize(
        _ request: TTSSynthesisRequest,
        to outputURL: URL,
        onProgress: @escaping @Sendable (Int) -> Void
    ) async throws -> TTSSynthesisResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Qwen3TTSError.emptyText }
        let loaded = locked { pipeline }
        guard let loaded else { throw Qwen3TTSError.notLoaded }

        try? FileManager.default.removeItem(at: outputURL)
        let started = Date()
        LlamaBridge.appendLogNote(
            "openTihui TTS: generation started — language = \(request.language.rawValue), " +
            "speaker = \(request.speaker.isEmpty ? "model default" : request.speaker)"
        )
        let task = Task<Int, Error> {
            try await loaded.generateToFile(
                text: text,
                speaker: request.speaker,
                outputURL: outputURL,
                temperature: request.temperature,
                onProgress: { value in onProgress(Int((value * 100).rounded())) }
            )
        }
        locked { generationTask = task }
        defer {
            locked { generationTask = nil }
        }
        let count = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        let result = TTSSynthesisResult(
            outputURL: outputURL,
            elapsed: Date().timeIntervalSince(started),
            sampleCount: count,
            sampleRate: Double(Qwen3TTSPipeline.sampleRate)
        )
        LlamaBridge.appendLogNote(
            "openTihui TTS: generation completed — samples = \(count), synthesis = " +
            "\(String(format: "%.2f", result.elapsed)) s, audio = " +
            "\(String(format: "%.2f", result.audioDuration)) s, RTF = " +
            "\(String(format: "%.2f", result.realTimeFactor))"
        )
        return result
    }

    func stop() {
        let task = locked { generationTask }
        task?.cancel()
        LlamaBridge.appendLogNote("openTihui TTS: stop requested")
    }

    func clearCache() async {
        let (loaded, busy) = locked { (pipeline, generationTask != nil) }
        guard !busy else {
            LlamaBridge.appendLogNote("openTihui TTS: cache clear deferred while generation is active")
            return
        }
        await Task.detached(priority: .utility) { loaded?.clearCache() }.value
        LlamaBridge.appendLogNote("openTihui TTS: MLX cache cleared")
    }

    func unload() async {
        let task = locked { generationTask }
        task?.cancel()
        if let task { _ = try? await task.value }

        let loaded = locked {
            let current = pipeline
            pipeline = nil
            generationTask = nil
            return current
        }
        await Task.detached(priority: .utility) { loaded?.clearCache() }.value
        LlamaBridge.appendLogNote("openTihui TTS: model unloaded and MLX cache cleared")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
