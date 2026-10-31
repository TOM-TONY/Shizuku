@testable import Core
import Darwin
import Foundation
import KanaKanjiConverterModule
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// llm-ime: 前の文章に書いた漢字の語を、1 字ずつの読みを辞書で確かめて候補に足す

private let mountainNote = "夏の山行の記録。谷底の沢を渡り、岩稜を越えて、山岳地図で道を確かめながら山小屋まで進んだ。"
    + "稜線には残雪があり、山雪の季節の写真と見比べた。"
    + "霧が出たら下山路を選び、水と行動食を確かめて早めに引き返す。\n"

private final class DocumentContext: SegmentManagerDelegate {
    var left: String?
    init(left: String?) { self.left = left }
    func getLeftSideContext(maxCount: Int) -> String? { left.map { String($0.suffix(maxCount)) } }
    func getRightSideContext(maxCount: Int) -> String? { nil }
}

/// 試験用の 1 字の読み（辞書の代わり。変換の順）
private let fixedSingles: [String: [Character]] = [
    "サン": ["山", "三"], "コウ": ["行", "高"], "ザン": ["残", "山"], "セツ": ["雪", "説"], "タニ": ["谷"], "ゾコ": ["底"], "ソコ": ["底"],
    "ガク": ["岳"], "チ": ["地"], "ズ": ["図"]
]

private func has(_ readings: DocumentReadings, _ surface: String, _ ruby: String) -> Bool {
    readings.entries.contains { $0.surface == surface && $0.ruby == ruby }
}

@Test func documentReadingsCollectsKanjiWordsNearestFirst() {
    let words = DocumentReadings.extractWords("古い山行の話。新しい山岳地図作成")
    #expect(words.first == "作成")
    #expect(words.contains("地図作成") && words.contains("山行") && words.contains("山岳地図") && !words.contains("地図作成の"))
    // 語の途中で切れた部分は拾わない
    #expect(!words.contains("岳地") && !words.contains("岳地図"))
    #expect(!words.contains { $0.count < 2 || $0.count > 4 })
    #expect(DocumentReadings.extractWords("ひらがなとカタカナだけ").isEmpty)
}

@Test func documentReadingsMatchesWordsReadOneCharacterAtATime() {
    var readings = DocumentReadings()
    readings.update(document: mountainNote)
    for (part, characters) in fixedSingles { readings.store(part, characters) }
    let onyomi = readings.match(target: "サンコウ")
    #expect(onyomi && has(readings, "山行", "サンコウ"))
    // 「山」もザンと読めるが、まれな読みなので「残雪」より順位の合計が大きい
    readings.match(target: "ザンセツ")
    let rare = readings.entries.first { $0.surface == "山雪" && $0.ruby == "ザンセツ" }
    let common = readings.entries.first { $0.surface == "残雪" && $0.ruby == "ザンセツ" }
    #expect(rare != nil && common != nil && common!.rank < rare!.rank)
    // 訓読み・連濁も、辞書に 1 字の読みがあれば読める
    let kunyomi = readings.match(target: "タニゾコ")
    #expect(kunyomi && has(readings, "谷底", "タニゾコ"))
    // 見つけた語は、文を打ち進めても覚えている
    let alreadyFound = readings.match(target: "ノサンコウ")
    #expect(!alreadyFound)
    let compound = readings.match(target: "サンガクチズ")
    #expect(compound && has(readings, "山岳地図", "サンガクチズ"))
    // 読めない読みでは足さない
    let count = readings.entries.count
    let unreadable = readings.match(target: "サンタク")
    #expect(!unreadable && readings.entries.count == count)
}

@Test func documentReadingsDefersMissingReadingsToLookups() {
    var readings = DocumentReadings()
    readings.update(document: mountainNote)
    // キーの処理では辞書を引かない。足りない読みを積むだけ（ン・ッ・ー・小書きの仮名で始まる読みは引かない）
    let beforeLookup = readings.match(target: "サンコウ")
    #expect(!beforeLookup)
    #expect(readings.pending.contains("サン") && readings.lookups == 0 && !readings.pending.contains { $0.first == "ン" })
    while let part = readings.pending.first {
        readings.complete(part, fixedSingles[part] ?? [])
        readings.match(target: "サンコウ", allSubstrings: true)
    }
    #expect(has(readings, "山行", "サンコウ"))
    // 引く読みは、今の読みの 4 字までの部分に限られる
    #expect(readings.lookups <= 4 * 4)
}

@Test func documentReadingsForgetsWordsThatLeaveTheDocument() {
    var readings = DocumentReadings()
    readings.update(document: mountainNote)
    for (part, characters) in fixedSingles { readings.store(part, characters) }
    readings.match(target: "サンコウ")
    #expect(!readings.entries.isEmpty)
    readings.update(document: "まったく別の話です。")
    #expect(readings.entries.isEmpty)
    readings.clear()
    #expect(readings.words.isEmpty && readings.pending.isEmpty)
}

@Test func documentReadingLookupUsesTheDictionaryOrder() {
    let lookup = DocumentReadingLookup()
    let zan = lookup.lookUpNow("ザン")
    #expect(zan.contains("残") && zan.contains("山"))
    if let common = zan.firstIndex(of: "残"), let rare = zan.firstIndex(of: "山") {
        #expect(common < rare)
    }
    #expect(lookup.lookUpNow("サン").contains("山"))
    #expect(lookup.lookUpNow("ゾコ").contains("底"))
}

@MainActor @Test func conversionOffersADocumentWordMissingFromTheDictionary() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = DocumentContext(left: mountainNote)
    let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
                                  containerURL: nil, context: .init(useZenzai: false))
    manager.delegate = context
    manager.insertAtCursorPosition("ganryou", inputStyle: .roman2kana)
    manager.update(requestRichCandidates: true)
    // 読みを引くのはキーの処理の後（ここではその場で引く）
    manager.resolveDocumentReadingsNow()
    #expect(manager.documentReadingStatistics.entries.contains { $0.surface == "岩稜" && $0.ruby == "ガンリョウ" })
    manager.update(requestRichCandidates: true)
    guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("Candidate window missing")
        return
    }
    #expect(candidates.first?.text == "岩稜")
    #expect(manager.refineFirstCandidate()?.text == "岩稜")
    // 文の中でも、変換の網に語として入る
    manager.insertAtCursorPosition("no", inputStyle: .roman2kana)
    manager.update(requestRichCandidates: true)
    guard case .selecting(let longer, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("Candidate window missing")
        return
    }
    #expect(longer.contains { $0.text.hasPrefix("岩稜") })
    // 文章がなくなれば足さない
    context.left = nil
    manager.update(requestRichCandidates: true)
    #expect(manager.documentReadingStatistics.entries.isEmpty)
}

private func residentMegabytes() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

/// 速さとメモリの計測（結果は表示するだけ。zenz を使わない Core の変換、文章 約 2000 字、10 語 × 2 回）
@MainActor @Test func documentReadingsTiming() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var document = ""
    while document.count < 2000 { document += mountainNote + "靴の手入れと雨具の準備、食事の計画について話し合った。" }
    document = String(document.suffix(2000))
    let words = ["sankou", "ganryou", "sangakutizu", "tanizoko", "zansetu", "yamagoya", "kutu", "amagu", "keikaku", "syokuji"]
    func p(_ values: [Double], _ q: Double) -> Double { values.isEmpty ? 0 : values.sorted()[min(values.count - 1, Int(Double(values.count) * q))] }
    let memoryBefore = residentMegabytes()
    _ = DocumentReadingLookup.shared.lookUpNow("ザン")
    print(String(format: "MEMORY lookup_dictionary_first_use_delta=%.1fMB", residentMegabytes() - memoryBefore))
    func run(_ label: String, enabled: Bool, lookupsBetweenKeys: Int) {
        let context = DocumentContext(left: document)
        let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
                                      containerURL: nil, context: .init(useZenzai: false))
        manager.delegate = context
        manager.documentReadingsEnabled = enabled
        for round in 0..<2 {
            var keys: [Double] = [], lookups: [Double] = [], applies: [Double] = [], slowest: [(String, Double)] = [], found = 0
            for word in words {
                manager.stopComposition()
                for character in word {
                    let start = Date()
                    manager.insertAtCursorPosition(String(character), inputStyle: .roman2kana)
                    manager.update(requestRichCandidates: true)
                    keys.append(Date().timeIntervalSince(start) * 1000)
                    // キーの間に裏で引ける回数
                    for _ in 0..<lookupsBetweenKeys {
                        guard let step = manager.resolveDocumentReadingsStep() else {
                            break
                        }
                        lookups.append(step.lookupMs); applies.append(step.applyMs); slowest.append((step.part, step.lookupMs))
                    }
                }
                // 変換（スペース）のときの第 1 候補
                manager.update(requestRichCandidates: true)
                if case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting),
                   let first = candidates.first, document.contains(first.text), first.text.count >= 2 { found += 1 }
            }
            print(String(format: "TIMING %@ round=%d keys=%d key_p50=%.2fms key_p95=%.2fms key_max=%.2fms lookups=%d bg_lookup_p50=%.2fms bg_lookup_p95=%.2fms bg_lookup_max=%.2fms main_apply_p95=%.3fms main_apply_max=%.3fms firstFromDocument=%d/%d",
                         label, round, keys.count, p(keys, 0.5), p(keys, 0.95), keys.max() ?? 0, lookups.count, p(lookups, 0.5), p(lookups, 0.95),
                         lookups.max() ?? 0, p(applies, 0.95), applies.max() ?? 0, found, words.count))
            print("SLOWEST \(label) round=\(round) " + slowest.sorted { $0.1 > $1.1 }.prefix(5).map { "\($0.0)=\(String(format: "%.1f", $0.1))ms" }.joined(separator: " "))
        }
        print("ENTRIES \(label) " + manager.documentReadingStatistics.entries.prefix(12).map { "\($0.surface)/\($0.ruby)/\($0.rank)" }.joined(separator: " "))
    }
    run("off", enabled: false, lookupsBetweenKeys: 0)
    run("on", enabled: true, lookupsBetweenKeys: 1)
    run("on_all_between_keys", enabled: true, lookupsBetweenKeys: 1000)
}
