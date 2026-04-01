#if arch(arm64)

import Foundation
import MLX
import MLXNN
import MLXAudioSTT
import MLXAudioCore
import Tokenizers

/// C callback type matching koe_mlx_event_callback.
/// event_type: 0=Interim, 1=Definite, 2=Final, 3=Error, 4=Connected, 5=Closed
typealias MLXEventCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    UnsafePointer<CChar>?
) -> Void

/// Manages Qwen3-ASR model loading and streaming inference via MLX.
class MLXAsrManager {
    private var model: Qwen3ASRModel?
    private var loadedModelPath: String?
    private var session: StreamingInferenceSession?
    private var eventTask: Task<Void, Never>?
    private var callback: MLXEventCallback?
    private var callbackCtx: UnsafeMutableRawPointer?
    private let callbackLock = NSLock()
    /// Monotonically increasing generation counter.  Each startSession bumps it;
    /// feedAudio / stop / cancel only act when the caller's generation matches.
    private var generation: UInt64 = 0

    /// Load a Qwen3-ASR model from a local directory (blocking).
    /// Skips loading if the same path is already loaded.
    func loadModel(path: String) -> Bool {
        if model != nil && loadedModelPath == path {
            NSLog("KoeMLX: model already loaded from %@, reusing", path)
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        Task {
            do {
                self.model = try await Self.loadModelFromLocal(path: path)
                self.loadedModelPath = path
                success = true
            } catch {
                NSLog("KoeMLX: failed to load model at %@: %@", path, error.localizedDescription)
                self.model = nil
                self.loadedModelPath = nil
            }
            semaphore.signal()
        }
        semaphore.wait()
        return success
    }

    /// Start a streaming recognition session.
    /// Returns the session generation (>0) on success, or 0 on failure.
    func startSession(language: String,
                      delayPreset: String,
                      callback: MLXEventCallback,
                      context: UnsafeMutableRawPointer?) -> UInt64 {
        guard let model = self.model else {
            NSLog("KoeMLX: model not loaded")
            return 0
        }

        // Cancel any in-flight session before overwriting singleton state
        session?.cancel()
        eventTask?.cancel()
        eventTask = nil
        session = nil

        generation &+= 1
        let thisGeneration = generation

        callbackLock.lock()
        self.callback = callback
        self.callbackCtx = context
        callbackLock.unlock()

        let preset: DelayPreset
        switch delayPreset {
        case "realtime": preset = .realtime
        case "agent": preset = .agent
        case "subtitle": preset = .subtitle
        default: preset = .realtime
        }

        let lang: String = (language == "auto") ? "auto" : language

        let config = StreamingConfig(
            delayPreset: preset,
            language: lang,
            temperature: 0.0,
            maxTokensPerPass: 512,
            minAgreementPasses: 2
        )

        let session = StreamingInferenceSession(model: model, config: config)
        self.session = session

        invokeCallback(eventType: 4, text: "", generation: thisGeneration)

        eventTask = Task { [weak self] in
            for await event in session.events {
                guard let self = self, self.generation == thisGeneration else { break }
                switch event {
                case .displayUpdate(let confirmed, let provisional):
                    self.invokeCallback(eventType: 0, text: confirmed + provisional, generation: thisGeneration)
                case .confirmed(let text):
                    self.invokeCallback(eventType: 1, text: text, generation: thisGeneration)
                case .ended(let fullText):
                    self.invokeCallback(eventType: 2, text: fullText, generation: thisGeneration)
                case .stats:
                    break
                default:
                    break
                }
            }
            if let self = self, self.generation == thisGeneration {
                self.invokeCallback(eventType: 5, text: "", generation: thisGeneration)
            }
        }

        return thisGeneration
    }

    /// Feed raw f32 PCM samples at 16kHz.
    /// Ignored if `gen` doesn't match the current session generation.
    func feedAudio(_ samples: UnsafePointer<Float>, count: Int, generation gen: UInt64) {
        guard gen == generation else { return }
        let buffer = Array(UnsafeBufferPointer(start: samples, count: count))
        session?.feedAudio(samples: buffer)
    }

    /// Gracefully stop the session (flush remaining audio, emit .ended).
    /// Ignored if `gen` doesn't match the current session generation.
    func stop(generation gen: UInt64) {
        guard gen == generation else { return }
        session?.stop()
    }

    /// Cancel the session immediately.
    /// Ignored if `gen` doesn't match the current session generation.
    func cancel(generation gen: UInt64) {
        guard gen == generation else { return }

        // Clear callback context under lock FIRST so any in-flight or
        // subsequent invokeCallback sees nil and never touches the pointer.
        // Rust's close() reclaims the pointer only after this returns.
        callbackLock.lock()
        callback = nil
        callbackCtx = nil
        callbackLock.unlock()

        session?.cancel()
        eventTask?.cancel()
        eventTask = nil
        session = nil
    }

    /// Unload the model to free memory.
    func unloadModel() {
        cancel(generation: generation)
        model = nil
        loadedModelPath = nil
    }

    // MARK: - Private

    private func invokeCallback(eventType: Int32, text: String, generation gen: UInt64) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard gen == generation, let cb = callback, let ctx = callbackCtx else { return }
        text.withCString { cstr in
            cb(ctx, eventType, cstr)
        }
    }

    // MARK: - Model Loading

    private static func loadModelFromLocal(path: String) async throws -> Qwen3ASRModel {
        let modelDir = URL(fileURLWithPath: path)

        let configPath = modelDir.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configPath)
        let config = try JSONDecoder().decode(Qwen3ASRConfig.self, from: configData)
        let perLayerQuantization = config.perLayerQuantization

        let model = Qwen3ASRModel(config)

        // Generate tokenizer.json if missing (Qwen3 ASR models don't ship it)
        let tokenizerJSONPath = modelDir.appendingPathComponent("tokenizer.json")
        if !FileManager.default.fileExists(atPath: tokenizerJSONPath.path) {
            try generateTokenizerJSON(in: modelDir)
        }

        model.tokenizer = try await AutoTokenizer.from(modelFolder: modelDir)

        // Load weights from safetensors
        var weights: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "safetensors" {
            let fileWeights = try MLX.loadArrays(url: file)
            weights.merge(fileWeights) { _, new in new }
        }

        let skipLmHead = config.textConfig.tieWordEmbeddings
        let sanitizedWeights = Qwen3ASRModel.sanitize(weights: weights, skipLmHead: skipLmHead)

        if perLayerQuantization != nil {
            quantize(model: model) { path, module in
                if path.hasPrefix("audio_tower") { return nil }
                if sanitizedWeights["\(path).scales"] != nil {
                    return perLayerQuantization?.quantization(layer: path)?.asTuple
                }
                return nil
            }
        }

        try model.update(parameters: ModuleParameters.unflattened(sanitizedWeights), verify: .all)
        eval(model)

        NSLog("KoeMLX: model loaded from %@", path)
        return model
    }

    /// Generate tokenizer.json from vocab.json + merges.txt.
    private static func generateTokenizerJSON(in modelDir: URL) throws {
        let vocabURL = modelDir.appendingPathComponent("vocab.json")
        let mergesURL = modelDir.appendingPathComponent("merges.txt")
        let tokenizerConfigURL = modelDir.appendingPathComponent("tokenizer_config.json")

        guard FileManager.default.fileExists(atPath: vocabURL.path),
              FileManager.default.fileExists(atPath: mergesURL.path) else { return }

        let vocabData = try Data(contentsOf: vocabURL)
        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        let mergeLines = mergesText.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }

        let mergesJSON = mergeLines.map { line -> String in
            let escaped = line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ",")

        var addedTokensJSON = "[]"
        if FileManager.default.fileExists(atPath: tokenizerConfigURL.path) {
            let configData = try Data(contentsOf: tokenizerConfigURL)
            if let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
               let addedTokensDecoder = configDict["added_tokens_decoder"] as? [String: Any] {
                var tokens: [(Int, [String: Any])] = []
                for (idStr, value) in addedTokensDecoder {
                    if let id = Int(idStr), let tokenDict = value as? [String: Any] {
                        let entry: [String: Any] = [
                            "id": id,
                            "content": tokenDict["content"] ?? "",
                            "single_word": tokenDict["single_word"] ?? false,
                            "lstrip": tokenDict["lstrip"] ?? false,
                            "rstrip": tokenDict["rstrip"] ?? false,
                            "normalized": tokenDict["normalized"] ?? false,
                            "special": tokenDict["special"] ?? false,
                        ]
                        tokens.append((id, entry))
                    }
                }
                tokens.sort { $0.0 < $1.0 }
                let tokenData = try JSONSerialization.data(
                    withJSONObject: tokens.map { $0.1 }, options: [])
                addedTokensJSON = String(data: tokenData, encoding: .utf8) ?? "[]"
            }
        }

        let preTokenizerPattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        let escapedPattern = preTokenizerPattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let vocabString = String(data: vocabData, encoding: .utf8) ?? "{}"

        let tokenizerJSON = """
        {
          "version": "1.0",
          "truncation": null,
          "padding": null,
          "added_tokens": \(addedTokensJSON),
          "normalizer": {"type": "NFC"},
          "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
              {
                "type": "Split",
                "pattern": {"Regex": "\(escapedPattern)"},
                "behavior": "Isolated",
                "invert": false
              },
              {
                "type": "ByteLevel",
                "add_prefix_space": false,
                "trim_offsets": true,
                "use_regex": false
              }
            ]
          },
          "post_processor": null,
          "decoder": {
            "type": "ByteLevel",
            "add_prefix_space": true,
            "trim_offsets": true,
            "use_regex": true
          },
          "model": {
            "type": "BPE",
            "dropout": null,
            "unk_token": null,
            "continuing_subword_prefix": "",
            "end_of_word_suffix": "",
            "fuse_unk": false,
            "byte_fallback": false,
            "vocab": \(vocabString),
            "merges": [\(mergesJSON)]
          }
        }
        """

        let outputPath = modelDir.appendingPathComponent("tokenizer.json")
        try tokenizerJSON.write(to: outputPath, atomically: true, encoding: .utf8)
        NSLog("KoeMLX: generated tokenizer.json")
    }
}

#endif
