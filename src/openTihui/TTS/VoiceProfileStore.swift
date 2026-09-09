//
//  VoiceProfileStore.swift
//  openTihui
//

import Foundation

struct VoiceProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let referenceAudioPath: String
    let referenceText: String
    let speakerEmbeddingPath: String
    let language: String
}

enum VoiceProfileError: LocalizedError {
    case emptyName
    case emptyTranscript
    case missingEmbedding
    case invalidProfile

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the Voice Profile."
        case .emptyTranscript: return "Enter the exact transcript of the reference WAV."
        case .missingEmbedding: return "Extract a speaker embedding before saving the Voice Profile."
        case .invalidProfile: return "The saved Voice Profile is incomplete or damaged."
        }
    }
}

@MainActor
final class VoiceProfileStore: ObservableObject {
    @Published private(set) var profiles: [VoiceProfile] = []
    @Published var currentProfileID: UUID? {
        didSet { UserDefaults.standard.set(currentProfileID?.uuidString, forKey: Self.currentKey) }
    }

    private static let currentKey = "tts.currentVoiceProfile"
    private let fileManager = FileManager.default

    init() {
        currentProfileID = UserDefaults.standard.string(forKey: Self.currentKey).flatMap {
            UUID(uuidString: $0)
        }
        reload()
    }

    static var profilesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("VoiceProfiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var currentProfile: VoiceProfile? {
        profiles.first { $0.id == currentProfileID }
    }

    func create(
        name: String,
        referenceAudio source: URL,
        referenceText: String,
        language: String,
        embedding: [Float]
    ) async throws -> VoiceProfile {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw VoiceProfileError.emptyName }
        guard !trimmedText.isEmpty else { throw VoiceProfileError.emptyTranscript }
        guard !embedding.isEmpty else { throw VoiceProfileError.missingEmbedding }

        let id = UUID()
        let directory = Self.profilesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        let audioName = "reference.\(source.pathExtension.lowercased())"
        let profile = VoiceProfile(
            id: id,
            name: trimmedName,
            referenceAudioPath: audioName,
            referenceText: trimmedText,
            speakerEmbeddingPath: "speaker-embedding.json",
            language: language
        )
        try await Task.detached(priority: .userInitiated) {
            let didAccess = source.startAccessingSecurityScopedResource()
            defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: source,
                    to: directory.appendingPathComponent(audioName)
                )
                try JSONEncoder().encode(embedding).write(
                    to: directory.appendingPathComponent(profile.speakerEmbeddingPath),
                    options: .atomic
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(profile).write(
                    to: directory.appendingPathComponent("profile.json"),
                    options: .atomic
                )
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
        reload()
        currentProfileID = profile.id
        return profile
    }

    func loadEmbedding(for profile: VoiceProfile) throws -> [Float] {
        let url = profileDirectory(profile).appendingPathComponent(profile.speakerEmbeddingPath)
        guard let data = try? Data(contentsOf: url),
              let embedding = try? JSONDecoder().decode([Float].self, from: data),
              !embedding.isEmpty else {
            throw VoiceProfileError.invalidProfile
        }
        return embedding
    }

    func delete(_ profile: VoiceProfile) throws {
        let root = Self.profilesDirectory.standardizedFileURL
        let target = profileDirectory(profile).standardizedFileURL
        guard target.deletingLastPathComponent() == root else { return }
        try fileManager.removeItem(at: target)
        reload()
    }

    func reload() {
        let root = Self.profilesDirectory
        let directories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        profiles = directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("profile.json")),
                  let profile = try? JSONDecoder().decode(VoiceProfile.self, from: data),
                  profile.id.uuidString == directory.lastPathComponent,
                  fileManager.fileExists(atPath: directory.appendingPathComponent(profile.referenceAudioPath).path),
                  fileManager.fileExists(atPath: directory.appendingPathComponent(profile.speakerEmbeddingPath).path)
            else { return nil }
            return profile
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let currentProfileID, !profiles.contains(where: { $0.id == currentProfileID }) {
            self.currentProfileID = nil
        }
        if currentProfileID == nil { currentProfileID = profiles.first?.id }
    }

    private func profileDirectory(_ profile: VoiceProfile) -> URL {
        Self.profilesDirectory.appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }
}
