@testable import Core
import Foundation
import KanaKanjiConverterModule
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// llm-ime: 同じ入力欄の、カーソルより前の文章に書いてある表記を先頭に置く

private func documentCandidate(_ text: String, reading: String = "センテイ") -> Candidate {
    .init(text: text, value: -10, composingCount: .inputCount(4), lastMid: 0,
          data: [.init(word: text, ruby: reading, cid: 0, mid: 0, value: -10)])
}

private final class FixedContext: SegmentManagerDelegate {
    var left: String?
    init(left: String?) { self.left = left }
    func getLeftSideContext(maxCount: Int) -> String? { left.map { String($0.suffix(maxCount)) } }
    func getRightSideContext(maxCount: Int) -> String? { nil }
}

private let report = "造船所の点検の記録。水中で船の船底を撮り、自己位置推定で撮った場所を残した。濁りがあっても、"
    + "船体と海面の境目を見分けて、船底の3Dモデルを作れるかを確かめる。作れなければ、"
    + "原因と対策をまとめて次の点検に生かす。\n"

@Test func documentGlossaryMovesOneWrittenSurfaceToTheTop() {
    let list = ["船艇", "選定", "剪定", "船底", "先帝"].map { documentCandidate($0) }
    let promoted = DocumentGlossary.promote(list, document: report) { _ in true }
    #expect(promoted.map(\.text) == ["船底", "船艇", "選定", "剪定", "先帝"])
    // 候補を足したり点数を変えたりしない
    #expect(promoted.map(\.value) == list.map(\.value))
    #expect(Set(promoted.map(\.text)) == Set(list.map(\.text)))
}

@Test func documentGlossaryKeepsTheOrderWhenItHasNothingToSay() {
    let list = ["船艇", "選定", "剪定", "船底", "先帝"].map { documentCandidate($0) }
    // 文章にない・文章が空・一部だけの候補
    #expect(DocumentGlossary.promote(list, document: "今日は晴れです。") { _ in true } == list)
    #expect(DocumentGlossary.promote(list, document: "") { _ in true } == list)
    #expect(DocumentGlossary.promote(list, document: report) { _ in false } == list)
    // 第 1 候補がすでに文章に書いてあれば、変換の判断に任せる
    #expect(DocumentGlossary.promote(list, document: "船艇と船底を比べる") { _ in true } == list)
    // ひらがなだけの表記・1 字の表記は、偶然の一致があるので上げない
    let kana = ["こと", "事", "古都"].map { documentCandidate($0, reading: "コト") }
    #expect(DocumentGlossary.promote(kana, document: "結論にすること。") { _ in true } == kana)
    let single = ["気", "木"].map { documentCandidate($0, reading: "キ") }
    #expect(DocumentGlossary.promote(single, document: "木の下で") { _ in true } == single)
    // 探す範囲（元の 20 位まで）より下は動かさない
    let deep = (0..<DocumentGlossary.searchDepth).map { documentCandidate("候補\($0)") } + [documentCandidate("船底")]
    #expect(DocumentGlossary.promote(deep, document: report) { _ in true } == deep)
}

@Test func documentGlossaryAcceptsKatakanaSurfaces() {
    let list = ["構成", "コウセイ"].map { documentCandidate($0, reading: "コウセイ") }
    #expect(DocumentGlossary.promote(list, document: "株式会社コウセイの資料") { _ in true }.first?.text == "コウセイ")
}

private let gardenNote = "先週は庭木の剪定を業者に頼みました。枝が伸びすぎて、隣の家の窓に当たりそうになっていたためです。"
    + "作業は午前中に終わり、落ち葉の片付けまでしてもらえました。次回は春に"

@MainActor @Test func conversionUsesWordsWrittenEarlierInTheSameField() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = FixedContext(left: nil)
    let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
                                  containerURL: nil, context: .init(useZenzai: false))
    manager.delegate = context
    manager.insertAtCursorPosition("sentei", inputStyle: .roman2kana)
    manager.update(requestRichCandidates: true)
    guard case .selecting(let originals, _) = manager.getCurrentCandidateWindow(inputState: .selecting),
          let index = originals.firstIndex(where: { $0.text == "剪定" }), index > 0 else {
        Issue.record("Dictionary must offer 剪定 below the first candidate for せんてい"); return
    }
    let baseline = originals.first?.text

    // 変換に渡す 40 字には「剪定」が入らない文章でも、同じ欄の前のほうに書いてあれば先頭に置く
    context.left = gardenNote
    #expect(!String(gardenNote.suffix(40)).contains("剪定"))
    manager.update(requestRichCandidates: true)
    guard case .selecting(let adjusted, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("Candidate window missing"); return
    }
    #expect(adjusted.first?.text == "剪定")
    #expect(Set(adjusted.map(\.text)) == Set(originals.map(\.text)))
    // 続き予測の土台（変換と同じ第 1 候補）もそろう
    #expect(manager.refineFirstCandidate()?.text == "剪定")
    #expect(manager.convertTarget == "せんてい")

    // 文章がなければ元の順に戻る
    context.left = nil
    manager.update(requestRichCandidates: true)
    guard case .selecting(let restored, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("Candidate window missing")
        return
    }
    #expect(restored.first?.text == baseline)
}

@MainActor @Test func documentGlossaryAloneCannotAddWordsMissingFromTheDictionary() throws {
    // 「船底」は辞書に「センテイ」の読みがないので、並べ替えだけでは候補にならない（DocumentReadings を止めた場合）
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = FixedContext(left: report)
    let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
                                  containerURL: nil, context: .init(useZenzai: false))
    manager.delegate = context
    manager.documentReadingsEnabled = false
    manager.insertAtCursorPosition("sentei", inputStyle: .roman2kana)
    manager.update(requestRichCandidates: true)
    guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("Candidate window missing")
        return
    }
    #expect(!candidates.contains { $0.text == "船底" })
}
