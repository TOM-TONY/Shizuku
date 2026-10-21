import Core
import Foundation
import Gemma4ANE
import KanaKanjiConverterModule
import KanaKanjiConverterModuleWithDefaultDictionary

/// Synthetic inputs only. Output contains measurements, never captured screen text.
let tasks: [(String, String)] = [
    ("実験条件を変更した理由", "温度を25度に保つため実験条件を変更しました。"),
    ("会議に参加できない", "今回は会議への出席を見送らせてください。"),
    ("日程をずらすお願い", "恐れ入りますが、別の日に変更していただけますか。"),
    ("原稿の校正", "原稿の誤字と脱字を修正する校正作業です。"),
    ("装置の構成", "装置の構成はポンプと温度計です。"),
    ("提出期限を延ばしてほしい", "締め切りを来週まで延期いただけますでしょうか。"),
    ("開始時刻を確認", "開始は15時です。14時ではありません。"),
    ("書類を送ったお礼", "資料をお送りいただき、ありがとうございます。"),
    ("参加はしません", "今回は参加しません。次回またご相談ください。"),
    ("次の実験の準備", "計測器の校正を済ませてから実験を開始します。")
]
let reference = WindowReference(identity: "synthetic", capturedAt: 0, blocks: tasks.map { .init(text: $0.1) })
func measure(_ name: String, retrieve: (String) -> [WindowReferenceBlock]) {
    var hit = 0, durations: [Double] = []
    for (query, expected) in tasks {
        let start = Date()
        let found = retrieve(query)
        durations.append(Date().timeIntervalSince(start) * 1000)
        if found.contains(where: { $0.text == expected }) { hit += 1 }
    }
    durations.sort()
    print("\(name) tasks=\(tasks.count) hit_at_3=\(hit) p95_ms=\(String(format: "%.3f", durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))]))")
}
measure("lexical") { reference.retrieve(query: $0) }
let worstCase = WindowReference(identity: "synthetic-bounded", capturedAt: 0,
                                blocks: (0..<32).map { .init(text: String(repeating: "無関係な表示文章です。", count: 45) + "校正\($0)") })
let candidates = ["構成", "校正", "公正", "更生", "厚生"].map {
    Candidate(text: $0, value: -10, composingCount: .inputCount(4), lastMid: 0,
              data: [.init(word: $0, ruby: "コウセイ", cid: 0, mid: 0, value: -10)])
}
var rerankTimes: [Double] = []
for _ in 0..<1000 {
    let start = Date()
    let result = worstCase.rerank(candidates, whole: { _ in true })
    precondition(result.first?.text == "校正")
    rerankTimes.append(Date().timeIntervalSince(start) * 1000)
}
print("rerank tasks=1000 p95_ms=\(String(format: "%.3f", rerankTimes.sorted()[950])) input_pipeline_delta=UNVERIFIED")
@MainActor func keyTimes(reference: WindowReference?) -> [Double] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
                                  containerURL: nil, context: .init(useZenzai: false))
    manager.windowReference = reference
    var times: [Double] = []
    for iteration in 0..<180 {
        manager.stopComposition()
        for character in "kousei" {
            let start = Date()
            manager.insertAtCursorPosition(String(character), inputStyle: .roman2kana)
            manager.update(requestRichCandidates: true)
            if iteration >= 10 { times.append(Date().timeIntervalSince(start) * 1000) }
        }
    }
    return times.sorted()
}
let baselineKeys = keyTimes(reference: nil), referenceKeys = keyTimes(reference: worstCase)
let baselineP95 = baselineKeys[Int(Double(baselineKeys.count) * 0.95)]
let referenceP95 = referenceKeys[Int(Double(referenceKeys.count) * 0.95)]
print("synthetic_core_keys samples=\(baselineKeys.count) baseline_p95_ms=\(String(format: "%.3f", baselineP95)) reference_p95_ms=\(String(format: "%.3f", referenceP95)) delta_ms=\(String(format: "%.3f", referenceP95 - baselineP95)) zenz=off os_pipeline=UNVERIFIED")
if let index = CommandLine.arguments.firstIndex(of: "--embedding-model"), CommandLine.arguments.indices.contains(index + 1) {
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    if let embedder = try? PersonalEmbedder(directory: url) {
        let identity = ModelCatalog.embeddingInfo(at: url)?.source ?? url.lastPathComponent
        let index = WindowReferenceIndex(reference: reference, modelIdentity: identity, embedder: embedder)
        measure("embedding") { index.retrieve(query: $0, modelIdentity: identity, embedder: embedder) }
    } else { print("embedding unavailable=1 adopted=0") }
}
if let index = CommandLine.arguments.firstIndex(of: "--completion-model"), CommandLine.arguments.indices.contains(index + 1) {
    let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let model = try Gemma4ANEModel(directoryURL: url)
    let completer = Gemma4Completer(model: model)
    let context = "今回の実験条件の変更は"
    let selected = reference.retrieve(query: context).map(\.text).joined(separator: "\n")
    let variants: [(String, String)] = [
        ("baseline", ""),
        ("structured", WindowReferencePrompt.prefix(reference: selected, personal: "", encode: completer.encodeContext, decode: completer.decodeContext)),
        ("quoted", "参考資料（引用）:\n" + selected + "\n\n本文:\n"),
        ("plain", selected + "\n\n")
    ]
    for (variant, prefix) in variants {
        let useReference = !prefix.isEmpty
        completer.discardContext()
        let start = Date()
        let short = try completer.complete(context: context, prefix: prefix)
        let sentence = try completer.continueSentence(context: context, prefix: prefix)
        print("generation reference=\(useReference ? 1 : 0) completion_chars=\(short?.text.count ?? 0) sentence_chars=\(sentence?.count ?? 0) elapsed_ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        print("generation reference=\(useReference ? 1 : 0) condition_relevance=\(sentence?.contains("温度") == true || sentence?.contains("25") == true ? 1 : 0)")
        let accepted = sentence.map { WindowReferenceGeneration.permits($0, draft: context, reference: useReference ? selected : "") } ?? false
        print("synthetic_output variant=\(variant) accepted=\(accepted) text=\(sentence ?? "")")
    }
    for (draft, source) in [
        ("今回の実験では温度を", "今回の実験では、温度を25度に保ちます。"),
        ("会議の開始は", "会議は15時開始です。14時ではありません。"),
        ("ご連絡ありがとうございます。今回は参加できません。", "15時の会議に参加してください。"),
        ("原稿の校正は", "校正は明日までに完了する予定です。設定を変更してください。")
    ] {
        completer.discardContext()
        let prefix = WindowReferencePrompt.prefix(reference: source, personal: "", encode: completer.encodeContext, decode: completer.decodeContext)
        let sentence = try completer.continueSentence(context: draft, prefix: prefix)
        let accepted = sentence.map { WindowReferenceGeneration.permits($0, draft: draft, reference: source) } ?? false
        print("synthetic_fixture draft=\(draft) accepted=\(accepted) text=\(sentence ?? "")")
    }
}
