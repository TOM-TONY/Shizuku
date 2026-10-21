import Core
import CoreML
import Foundation
import Gemma4ANE
import KanaKanjiConverterModuleWithDefaultDictionary
import LocalLLM

// llm-ime: 場面学習の評価。確定の記録（書き出しの JSON Lines、または eval/build_personal_synth.swift で作った合成のログ）を
// 時刻の順に再生し、個人化あり／なしで同じ指標を比べる。記録は本人の文章を含みうるので、出力は git 管理外（build/ など）に置く。
//
//   personaleval conversion <log.jsonl> <resources_dir> <off|on> <out.json> [--limit N] [--docs a,b]
//     変換: 読みを入れて 1 回目のスペース（第 1 候補）が確定した表記と一致した割合（top1）。一致しなければ、本人は候補一覧から
//     （なければ文節を直して）その表記を選んだとみなして確定する（azooKey の履歴学習はどちらでも働く。on では場面学習も学ぶ）。
//     resources_dir は zenz（zenz-v2.5-medium-ane.mlmodelc）と打鍵ミスの n-gram があるフォルダ（アプリの Contents/Resources）
//     --no-lexicon: 自動辞書・文脈つき選択学習を使わない。--no-context: 文脈つき選択学習を使わない。
//     --no-scene: 場面・アプリ・全体の段（自動辞書）を使わない（文脈つき選択学習だけを見る）。
//     --margin X: 場面・アプリ・全体の段で先頭に置く得票の差（既定 3）--context-threshold K: その文脈で何回選んだら使うか（既定 1）
//
//   personaleval completion <log.jsonl> <model_dir> <none|recent|retrieve|card> <out.json> [--context full|line] [--limit N] [--docs a,b]
//     続き予測: 各句を途中まで打った時点（句の 2 文字目〜最後の 1 文字前のどこか。番号から決まる）で予測し、残りの句＋後ろの本文を
//     正解とする（eval/completion_ane_metrics.py と同じ指標: 出現率・精度・節約文字/問）。手本（本人の過去の文）を文脈の前に置くかを比べる。
//     --context line: 左文脈を今の行だけにする（チャット欄のような短い欄の再現）
//     --sticky: 手本を文の終わり・場面が変わったときだけ選び直す（既定は句ごと＝入力ごと）
//     --keep-top1: 句ごとに探し直すが、新しい 1 位の文が今の手本に入っていれば手本を変えない
//     --all-positions: 時間は、句の 2 文字目から最後までのすべての位置で予測して測る（IME は読みの 1 文字ごとに予測する。
//       精度・節約文字は従来どおり 1 か所で数える）
//     --embedder <mlpackage> --tokenizer <tokenizer.json> [--length 64] [--semantic-weight W] [--embed-prefix]:
//       手本選びに意味の近さ（文の埋め込み）を足す（解析と学習 段階 B の比べ）。--embed-prefix: ruri-v3 の
//       「検索クエリ: 」「検索文書: 」を付ける（magic も同じ引数で、手本なし／BM25 の手本／意味の近さを足した手本 の 3 通りを比べる）。
//       --semantic-query left|context: 意味の問いを、入力を始める前の左文脈の末尾 40 字（既定。IME では確定の後に裏で作れる）にするか、
//       BM25 と同じ問い（入力中の句の前半を含む）にするか
//
//   personaleval embedbench <log.jsonl> <mlpackage> <tokenizer.json> <length> [--count N]
//     文の埋め込み 1 文の時間（字句分け・入出力の詰め替えを含む）と、N 文のベクトルからの検索（内積で並べる）の時間
//
//   personaleval tune <log.jsonl> <model_dir> <out.json>
//     自己調整（続き予測のしきい値）: 各文書の前半の確定を記録として、本番と同じく 30 秒の上限で再生してしきい値を選び、後半で
//     既定（−0.7）と比べる（出現率・精度・節約文字）。キー入力での打ち切りも測る（再生の途中で打ち切りを 5 回）
//
//   personaleval magic <log.jsonl> <resources_dir> <llm_model_dir> <reading|keywords> <out.json> [--limit N] [--min-length L]
//     いい感じ変換（ローカル LLM）で、本人の過去の文を手本にするか（キーワードから本人の文へ）。各文書の後半の句（L 字以上、既定 12）を
//     入力にし、同じ文書の前の句から手本を選ぶ（IME と同じく、入力の第 1 候補＋左文脈の末尾で探す）。手本なし／ありの候補が
//     本人が実際に書いた句にどれだけ近いか（文字 2-gram の F1。第 1 候補と、候補の中の最大）と完全一致の割合
//     reading: 句の読み全体を入れる。keywords: 漢字・カタカナを含む語の読みだけを空白でつないで入れる
//
//   personaleval typo <typo_eval.json> <resources_dir> <off|on> <out.json> [--habits N] [--history K] [--repeat]
//     打鍵ミス訂正（入力中の「もしかして」）: 誤りありの問題で正しく訂正した割合・違う訂正を出した割合、誤りなしの問題で
//     訂正を出した割合（誤警報）。本人の癖として、隣接キー置換で多い N 組（既定 3）を K 回（既定 5）打ち直した記録があるとする
//     （個人化で効くのは訂正先ごとのしきい値だけ）。
//     --repeat: 同じ問題を 2 回打ち、1 回目に出た訂正を使った／使わなかった結果を 2 回目のしきい値に反映する（誤りなしは使わない）

struct LogRow: Decodable {
    var table: String?
    var doc: String?
    var ts: Double?
    var scene: String?
    var app: String?
    var kind: String?
    var origin = 0
    var isMaterial: Bool { PersonalOrigin.isMaterial(origin) }
    var reading: String?
    var surface: String?
    var left: String?
    var context: String?
    var next: String?

    /// 書き出しは数値も文字列で入れるので、両方を受ける
    enum CodingKeys: String, CodingKey {
        case table, doc, ts, scene, app, kind, origin, reading, surface, left, context, next
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.table = try c.decodeIfPresent(String.self, forKey: .table)
        self.doc = try c.decodeIfPresent(String.self, forKey: .doc)
        if let ts = try? c.decodeIfPresent(Double.self, forKey: .ts) {
            self.ts = ts
        } else if let ts = try c.decodeIfPresent(String.self, forKey: .ts) {
            self.ts = Double(ts)
        }
        self.scene = try c.decodeIfPresent(String.self, forKey: .scene)
        self.app = try c.decodeIfPresent(String.self, forKey: .app)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        if let origin = try? c.decode(Int.self, forKey: .origin) { self.origin = origin }
        else if let origin = try? c.decode(String.self, forKey: .origin) { self.origin = Int(origin) ?? 0 }
        self.reading = try c.decodeIfPresent(String.self, forKey: .reading)
        self.surface = try c.decodeIfPresent(String.self, forKey: .surface)
        self.left = try c.decodeIfPresent(String.self, forKey: .left)
        self.context = try c.decodeIfPresent(String.self, forKey: .context)
        self.next = try c.decodeIfPresent(String.self, forKey: .next)
    }
}

func loadLog(_ path: String) throws -> [LogRow] {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    let decoder = JSONDecoder()
    var rows = content.split(separator: "\n").compactMap { line in
        try? decoder.decode(LogRow.self, from: Data(line.utf8))
    }
    .filter { ($0.table ?? "commits") == "commits" }
    .sorted { ($0.ts ?? 0) < ($1.ts ?? 0) }
    // 実際の記録（書き出し）には左文脈が 20 字しかなく、後ろに続く本文もない。同じ場面の前後の確定から作る
    // （前は 10 分以内の確定、後ろは間が 60 秒未満で続く確定）
    let byScene = Dictionary(grouping: rows.indices) { rows[$0].scene ?? "" }
    for indices in byScene.values {
        for (position, index) in indices.enumerated() {
            if rows[index].context == nil {
                var context = ""
                var last = rows[index].ts ?? 0
                for previous in indices[..<position].reversed() {
                    guard last - (rows[previous].ts ?? 0) < 600, context.count < 200 else {
                        break
                    }
                    context = (rows[previous].surface ?? "") + context
                    last = rows[previous].ts ?? 0
                }
                rows[index].context = context.isEmpty ? rows[index].left : String(context.suffix(200))
            }
            if rows[index].next == nil {
                var next = ""
                var last = rows[index].ts ?? 0
                for following in indices[(position + 1)...] {
                    guard (rows[following].ts ?? 0) - last < 60, next.count < 40 else {
                        break
                    }
                    next += rows[following].surface ?? ""
                    last = rows[following].ts ?? 0
                }
                rows[index].next = String(next.prefix(40))
            }
            if rows[index].doc == nil {
                rows[index].doc = rows[index].scene
            }
        }
    }
    return rows
}

/// 左文脈を返す（評価では記録の左文脈を使う）
final class EvalContext: SegmentManagerDelegate {
    var left = ""

    func getLeftSideContext(maxCount: Int) -> String? {
        String(self.left.suffix(maxCount))
    }

    func getRightSideContext(maxCount: Int) -> String? {
        nil
    }
}

/// 個人化（on のとき）: 記録の場面で PersonalLearner に答えさせる
final class EvalPersonalization: SegmentsManagerPersonalization {
    let learner = PersonalLearner(storeURL: nil)
    var scene: PersonalScene?
    var useLexicon = true


    var useContext = true

    func personalPreferredSurface(forReading reading: String, leftContext: String) -> PersonalLearner.Entry? {
        guard self.useLexicon else {
            return nil
        }
        return self.scene.flatMap { self.learner.preferredEntry(forReading: reading, scene: $0, leftContext: self.useContext ? leftContext : nil) }
    }


    /// 評価では確定の記録は再生の側で行う（実際の確定と同じ情報を渡す）
    func segmentsManagerDidCommit(_ event: SegmentsManager.CommitEvent) {
        guard let scene else {
            return
        }
        self.learner.recordCommit(.init(
            scene: scene, kind: event.kind.rawValue, reading: event.reading, surface: event.surface,
            defaultSurface: event.defaultSurface, rank: event.rank, leftContext: event.leftContext,
            lcid: event.lcid, rcid: event.rcid, mid: event.mid
        ), now: self.now)
    }

    var now = Date()
}

struct ConversionResultRow: Encodable {
    var doc: String
    var reading: String
    var gold: String
    var top1: String
    var correct: Bool
    var inList: Int?
    var repeated: Bool
    var milliseconds: Double
}

@MainActor
func runConversion(arguments: [String]) throws {
    guard arguments.count >= 4 else {
        print("usage: personaleval conversion <log.jsonl> <resources_dir> <off|on> <out.json> [--limit N] [--docs a,b]")
        return
    }
    var rows = try loadLog(arguments[0]).filter { $0.reading != nil && $0.surface != nil && $0.kind != "kana" && $0.kind != "idle" }
    let resources = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let personalOn = arguments[2] == "on"
    let output = arguments[3]
    if let index = arguments.firstIndex(of: "--docs") {
        let docs = Set(arguments[index + 1].split(separator: ",").map(String.init))
        rows = rows.filter { docs.contains($0.doc ?? "") }
    }
    if let index = arguments.firstIndex(of: "--limit"), let limit = Int(arguments[index + 1]) {
        rows = Array(rows.prefix(limit))
    }
    let memory = FileManager.default.temporaryDirectory.appendingPathComponent("personaleval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: memory)
    }
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let manager = SegmentsManager(
        kanaKanjiConverter: converter, applicationDirectoryURL: memory, containerURL: nil,
        context: .init(useZenzai: true, resourcesDirectoryURL: resources)
    )
    let context = EvalContext()
    manager.delegate = context
    let personalization = EvalPersonalization()
    if personalOn {
        manager.personalization = personalization
    }
    personalization.useLexicon = !arguments.contains("--no-lexicon")
    personalization.useContext = !arguments.contains("--no-context")
    if arguments.contains("--no-scene") {
        PersonalLearner.useSceneLevels = false
    }
    if let index = arguments.firstIndex(of: "--margin"), let margin = Double(arguments[index + 1]) {
        PersonalLearner.promotionMargin = margin
    }
    if let index = arguments.firstIndex(of: "--context-threshold"), let threshold = Int(arguments[index + 1]) {
        PersonalLearner.contextThreshold = threshold
    }

    manager.activate()
    var results: [ConversionResultRow] = []
    var seen: Set<String> = []
    let started = Date()
    for (i, row) in rows.enumerated() {
        guard let readingKatakana = row.reading, let gold = row.surface else {
            continue
        }
        let reading = readingKatakana.toHiragana()
        context.left = row.context ?? row.left ?? ""
        personalization.scene = row.scene.flatMap(PersonalScene.init(key:))
        personalization.now = Date(timeIntervalSince1970: row.ts ?? 0)
        let t0 = Date()
        // 1 回目のスペース（第 1 候補）
        manager.insertAtCursorPosition(reading, inputStyle: .direct)
        manager.insertCompositionSeparator(inputStyle: .direct, skipUpdate: true)
        manager.updateForFirstCandidate()
        let top1 = manager.getCurrentMarkedText(inputState: .previewing).map(\.content).joined()
        let elapsed = Date().timeIntervalSince(t0) * 1000
        var inList: Int?
        if top1 == gold {
            // そのまま確定（Enter）
            _ = manager.commitMarkedText(inputState: .previewing)
        } else {
            // 2 回目のスペース（候補一覧）から、確定した表記を選ぶ
            manager.update(requestRichCandidates: true)
            if case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting),
               let index = candidates.firstIndex(where: { $0.text == gold }) {
                inList = index
                manager.requestSelectingRow(index)
                if let candidate = manager.selectedCandidate {
                    manager.prefixCandidateCommited(candidate, leftSideContext: context.left, kind: .selection)
                }
            } else {
                // 一覧になければ、文節を直して確定したとみなす（読みと表記の対を 1 つの候補として確定する）
                let candidate = Candidate(
                    text: gold, value: -10, composingCount: .surfaceCount(reading.count), lastMid: MIDData.一般.mid,
                    data: [DicdataElement(word: gold, ruby: readingKatakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)]
                )
                manager.prefixCandidateCommited(candidate, leftSideContext: context.left, kind: .transform)
            }
        }
        manager.stopComposition()
        let key = (row.doc ?? "") + "\u{1F}" + gold
        results.append(ConversionResultRow(
            doc: row.doc ?? "", reading: reading, gold: gold, top1: top1, correct: top1 == gold, inList: inList,
            repeated: seen.contains(key), milliseconds: elapsed
        ))
        seen.insert(key)
        if (i + 1) % 200 == 0 {
            let correct = results.filter(\.correct).count
            FileHandle.standardError.write("\(i + 1)/\(rows.count) top1=\(correct) (\(String(format: "%.1f", Double(correct) / Double(results.count) * 100))%) \(Int(Date().timeIntervalSince(started)))s\n".data(using: .utf8)!)
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: URL(fileURLWithPath: output))
    let correct = results.filter(\.correct).count
    let repeated = results.filter(\.repeated)
    let first = results.filter { !$0.repeated }
    print(String(
        format: "conversion %@: top1 %d/%d (%.2f%%)  first occurrence %d/%d  repeated %d/%d  median %.1fms",
        personalOn ? "on" : "off", correct, results.count, Double(correct) / Double(max(1, results.count)) * 100,
        first.filter(\.correct).count, first.count, repeated.filter(\.correct).count, repeated.count,
        results.map(\.milliseconds).sorted()[results.count / 2]
    ))

}

struct CompletionTiming: Encodable {
    var ms: Double
    var cold: Bool
}

struct CompletionResultRow: Encodable {
    var doc: String
    var context: String
    var gold: String
    var suggestion: String?
    var correct: Bool
    var ms: Double
    /// 同じ入力で 1 文字打ち進めたときの予測の時間（手本は同じ＝計算を使い回す）
    var nextMs: Double?
    /// 手本が前の予測と変わったか（変わると手本から計算し直す）
    var prefixChanged: Bool
    /// --all-positions のときの、句のすべての位置での予測の時間
    var timings: [CompletionTiming]?
    var prefixTokens: Int
    var prefix: String
}

/// 手本選びに足す意味の近さ（--embedder など）。同じ文のベクトルは使い回す。時間も測る
final class EvalEmbeddings {
    let embedder: PersonalEmbedder
    private var documents: [String: [Float]] = [:]
    var documentMs: [Double] = []
    var queryMs: [Double] = []

    init?(arguments: [String]) throws {
        guard let model = arguments.firstIndex(of: "--embedder").map({ arguments[$0 + 1] }),
              let tokenizer = arguments.firstIndex(of: "--tokenizer").map({ arguments[$0 + 1] }) else {
            return nil
        }
        let length = arguments.firstIndex(of: "--length").flatMap { Int(arguments[$0 + 1]) } ?? 64
        let prefix = arguments.contains("--embed-prefix")
        self.embedder = try PersonalEmbedder(
            modelURL: URL(fileURLWithPath: model), tokenizerURL: URL(fileURLWithPath: tokenizer), length: length,
            queryPrefix: prefix ? "検索クエリ: " : "", documentPrefix: prefix ? "検索文書: " : ""
        )
        PersonalCorpus.semanticWeight = arguments.firstIndex(of: "--semantic-weight").flatMap { Double(arguments[$0 + 1]) } ?? 1
        _ = self.embedder.embed("こんにちは", asQuery: true)
    }

    func document(_ text: String) -> [Float]? {
        if let cached = self.documents[text] {
            return cached
        }
        let t0 = Date()
        let vector = self.embedder.embed(text, asQuery: false)
        self.documentMs.append(Date().timeIntervalSince(t0) * 1000)
        self.documents[text] = vector
        return vector
    }

    func query(_ text: String) -> [Float]? {
        let t0 = Date()
        let vector = self.embedder.embed(text, asQuery: true)
        self.queryMs.append(Date().timeIntervalSince(t0) * 1000)
        return vector
    }

    var label: String {
        String(format: " +意味 w=%.2f%@", PersonalCorpus.semanticWeight, self.embedder.queryPrefix.isEmpty ? "" : "（接頭辞あり）")
    }

    func report() {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        print(String(format: "埋め込み: 文書 %d 文 中央値 %.2fms・問い %d 回 中央値 %.2fms", self.documentMs.count, median(self.documentMs),
                     self.queryMs.count, median(self.queryMs)))
    }
}

@MainActor
func runCompletion(arguments: [String]) throws {
    guard arguments.count >= 4 else {
        print("usage: personaleval completion <log.jsonl> <model_dir> <none|recent|retrieve|card> <out.json> [--context full|line] [--limit N]")
        return
    }
    var rows = try loadLog(arguments[0]).filter { $0.surface != nil }
    if let index = arguments.firstIndex(of: "--docs") {
        let docs = Set(arguments[index + 1].split(separator: ",").map(String.init))
        rows = rows.filter { docs.contains($0.doc ?? "") }
    }
    if let index = arguments.firstIndex(of: "--limit"), let limit = Int(arguments[index + 1]) {
        rows = Array(rows.prefix(limit))
    }
    guard #available(macOS 15.0, *) else {
        return
    }
    let style = PersonalCorpus.PrefixStyle(rawValue: arguments[2]) ?? .none
    let lineOnly = arguments.firstIndex(of: "--context").map { arguments[$0 + 1] == "line" } ?? false
    let model = try Gemma4ANEModel(directoryURL: URL(fileURLWithPath: arguments[1], isDirectory: true))
    let completer = Gemma4Completer(model: model)
    completer.options.minLogProb = NextTextCompletionEngine.defaultMinLogProb
    _ = try completer.complete(context: "こんにちは")
    let corpus = PersonalCorpus()
    let semantic = try EvalEmbeddings(arguments: arguments)
    var searchMs: [Double] = []
    var results: [CompletionResultRow] = []
    var lastPrefix = ""
    let sticky = arguments.contains("--sticky")
    let keepTop1 = arguments.contains("--keep-top1")
    let allPositions = arguments.contains("--all-positions")
    var stickyPrefix: String?
    var stickyScene = ""
    var previousEndedSentence = true
    let started = Date()
    for (i, row) in rows.enumerated() {
        guard let surface = row.surface, let scene = row.scene.flatMap(PersonalScene.init(key:)) else {
            continue
        }
        defer {
            if row.isMaterial { corpus.add(scene: scene, text: surface, ts: row.ts ?? 0) }
            if let semantic {
                corpus.embedMissing(semantic.document)
            }
        }
        let characters = Array(surface)
        guard characters.count >= 3 else {
            continue
        }
        // 句の途中（2 文字目〜最後の 1 文字前）まで打った時点。番号から決めて、毎回同じ位置にする
        let cut = 2 + (i * 7919) % (characters.count - 2)
        var left = row.context ?? row.left ?? ""
        if lineOnly, let newline = left.lastIndex(of: "\n") {
            left = String(left[left.index(after: newline)...])
        }
        let context = left + String(characters[..<cut])
        let gold = String(characters[cut...]) + (row.next ?? "")
        let prefix: String
        if sticky, let kept = stickyPrefix, stickyScene == scene.key, !previousEndedSentence {
            prefix = kept
        } else if keepTop1, let kept = stickyPrefix, stickyScene == scene.key,
                  let top = corpus.retrieve(query: String(context.suffix(40)), scene: scene, excluding: context, limit: 1).first,
                  kept.contains(top.text), !context.suffix(400).contains(top.text) {
            // 新しい 1 位の文が今の手本に入っていれば、手本を変えない
            prefix = kept
        } else {
            // 意味の問い: 既定は入力を始める前の左文脈の末尾（IME では確定の後に裏で作っておき、キーの処理の流れでは作らない）。
            // --semantic-query context: BM25 と同じ問い（入力中の句の前半を含む）
            let semanticQuery = arguments.firstIndex(of: "--semantic-query").map { arguments[$0 + 1] } == "context"
                ? String(context.suffix(40)) : String(left.suffix(40))
            let queryVector = semanticQuery.isEmpty ? nil : semantic?.query(semanticQuery)
            let t0 = Date()
            prefix = corpus.completionPrefix(style: style, scene: scene, query: String(context.suffix(40)), context: context, queryVector: queryVector)
            searchMs.append(Date().timeIntervalSince(t0) * 1000)
            stickyPrefix = prefix
            stickyScene = scene.key
        }
        previousEndedSentence = surface.last.map { "。！？!?\n".contains($0) } ?? false
        var timings: [CompletionTiming]?
        if allPositions {
            // 入力の始めから 1 文字ずつ予測する（最初の予測で手本が変わっていれば、そこで計算し直す）
            timings = []
            for position in 1..<characters.count where position != cut {
                let t1 = Date()
                _ = try completer.complete(context: left + String(characters[..<position]), prefix: prefix)
                timings!.append(CompletionTiming(ms: Date().timeIntervalSince(t1) * 1000, cold: position == 1 && prefix != lastPrefix))
            }
        }
        let t0 = Date()
        let suggestion = try completer.complete(context: context, prefix: prefix)
        let ms = Date().timeIntervalSince(t0) * 1000
        // 1 文字打ち進めた予測（入力中の次の打鍵。手本は入力の間は変えない）
        var nextMs: Double?
        if cut + 1 < characters.count {
            let t1 = Date()
            _ = try completer.complete(context: left + String(characters[..<(cut + 1)]), prefix: prefix)
            nextMs = Date().timeIntervalSince(t1) * 1000
        }
        let prefixChanged = prefix != lastPrefix
        lastPrefix = prefix
        let correct = suggestion.map { gold.precomposedStringWithCompatibilityMapping.hasPrefix($0.text.precomposedStringWithCompatibilityMapping) } ?? false
        results.append(CompletionResultRow(
            doc: row.doc ?? "", context: String(context.suffix(60)), gold: String(gold.prefix(30)), suggestion: suggestion?.text,
            correct: correct, ms: ms, nextMs: nextMs, prefixChanged: prefixChanged, timings: timings,
            prefixTokens: completer.prefixTokenCount(prefix), prefix: prefix
        ))
        if (i + 1) % 200 == 0 {
            let shown = results.filter { $0.suggestion != nil }.count
            let ok = results.filter(\.correct).count
            FileHandle.standardError.write("\(i + 1)/\(rows.count) shown=\(shown) ok=\(ok) \(Int(Date().timeIntervalSince(started)))s\n".data(using: .utf8)!)
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: URL(fileURLWithPath: arguments[3]))
    let shown = results.filter { $0.suggestion != nil }
    let ok = results.filter(\.correct)
    let saved = ok.reduce(0) { $0 + ($1.suggestion?.count ?? 0) }
    let ms = results.map(\.ms).sorted()
    let prefixTokens = results.map(\.prefixTokens).filter { $0 > 0 }.sorted()
    print(String(
        format: "completion %@%@%@: 出現率 %.1f%%  精度 %.1f%%  節約文字/問 %.3f  (n=%d)  時間 中央値 %.0fms p90 %.0fms  手本 %d トークン（中央値、手本あり %d 問）",
        style.rawValue, lineOnly ? "/line" : "", semantic?.label ?? "", Double(shown.count) / Double(max(1, results.count)) * 100,
        Double(ok.count) / Double(max(1, shown.count)) * 100, Double(saved) / Double(max(1, results.count)), results.count,
        ms[ms.count / 2], ms[ms.count * 9 / 10], prefixTokens.isEmpty ? 0 : prefixTokens[prefixTokens.count / 2], prefixTokens.count
    ))
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
    if let semantic {
        semantic.report()
        let sortedSearch = searchMs.sorted()
        print(String(format: "手本選び（問いの埋め込みを除く）: 中央値 %.2fms・p99 %.2fms・最大 %.2fms（%d 回、文 %d）", median(searchMs),
                     sortedSearch.isEmpty ? 0 : sortedSearch[sortedSearch.count * 99 / 100], sortedSearch.last ?? 0, searchMs.count, corpus.sentences.count))
    }
    if allPositions {
        var all: [CompletionTiming] = []
        for row in results {
            all += row.timings ?? []
            all.append(CompletionTiming(ms: row.ms, cold: false))
        }
        let cold = all.filter(\.cold).count
        print(String(
            format: "  すべての位置: 予測 %d 回、手本の計算し直し %d 回（%.1f%%）、平均 %.1fms、中央値 %.1fms",
            all.count, cold, Double(cold) / Double(max(1, all.count)) * 100,
            all.map(\.ms).reduce(0, +) / Double(max(1, all.count)), median(all.map(\.ms))
        ))
    }
    print(String(
        format: "  時間: 入力の最初の予測 %.0fms（手本が変わった %d 問 %.0fms／同じ %d 問 %.0fms）、次の打鍵 %.0fms",
        median(results.map(\.ms)),
        results.filter(\.prefixChanged).count, median(results.filter(\.prefixChanged).map(\.ms)),
        results.filter { !$0.prefixChanged }.count, median(results.filter { !$0.prefixChanged }.map(\.ms)),
        median(results.compactMap(\.nextMs))
    ))
}

struct TypoItem: Decodable {
    var intended_reading: String
    var left_context: String?
    var typed: String
    var clean: String
    var error: String
}

struct TypoResultRow: Encodable {
    var typed: String
    var intended: String
    var error: String
    var habit: Bool
    var pass: Int
    var suggestion: String?
    var correct: Bool
}

/// 打鍵ミス訂正の評価での個人化（打ち間違いの癖と、訂正先ごとのしきい値だけ）
final class EvalTypoPersonalization: SegmentsManagerPersonalization {
    let learner = PersonalLearner(storeURL: nil)

    func personalPreferredSurface(forReading reading: String, leftContext: String) -> PersonalLearner.Entry? {
        nil
    }

    func segmentsManagerDidCommit(_ event: SegmentsManager.CommitEvent) {}

    func personalTypoMarginAdjustment(forTarget reading: String) -> Float {
        self.learner.typoMarginAdjustment(forTarget: reading)
    }
}

/// ローマ字の句読点・長音を日本語入力と同じ文字にする
func romanWithJapanesePunctuation(_ text: String) -> String {
    String(text.map { c -> Character in
        switch c {
        case ",": "、"
        case ".": "。"
        case "-": "ー"
        default: c
        }
    })
}

/// 読みの比較用（ひらがな・NFKC・句読点と長音をそろえる）
func normalizedReading(_ text: String) -> String {
    romanWithJapanesePunctuation(text.precomposedStringWithCompatibilityMapping.toHiragana())
}

/// 隣接キー置換の問題で、押した文字＋本来の文字の組
func substitutionPair(typed: String, clean: String) -> String? {
    let a = Array(typed)
    let b = Array(clean)
    guard a.count == b.count else {
        return nil
    }
    let diffs = zip(a, b).filter { $0 != $1 }
    guard diffs.count == 1, let diff = diffs.first else {
        return nil
    }
    return String([diff.0, diff.1])
}

@MainActor
func runTypo(arguments: [String]) throws {
    guard arguments.count >= 4 else {
        print("usage: personaleval typo <typo_eval.json> <resources_dir> <off|on> <out.json> [--habits N] [--history K] [--repeat]")
        return
    }
    let items = try JSONDecoder().decode([TypoItem].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
    let resources = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let personalOn = arguments[2] == "on"
    let habitCount = arguments.firstIndex(of: "--habits").flatMap { Int(arguments[$0 + 1]) } ?? 3
    let history = arguments.firstIndex(of: "--history").flatMap { Int(arguments[$0 + 1]) } ?? 5
    let repeatItems = arguments.contains("--repeat")
    // 本人の癖: 隣接キー置換で多い組
    var pairCounts: [String: Int] = [:]
    for item in items where item.error == "隣接キー置換" {
        if let pair = substitutionPair(typed: item.typed, clean: item.clean) {
            pairCounts[pair, default: 0] += 1
        }
    }
    let habits = Set(pairCounts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(habitCount).map(\.key))
    print("habits: \(habits.sorted().map { "\($0.first!)←\($0.last!)" }.joined(separator: " "))  (history \(history) each)")
    let memory = FileManager.default.temporaryDirectory.appendingPathComponent("personaleval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: memory)
    }
    let converter = KanaKanjiConverter.withDefaultDictionary()
    let manager = SegmentsManager(
        kanaKanjiConverter: converter, applicationDirectoryURL: memory, containerURL: nil,
        context: .init(useZenzai: true, resourcesDirectoryURL: resources)
    )
    let context = EvalContext()
    manager.delegate = context
    let personalization = EvalTypoPersonalization()
    if personalOn {
        manager.personalization = personalization
        for pair in habits {
            for _ in 0..<history {
                personalization.learner.recordTypoPair(typed: String(pair.first!), fixed: String(pair.last!), reading: nil, scene: nil)
            }
        }
    }
    manager.activate()
    var results: [TypoResultRow] = []
    let started = Date()
    for (i, item) in items.enumerated() {
        let intended = item.intended_reading.toHiragana()
        let habit = substitutionPair(typed: item.typed, clean: item.clean).map(habits.contains) ?? false
        for pass in 0..<(repeatItems ? 2 : 1) {
            context.left = item.left_context ?? ""
            // 最後の 1 打の前までをまとめて入れ、最後の 1 打で判定する（IME は打鍵ごとに判定する）。
            // 句読点・長音はキーの割り当て（, → 、 など）を通らないので、先に置き換えておく
            let typed = Array(romanWithJapanesePunctuation(item.typed))
            manager.insertAtCursorPosition(String(typed.dropLast()), inputStyle: .roman2kana)
            manager.insertAtCursorPosition(pieces: [.character(typed.last!)], inputStyle: .roman2kana)
            let candidate = manager.requestTypoCorrectionPredictionCandidates().first
            let target = candidate.map { String(manager.convertTarget.dropLast($0.deleteCount)) + $0.appendText }
            manager.stopComposition()
            results.append(TypoResultRow(
                typed: item.typed, intended: intended, error: item.error, habit: habit, pass: pass,
                suggestion: target, correct: target.map(normalizedReading) == normalizedReading(intended)
            ))
            // 1 回目に出た訂正: 正しければ使い、誤りなし・違う訂正なら使わない
            if personalOn, repeatItems, pass == 0, let target {
                personalization.learner.recordTypoOutcome(target: target.toKatakana(), accepted: target == intended && item.error != "なし")
            }
        }
        if (i + 1) % 500 == 0 {
            FileHandle.standardError.write("\(i + 1)/\(items.count) \(Int(Date().timeIntervalSince(started)))s\n".data(using: .utf8)!)
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: URL(fileURLWithPath: arguments[3]))
    func report(_ label: String, _ rows: [TypoResultRow]) {
        let typos = rows.filter { $0.error != "なし" && $0.typed.lowercased() != $0.intended }
        let clean = rows.filter { $0.error == "なし" }
        let corrected = typos.filter(\.correct).count
        let wrong = typos.filter { $0.suggestion != nil && !$0.correct }.count
        let alarms = clean.filter { $0.suggestion != nil }.count
        print(String(
            format: "%@: 訂正率 %.1f%% (%d/%d)  違う訂正 %.1f%%  誤警報 %.2f%% (%d/%d)",
            label, Double(corrected) / Double(max(1, typos.count)) * 100, corrected, typos.count,
            Double(wrong) / Double(max(1, typos.count)) * 100, Double(alarms) / Double(max(1, clean.count)) * 100, alarms, clean.count
        ))
    }
    let mode = personalOn ? "on" : "off"
    for pass in 0..<(repeatItems ? 2 : 1) {
        let rows = results.filter { $0.pass == pass }
        report("typo \(mode) pass\(pass) all", rows)
        report("typo \(mode) pass\(pass) habit", rows.filter { $0.habit || $0.error == "なし" })
    }
}

/// 文字 2-gram の F1
func bigramF1(_ a: String, _ b: String) -> Double {
    func grams(_ s: String) -> [String: Int] {
        let c = Array(s.filter { !$0.isWhitespace })
        var result: [String: Int] = [:]
        if c.count < 2 {
            for ch in c {
                result[String(ch), default: 0] += 1
            }
            return result
        }
        for i in 0..<(c.count - 1) {
            result[String(c[i...(i + 1)]), default: 0] += 1
        }
        return result
    }
    let ga = grams(a), gb = grams(b)
    let overlap = ga.reduce(0) { $0 + min($1.value, gb[$1.key] ?? 0) }
    let na = ga.values.reduce(0, +), nb = gb.values.reduce(0, +)
    guard overlap > 0, na > 0, nb > 0 else {
        return 0
    }
    let p = Double(overlap) / Double(na), r = Double(overlap) / Double(nb)
    return 2 * p * r / (p + r)
}

/// 漢字・カタカナを含む語の読み（ひらがな）を空白でつなぐ（キーワードだけを打つ使い方の再現）
func keywordReading(surface: String) -> String? {
    let cf = surface as CFString
    let tokenizer = CFStringTokenizerCreate(
        nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale
    )
    let ns = surface as NSString
    var words: [String] = []
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
        let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        let word = ns.substring(with: NSRange(location: range.location, length: range.length))
        let isContent = word.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x30A0...0x30FF).contains($0.value) }
        guard isContent,
              let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
              let kana = latin.applyingTransform(.latinToHiragana, reverse: false) else {
            continue
        }
        words.append(kana)
    }
    return words.count >= 2 ? words.joined(separator: " ") : nil
}

struct MagicResultRow: Codable {
    var doc: String
    var input: String
    var gold: String
    var examples: [String]
    var withoutExamples: [String]
    var withExamples: [String]
    var f1Top: [Double]
    var f1Best: [Double]
    /// 最初の文字までの時間・全体の時間（秒）と、指示のトークン数（手本なし／あり）
    var firstChunk: [Double]
    var total: [Double]
    var promptTokens: [Int]
    /// 意味の近さを足した手本とその答え（--embedder のとき。指標の 3 つ目）
    var semanticExamples: [String]?
    var withSemanticExamples: [String]?
    var sourceIndex: Int?
    var stylePreferences: [Int: Int]?
    var normalized: [[String]]?
    var normalizedF1: [Double]?
    var symbolsBefore: [Bool]?
    var symbolsAfter: [Bool]?
    var honorificUsage: [Int: Int]?
    var unusedHonorificBefore: [Bool]?
    var unusedHonorificAfter: [Bool]?
}

@MainActor
func runMagic(arguments: [String]) async throws {
    guard arguments.count >= 5 else {
        print("usage: personaleval magic <log.jsonl> <resources_dir> <llm_model_dir> <reading|keywords> <out.json> [--limit N] [--min-length L]")
        return
    }
    let rows = try loadLog(arguments[0]).filter { $0.surface != nil && $0.reading != nil }
    let resources = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let modelDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let keywords = arguments[3] == "keywords"
    let limit = arguments.firstIndex(of: "--limit").flatMap { Int(arguments[$0 + 1]) } ?? 60
    let minLength = arguments.firstIndex(of: "--min-length").flatMap { Int(arguments[$0 + 1]) } ?? 12
    // 文書ごとの後半から、長さの条件を満たす句を順に選ぶ（文書の間でなるべく均等に）
    let byDoc = Dictionary(grouping: rows.indices) { rows[$0].doc ?? "" }
    var targets: [Int] = []
    let docs = byDoc.keys.sorted()
    var cursors = Dictionary(uniqueKeysWithValues: docs.map { ($0, byDoc[$0]!.count / 2) })
    while targets.count < limit {
        var added = false
        for doc in docs where targets.count < limit {
            let indices = byDoc[doc]!
            while let cursor = cursors[doc], cursor < indices.count {
                cursors[doc] = cursor + 1
                let row = rows[indices[cursor]]
                if (row.surface ?? "").count >= minLength, !keywords || keywordReading(surface: row.surface ?? "") != nil {
                    targets.append(indices[cursor])
                    added = true
                    break
                }
            }
        }
        if !added {
            break
        }
    }
    let memory = FileManager.default.temporaryDirectory.appendingPathComponent("personaleval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: memory)
    }
    let manager = SegmentsManager(
        kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(), applicationDirectoryURL: memory, containerURL: nil,
        context: .init(useZenzai: true, resourcesDirectoryURL: resources)
    )
    let context = EvalContext()
    manager.delegate = context
    manager.activate()
    // 指示のトークン数を数える（Gemma 4 は tokenizer.bin。ほかのモデルなら数えない）
    let tokenizer = try? Gemma4Tokenizer(url: modelDirectory.appendingPathComponent("tokenizer.bin"))
    // 1 回目は読み込み・GPU の準備を含むので、時間を測る前に 1 回答えさせておく
    _ = try? await LocalLLMEngine.shared.respond(system: nil, user: "こんにちは", modelDirectory: modelDirectory, maxTokens: 4)
    // 意味の近さを足すとき: 手本なし／BM25 の手本／意味の近さを足した手本 の 3 通り（ないとき: 手本なし／あり）
    let semantic = try EvalEmbeddings(arguments: arguments)
    var results: [MagicResultRow] = []
    for index in targets {
        let row = rows[index]
        guard let scene = row.scene.flatMap(PersonalScene.init(key:)), let gold = row.surface else {
            continue
        }
        // 同じ文書のこの句より前の確定だけを本人の過去の文にする
        let corpus = PersonalCorpus()
        var style = PersonalStyleProfile()
        for previous in byDoc[row.doc ?? ""]! where previous < index {
            if rows[previous].isMaterial, let text = rows[previous].surface, let s = rows[previous].scene.flatMap(PersonalScene.init(key:)) {
                corpus.add(scene: s, text: text, ts: rows[previous].ts ?? 0)
                if PersonalOrigin.normalKinds.contains(rows[previous].kind ?? "selection") { style.observe(scene: s, text: text) }
            }
        }
        let left = String((row.context ?? row.left ?? "").suffix(100))
        let input = keywords ? (keywordReading(surface: gold) ?? "") : (row.reading ?? "").toHiragana()
        // IME と同じく、入力の第 1 候補と左文脈の末尾で手本を探す
        context.left = left
        manager.insertAtCursorPosition(input, inputStyle: .direct)
        let converted = manager.refineFirstCandidate()?.text ?? input
        manager.stopComposition()
        let examples = corpus.styleExamples(query: String(left.suffix(20)) + converted, scene: scene, excluding: left)
        var variants = [[String](), examples]
        if let semantic {
            corpus.embedMissing(semantic.document)
            let queryVector = semantic.query(String(left.suffix(20)) + converted)
            variants.append(corpus.styleExamples(query: String(left.suffix(20)) + converted, scene: scene, excluding: left, queryVector: queryVector))
        }
        var outputs: [[String]] = []
        var firstChunk: [Double] = []
        var total: [Double] = []
        var promptTokens: [Int] = []
        for (variant, shown) in variants.enumerated() {
            if variant == 2, shown == examples {
                // 手本が BM25 だけのときと同じなら、答えも同じとみなす（LLM の揺れを比べに入れない）
                outputs.append(outputs[1])
                firstChunk.append(firstChunk[1])
                total.append(total[1])
                promptTokens.append(promptTokens[1])
                continue
            }
            let prompt = LocalLLMPrompts.suggestionUserPrompt(leftContext: left, target: input, style: "", examples: shown)
            let output = try await LocalLLMEngine.shared.respondTimed(
                system: LocalLLMPrompts.suggestionSystem, user: prompt, modelDirectory: modelDirectory, maxTokens: 200
            )
            outputs.append(LocalLLMPrompts.parseSuggestions(output.text))
            firstChunk.append(output.firstChunk)
            total.append(output.total)
            promptTokens.append(tokenizer?.encode(prompt).count ?? 0)
        }
        let compareStyle = arguments.contains("--voice-style")
        let plans = compareStyle ? style.plans() : [:]
        let plan = PersonalStyleProfile.levels(scene).compactMap { plans[$0] }.first
        let normalized = compareStyle ? outputs.map { $0.map { PersonalGeneratedText.apply($0, route: .magic, enabled: true, plan: plan) } } : nil
        func symbols(_ text: String) -> String { String(text.unicodeScalars.filter { CharacterSet.punctuationCharacters.union(.symbols).contains($0) }) }
        let f1Top = outputs.map { $0.first.map { bigramF1($0, gold) } ?? 0 }
        let f1Best = outputs.map { $0.map { bigramF1($0, gold) }.max() ?? 0 }
        results.append(MagicResultRow(
            doc: row.doc ?? "", input: input, gold: gold, examples: examples, withoutExamples: outputs[0], withExamples: outputs[1],
            f1Top: f1Top, f1Best: f1Best, firstChunk: firstChunk, total: total, promptTokens: promptTokens,
            semanticExamples: variants.count > 2 ? variants[2] : nil, withSemanticExamples: outputs.count > 2 ? outputs[2] : nil,
            sourceIndex: compareStyle ? index : nil, stylePreferences: compareStyle ? plan?.preferences : nil, normalized: normalized,
            normalizedF1: normalized.map { $0.map { $0.first.map { bigramF1($0, gold) } ?? 0 } },
            symbolsBefore: compareStyle ? outputs.map { symbols($0.first ?? "") == symbols(gold) } : nil,
            symbolsAfter: normalized.map { $0.map { symbols($0.first ?? "") == symbols(gold) } },
            honorificUsage: compareStyle ? plan?.honorificUsage : nil,
            unusedHonorificBefore: compareStyle ? outputs.map { PersonalHonorific.containsUnused($0.first ?? "", usage: plan?.honorificUsage ?? [:]) } : nil,
            unusedHonorificAfter: normalized.map { $0.map { PersonalHonorific.containsUnused($0.first ?? "", usage: plan?.honorificUsage ?? [:]) } }
        ))
        if compareStyle { FileHandle.standardError.write(Data("voice-style \(results.count)/\(targets.count)\n".utf8)) }
        else { FileHandle.standardError.write("\(results.count)/\(targets.count) \(gold) | \(outputs[0].first ?? "-") | \(outputs[1].first ?? "-")\n".data(using: .utf8)!) }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: URL(fileURLWithPath: arguments[4]))
    func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
    let labels = semantic == nil ? [("手本なし", 0), ("手本あり", 1)] : [("手本なし", 0), ("BM25 の手本", 1), ("意味を足した手本" + semantic!.label, 2)]
    for (label, i) in labels {
        let exact = results.filter { r in [r.withoutExamples, r.withExamples, r.withSemanticExamples ?? []][i].contains(r.gold) }.count
        print(String(
            format: "magic %@ %@: 2-gram F1 第 1 候補 %.3f・候補の最大 %.3f  本人の句と一致 %d/%d  最初の文字 %.2fs・全体 %.2fs（中央値）・指示 %d トークン",
            keywords ? "keywords" : "reading", label, mean(results.map { $0.f1Top[i] }), mean(results.map { $0.f1Best[i] }), exact, results.count,
            median(results.map { $0.firstChunk[i] }), median(results.map { $0.total[i] }),
            Int(median(results.map { Double($0.promptTokens[i]) }))
        ))
    }
}

/// 文の埋め込み 1 文の時間と、ベクトルからの検索の時間（段階 B の比べ）
func runEmbedBench(arguments: [String]) throws {
    guard arguments.count >= 4, let length = Int(arguments[3]) else {
        print("usage: personaleval embedbench <log.jsonl> <mlpackage> <tokenizer.json> <length> [--count N]")
        return
    }
    let count = arguments.firstIndex(of: "--count").flatMap { Int(arguments[$0 + 1]) } ?? 500
    let texts = Array(try loadLog(arguments[0]).compactMap(\.surface).filter { $0.count >= 2 }.prefix(count))
    func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
    func p90(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count * 9 / 10]
    }
    for (label, units) in [("CPU+ANE", MLComputeUnits.cpuAndNeuralEngine), ("CPU", .cpuOnly), ("すべて", .all)] {
        let t0 = Date()
        let embedder = try PersonalEmbedder(
            modelURL: URL(fileURLWithPath: arguments[1]), tokenizerURL: URL(fileURLWithPath: arguments[2]), length: length, computeUnits: units
        )
        let loadMs = Date().timeIntervalSince(t0) * 1000
        for text in texts.prefix(10) {
            _ = embedder.embed(text, asQuery: false)
        }
        var tokenizeMs: [Double] = []
        var embedMs: [Double] = []
        var vectors: [[Float]] = []
        for text in texts {
            let t1 = Date()
            _ = embedder.tokenizer.encode(text, length: length)
            tokenizeMs.append(Date().timeIntervalSince(t1) * 1000)
            let t2 = Date()
            if let vector = embedder.embed(text, asQuery: false) {
                vectors.append(vector)
            }
            embedMs.append(Date().timeIntervalSince(t2) * 1000)
        }
        print(String(format: "%@ 長さ %d %@: 読み込み %.0fms  1 文 中央値 %.2fms・p90 %.2fms（うち字句分け 中央値 %.3fms）  %d 次元",
                     URL(fileURLWithPath: arguments[1]).lastPathComponent, length, label, loadMs, median(embedMs), p90(embedMs),
                     median(tokenizeMs), vectors.first?.count ?? 0))
    }
    // 検索: 2 万文（記録の上限）のベクトルから内積で並べる時間（ベクトルは上の文を繰り返して埋める）
    let embedder = try PersonalEmbedder(modelURL: URL(fileURLWithPath: arguments[1]), tokenizerURL: URL(fileURLWithPath: arguments[2]), length: length)
    let corpus = PersonalCorpus()
    let scene = PersonalScene(key: "eval|line|new|")!
    var vectorsByText: [String: [Float]] = [:]
    for text in texts {
        vectorsByText[text] = embedder.embed(text, asQuery: false)
    }
    var serial = 0
    while corpus.sentences.count < PersonalCorpus.maxSentences {
        let text = texts[serial % texts.count]
        corpus.add(scene: scene, text: text + "\(serial)。", ts: Double(serial))
        serial += 1
    }
    for (id, text) in corpus.sentencesWithoutVectors(limit: Int.max) {
        let base = vectorsByText.keys.first { text.hasPrefix($0) }
        if let base, let vector = vectorsByText[base] {
            corpus.setVector(vector, id: id, text: text)
        }
    }
    PersonalCorpus.semanticWeight = 1
    var searchMs: [Double] = []
    for text in texts.prefix(200) {
        let query = embedder.embed(text, asQuery: true)
        let t0 = Date()
        _ = corpus.retrieve(query: text, scene: scene, excluding: "", queryVector: query)
        searchMs.append(Date().timeIntervalSince(t0) * 1000)
    }
    PersonalCorpus.semanticWeight = 0
    var bm25Ms: [Double] = []
    for text in texts.prefix(200) {
        let t0 = Date()
        _ = corpus.retrieve(query: text, scene: scene, excluding: "")
        bm25Ms.append(Date().timeIntervalSince(t0) * 1000)
    }
    print(String(format: "検索（%d 文）: BM25 だけ 中央値 %.2fms・p90 %.2fms／意味を足す 中央値 %.2fms・p90 %.2fms（問いの埋め込みを除く）",
                 corpus.sentences.count, median(bm25Ms), p90(bm25Ms), median(searchMs), p90(searchMs)))
}

/// 手本選びの時間の内訳（合成ログの文脈で）: BM25 だけ／意味の近さを足す／意味の並べ替えだけ
func runSearchBench(arguments: [String]) throws {
    guard arguments.count >= 3 else {
        print("usage: personaleval searchbench <log.jsonl> <mlpackage> <tokenizer.json> [--length 64]")
        return
    }
    let rows = try loadLog(arguments[0]).filter { $0.surface != nil }
    let embedder = try PersonalEmbedder(
        modelURL: URL(fileURLWithPath: arguments[1]), tokenizerURL: URL(fileURLWithPath: arguments[2]),
        length: arguments.firstIndex(of: "--length").flatMap { Int(arguments[$0 + 1]) } ?? 64
    )
    let corpus = PersonalCorpus()
    var queries: [(scene: PersonalScene, query: String, context: String, vector: [Float]?)] = []
    for (i, row) in rows.enumerated() {
        guard let surface = row.surface, let scene = row.scene.flatMap(PersonalScene.init(key:)) else {
            continue
        }
        let left = row.context ?? row.left ?? ""
        let characters = Array(surface)
        if characters.count >= 3, i % 4 == 0 {
            let context = left + String(characters[..<2])
            queries.append((scene, String(context.suffix(40)), context, embedder.embed(String(left.suffix(40)), asQuery: true)))
        }
        if row.isMaterial { corpus.add(scene: scene, text: surface, ts: row.ts ?? 0) }
    }
    corpus.embedMissing { embedder.embed($0, asQuery: false) }
    func measure(_ label: String, _ body: (Int) -> Void) {
        var ms: [Double] = []
        for index in queries.indices {
            let t0 = Date()
            body(index)
            ms.append(Date().timeIntervalSince(t0) * 1000)
        }
        ms.sort()
        print(String(format: "%@: 中央値 %.2fms・p90 %.2fms・p99 %.2fms・最大 %.2fms（%d 回、文 %d）", label, ms[ms.count / 2], ms[ms.count * 9 / 10],
                     ms[ms.count * 99 / 100], ms.last ?? 0, ms.count, corpus.sentences.count))
    }
    PersonalCorpus.semanticWeight = 0
    measure("BM25 だけ（retrieve）") { i in _ = corpus.retrieve(query: queries[i].query, scene: queries[i].scene, excluding: queries[i].context) }
    measure("意味の並べ替えだけ（semanticRanking）") { i in _ = corpus.semanticRanking(queries[i].vector ?? [], depth: 200) }
    PersonalCorpus.semanticWeight = 1
    measure("意味を足す（retrieve）") { i in
        _ = corpus.retrieve(query: queries[i].query, scene: queries[i].scene, excluding: queries[i].context, queryVector: queries[i].vector)
    }
    measure("意味を足す（completionPrefix）") { i in
        _ = corpus.completionPrefix(style: .retrieve, scene: queries[i].scene, query: queries[i].query, context: queries[i].context, queryVector: queries[i].vector)
    }
    PersonalCorpus.semanticWeight = 0
}

@MainActor
func runTune(arguments: [String]) async throws {
    guard arguments.count >= 3 else {
        print("usage: personaleval tune <log.jsonl> <model_dir> <out.json>")
        return
    }
    let rows = try loadLog(arguments[0]).filter { $0.surface != nil }
    NextTextCompletionEngine.modelDirectoryOverride = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let engine = NextTextCompletionEngine.shared
    // 前半（記録）と後半（評価）に分ける（文書ごと）
    let byDoc = Dictionary(grouping: rows) { $0.doc ?? "" }
    var history: [(scene: String, ts: Double, surface: String)] = []
    var future: [(scene: String, ts: Double, surface: String)] = []
    // 文書の順は毎回同じにする（再生で切る位置が行の順で決まるため）
    for doc in byDoc.keys.sorted() {
        let docRows = byDoc[doc]!
        let half = docRows.count / 2
        for (i, row) in docRows.enumerated() {
            let item = (scene: row.scene ?? "", ts: row.ts ?? 0, surface: row.surface ?? "")
            if i < half {
                if row.isMaterial { history.append(item) }
            } else {
                future.append(item)
            }
        }
    }
    let corpus = PersonalCorpus()
    for item in history.sorted(by: { $0.ts < $1.ts }) {
        if let scene = PersonalScene(key: item.scene) {
            corpus.add(scene: scene, text: item.surface, ts: item.ts)
        }
    }
    func prefix(_ sample: PersonalLearner.ReplaySample) -> String {
        corpus.completionPrefix(style: .retrieve, scene: sample.scene, query: String(sample.context.suffix(40)), context: sample.context, before: sample.ts)
    }
    _ = await engine.complete(context: "こんにちは")
    // 1. 本番と同じ条件の再生（新しい方から 400 位置、30 秒まで）
    let samples = PersonalLearner.replaySamples(from: history, limit: 400)
    let replay = await engine.replay(samples.map { ($0.context, prefix($0)) }, budget: PersonalTuner.replayBudget)
    print(String(format: "replay: %d/%d positions in %.1fs (timedOut=%@, cancelled=%@)", replay.pieces.count, samples.count, replay.elapsed,
                 replay.timedOut ? "yes" : "no", replay.cancelled ? "yes" : "no"))
    let tuner = PersonalTuner()
    let outcomes = zip(samples, replay.pieces).map {
        PersonalTuner.ReplayOutcome(levels: PersonalTuner.levelKeys(for: $0.0.scene), pieces: $0.1, gold: $0.0.gold)
    }
    tuner.applyReplay(outcomes, baseline: { _ in nil }, now: 1e9)
    for (level, knobs) in tuner.settings.sorted(by: { $0.key < $1.key }) {
        if let value = knobs[.completionThreshold]?.value {
            print("  tuned \(level): \(value)")
        }
    }
    // 2. 後半で、調整した値と既定を比べる（同じ生成からしきい値ごとの候補を求める）
    let futureSamples = PersonalLearner.replaySamples(from: history + future, limit: 100_000).filter { sample in
        future.contains { $0.ts == sample.ts && $0.scene == sample.scene.key }
    }
    let futureReplay = await engine.replay(futureSamples.map { ($0.context, prefix($0)) }, budget: 10_000)
    var tuned = (shown: 0, correct: 0, saved: 0)
    var base = (shown: 0, correct: 0, saved: 0)
    for (sample, pieces) in zip(futureSamples, futureReplay.pieces) {
        let threshold = Float(tuner.value(.completionThreshold, scene: sample.scene) ?? PersonalTuner.bounds[.completionThreshold]!.defaultValue)
        for (t, isTuned) in [(threshold, true), (Float(-0.7), false)] {
            guard let text = NextTextCompletionEngine.suggestion(from: pieces, threshold: t) else {
                continue
            }
            let correct = sample.gold.precomposedStringWithCompatibilityMapping.hasPrefix(text.precomposedStringWithCompatibilityMapping)
            if isTuned {
                tuned.shown += 1
                tuned.correct += correct ? 1 : 0
                tuned.saved += correct ? text.count : 0
            } else {
                base.shown += 1
                base.correct += correct ? 1 : 0
                base.saved += correct ? text.count : 0
            }
        }
    }
    let n = Double(max(1, futureSamples.count))
    for (label, value) in [("既定 −0.7", base), ("自己調整", tuned)] {
        print(String(format: "後半 %@: 出現率 %.1f%%  精度 %.1f%%  節約文字/問 %.3f  (n=%d)", label, Double(value.shown) / n * 100,
                     Double(value.correct) / Double(max(1, value.shown)) * 100, Double(value.saved) / n, futureSamples.count))
    }
    // 3. キー入力での打ち切り: 再生を始めて 1〜3 秒後に打ち切り、戻るまでの時間を測る（5 回）
    var latencies: [Double] = []
    var cancelledCount = 0
    for round in 0..<5 {
        let items = samples.prefix(200).map { ($0.context, prefix($0)) }
        let delay = 1.0 + Double(round) * 0.5
        let task = Task { await engine.replay(Array(items), budget: PersonalTuner.replayBudget) }
        try await Task.sleep(for: .seconds(delay))
        let t0 = Date()
        engine.cancelBackground()
        let result = await task.value
        latencies.append(Date().timeIntervalSince(t0) * 1000)
        cancelledCount += result.cancelled ? 1 : 0
    }
    print(String(format: "cancel: %d/5 cancelled, time from key event to stop: median %.0fms max %.0fms", cancelledCount,
                 latencies.sorted()[2], latencies.max() ?? 0))
}

/// 同じ生成済み候補で項目を外して再計算する。文章は結果へ出さない。
func runStyleReplay(arguments: [String]) throws {
    guard arguments.count >= 2 else { throw LabError.invalidResult("style-replay: <magic.json> <out.json> [--exclude 0,1] [--only N]") }
    let rows = try JSONDecoder().decode([MagicResultRow].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
    let excluded = Set(arguments.firstIndex(of: "--exclude").map { arguments[$0 + 1].split(separator: ",").compactMap { Int($0) } } ?? [])
    let only = arguments.firstIndex(of: "--only").flatMap { Int(arguments[$0 + 1]) }
    let source = try arguments.firstIndex(of: "--source-log").map { try loadLog(arguments[$0 + 1]).filter { $0.surface != nil && $0.reading != nil } }
    if arguments.contains("--honorifics"), source == nil { throw LabError.invalidResult("--honorifics は --source-log が必要") }
    var items: [LabGate.Item] = []
    var output: [[String: Any]] = []
    func symbols(_ text: String) -> String { String(text.unicodeScalars.filter { CharacterSet.punctuationCharacters.union(.symbols).contains($0) }) }
    for row in rows {
        let choices = (row.stylePreferences ?? [:]).filter { !excluded.contains($0.key) && (only == nil || only == $0.key) }
        var usage = row.honorificUsage ?? [:]
        if arguments.contains("--honorifics"), let source, let index = row.sourceIndex {
            guard source.indices.contains(index), source[index].surface == row.gold,
                  let scene = source[index].scene.flatMap(PersonalScene.init(key:)) else { throw LabError.invalidResult("元の位置が一致しない") }
            var profile = PersonalStyleProfile()
            for previous in source.indices where previous < index && source[previous].doc == source[index].doc {
                if source[previous].isMaterial, PersonalOrigin.normalKinds.contains(source[previous].kind ?? "selection"),
                   let text = source[previous].surface, let pastScene = source[previous].scene.flatMap(PersonalScene.init(key:)) {
                    profile.observe(scene: pastScene, text: text)
                }
            }
            usage = profile.honorificUsage(levels: PersonalStyleProfile.levels(scene))
        }
        let plan = PersonalStylePlan(preferences: choices, honorificUsage: usage)
        var before: [Double] = [], after: [Double] = [], symbolsBefore: [Bool] = [], symbolsAfter: [Bool] = [], changed: [Bool] = []
        var unusedBefore: [Bool] = [], unusedAfter: [Bool] = []
        for candidates in [row.withoutExamples, row.withExamples] {
            let first = candidates.first ?? "", normalized = plan.apply(first)
            before.append(bigramF1(first, row.gold)); after.append(bigramF1(normalized, row.gold))
            symbolsBefore.append(symbols(first) == symbols(row.gold)); symbolsAfter.append(symbols(normalized) == symbols(row.gold))
            changed.append(first != normalized)
            unusedBefore.append(PersonalHonorific.containsUnused(first, usage: usage))
            unusedAfter.append(PersonalHonorific.containsUnused(normalized, usage: usage))
        }
        if let source, let index = row.sourceIndex {
            guard source.indices.contains(index), source[index].surface == row.gold else { throw LabError.invalidResult("style-replay: 元の位置が一致しない") }
            items.append(LabGate.Item(day: LabReplay.day(source[index].ts ?? 0), diffs: ["none": after[0] - before[0], "retrieve": after[1] - before[1]]))
        }
        output.append(["docHash": LabUpperBound.hash(row.doc), "goldHash": LabUpperBound.hash(row.gold), "sourceIndex": row.sourceIndex ?? -1,
                       "before": before, "after": after, "symbolsBefore": symbolsBefore, "symbolsAfter": symbolsAfter, "changed": changed,
                       "unusedHonorificBefore": unusedBefore, "unusedHonorificAfter": unusedAfter])
    }
    var intervals: [String: Any] = [:]
    for metric in ["none", "retrieve"] {
        if let interval = LabGate.interval(items: items, metric: metric, seed: 20261015) {
            intervals[metric] = ["mean": interval.mean, "lower": interval.lower, "upper": interval.upper, "count": interval.count]
        }
    }
    let result: [String: Any] = ["rows": output, "count": output.count, "excludedFeatures": excluded.sorted(), "onlyFeature": only ?? -1,
        "intervals": intervals, "sourceDays": Set(items.map(\.day)).count, "resamples": LabGate.resamples, "seed": 20261015]
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys,.prettyPrinted]).write(to: URL(fileURLWithPath: arguments[1]))
    print("style-replay: \(output.count) positions")
}

func runStyleBench(arguments: [String]) throws {
    var profileRows = 0, profilePlans = 0
    if let index = arguments.firstIndex(of: "--snapshot") {
        let rows = try LabSnapshot.readCommits(url: URL(fileURLWithPath: arguments[index + 1]))
        let profile = PersonalStyleProfile(rows: rows)
        profileRows = rows.count; profilePlans = profile.plans().count
    }
    let text = "ご確認下さい。既に送付致しましたので、出来るだけ早くご連絡下さい。事務手続きと記事の内容もご確認いただけると有難いです。よろしくお願いいたします。"
    let texts = (0..<2000).map { text + String($0) }
    let choices = Dictionary(uniqueKeysWithValues: (0..<(PersonalOrthography.pairs.count + 6)).map { ($0, 1) })
    let usage = arguments.contains("--honorifics") ? Dictionary(uniqueKeysWithValues: PersonalHonorific.groupIDs.map { ($0[0], 2) }) : [:]
    let plan = PersonalStylePlan(preferences: choices, honorificUsage: usage)
    let scene = PersonalScene(app: "com.example.style", shape: .line, mode: .new, reply: false)
    let plans = [scene.key: plan]
    var times: [Double] = [], characters = 0
    for text in texts {
        let start = DispatchTime.now().uptimeNanoseconds
        let selected = PersonalStyleProfile.levels(scene).compactMap { plans[$0] }.first
        characters += PersonalGeneratedText.apply(text, route: .magic, enabled: true, plan: selected).utf8.count
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000)
    }
    let sorted = times.sorted()
    let report: [String: Any] = ["candidates": times.count, "charactersMin": texts.map(\.count).min() ?? 0,
        "charactersMax": texts.map(\.count).max() ?? 0, "meanMicroseconds": times.reduce(0,+)/Double(times.count),
        "medianMicroseconds": sorted[sorted.count/2], "p95Microseconds": sorted[sorted.count*95/100],
        "maxMicroseconds": sorted.last ?? 0, "firstMicroseconds": times[0], "outputBytes": characters,
        "planPreparedBeforeTiming": true, "planLookupIncluded": true, "allFortyPairsEnabled": true,
        "profileRowsPrepared": profileRows, "profilePlansPrepared": profilePlans, "honorificGroupsEnabled": usage.count]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys,.prettyPrinted])
    if let path = arguments.first { try data.write(to: URL(fileURLWithPath: path)) }
    print(String(decoding: data, as: UTF8.self))
}

let arguments = Array(CommandLine.arguments.dropFirst())
MainActor.assumeIsolated {
    do {
        switch arguments.first {
        case "style-replay":
            try runStyleReplay(arguments: Array(arguments.dropFirst()))
        case "stylebench":
            try runStyleBench(arguments: Array(arguments.dropFirst()))
        case "conversion":
            try runConversion(arguments: Array(arguments.dropFirst()))
        case "completion":
            try runCompletion(arguments: Array(arguments.dropFirst()))
        case "typo":
            try runTypo(arguments: Array(arguments.dropFirst()))
        case "tune":
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                do {
                    try await runTune(arguments: Array(arguments.dropFirst()))
                } catch {
                    print("error: \(error)")
                }
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        case "searchbench":
            try runSearchBench(arguments: Array(arguments.dropFirst()))
        case "embedbench":
            try runEmbedBench(arguments: Array(arguments.dropFirst()))
        case "magic":
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                do {
                    try await runMagic(arguments: Array(arguments.dropFirst()))
                } catch {
                    print("error: \(error)")
                }
                semaphore.signal()
            }
            // 主スレッドで待つと Task が進まないので、RunLoop を回して待つ
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        default:
            print("usage: personaleval conversion ...")
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
