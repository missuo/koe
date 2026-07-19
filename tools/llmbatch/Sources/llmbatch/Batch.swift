#if arch(arm64)

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// Mirrors KoeMLX/MLXLlmManager.generate so offline batch results match runtime:
// chat = [system, user], enable_thinking=false, strip <think> blocks, temp/topP
// from config, KV cache cleared per generation.
@main
struct Batch {
    static func stripThinking(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result = String(result[result.startIndex..<start.lowerBound])
                break
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write("usage: llmbatch <modelDir> <prompts.jsonl>\n".data(using: .utf8)!)
            exit(2)
        }
        let modelPath = args[1]
        let promptsPath = args[2]

        // Generation config — matches ~/.koe/config.yaml llm.{temperature,top_p,max_output_tokens}
        let params = GenerateParameters(maxTokens: 1024, temperature: 0.0, topP: 1.0)

        let container: ModelContainer
        do {
            container = try await LLMModelFactory.shared.loadContainer(
                configuration: ModelConfiguration(directory: URL(fileURLWithPath: modelPath))
            )
        } catch {
            FileHandle.standardError.write("load failed for \(modelPath): \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        guard let raw = try? String(contentsOfFile: promptsPath, encoding: .utf8) else {
            FileHandle.standardError.write("cannot read \(promptsPath)\n".data(using: .utf8)!)
            exit(1)
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  let system = obj["system"] as? String,
                  let user = obj["user"] as? String else { continue }
            let id = obj["id"] ?? NSNull()

            let input = UserInput(
                chat: [.system(system), .user(user)],
                additionalContext: ["enable_thinking": false]
            )

            var output = ""
            do {
                let lmInput = try await container.prepare(input: input)
                let stream = try await container.generate(input: lmInput, parameters: params)
                for await gen in stream {
                    if case .chunk(let t) = gen { output += t }
                }
            } catch {
                output = ""
            }
            MLX.Memory.clearCache()

            let cleaned = stripThinking(output)
            let res: [String: Any] = ["id": id, "output": cleaned]
            if let rd = try? JSONSerialization.data(withJSONObject: res),
               let s = String(data: rd, encoding: .utf8) {
                print(s)
                fflush(stdout)
            }
        }
    }
}

#else
@main struct Batch { static func main() { fatalError("arm64 only") } }
#endif
