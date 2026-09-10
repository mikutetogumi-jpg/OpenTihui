# Qwen3-TTS integration status

Updated: 2026-09-10

## Scope

The isolated developer TTS page now includes a minimal ICL reference-audio Voice Clone test. It does not add character support, automatic chat speech, or any change to `LlamaBridge.mm`.

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
- `ReferenceAudioLoader.swift`: decodes a selected WAV and converts it to 24 kHz mono Float32 samples, matching the pinned package's ICL audio encoder.
- `VoiceProfileStore.swift`: saves the reference WAV, exact transcript, language, and package-produced ICL reference codes under `Documents/VoiceProfiles`.

## Model directory format

Import a directory containing at least:

```text
config.json
model.safetensors
speech_tokenizer/config.json
speech_tokenizer/model.safetensors
```

The text tokenizer may use either `tokenizer.json`, or the split Hugging Face
BPE files `vocab.json` and `merges.txt`. `tokenizer_config.json` is optional
metadata consumed by the package when present. The suggested official 0.6B
MLX model uses the split BPE layout.

The actual model format is a directory. ZIP import was deliberately not added because the selected package does not consume archives and adding an unzip dependency is not necessary for the smoke test.

Test model: `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit`. The real-device smoke test confirmed that this Base model loads, supports voice cloning, and reports no built-in speakers. Generation without a speaker embedding produced an empty WAV, so the page now requires a saved Voice Profile for such a model.

## Voice Clone test path

1. Load the Base TTS model.
2. Select a clean 2–8 second local WAV and enter its exact transcript.
3. Encode and save a Voice Profile. The package receives 24 kHz mono samples and returns stored ICL reference codes.
4. Select the saved profile and generate a short target sentence.
5. The transcript and reference codes are passed to the package's existing `generateToFile` API; no MLX inference implementation is duplicated in the app.

The initial speaker-embedding path crashes inside the package's MLX FFT on the tested iPhone. The debug path therefore uses the package's existing ICL reference-audio encoder, which bypasses that Speaker Encoder FFT without replacing any MLX inference code.

The pinned 0.2.0 package also expects obsolete speech-tokenizer codebook keys (`_codebook.embedding_sum`) while the current official model uses `codebook.embed_sum` plus an inference-irrelevant `initialized` value. A narrow CI-applied patch corrects those mappings and the downsample convolution path before Xcode builds the package. The package version remains pinned at 0.2.0 and the patch is validated with `git apply --check` on every build.

For iPhone diagnosis and lower peak graph pressure, the same narrow patch materializes and clears the MLX cache between the ICL CNN and Transformer layers, then the Downsample and Quantizer. Each boundary is persisted in the TTS debug log so a native Metal termination can be localized after relaunch. Cancelling a model load after an iOS memory warning now also releases the newly constructed pipeline instead of installing it after the unload request.

Real-device staged logs localized the next native termination to the residual-vector Quantizer. The package originally evaluated one semantic plus 31 acoustic codebooks and only afterward discarded all but the valid streams, while the Qwen3-TTS ICL talker consumes only `refCodes[0]`. The CI patch now evaluates only that required semantic codebook, materializes the projection and code indices separately, and records both boundaries. This preserves the exact ICL input used downstream while removing 31 unused codebook evaluations from the iPhone memory peak.

The following real-device run completed the semantic projection but terminated inside MLX's 2048-wide `argMin` codebook reduction. The final short-reference nearest-neighbour search now runs on the CPU while the CNN, Transformer, and projection remain Metal-accelerated. It computes the same squared-L2 nearest code for each frame, avoids the iPhone Metal reduction limit, and adds only about 2 MB of temporary arrays for the tested model.

## Memory behavior

- Loading TTS from the debug page explicitly unloads the active llama.cpp/GGUF model first.
- The log records available process memory before load, after load, the lowest sampled availability during generation, and after unload. This is iOS process-limit availability, not an exact physical-RAM profiler.
- `UIApplication.didReceiveMemoryWarningNotification` stops playback/generation, releases the TTS pipeline, and clears MLX caches.
- Clear Cache and Unload Model are also exposed as separate debug controls.
- A zero-sample result is deleted and reported as an empty-generation error. It is never handed to AVFoundation for playback.

## Build status

- The Xcode project pins the TTS package at `0.2.0`.
- GitHub Actions now explicitly resolves packages and reuses the resolved checkout for the unsigned iPhone Release build.
- Pre-TTS baseline workflow: passed on the user's real-device build.
- TTS integration workflow: passed — [GitHub Actions #7](https://github.com/mikutetogumi-jpg/OpenTihui/actions/runs/34314882548). Package resolution, MLX/Qwen3-TTS compilation, the unsigned iPhone Release build, IPA packaging, and artifact uploads all completed successfully.

CI can prove package resolution and `iphoneos` compilation. It cannot honestly prove a multi-gigabyte model loads or produces audible speech on a physical iPhone. Those final smoke-test items remain pending real-device testing.

## Real-device checklist

- [x] Import the complete TTS model folder.
- [x] Load the model without app termination.
- [ ] Select a clean reference WAV and save a Voice Profile.
- [ ] Generate a short Chinese sentence with the selected Voice Profile.
- [ ] Confirm the resulting audio duration is greater than zero and AVFoundation playback works.
- [ ] Record the metrics and logs shown on the page.
- [ ] Run Clear MLX Cache and Unload; confirm the app remains responsive.

## Next gate

Stop after the speaker-embedding Voice Clone build and real-device test. Do not connect TTS to chat until GGUF chat and cloned speech are independently stable.
