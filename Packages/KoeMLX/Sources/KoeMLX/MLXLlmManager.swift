#if arch(arm64)

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Manages local LLM model loading and text generation via MLX.
class MLXLlmManager {
    private var container: ModelContainer?
    private var loadedModelPath: String?
    private let lock = NSLock()

    /// Load an LLM model from a local directory (blocking).
    /// Skips loading if the same path is already loaded.
    func loadModel(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if container != nil && loadedModelPath == path {
            NSLog("KoeMLX LLM: model already loaded from %@, reusing", path)
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        Task {
            do {
                let config = ModelConfiguration(
                    directory: URL(fileURLWithPath: path)
                )
                let newContainer = try await LLMModelFactory.shared.loadContainer(
                    configuration: config
                )
                self.container = newContainer
                self.loadedModelPath = path
                success = true
                NSLog("KoeMLX LLM: model loaded from %@", path)
            } catch {
                NSLog("KoeMLX LLM: failed to load model at %@: %@", path, error.localizedDescription)
                self.container = nil
                self.loadedModelPath = nil
            }
            semaphore.signal()
        }
        semaphore.wait()
        return success
    }

    /// Generate corrected text from system + user prompts (blocking).
    /// Automatically loads the model if needed.
    /// Returns nil on failure.
    func generate(
        modelPath: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Float,
        topP: Float,
        maxTokens: Int
    ) -> String? {
        // Ensure model is loaded (lazy load / switch)
        if container == nil || loadedModelPath != modelPath {
            if !loadModel(path: modelPath) {
                return nil
            }
        }

        guard let container = self.container else { return nil }

        let input = UserInput(
            chat: [
                .system(systemPrompt),
                .user(userPrompt),
            ],
            additionalContext: ["enable_thinking": false]
        )

        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP
        )

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        Task {
            do {
                let lmInput = try await container.prepare(input: input)
                let stream = try await container.generate(
                    input: lmInput,
                    parameters: parameters
                )

                var output = ""
                for await generation in stream {
                    switch generation {
                    case .chunk(let text):
                        output += text
                    default:
                        break
                    }
                }

                // Strip <think>...</think> blocks (small models may emit reasoning tokens)
                let cleaned = Self.stripThinkingTokens(output)
                if cleaned.isEmpty && !output.isEmpty {
                    NSLog("KoeMLX LLM: WARNING output became empty after stripping <think> tags")
                }
                result = cleaned
            } catch {
                NSLog("KoeMLX LLM: generation failed: %@", error.localizedDescription)
                result = nil
            }

            // Free KV cache and intermediate tensors from this generation
            MLX.Memory.clearCache()

            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Unload the model to free memory.
    func unloadModel() {
        lock.lock()
        defer { lock.unlock() }
        container = nil
        loadedModelPath = nil
        MLX.Memory.clearCache()
        NSLog("KoeMLX LLM: model unloaded")
    }

    // MARK: - Private

    /// Remove <think>...</think> blocks from model output.
    /// If `</think>` is missing (e.g. maxTokens hit), keeps the text after the
    /// incomplete `<think>` block rather than discarding everything.
    private static func stripThinkingTokens(_ text: String) -> String {
        var result = text
        while let thinkStart = result.range(of: "<think>") {
            if let thinkEnd = result.range(of: "</think>", range: thinkStart.upperBound..<result.endIndex) {
                result.removeSubrange(thinkStart.lowerBound..<thinkEnd.upperBound)
            } else {
                // Unclosed <think> — truncated by maxTokens.
                // Drop only the incomplete thinking block, not the whole tail.
                // There's no useful content after an unclosed <think>, so just
                // keep whatever came before it.
                result = String(result[result.startIndex..<thinkStart.lowerBound])
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#endif
