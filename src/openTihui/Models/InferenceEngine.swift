//
//  InferenceEngine.swift
//  openTihui
//
//  Swift-friendly async wrapper around the Objective-C `LlamaBridge`. All heavy
//  work runs on a dedicated serial queue; token output is delivered as an
//  AsyncStream so SwiftUI can render it incrementally.
//

import Foundation

enum GenerationEvent {
    case token(String)
    case done(stats: String)
    case failed(String)
}

/// An immutable, thread-safe copy of model info. Built on the inference queue
/// after a load completes, so the UI never has to touch the live model pointer.
struct ModelSnapshot: Sendable {
    var desc: String
    var sizeBytes: UInt64
    var nParams: UInt64
    var nCtxTrain: Int32
    var supportsVision: Bool
    var supportsAudio: Bool
    var usingGPU: Bool
    var backend: String
    var chatTemplate: String
    var loadNotice: String

    init(_ info: LMModelInfo) {
        desc = info.desc
        sizeBytes = info.sizeBytes
        nParams = info.nParams
        nCtxTrain = info.nCtxTrain
        supportsVision = info.supportsVision
        supportsAudio = info.supportsAudio
        usingGPU = info.usingGPU
        backend = info.backend
        chatTemplate = info.chatTemplate
        loadNotice = info.loadNotice
    }
}

enum EngineError: LocalizedError {
    case loadFailed(String)
    case notLoaded
    var errorDescription: String? {
        switch self {
        case .loadFailed(let m): return m
        case .notLoaded:         return "No model is loaded."
        }
    }
}

final class InferenceEngine: @unchecked Sendable {
    private let bridge = LlamaBridge()
    private let queue = DispatchQueue(label: "org.cyyself.opentihui.inference", qos: .userInitiated)

    private(set) var loadedModelID: UUID?

    var isLoaded: Bool { bridge.isLoaded }
    var mediaMarker: String { LlamaBridge.mediaMarker() }

    var contextUsage: (past: Int, total: Int) { (Int(bridge.nPast), Int(bridge.nCtx)) }

    func modelInfo() -> LMModelInfo? { bridge.modelInfo }

    // MARK: Loading

    /// GPU offload works on real devices but crashes ggml-metal in the iOS
    /// Simulator, so it is never enabled there regardless of the user setting.
    ///
    /// The underlying probe creates a Metal/ggml backend and is comparatively
    /// expensive, so it's computed once (thread-safe `static let`) instead of on
    /// every view render. Call `warmGPUAvailability()` at launch to pay that cost
    /// off the main thread so views (e.g. Settings) never block on it.
    private static let _gpuAvailable: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        return LlamaBridge.gpuOffloadSupported()
        #endif
    }()
    static var gpuAvailable: Bool { _gpuAvailable }

    /// Pre-compute `gpuAvailable` on a background thread so its first (slow) read
    /// doesn't stall the UI.
    static func warmGPUAvailability() {
        DispatchQueue.global(qos: .utility).async {
            let supported = _gpuAvailable
            DispatchQueue.main.async { AppSettings.shared.gpuSupported = supported }
        }
    }

    @discardableResult
    func load(model: ManagedModel, contextLength: Int, gpuEnabled: Bool, useProjector: Bool = true,
              onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelSnapshot? {
        let gpuLayers: Int32 = (gpuEnabled && InferenceEngine.gpuAvailable) ? 999 : 0
        let ctx = Int32(contextLength)
        let mmproj = useProjector ? model.mmprojPath : nil

        // Pre-flight memory check. Treat the estimate as advisory when the model
        // files themselves fit: the fixed headroom is deliberately conservative,
        // and mmap/Metal residency varies by model and device. Only refuse when
        // the selected files alone consume the app's entire remaining allowance.
        // Simulator has no comparable limit.
        let preflightWarning: String?
        #if !targetEnvironment(simulator)
        func fileSize(_ path: String?) -> UInt64 {
            guard let path,
                  let n = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber
            else { return 0 }
            return n.uint64Value
        }
        let weights = fileSize(model.modelPath)
        let projector = fileSize(mmproj)
        let headroom: UInt64 = 700 << 20   // KV cache + compute buffers + app
        let fileBytes = weights + projector
        let estimatedNeeded = fileBytes + headroom
        let available = UInt64(os_proc_available_memory())
        LlamaBridge.appendLogNote("openTihui: load pre-flight — weights \(weights >> 20) MB + projector \(projector >> 20) MB + headroom \(headroom >> 20) MB = estimated \(estimatedNeeded >> 20) MB vs available \(available >> 20) MB; context = \(contextLength), gpu = \(gpuLayers > 0)")
        if available > 0 && fileBytes >= available {
            LlamaBridge.appendLogNote("openTihui: load pre-flight decision = block — model files alone meet or exceed the process allowance")
            let msg = "Not enough memory to load this model: its model files total \(fileBytes >> 20) MB but only \(available >> 20) MB remains before the iOS app memory limit. Try a smaller model or quant, or turn off Multimodal (projector) in Chat Settings."
            throw EngineError.loadFailed(msg)
        }
        if available > 0 && estimatedNeeded > available {
            preflightWarning = "Memory estimate is close to the iOS app limit. Loading was allowed because the model files themselves fit; if the app closes, use a smaller context, model, or quant, and turn off Multimodal when it is not needed."
            LlamaBridge.appendLogNote("openTihui: load pre-flight decision = warn and continue — conservative headroom exceeds the process allowance")
        } else {
            preflightWarning = nil
            LlamaBridge.appendLogNote("openTihui: load pre-flight decision = continue")
        }
        #else
        preflightWarning = nil
        #endif
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ModelSnapshot?, Error>) in
            // Run the load at lower priority so the UI thread is never starved
            // while a multi-GB model is mapped/initialised in the background.
            queue.async(qos: .utility, flags: .enforceQoS) {
                self.bridge.onLoadProgress = onProgress.map { cb in { p in cb(Double(p)) } }
                defer { self.bridge.onLoadProgress = nil }
                do {
                    try self.bridge.loadModel(atPath: model.modelPath,
                                              mmprojPath: mmproj,
                                              nCtx: ctx,
                                              nGpuLayers: gpuLayers,
                                              compressionEnabled: true)   // always auto-compact on overflow
                    self.loadedModelID = model.id
                    // Snapshot model info here, on the queue, where it is safe to
                    // touch the model pointer.
                    var snap = self.bridge.modelInfo.map { ModelSnapshot($0) }
                    if let preflightWarning, var snapshot = snap {
                        snapshot.loadNotice = snapshot.loadNotice.isEmpty
                            ? preflightWarning
                            : "\(snapshot.loadNotice)\n\(preflightWarning)"
                        snap = snapshot
                    }
                    cont.resume(returning: snap)
                } catch {
                    cont.resume(throwing: EngineError.loadFailed(error.localizedDescription))
                }
            }
        }
    }

    func unload() {
        queue.async {
            self.bridge.unload()
            self.loadedModelID = nil
        }
    }

    /// Recreate the context with a new window size without reloading the model.
    /// Returns true if the existing KV cache was migrated (no replay needed).
    @discardableResult
    func resizeContext(nCtx: Int) async throws -> Bool {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            queue.async(qos: .utility, flags: .enforceQoS) {
                var preserved: ObjCBool = false
                do {
                    try self.bridge.resizeContext(to: Int32(nCtx), didPreserve: &preserved)
                    cont.resume(returning: preserved.boolValue)
                } catch {
                    cont.resume(throwing: EngineError.loadFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Reset the conversation, pinning a chat-formatted system block.
    func reset(systemPrompt: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.bridge.reset(withSystemPrompt: systemPrompt)
                    cont.resume()
                } catch {
                    cont.resume(throwing: EngineError.loadFailed(error.localizedDescription))
                }
            }
        }
    }

    func stop() { bridge.requestStop() }

    /// Evaluate a prompt delta (optionally with media) into the KV cache without
    /// generating — used to replay a conversation's history on switch.
    func evaluate(prompt: String, imagePaths: [String], audioPaths: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.bridge.evaluatePrompt(prompt, imagePaths: imagePaths, audioPaths: audioPaths)
                    cont.resume()
                } catch {
                    cont.resume(throwing: EngineError.loadFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: Generation

    func generate(prompt: String,
                  imagePaths: [String],
                  audioPaths: [String],
                  params: LMGenerationParams) -> AsyncStream<GenerationEvent> {
        AsyncStream { continuation in
            queue.async {
                self.bridge.generate(withPrompt: prompt,
                                     imagePaths: imagePaths,
                                     audioPaths: audioPaths,
                                     params: params,
                                     onToken: { piece in
                                         continuation.yield(.token(piece))
                                     },
                                     onDone: { success, errMsg, stats in
                                         if success {
                                             continuation.yield(.done(stats: stats ?? ""))
                                         } else {
                                             continuation.yield(.failed(errMsg ?? "Generation failed"))
                                         }
                                         continuation.finish()
                                     })
            }
        }
    }
}
