//
//  TTSModelManager.swift
//  openTihui
//
//  TTS models are directories and intentionally live outside the GGUF store.
//

import Foundation

struct TTSModelInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let directory: URL
    let sizeBytes: UInt64
    let modelType: String
    let supportsVoiceCloning: Bool
    let quantization: String

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

enum TTSModelImportError: LocalizedError {
    case notDirectory
    case missingFile(String)
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .notDirectory:
            return "Select the Qwen3-TTS model folder, not an individual file."
        case .missingFile(let path):
            return "This is not a complete Qwen3-TTS model folder. Missing: \(path)"
        case .destinationExists:
            return "A TTS model folder with this name already exists. Delete it first or rename the source folder."
        }
    }
}

@MainActor
final class TTSModelManager: ObservableObject {
    @Published private(set) var models: [TTSModelInfo] = []
    @Published var currentModelID: String? {
        didSet { UserDefaults.standard.set(currentModelID, forKey: Self.currentModelKey) }
    }

    private static let currentModelKey = "tts.currentModelDirectory"
    private let fileManager = FileManager.default

    init() {
        currentModelID = UserDefaults.standard.string(forKey: Self.currentModelKey)
        reload()
    }

    static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("TTSModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var outputDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("TTSOutput", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var currentModel: TTSModelInfo? {
        models.first { $0.id == currentModelID }
    }

    func reload() {
        let root = Self.modelsDirectory
        let urls = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        models = urls.compactMap(Self.inspectModel).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if let currentModelID, !models.contains(where: { $0.id == currentModelID }) {
            self.currentModelID = nil
        }
        if currentModelID == nil { currentModelID = models.first?.id }
    }

    func importModelDirectory(_ source: URL) async throws {
        let destinationName = source.lastPathComponent
        let destination = Self.modelsDirectory.appendingPathComponent(destinationName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw TTSModelImportError.destinationExists
        }

        LlamaBridge.appendLogNote("openTihui TTS: import type = model directory, name = \(destinationName)")
        let importedURL = try await Task.detached(priority: .userInitiated) {
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
            try Self.validateModel(at: source)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                try Self.validateModel(at: destination)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }.value

        reload()
        currentModelID = importedURL.lastPathComponent
        LlamaBridge.appendLogNote("openTihui TTS: model import completed — \(importedURL.lastPathComponent)")
    }

    func delete(_ model: TTSModelInfo) throws {
        // Only entries discovered directly under our dedicated TTSModels folder
        // can reach this method; never delete a caller-provided path.
        let root = Self.modelsDirectory.standardizedFileURL
        let target = model.directory.standardizedFileURL
        guard target.deletingLastPathComponent() == root else { return }
        try fileManager.removeItem(at: target)
        LlamaBridge.appendLogNote("openTihui TTS: deleted model directory — \(model.name)")
        reload()
    }

    private nonisolated static func validateModel(at directory: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TTSModelImportError.notDirectory
        }
        let required = [
            "config.json",
            "model.safetensors",
            "tokenizer.json",
            "speech_tokenizer/config.json",
            "speech_tokenizer/model.safetensors"
        ]
        for path in required where !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(path).path
        ) {
            throw TTSModelImportError.missingFile(path)
        }
    }

    private nonisolated static func inspectModel(_ directory: URL) -> TTSModelInfo? {
        guard (try? validateModel(at: directory)) != nil else { return nil }
        let configURL = directory.appendingPathComponent("config.json")
        let json = (try? Data(contentsOf: configURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let modelType = (json["tts_model_type"] as? String) ?? "base"
        let quantization = quantizationDescription(json: json, directoryName: directory.lastPathComponent)
        return TTSModelInfo(
            id: directory.lastPathComponent,
            name: directory.lastPathComponent,
            directory: directory,
            sizeBytes: directorySize(directory),
            modelType: modelType,
            supportsVoiceCloning: modelType == "base",
            quantization: quantization
        )
    }

    private nonisolated static func quantizationDescription(json: [String: Any], directoryName: String) -> String {
        let quant = (json["quantization"] as? [String: Any])
            ?? (json["quantization_config"] as? [String: Any])
        if let bits = quant?["bits"] as? Int { return "\(bits)-bit" }
        let lower = directoryName.lowercased()
        for bits in [4, 6, 8] where lower.contains("\(bits)bit") { return "\(bits)-bit" }
        return quant == nil ? "Full precision / unknown" : "Quantized"
    }

    private nonisolated static func directorySize(_ directory: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }
}
