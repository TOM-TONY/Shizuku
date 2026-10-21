import Foundation
import Gemma4ANE

// llm-ime: Gemma 4 ANE 実行系の確認用 CLI。
//   gemma4bench tokenize <model_dir> <lines.txt>          各行のトークン列を JSON で出力
//   gemma4bench argmax <model_dir> <ids.json>             位置ごとの次トークン argmax と対数確率（1 トークンずつ）
//   gemma4bench bench <model_dir>                         infer / prefill の時間
//   gemma4bench draft <model_dir> <文章> [文の数]          書き進める補完（1 文ずつ）
//   gemma4bench complete <model_dir> <eval.json> <out.json> [minLogProb] [truncate|whole] [heal|noheal] [lead]
//       続き予測（eval/completion_eval.json 形式）

@available(macOS 15.0, *)
func run() throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
        print("usage: gemma4bench tokenize|argmax|bench|complete <model_dir> ...")
        return
    }
    let dir = URL(fileURLWithPath: args[2])
    switch args[1] {
    case "tokenize":
        let tokenizer = try Gemma4Tokenizer(url: dir.appendingPathComponent("tokenizer.bin"))
        let lines = try String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        var out: [[Int32]] = []
        let t0 = Date()
        for line in lines {
            out.append(tokenizer.encode(String(line)))
        }
        FileHandle.standardError.write("encode \(lines.count) lines: \(Int(Date().timeIntervalSince(t0) * 1000))ms\n".data(using: .utf8)!)
        let data = try JSONEncoder().encode(out)
        FileHandle.standardOutput.write(data)
    case "argmax":
        let model = try Gemma4ANEModel(directoryURL: dir)
        let ids = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        var rows: [[String: Double]] = []
        for (p, id) in ids.enumerated() {
            let h = try model.forward(tokens: [id], start: p)
            let top = try model.topTokens(hidden: h)[0]
            rows.append(["token": Double(top.token), "logprob": Double(top.logProb)])
        }
        // prefill（最後の 1 つ前まで）→ 最後を infer
        model.resetState()
        _ = try model.forward(tokens: Array(ids.dropLast()), start: 0)
        let h = try model.forward(tokens: [ids.last!], start: ids.count - 1)
        let top = try model.topTokens(hidden: h)[0]
        rows.append(["prefill_last_token": Double(top.token), "logprob": Double(top.logProb)])
        FileHandle.standardOutput.write(try JSONEncoder().encode(rows))
    case "bench":
        let t0 = Date()
        let model = try Gemma4ANEModel(directoryURL: dir)
        print("load \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        var infer: [Double] = []
        var head: [Double] = []
        for p in 0..<40 {
            let a = Date()
            let h = try model.forward(tokens: [Int32(1000 + p)], start: p)
            let b = Date()
            _ = try model.topTokens(hidden: h)
            infer.append(b.timeIntervalSince(a) * 1000)
            head.append(Date().timeIntervalSince(b) * 1000)
        }
        var prefill: [Double] = []
        for _ in 0..<8 {
            model.resetState()
            let a = Date()
            _ = try model.forward(tokens: (0..<Int32(model.prefillLength)).map { 1000 + $0 }, start: 0)
            prefill.append(Date().timeIntervalSince(a) * 1000)
        }
        func median(_ x: [Double]) -> String { String(format: "%.1fms", x.dropFirst(2).sorted()[(x.count - 2) / 2]) }
        print("infer(FFN) \(median(infer))  head+softmax \(median(head))  prefill(\(model.prefillLength)) \(median(prefill))")
    case "complete":
        struct Item: Codable {
            var prefix: String
            var gold: String?
        }
        struct Row: Codable {
            var prefix: String
            var gold: String?
            var suggestion: String?
            var min_logprob: Float?
            var ms: Double
            var tokens: Int
        }
        let model = try Gemma4ANEModel(directoryURL: dir)
        let completer = Gemma4Completer(model: model)
        completer.options.minLogProb = args.count > 5 ? Float(args[5])! : -.infinity
        completer.options.truncateAtLowConfidence = args.count > 6 ? args[6] == "truncate" : true
        completer.options.tokenHealing = args.count > 7 ? args[7] == "heal" : true
        completer.options.leadingPunctuation = args.count > 8 && args[8] == "lead"
        if !completer.options.minLogProb.isFinite {
            completer.options.minCharacters = 1  // しきい値なしの記録では元の評価と同じく 1 文字から
        }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        var rows: [Row] = []
        _ = try completer.complete(context: "こんにちは")  // ウォームアップ
        for item in items {
            let t0 = Date()
            let s = try completer.complete(context: item.prefix)
            rows.append(Row(prefix: item.prefix, gold: item.gold, suggestion: s?.text, min_logprob: s?.minLogProb,
                            ms: Date().timeIntervalSince(t0) * 1000, tokens: s?.tokenCount ?? 0))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: args[4]))
        let ms = rows.map(\.ms).sorted()
        print("items \(rows.count)  median \(String(format: "%.0f", ms[ms.count / 2]))ms  p90 \(String(format: "%.0f", ms[ms.count * 9 / 10]))ms")
    case "draft":
        // gemma4bench draft <model_dir> <文章> [文の数]: 書き進める補完を続けて呼ぶ
        let model = try Gemma4ANEModel(directoryURL: dir)
        let completer = Gemma4Completer(model: model)
        var context = args[3]
        let count = args.count > 4 ? Int(args[4])! : 3
        for i in 0..<count {
            let t0 = Date()
            let trace: ((String) -> Void)? = ProcessInfo.processInfo.environment["TRACE"] != nil ? { print("  ", $0) } : nil
            let penalty: Gemma4Completer.RepetitionPenalty? = ProcessInfo.processInfo.environment["NODRY"] != nil ? nil : .init()
            guard let sentence = try completer.continueSentence(context: context, repetitionPenalty: penalty, trace: trace) else {
                print("[\(i)] なし")
                break
            }
            print(String(format: "[%d] %.0fms ", i, Date().timeIntervalSince(t0) * 1000) + sentence.debugDescription)
            context += sentence
        }
        print("---\n" + context)
    default:
        print("unknown mode \(args[1])")
    }
}

if #available(macOS 15.0, *) {
    do {
        try run()
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
