//
//  TTSDebugView.swift
//  openTihui
//

import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TTSDebugViewModel: ObservableObject {
    private static let persistedLogKey = "openTihui.ttsDebug.recentLog"
    private static let maximumPersistedLogLines = 80

    @Published var text = "你好，这是 Qwen3-TTS 在 iPhone 上运行的本地语音测试。"
    @Published var language: TTSLanguage = .automatic
    @Published var speaker = ""
    @Published var temperature: Double = 0.7
    @Published private(set) var speakers: [String] = []
    @Published private(set) var supportsVoiceCloning = false
    @Published private(set) var loadedModelID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var isExtractingVoice = false
    @Published private(set) var referenceAudioURL: URL?
    @Published var voiceProfileName = ""
    @Published var referenceText = ""
    @Published private(set) var progress = 0
    @Published private(set) var loadTime: TimeInterval?
    @Published private(set) var synthesis: TTSSynthesisResult?
    @Published private(set) var logLines: [String] = []
    @Published var errorMessage: String?

    let player = AudioPlayer()
    private let engine = Qwen3TTSEngine()
    private var workTask: Task<Void, Never>?
    private var memorySampler: Task<Void, Never>?
    private var lowestAvailableBytes: UInt64?

    init() {
        logLines = UserDefaults.standard.stringArray(forKey: Self.persistedLogKey) ?? []
    }

    func load(_ model: TTSModelInfo, chat: ChatViewModel) {
        guard !isLoading, !isGenerating, !isExtractingVoice else { return }
        stop()
        chat.unload()
        append("GGUF model unloaded before TTS load")
        let before = availableMemory()
        appendMemory("Before load", bytes: before)
        isLoading = true
        errorMessage = nil
        workTask = Task {
            do {
                let result = try await engine.loadModel(at: model.directory)
                loadedModelID = model.id
                loadTime = result.elapsed
                speakers = result.availableSpeakers
                supportsVoiceCloning = result.supportsVoiceCloning
                speaker = speakers.first ?? ""
                append("Loaded \(model.name) in \(format(result.elapsed)) s; voice clone = \(result.supportsVoiceCloning)")
                appendMemory("After load", bytes: availableMemory())
                if speakers.isEmpty {
                    append("No built-in speakers reported; this model may require a voice reference in the later Voice Clone phase")
                }
            } catch {
                fail(error)
            }
            isLoading = false
        }
    }

    func selectReferenceAudio(_ url: URL) {
        referenceAudioURL = url
        if voiceProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            voiceProfileName = url.deletingPathExtension().lastPathComponent
        }
        append("Reference WAV selected — \(url.lastPathComponent)")
    }

    func createVoiceProfile(in store: VoiceProfileStore) {
        guard !isLoading, !isGenerating, !isExtractingVoice else { return }
        guard supportsVoiceCloning else {
            errorMessage = Qwen3TTSError.speakerEmbeddingUnavailable.localizedDescription
            return
        }
        guard let referenceAudioURL else {
            errorMessage = "Select a reference WAV first."
            return
        }
        let trimmedName = voiceProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = VoiceProfileError.emptyName.localizedDescription
            return
        }
        let trimmedText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            errorMessage = VoiceProfileError.emptyTranscript.localizedDescription
            return
        }
        isExtractingVoice = true
        errorMessage = nil
        append("Speaker embedding extraction started")
        workTask = Task {
            do {
                let audio = try await ReferenceAudioLoader.loadForSpeakerEmbedding(from: referenceAudioURL)
                append("Reference WAV decoded — \(format(audio.duration)) s, \(audio.samples.count) samples at 24 kHz")
                appendMemory("Before speaker embedding cache clear", bytes: availableMemory())
                await engine.clearCache()
                appendMemory("Before speaker embedding eval", bytes: availableMemory())
                append("Entering Qwen3-TTS speaker encoder")
                let embedding = try await engine.extractSpeakerEmbedding(audioSamples: audio.samples)
                appendMemory("After speaker embedding eval", bytes: availableMemory())
                let profile = try await store.create(
                    name: trimmedName,
                    referenceAudio: referenceAudioURL,
                    referenceText: trimmedText,
                    language: language.rawValue,
                    embedding: embedding
                )
                append("Voice Profile saved — \(profile.name), embedding dimensions = \(embedding.count)")
            } catch is CancellationError {
                append("Speaker embedding extraction cancelled")
            } catch {
                fail(error)
            }
            isExtractingVoice = false
        }
    }

    func generate(using voiceProfiles: VoiceProfileStore) {
        guard !isLoading, !isGenerating, !isExtractingVoice else { return }
        guard loadedModelID != nil else {
            errorMessage = Qwen3TTSError.notLoaded.localizedDescription
            return
        }
        var embedding: [Float]?
        if speakers.isEmpty {
            guard supportsVoiceCloning, let profile = voiceProfiles.currentProfile else {
                errorMessage = Qwen3TTSError.voiceReferenceRequired.localizedDescription
                return
            }
            do {
                embedding = try voiceProfiles.loadEmbedding(for: profile)
                append("Using Voice Profile — \(profile.name)")
            } catch {
                fail(error)
                return
            }
        }
        isGenerating = true
        errorMessage = nil
        synthesis = nil
        progress = 0
        lowestAvailableBytes = availableMemory()
        startMemorySampler()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let output = TTSModelManager.outputDirectory.appendingPathComponent("qwen3-tts-\(stamp).wav")
        let request = TTSSynthesisRequest(
            text: text,
            language: language,
            speaker: speaker,
            speakerEmbedding: embedding,
            temperature: Float(temperature)
        )
        append("Generate started; language = \(language.rawValue), output = \(output.lastPathComponent)")
        workTask = Task {
            do {
                let result = try await engine.synthesize(request, to: output) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                synthesis = result
                progress = 100
                append("Generated WAV: \(format(result.elapsed)) s synthesis, \(format(result.audioDuration)) s audio, RTF \(format(result.realTimeFactor))")
                appendMemory("Generate minimum available (peak pressure)", bytes: lowestAvailableBytes ?? 0)
                try player.play(output)
                append("AVFoundation playback started")
            } catch is CancellationError {
                append("Generation cancelled")
            } catch {
                fail(error)
            }
            memorySampler?.cancel()
            memorySampler = nil
            isGenerating = false
        }
    }

    func play() {
        guard let url = synthesis?.outputURL else { return }
        do { try player.play(url); append("AVFoundation playback started") }
        catch { fail(error) }
    }

    func stop() {
        player.stop()
        engine.stop()
        workTask?.cancel()
        memorySampler?.cancel()
        append("Stop requested for generation and playback")
    }

    func clearCache() {
        Task {
            await engine.clearCache()
            append("MLX cache clear requested")
        }
    }

    func unload() {
        stop()
        isLoading = true
        Task {
            await engine.unload()
            loadedModelID = nil
            speakers = []
            supportsVoiceCloning = false
            speaker = ""
            isLoading = false
            appendMemory("After unload", bytes: availableMemory())
        }
    }

    func handleMemoryWarning() {
        append("MEMORY WARNING received — stopping TTS and releasing model")
        stop()
        unload()
    }

    private func startMemorySampler() {
        memorySampler?.cancel()
        memorySampler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.availableMemory()
                self.lowestAvailableBytes = min(self.lowestAvailableBytes ?? current, current)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func availableMemory() -> UInt64 {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.physicalMemory
        #else
        return UInt64(os_proc_available_memory())
        #endif
    }

    private func appendMemory(_ label: String, bytes: UInt64) {
        append("\(label): \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)) available before iOS limit")
    }

    private func append(_ line: String) {
        let entry = "[\(Date().formatted(date: .omitted, time: .standard))] \(line)"
        logLines.append(entry)
        if logLines.count > Self.maximumPersistedLogLines {
            logLines.removeFirst(logLines.count - Self.maximumPersistedLogLines)
        }
        UserDefaults.standard.set(logLines, forKey: Self.persistedLogKey)
        // This log is intentionally flushed because a native Metal failure can terminate
        // the process before Swift has a chance to present or persist an error.
        UserDefaults.standard.synchronize()
        LlamaBridge.appendLogNote("openTihui TTS Debug: \(line)")
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        append("ERROR: \(error.localizedDescription)")
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

struct TTSDebugView: View {
    @EnvironmentObject private var models: TTSModelManager
    @EnvironmentObject private var chat: ChatViewModel
    @StateObject private var viewModel = TTSDebugViewModel()
    @StateObject private var voiceProfiles = VoiceProfileStore()
    @State private var importing = false
    @State private var importingReferenceAudio = false
    @State private var exportFile: ExportFile?
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                if models.models.isEmpty {
                    Text("No TTS models imported").foregroundStyle(.secondary)
                }
                ForEach(models.models) { model in
                    Button {
                        models.currentModelID = model.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name).foregroundStyle(.primary)
                                Text("\(model.modelType) · \(model.quantization) · \(model.sizeText)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(model.supportsVoiceCloning ? "Voice Clone capable" : "No Voice Clone metadata")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if models.currentModelID == model.id { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            do { try models.delete(model) }
                            catch { importError = error.localizedDescription }
                        }
                    }
                }
                Button { importing = true } label: {
                    Label("Import Qwen3-TTS Model Folder", systemImage: "folder.badge.plus")
                }
                Button {
                    if let model = models.currentModel { viewModel.load(model, chat: chat) }
                } label: {
                    Label(viewModel.isLoading ? "Loading…" : "Load Model", systemImage: "memorychip")
                }
                .disabled(
                    models.currentModel == nil || viewModel.isLoading ||
                    viewModel.isGenerating || viewModel.isExtractingVoice
                )
            } header: {
                Text("TTS Models")
            } footer: {
                Text("Imports a complete local model directory into Documents/TTSModels. Loading TTS first unloads the active GGUF model.")
            }

            if viewModel.supportsVoiceCloning {
                Section {
                    if voiceProfiles.profiles.isEmpty {
                        Text("No Voice Profiles saved").foregroundStyle(.secondary)
                    }
                    ForEach(voiceProfiles.profiles) { profile in
                        Button {
                            voiceProfiles.currentProfileID = profile.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.language).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if voiceProfiles.currentProfileID == profile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                do { try voiceProfiles.delete(profile) }
                                catch { importError = error.localizedDescription }
                            }
                        }
                    }
                    Button { importingReferenceAudio = true } label: {
                        Label("Select Reference WAV", systemImage: "waveform.badge.plus")
                    }
                    if let url = viewModel.referenceAudioURL {
                        LabeledContent("Reference", value: url.lastPathComponent)
                    }
                    TextField("Voice Profile name", text: $viewModel.voiceProfileName)
                    Text("Exact reference transcript").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.referenceText).frame(minHeight: 70)
                    Button {
                        viewModel.createVoiceProfile(in: voiceProfiles)
                    } label: {
                        Label(
                            viewModel.isExtractingVoice ? "Extracting…" : "Extract & Save Voice Profile",
                            systemImage: "person.wave.2"
                        )
                    }
                    .disabled(
                        viewModel.referenceAudioURL == nil || viewModel.isLoading ||
                        viewModel.isGenerating || viewModel.isExtractingVoice
                    )
                } header: {
                    Text("Voice Clone")
                } footer: {
                    Text("Speaker Embedding mode: use a clean 5–10 second WAV and enter its exact transcript. The reference audio and embedding remain on this device.")
                }
            }

            Section("Synthesis") {
                TextEditor(text: $viewModel.text).frame(minHeight: 100)
                Picker("Language", selection: $viewModel.language) {
                    ForEach(TTSLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
                if !viewModel.speakers.isEmpty {
                    Picker("Speaker", selection: $viewModel.speaker) {
                        ForEach(viewModel.speakers, id: \.self) { Text($0).tag($0) }
                    }
                }
                LabeledContent("Temperature", value: String(format: "%.2f", viewModel.temperature))
                Slider(value: $viewModel.temperature, in: 0...1, step: 0.05)
                Button { viewModel.generate(using: voiceProfiles) } label: {
                    Label(viewModel.isGenerating ? "Generating \(viewModel.progress)%" : "Generate WAV", systemImage: "waveform")
                }
                .disabled(
                    viewModel.loadedModelID == nil || viewModel.isLoading || viewModel.isGenerating ||
                    viewModel.isExtractingVoice ||
                    (viewModel.speakers.isEmpty && voiceProfiles.currentProfile == nil)
                )
                if viewModel.loadedModelID != nil,
                   viewModel.speakers.isEmpty,
                   voiceProfiles.currentProfile == nil {
                    Text("This Base model requires a saved Voice Profile before generation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if viewModel.isGenerating { ProgressView(value: Double(viewModel.progress), total: 100) }
                HStack {
                    Button("Play") { viewModel.play() }
                        .disabled(viewModel.synthesis == nil || viewModel.player.isPlaying)
                    Button("Stop", role: .destructive) { viewModel.stop() }
                    Spacer()
                    if let result = viewModel.synthesis {
                        Button("Save WAV") { exportFile = ExportFile(url: result.outputURL) }
                    }
                }
            }

            Section("Metrics") {
                LabeledContent("Model load", value: metric(viewModel.loadTime, suffix: "s"))
                LabeledContent("Synthesis", value: metric(viewModel.synthesis?.elapsed, suffix: "s"))
                LabeledContent("Audio length", value: metric(viewModel.synthesis?.audioDuration, suffix: "s"))
                LabeledContent("RTF", value: metric(viewModel.synthesis?.realTimeFactor, suffix: ""))
            }

            Section("Lifecycle") {
                Button("Clear MLX Cache") { viewModel.clearCache() }
                Button("Unload TTS Model", role: .destructive) { viewModel.unload() }
            }

            Section("TTS Log") {
                if viewModel.logLines.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
                else { Text(viewModel.logLines.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
        .navigationTitle("Qwen3-TTS Test")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            Task {
                do {
                    guard let url = try result.get().first else { return }
                    try await models.importModelDirectory(url)
                } catch { importError = error.localizedDescription }
            }
        }
        .fileImporter(
            isPresented: $importingReferenceAudio,
            allowedContentTypes: [.wav],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                viewModel.selectReferenceAudio(url)
            } catch {
                importError = error.localizedDescription
            }
        }
        .sheet(item: $exportFile) { ShareSheet(items: [$0.url]) }
        .alert("TTS Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil || importError != nil },
            set: { if !$0 { viewModel.errorMessage = nil; importError = nil } }
        )) { Button("OK") { viewModel.errorMessage = nil; importError = nil } }
        message: { Text(viewModel.errorMessage ?? importError ?? "Unknown error") }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            viewModel.handleMemoryWarning()
        }
        .onDisappear { viewModel.stop() }
    }

    private func metric(_ value: Double?, suffix: String) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f%@", value, suffix)
    }
}
