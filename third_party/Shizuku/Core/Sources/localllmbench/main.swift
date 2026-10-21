import Core
import Foundation
import LocalLLM

// llm-ime: いい感じ変換用ローカル LLM（Gemma 4 12B / 31B, MLX）の確認用 CLI。
//   localllmbench suggest <読み> [前の文脈] [スタイル指示]
//   localllmbench transform <文章> <指示>
//   環境変数 LOCAL_LLM_MODEL でモデルのディレクトリ名（既定 gemma4-12b-it-mlx）を変える

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: localllmbench suggest <reading> [left] [style] | transform <text> <instruction>")
    exit(1)
}
let start = Date()
let modelDirectory = LocalLLMEngine.modelDirectoryURL(
    name: ProcessInfo.processInfo.environment["LOCAL_LLM_MODEL"] ?? LocalLLMEngine.standardModelName
)
do {
    switch args[1] {
    case "suggest":
        let user = LocalLLMPrompts.suggestionUserPrompt(
            leftContext: args.count > 3 ? args[3] : "",
            target: args[2],
            style: args.count > 4 ? args[4] : ""
        )
        await LocalLLMEngine.shared.preload(directory: modelDirectory)
        print(String(format: "load %.1fs", Date().timeIntervalSince(start)))
        for round in 0..<2 {
            let t0 = Date()
            let output = try await LocalLLMEngine.shared.respond(system: LocalLLMPrompts.suggestionSystem, user: user, modelDirectory: modelDirectory, maxTokens: 200)
            print(String(format: "[%d] %.0fms", round, Date().timeIntervalSince(t0) * 1000), LocalLLMPrompts.parseSuggestions(output))
        }
    case "transform":
        let user = LocalLLMPrompts.transformUserPrompt(text: args[2], instruction: args.count > 3 ? args[3] : "丁寧にして", before: "", after: "")
        await LocalLLMEngine.shared.preload(directory: modelDirectory)
        let t0 = Date()
        let output = try await LocalLLMEngine.shared.respond(system: LocalLLMPrompts.transformSystem, user: user, modelDirectory: modelDirectory)
        print(String(format: "%.0fms", Date().timeIntervalSince(t0) * 1000))
        print(output)
    default:
        print("unknown mode")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
