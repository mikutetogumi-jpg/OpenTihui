# Qwen3-TTS integration status

Updated: 2026-09-09

## Scope

This round adds an isolated, developer-only TTS smoke-test path. It does not add voice profiles, voice cloning, character support, automatic chat speech, or any change to `LlamaBridge.mm`.

## Implementation choice

Selected: [`hamptus/mlx-swift-qwen3-tts`](https://github.com/hamptus/mlx-swift-qwen3-tts), pinned to `0.2.0`.

Why it was selected:

- Its package manifest targets iOS 17 and Swift tools 5.9, matching openTihui's iOS 17 deployment target.
- It directly supports Qwen3-TTS 0.6B/1.7B, pre-quantized models, local model directories, incremental WAV output, cache clearing, speaker embeddings, and reference-audio/ICL APIs.
- Its only package dependency is MLX Swift. That keeps the first integration smaller and lowers dependency-conflict risk.
- `mlx-audio-swift` is broader, but its current package uses Swift tools 6.2 and adds MLX LM, Swift Transformers, Swift Hugging Face, Hub, tokenizers, audio utilities, and multiple model families. That is unnecessary surface area for this focused Qwen3-TTS test.

No Hugging Face download code was added in this round. TTS model directories are imported from Files so package/build correctness and real-device memory can be established first.

## Added components

- `TTSEngine.swift`: provider-neutral lifecycle and synthesis interface.
- `Qwen3TTSEngine.swift`: thin wrapper around the selected package. It loads a local directory, writes WAV incrementally, exposes progress, clears MLX caches, and releases the pipeline on unload.
- `TTSModelManager.swift`: dedicated `Documents/TTSModels` store, validation, list, current selection, metadata, size, and deletion. It does not use the GGUF model list.
- `AudioPlayer.swift`: AVFoundation playback and stop.
- `TTSDebugView.swift`: Settings → Developer / Experimental → Qwen3-TTS Test.

## Model directory format

Import a directory containing at least:

```text
config.json
model.safetensors
tokenizer.json
speech_tokenizer/config.json
speech_tokenizer/model.safetensors
```

The actual model format is a directory. ZIP import was deliberately not added because the selected package does not consume archives and adding an unzip dependency is not necessary for the smoke test.

Suggested first memory test: `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit` (about 1.7 GB according to the package documentation). A Base model may report no built-in speakers; the debug page logs that fact. Do not implement or judge Voice Clone until the basic device load/WAV path has been measured.

## Memory behavior

- Loading TTS from the debug page explicitly unloads the active llama.cpp/GGUF model first.
- The log records available process memory before load, after load, the lowest sampled availability during generation, and after unload. This is iOS process-limit availability, not an exact physical-RAM profiler.
- `UIApplication.didReceiveMemoryWarningNotification` stops playback/generation, releases the TTS pipeline, and clears MLX caches.
- Clear Cache and Unload Model are also exposed as separate debug controls.

## Build status

- The Xcode project pins the TTS package at `0.2.0`.
- GitHub Actions now explicitly resolves packages and reuses the resolved checkout for the unsigned iPhone Release build.
- Pre-TTS baseline workflow: passed on the user's real-device build.
- TTS integration workflow: passed — [GitHub Actions #7](https://github.com/mikutetogumi-jpg/OpenTihui/actions/runs/34314882548). Package resolution, MLX/Qwen3-TTS compilation, the unsigned iPhone Release build, IPA packaging, and artifact uploads all completed successfully.

CI can prove package resolution and `iphoneos` compilation. It cannot honestly prove a multi-gigabyte model loads or produces audible speech on a physical iPhone. Those final smoke-test items remain pending real-device testing.

## Real-device checklist

- [ ] Import the complete TTS model folder.
- [ ] Load the model without app termination.
- [ ] Generate the default Chinese text to WAV.
- [ ] Confirm AVFoundation playback and Stop.
- [ ] Record the metrics and logs shown on the page.
- [ ] Run Clear MLX Cache and Unload; confirm the app remains responsive.

## Next gate

Stop after this first smoke-test build. Voice profile storage, speaker-embedding/reference-audio cloning, and chat auto-speech must wait for the user's real-iPhone result.
