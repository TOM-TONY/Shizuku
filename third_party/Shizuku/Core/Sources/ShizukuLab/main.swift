import Core
import Foundation
import Gemma4ANE
import KanaKanjiConverterModuleWithDefaultDictionary
import LocalLLM

// ShizukuLab: 解析と学習。ConverterServer が必要なときだけ起動する別のプロセス。
// 記録の写し（ConverterServer が VACUUM INTO で作ったもの）を読み取り専用で開き、結果は置き場所（staging）にだけ書く。
// 記録の本体（personal.sqlite）は開かない。採否は ConverterServer が結果を確かめて決める。
//
//   ShizukuLab run --snapshot <写し> --snapshot-id <ID> --run-id <ID> --split <時刻> --staging <置き場所> --resources <Resources>
//                  --baseline <今の値の JSON> --seed <数> [--completion-model <フォルダ>] [--skip-completion <理由>]
//                  [--embedding-model <文の埋め込みのフォルダ>]
//                  [--local-model <MLX モデルのフォルダ>] [--style <本人のスタイル指示>]
//                  [--knowledge <文体の説明>] [--adapter <今の版のアダプタ>]
//   ShizukuLab import-jsonl <synth.jsonl> <out.sqlite> <resources> [--days 60]
//                  （開発用: 合成の記録を、日付を広げて写しと同じ形の記録にする。第 1 候補は変換で求める）
//   ShizukuLab upper-bound --snapshot <写し> --resources <Resources> --out <json> [--completion-model <フォルダ>] [--limit N]
//                  （履歴の上限だけを測る。採否・学習をせず、数とハッシュだけを書く）
//   ShizukuLab embedding-check --embedding-model <フォルダ>
//                  （開発用: サンドボックス内でモデルの読み込みと推論を確かめる。本人の記録は使わず、数だけ表示する）
//   ShizukuLab large-check --local-model <フォルダ> --staging <置き場所>
//                  （開発用: 公開の短い例で解析と2ステップの学習・再読込を確かめる）

let arguments = Array(CommandLine.arguments.dropFirst())

func value(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

/// 進み具合を置き場所に書く（1 行ずつ）
final class Progress: @unchecked Sendable {
    let url: URL
    let sortedKeys: Bool
    init(staging: URL, sortedKeys: Bool = false) {
        self.url = staging.appendingPathComponent("progress.jsonl")
        self.sortedKeys = sortedKeys
        FileManager.default.createFile(atPath: self.url.path, contents: nil)
    }

    func report(_ stage: String, _ fraction: Double, _ note: String = "") {
        let encoder = JSONEncoder()
        if self.sortedKeys { encoder.outputFormatting = [.sortedKeys] }
        guard let data = try? encoder.encode(LabProgress(stage: stage, fraction: fraction, note: note)),
              let handle = try? FileHandle(forWritingTo: self.url) else {
            return
        }
        handle.seekToEndOfFile()
        handle.write(data + Data("\n".utf8))
        try? handle.close()
    }
}

/// 使える記憶（空き＋再利用できるもの、バイト）
func availableMemory() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard result == KERN_SUCCESS else {
        return 0
    }
    return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * UInt64(sysconf(_SC_PAGESIZE))
}

func directorySize(_ url: URL) -> UInt64 {
    let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
    var total: UInt64 = 0
    while let file = enumerator?.nextObject() as? URL {
        total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return total
}

func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

/// 記録の量の下限（段階 A。合成ログで測って決める）
let minimumHeldOutConversion = 200
let minimumValidationConversion = 200
let minimumCompletionSamples = 100

@MainActor
func run() async throws {
    guard let snapshotPath = value("--snapshot"), let snapshotID = value("--snapshot-id"), let runID = value("--run-id"),
          let split = value("--split").flatMap(Double.init), let stagingPath = value("--staging"), let resourcesPath = value("--resources"),
          let baselineJSON = value("--baseline"), let seed = value("--seed").flatMap(UInt64.init) else {
        FileHandle.standardError.write(Data("usage: ShizukuLab run --snapshot … (see source)\n".utf8))
        exit(2)
    }
    let started = Date()
    let staging = URL(fileURLWithPath: stagingPath, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let progress = Progress(staging: staging)
    let baseline = try JSONDecoder().decode(LabParameters.self, from: Data(baselineJSON.utf8))
    progress.report("snapshot", 0, "記録の写しを読む")
    let commits = try LabSnapshot.readCommits(url: URL(fileURLWithPath: snapshotPath))
    let labSplit = LabSplit(split: split)
    let train = LabTrainView(commits, split: labSplit)
    let heldOut = LabHeldOut(commits, split: labSplit)
    // 案は学習側の最も新しい 2 週間（選ぶ用）で選び、取り置き分では 1 つの案だけを確かめる（たまたま良い案を選ばないように）
    let validationSplit = LabSplit(split: split - LabSplit.heldOutDays * 86400)
    let trainForValidation = LabTrainView(train.commits, split: validationSplit)
    let validation = LabHeldOut(train.commits, split: validationSplit)
    let heldConversion = heldOut.commits.filter(LabReplay.isConversionItem)
    let validationConversion = validation.commits.filter(LabReplay.isConversionItem)
    var counts: [String: Int] = [
        "commits": commits.count, "train": train.commits.count, "heldOut": heldOut.commits.count,
        "heldOutConversion": heldConversion.count, "validationConversion": validationConversion.count,
    ]
    var skipped: [String] = []
    var notes: [String] = []
    var artifacts: [LabArtifact] = []
    func finish(_ status: LabRunResult.Status, candidate: LabParameters?, items: [LabGate.Item], decision: LabGate.Decision?) throws {
        let result = LabRunResult(
            runID: runID, snapshotID: snapshotID, split: split, status: status, baseline: baseline, candidate: candidate, seed: seed,
            items: items, decision: decision, counts: counts, skipped: skipped, notes: notes,
            dataFrom: commits.first?.ts, dataTo: commits.last?.ts, elapsed: Date().timeIntervalSince(started), artifacts: artifacts
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(result).write(to: staging.appendingPathComponent("result.json"), options: .atomic)
        progress.report("done", 1, status.rawValue)
    }
    guard heldConversion.count >= minimumHeldOutConversion, validationConversion.count >= minimumValidationConversion else {
        notes.append("記録が足りない（取り置き \(heldConversion.count)、選ぶ用 \(validationConversion.count)。それぞれ \(minimumHeldOutConversion) 以上）")
        try finish(.insufficient, candidate: nil, items: [], decision: nil)
        return
    }

    // 1. 自動辞書の値（場面のしきい値 → 票の差 → 文脈の票の差の順に 1 つずつ動かす）
    let replay = LabConversionReplay(resources: URL(fileURLWithPath: resourcesPath, isDirectory: true))
    func validationTop1(_ parameters: LabParameters) throws -> Double {
        mean(try replay.run(train: trainForValidation, items: validationConversion, parameters: parameters).map { $0 ? 1 : 0 })
    }
    progress.report("lexicon", 0.05, "今の値で変換を再生")
    var lexicon = baseline
    var lexiconScore = try validationTop1(baseline)
    let lexiconSteps: [(String, [(inout LabParameters) -> Void])] = [
        ("sceneThreshold", [2, 3].map { v in { $0.sceneThreshold = v } }),
        ("promotionMargin", [2.5, 3.0, 4.0].map { v in { $0.promotionMargin = v } }),
        ("contextPromotionMargin", [1.5, 2.0, 3.0].map { v in { $0.contextPromotionMargin = v } }),
    ]
    for (index, (name, options)) in lexiconSteps.enumerated() {
        for option in options {
            var trial = lexicon
            option(&trial)
            guard trial != lexicon, trial.isWithinBounds else {
                continue
            }
            let score = try validationTop1(trial)
            if score > lexiconScore + 0.001 {
                lexicon = trial
                lexiconScore = score
            }
        }
        progress.report("lexicon", 0.05 + 0.4 * Double(index + 1) / Double(lexiconSteps.count), name)
    }

    // 2. 手本の選び方（続き予測。E2B のとき・記憶が足りないときは飛ばす）
    var corpus = baseline
    var engineReady = false
    if let reason = value("--skip-completion") {
        skipped.append("続き予測の答え合わせ: \(reason)")
    } else if let modelPath = value("--completion-model") {
        let model = URL(fileURLWithPath: modelPath, isDirectory: true)
        let needed = directorySize(model) + 2 * 1024 * 1024 * 1024
        if availableMemory() < needed {
            skipped.append("続き予測の答え合わせ: 空いている記憶が足りない（\(availableMemory() / 1_048_576)MB、要る量 \(needed / 1_048_576)MB）")
        } else {
            NextTextCompletionEngine.modelDirectoryOverride = model
            engineReady = true
        }
    } else {
        skipped.append("続き予測の答え合わせ: 続き予測のモデルがない")
    }
    // 文の埋め込み（ConverterServer が --embedding-model を渡したときだけ。手本選びに意味の近さを足す案も試す）
    var embedder: PersonalEmbedder?
    if let embeddingPath = value("--embedding-model") {
        do {
            embedder = try PersonalEmbedder(directory: URL(fileURLWithPath: embeddingPath, isDirectory: true))
        } catch {
            skipped.append("意味の近さ: 文の埋め込みのモデルを読めない")
        }
    }
    var documentVectors: [String: [Float]] = [:]
    let embed: LabReplay.Embed? = embedder.map { embedder in
        { text, asQuery in
            if asQuery {
                return embedder.embed(text, asQuery: true)
            }
            if let cached = documentVectors[text] {
                return cached
            }
            let vector = embedder.embed(text, asQuery: false)
            documentVectors[text] = vector
            return vector
        }
    }
    var pieceCache: [String: [NextTextCompletionEngine.Piece]] = [:]
    func completionOutcomes(train: LabTrainView, items heldOutCommits: [LabCommit], parameters: LabParameters) async throws -> [(ts: Double, outcome: (saved: Int, wrong: Bool))] {
        let samples = LabReplay.completionItems(train: train, heldOut: heldOutCommits, parameters: parameters, limit: 300, embed: embed)
        let missing = samples.filter { pieceCache[$0.sample.context + "\u{1F}" + $0.prefix] == nil }
        if !missing.isEmpty {
            // 時間の上限は ConverterServer が動いている時間で数える（止めている間も進む壁時計では切らない）。
            // 全部の位置の結果がそろわなければ失敗にする（そろわない分を「出さなかった」と数えると、結果が実行ごとに変わる）
            let result = await NextTextCompletionEngine.shared.replay(missing.map { ($0.sample.context, $0.prefix) }, budget: .infinity)
            guard result.pieces.count == missing.count, !result.cancelled, !result.timedOut else {
                throw LabError.incompleteReplay(result.pieces.count, missing.count)
            }
            for (item, pieces) in zip(missing, result.pieces) {
                pieceCache[item.sample.context + "\u{1F}" + item.prefix] = pieces
            }
        }
        return samples.map { item in
            (item.sample.ts, LabReplay.completionOutcome(
                pieces: pieceCache[item.sample.context + "\u{1F}" + item.prefix] ?? [], gold: item.sample.gold,
                threshold: NextTextCompletionEngine.defaultMinLogProb
            ))
        }
    }
    if engineReady {
        func score(_ parameters: LabParameters) async throws -> (saved: Double, notWrong: Double, count: Int) {
            let outcomes = try await completionOutcomes(train: trainForValidation, items: validation.commits, parameters: parameters)
            return (mean(outcomes.map { Double($0.outcome.saved) }), mean(outcomes.map { $0.outcome.wrong ? 0 : 1 }), outcomes.count)
        }
        progress.report("corpus", 0.5, "今の値で続き予測を再生")
        var best = try await score(baseline)
        counts["validationCompletion"] = best.count
        if best.count < minimumCompletionSamples {
            skipped.append("手本の選び方: 続き予測の位置が足りない（\(best.count)）")
        } else {
            let corpusSteps: [(String, [(inout LabParameters) -> Void])] = [
                ("exemplarBudget", [120, 160, 200].map { v in { $0.exemplarBudget = v } }),
                ("bm25K1", [1.2, 1.6].map { v in { $0.bm25K1 = v } }),
                ("bm25B", [0.5, 0.75, 1.0].map { v in { $0.bm25B = v } }),
            ] + (embed == nil ? [] : [("semanticWeight", [0.0, 0.5, 1.0].map { v in { $0.semanticWeight = v } })])
            for (index, (name, options)) in corpusSteps.enumerated() {
                for option in options {
                    var trial = corpus
                    option(&trial)
                    guard trial != corpus, trial.isWithinBounds else {
                        continue
                    }
                    let result = try await score(trial)
                    if result.saved > best.saved + 0.002, result.notWrong >= best.notWrong - 0.005 {
                        corpus = trial
                        best = result
                    }
                }
                progress.report("corpus", 0.5 + 0.3 * Double(index + 1) / Double(corpusSteps.count), name)
            }
        }
    }

    // 3. 組ごとの勝者を 1 つの案にまとめ、取り置き分で 1 回だけ確かめる（何度も確かめて、たまたま通るのを防ぐ）
    var candidate = baseline.merging(lexicon: lexicon, corpus: corpus)
    var large: LargeModelLab?
    if let path = value("--local-model") {
        let model = URL(fileURLWithPath: path, isDirectory: true)
        let needed = directorySize(model) + 6 * 1024 * 1024 * 1024
        let validationMagic = LabMagic.samples(validation.commits)
        let heldMagic = LabMagic.samples(heldOut.commits)
        counts["validationMagic"] = validationMagic.count; counts["heldOutMagic"] = heldMagic.count
        if availableMemory() < needed {
            skipped.append("大きいモデル: 空いている記憶が足りない（必要 \(needed / 1_048_576)MB）")
        } else if min(validationMagic.count, heldMagic.count) < LabRules.minimumMagicItems {
            skipped.append("大きいモデル: いい感じ変換の比較に使える記録が足りない（各 \(LabRules.minimumMagicItems) 件以上必要）")
        } else {
            do {
                let oldKnowledge = value("--knowledge").flatMap { LabKnowledge.read(at: URL(fileURLWithPath: $0)) }
                let oldAdapter = value("--adapter").map { URL(fileURLWithPath: $0, isDirectory: true) }
                let engine = try LargeModelLab(model: model, train: trainForValidation, embedding: embed,
                    style: value("--style") ?? "", progress: progress, baselineKnowledge: oldKnowledge, baselineAdapter: oldAdapter,
                    baselineParameters: baseline, parameters: candidate,
                    embeddingSource: value("--embedding-model").flatMap { ModelCatalog.embeddingInfo(at: URL(fileURLWithPath: $0))?.source },
                    resources: URL(fileURLWithPath: resourcesPath, isDirectory: true))
                _ = try await engine.analyse(validation: validationMagic, staging: staging, seed: seed)
                large = engine
                let from = trainForValidation.commits.first?.ts ?? 0, to = trainForValidation.commits.last?.ts ?? 0
                if engine.knowledge != oldKnowledge, let knowledge = engine.knowledge {
                    try JSONEncoder().encode(knowledge).write(to: staging.appendingPathComponent("knowledge.json"), options: .atomic)
                    let artifact = try LabArtifact.measure(kind: .knowledge, root: staging, dataFrom: from, dataTo: to)
                    artifacts.append(artifact); candidate.knowledgeID = artifact.digest
                }
                if engine.adapter != oldAdapter, engine.adapter != nil {
                    let artifact = try LabArtifact.measure(kind: .adapter, root: staging, dataFrom: from, dataTo: to)
                    artifacts.append(artifact); candidate.adapterID = artifact.digest
                }
                try JSONEncoder().encode(engine.report).write(to: staging.appendingPathComponent("report.json"), options: .atomic)
                artifacts.append(try LabArtifact.measure(kind: .report, root: staging, dataFrom: from, dataTo: to))
                notes.append(engine.report.loraNote)
            } catch {
                skipped.append("大きいモデルの解析: 完了しなかったため採用しない（\(error)）")
                large = nil
                candidate.knowledgeID = baseline.knowledgeID; candidate.adapterID = baseline.adapterID
                artifacts.removeAll()
                await LocalLLMEngine.shared.unload()
            }
        }
    } else { skipped.append("大きいモデルの解析: ローカルモデルがない") }
    let families = LabRules.families(baseline: baseline, candidate: candidate)
    guard !families.isEmpty else {
        notes.append("今の値より良い案がなかった")
        try finish(.noCandidate, candidate: nil, items: [], decision: nil)
        return
    }
    progress.report("heldOut", 0.85, "取り置き分で今の値と案を比べる")
    let baselineHeld = try replay.run(train: train, items: heldConversion, parameters: baseline)
    let candidateHeld = families.contains(.lexicon) ? try replay.run(train: train, items: heldConversion, parameters: candidate) : baselineHeld
    var completionPairs: [(ts: Double, baseline: (saved: Int, wrong: Bool), candidate: (saved: Int, wrong: Bool))] = []
    if engineReady, families.contains(.corpus) {
        let base = try await completionOutcomes(train: train, items: heldOut.commits, parameters: baseline)
        let cand = try await completionOutcomes(train: train, items: heldOut.commits, parameters: candidate)
        completionPairs = zip(base, cand).map { ($0.ts, $0.outcome, $1.outcome) }
        counts["heldOutCompletion"] = completionPairs.count
    }
    var items = LabReplay.pairedItems(
        conversion: zip(heldConversion, zip(baselineHeld, candidateHeld)).map { ($0.ts, $1.0, $1.1) },
        completion: completionPairs
    )
    if let large {
        let rows = LabMagic.samples(heldOut.commits)
        let base = try await large.score(rows: rows, knowledge: large.baselineKnowledge, adapter: large.baselineAdapter, parameters: baseline)
        let changed = try await large.score(rows: rows, knowledge: large.knowledge, adapter: large.adapter)
        items += zip(rows, zip(base, changed)).map { row, pair in
            LabGate.Item(day: LabReplay.day(row.ts), diffs: ["f1": pair.1.f1 - pair.0.f1, "magicTime": pair.0.seconds - pair.1.seconds])
        }
        await LocalLLMEngine.shared.unload()
    }
    let decision = LabGate.decide(items: items, rules: LabRules.rules(for: families), seed: seed)
    notes.append("変えた組: " + families.map(\.rawValue).sorted().joined(separator: "・"))
    try finish(.candidate, candidate: candidate, items: items, decision: decision)
}

/// 開発用: 合成の記録（JSON Lines）を、日付を広げて写しと同じ形の記録にする（第 1 候補は個人化なしの変換で求める）
@MainActor
func importJSONL() throws {
    guard arguments.count >= 4 else {
        FileHandle.standardError.write(Data("usage: ShizukuLab import-jsonl <synth.jsonl> <out.sqlite> <resources> [--days 60]\n".utf8))
        exit(2)
    }
    struct Row: Decodable {
        var ts: Double?
        var scene: String?
        var kind: String?
        var reading: String?
        var surface: String?
        var left: String?
    }
    let rows = try String(contentsOfFile: arguments[1], encoding: .utf8).split(separator: "\n").compactMap {
        try? JSONDecoder().decode(Row.self, from: Data($0.utf8))
    }.filter { $0.surface != nil && $0.scene.flatMap(PersonalScene.init(key:)) != nil }
    let days = value("--days").flatMap(Double.init) ?? 60
    let start = Date().timeIntervalSince1970 - days * 86400
    let step = days * 86400 / Double(max(1, rows.count))
    let store = try PersonalStore(url: URL(fileURLWithPath: arguments[2]))
    let memory = FileManager.default.temporaryDirectory.appendingPathComponent("shizukulab-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: memory)
    }
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(), applicationDirectoryURL: memory, containerURL: nil,
        context: .init(useZenzai: true, resourcesDirectoryURL: URL(fileURLWithPath: arguments[3], isDirectory: true))
    )
    manager.activate()
    for (index, row) in rows.enumerated() {
        var first: String?
        if let reading = row.reading {
            manager.insertAtCursorPosition(reading.toHiragana(), inputStyle: .direct)
            manager.insertCompositionSeparator(inputStyle: .direct, skipUpdate: true)
            manager.updateForFirstCandidate()
            first = manager.getCurrentMarkedText(inputState: .previewing).map(\.content).joined()
            manager.stopComposition()
        }
        let scene = PersonalScene(key: row.scene!)!
        try store.queue.sync {
            try store.execute(
                "INSERT INTO commits(id, ts, composition, scene, app, shape, mode, reply, kind, reading, surface, first, left, keys, backspaces) VALUES(?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)",
                [
                    .int(Int64(index + 1)), .double(start + Double(index) * step), .text(scene.key), .text(scene.app), .text(scene.shape.rawValue),
                    .text(scene.mode.rawValue), .int(scene.reply ? 1 : 0), .text(row.kind ?? "selection"), .optionalText(row.reading),
                    .text(row.surface!), .optionalText(first), .optionalText(row.left),
                ]
            )
        }
        if (index + 1) % 500 == 0 {
            FileHandle.standardError.write(Data("\(index + 1)/\(rows.count)\n".utf8))
        }
    }
    print("imported \(rows.count) commits over \(Int(days)) days → \(arguments[2])")
}

/// 開発用: 答え合わせが毎回同じ結果になるかを確かめる。今の値で、選ぶ用の変換と続き予測を repeat 回再生し、項目ごとの結果
/// （第 1 候補・手本・続きの文字列はハッシュだけ）を JSON に書く。別のプロセスで 2 回走らせて出力を比べる
@MainActor
func replayDump() async throws {
    guard let snapshotPath = value("--snapshot"), let resourcesPath = value("--resources"), let outPath = value("--out") else {
        FileHandle.standardError.write(Data("usage: ShizukuLab replay-dump --snapshot <db> --resources <dir> --out <json> [--completion-model <dir>] [--repeat N] [--limit N]\n".utf8))
        exit(2)
    }
    func fnv(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
    let repeats = value("--repeat").flatMap(Int.init) ?? 1
    let limit = value("--limit").flatMap(Int.init) ?? Int.max
    var commits = try LabSnapshot.readCommits(url: URL(fileURLWithPath: snapshotPath))
    if arguments.contains("--include-model-origin") {
        for index in commits.indices { commits[index].origin = 0 }
    }
    guard let last = commits.last?.ts else {
        exit(1)
    }
    let split = LabSplit.make(lastCommit: last).split
    let train = LabTrainView(commits, split: LabSplit(split: split))
    let validationSplit = LabSplit(split: split - LabSplit.heldOutDays * 86400)
    let trainForValidation = LabTrainView(train.commits, split: validationSplit)
    let validation = LabHeldOut(train.commits, split: validationSplit)
    let items = Array(validation.commits.filter(LabReplay.isConversionItem).prefix(limit))
    let replay = LabConversionReplay(resources: URL(fileURLWithPath: resourcesPath, isDirectory: true))
    var output: [String: [[String]]] = ["conversion": [], "completion": []]
    for round in 0..<repeats {
        let t0 = Date()
        let results = try replay.run(train: trainForValidation, items: items, parameters: LabParameters())
        output["conversion"]!.append(zip(results, replay.lastTop1).map { "\($0 ? 1 : 0) \(fnv($1))" })
        FileHandle.standardError.write(Data("conversion round \(round): top1 \(results.filter { $0 }.count)/\(results.count) \(Int(Date().timeIntervalSince(t0)))s\n".utf8))
    }
    if let modelPath = value("--completion-model") {
        NextTextCompletionEngine.modelDirectoryOverride = URL(fileURLWithPath: modelPath, isDirectory: true)
        let samples = LabReplay.completionItems(train: trainForValidation, heldOut: validation.commits, parameters: LabParameters(), limit: min(limit, 300))
        for round in 0..<repeats {
            let t0 = Date()
            let result = await NextTextCompletionEngine.shared.replay(samples.map { ($0.sample.context, $0.prefix) }, budget: 3600)
            output["completion"]!.append(zip(samples, result.pieces).map { item, pieces in
                let outcome = LabReplay.completionOutcome(pieces: pieces, gold: item.sample.gold, threshold: NextTextCompletionEngine.defaultMinLogProb)
                let piecesText = pieces.map { "\($0.text)\u{1F}\($0.logProb)" }.joined(separator: "\u{1E}")
                return "\(outcome.saved) \(outcome.wrong ? 1 : 0) prefix=\(fnv(item.prefix)) pieces=\(fnv(piecesText))"
            })
            FileHandle.standardError.write(Data("completion round \(round): \(result.pieces.count)/\(samples.count) \(Int(Date().timeIntervalSince(t0)))s\n".utf8))
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(output).write(to: URL(fileURLWithPath: outPath))
}

/// 開発用の測定。文章はメモリ内だけに置き、採否・版・学習の入口を呼ばない。
@MainActor
func upperBound() async throws {
    guard let snapshot = value("--snapshot"), value("--resources") != nil, let out = value("--out") else {
        throw LabError.invalidResult("upper-bound: --snapshot --resources --out が必要")
    }
    let limit = value("--limit").flatMap(Int.init) ?? Int.max
    guard limit > 0 else { throw LabError.invalidResult("limit は正の数が必要") }
    let url = URL(fileURLWithPath: snapshot)
    let rows = try LabSnapshot.readCommits(url: url)
    let auxiliary = try LabSnapshot.readUpperBoundAuxiliary(url: url)
    let destination = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let progress = Progress(staging: destination.deletingLastPathComponent(), sortedKeys: true)
    var status = "no-model"
    var generate: LabUpperBound.Generator?
    if let model = value("--completion-model") {
        let directory = URL(fileURLWithPath: model, isDirectory: true)
        if PersonalTuner.isPowerSavingModel(directory) {
            status = "E2B-skipped"
        } else {
            status = "E4B"
            NextTextCompletionEngine.modelDirectoryOverride = directory
            generate = { items in
                let result = await NextTextCompletionEngine.shared.replay(items, budget: .greatestFiniteMagnitude)
                guard !result.cancelled, !result.timedOut, result.pieces.count == items.count else {
                    throw LabError.invalidResult("続き予測の位置がそろわなかった")
                }
                return result.pieces
            }
        }
    }
    var report = try await LabUpperBound.measure(commits: rows, auxiliary: auxiliary, limit: limit, completionStatus: status, generate: generate) { stage, fraction in
        progress.report(stage, fraction)
    }
    if let model = value("--completion-model"), let data = try? Data(contentsOf: URL(fileURLWithPath: model).appendingPathComponent("meta.json")) {
        report.modelConfigurationHash = LabUpperBound.hash(String(decoding: data, as: UTF8.self))
    }
    try report.canonicalJSON().write(to: destination, options: .atomic)
    progress.report("upper-bound-done", 1)
    print("upper-bound: 確定 \(report.commits) 件、途中 \(report.positions["mid"] ?? 0) 位置、先頭 \(report.positions["start"] ?? 0) 位置、場面 \(report.scenes.count) 行")
}

/// 開発用: 通常の解析と同じモデルの読み込みを、本人の記録なしで確かめる。サーバーからは呼ばれない。
func checkEmbedding() throws {
    guard let path = value("--embedding-model") else {
        FileHandle.standardError.write(Data("usage: ShizukuLab embedding-check --embedding-model <dir>\n".utf8))
        exit(2)
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    guard let info = ModelCatalog.embeddingInfo(at: directory) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let embedder = try PersonalEmbedder(directory: directory)
    for asQuery in [true, false] {
        guard let vector = embedder.embed("書類を確認してください。", asQuery: asQuery),
              !vector.isEmpty, vector.count == info.dimension, vector.allSatisfy({ $0.isFinite }),
              abs(vector.reduce(0.0) { $0 + Double($1) * Double($1) } - 1) < 0.02 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    print("埋め込み確認: \(info.dimension) 次元・問いと文書の推論成功・有限値と単位長を確認")
}

/// 開発用: 公開の短い例だけで解析・逆伝播・保存・再読込を一巡させる。通常の採用条件は変えない。
@MainActor
func checkLargeModel() async throws {
    guard let path = value("--local-model"), let output = value("--staging") else { throw LabError.invalidResult("モデルと置き場所が必要") }
    let staging = URL(fileURLWithPath: output, isDirectory: true)
    let discard = arguments.contains("--discard")
    if discard, (try? FileManager.default.attributesOfItem(atPath: staging.path)) != nil {
        throw LabError.invalidResult("消去する確認の置き場所は新しいフォルダにしてください")
    }
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { if discard { try? FileManager.default.removeItem(at: staging) } }
    let scene = "dev.example.editor|short|new|-"
    let pairs = [("しょるいをかくにんしてください", "書類を確認してください。"),
                 ("あしたのかいぎにさんかします", "明日の会議に参加します。"),
                 ("れんらくありがとうございます", "連絡ありがとうございます。")]
    let rows = (0..<12).map { i in LabCommit(ts: Double(i), scene: scene, kind: "selection", reading: pairs[i % 3].0,
                                            surface: pairs[i % 3].1, first: pairs[i % 3].1, left: nil) }
    let engine = try LargeModelLab(model: URL(fileURLWithPath: path), train: LabTrainView(rows, split: LabSplit(split: 20)),
                                   embedding: nil, style: "", progress: Progress(staging: staging), baselineKnowledge: nil, baselineAdapter: nil)
    _ = try await engine.analyse(validation: Array(rows.prefix(2)), staging: staging, seed: LabRules.seed,
                                 minimumLoRASamples: 1, iterations: 2)
    try JSONEncoder().encode(engine.report).write(to: staging.appendingPathComponent("report.json"), options: .atomic)
    print("大きいモデル確認: \(engine.report.modelName)、道具 \(engine.report.calls.count) 回、\(engine.report.loraNote)")
    let tools = Set(engine.report.calls.filter(\.accepted).map(\.tool))
    print("実行した道具: " + tools.sorted().joined(separator: "・"))
    guard tools.isSuperset(of: ["propose", "evaluate", "finish"]), !engine.report.loraNote.contains("完了しなかった") else {
        throw LabError.invalidResult("解析の提案・評価・まとめ、または学習が完了しなかった")
    }
}

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    if let path = ProcessInfo.processInfo.environment["SHIZUKU_INFERENCE_USAGE"] {
        let url = URL(fileURLWithPath: path)
        InferenceActivity.setObserver { _ in try? InferenceActivity.save(to: url) }
    }
    do {
        switch arguments.first {
        case "run":
            try await run()
        case "import-jsonl":
            try importJSONL()
        case "replay-dump":
            try await replayDump()
        case "upper-bound":
            try await upperBound()
        case "embedding-check":
            try checkEmbedding()
        case "large-check":
            try await checkLargeModel()
        default:
            FileHandle.standardError.write(Data("usage: ShizukuLab run|upper-bound|replay-dump|import-jsonl …\n".utf8))
            exit(2)
        }
    } catch {
        FileHandle.standardError.write(Data("ShizukuLab: \(error)\n".utf8))
        exit(1)
    }
    semaphore.signal()
}
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}
