import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

// MARK: - 記録の再生による答え合わせ（llm-ime、解析と学習 段階 A）
//
// 学習側（LabTrainView）の確定で場面学習の状態を作り、答え合わせ用の確定を時刻の順に再生する（場面学習の評価 personaleval と同じ
// 手順。SegmentsManager・PersonalLearner をそのまま使う）。今の版と案を同じ項目で評価し、項目ごとの差を LabGate に渡す。

public enum LabReplay {
    /// 変換の答え合わせに使う確定（読みと表記がそろっていて、続き予測・放置の続き・書き出し・言い直し・かなのままでないもの）
    public static func isConversionItem(_ commit: LabCommit) -> Bool {
        commit.reading != nil && !commit.surface.isEmpty && ["selection", "enter", "transform"].contains(commit.kind)
    }

    /// 日ごとのまとまり（ブートストラップの単位）
    public static func day(_ ts: Double) -> Int {
        Int(floor(ts / 86400))
    }

    /// 学習側の確定から、場面学習の状態（自動辞書・文脈の選択・手本の文）を作る（変換は使わない）
    public static func primedLearner(_ train: LabTrainView) -> PersonalLearner {
        let learner = PersonalLearner(storeURL: nil)
        for commit in train.commits {
            guard let scene = PersonalScene(key: commit.scene) else {
                continue
            }
            learner.recordCommit(
                .init(scene: scene, kind: commit.kind, reading: commit.reading, surface: commit.surface, defaultSurface: commit.first,
                      leftContext: commit.left ?? ""),
                now: Date(timeIntervalSince1970: commit.ts), origin: commit.origin
            )
        }
        return learner
    }

    /// 文の埋め込み（文、問いか）。同じ文は使い回す前提（ShizukuLab が持つ）
    public typealias Embed = (_ text: String, _ asQuery: Bool) -> [Float]?

    /// 続き予測の答え合わせの位置（答え合わせ用の確定から。文脈は前後の確定から作る）と、学習側の文だけで選んだ手本。
    /// 意味の近さの重みが 0 より大きく embed があれば、学習側の文のベクトルと、句を打ち始める前の左文脈の末尾 40 字の問いで
    /// 意味の近さも足す（IME と同じ問い）
    public static func completionItems(
        train: LabTrainView, heldOut: [LabCommit], parameters: LabParameters, limit: Int, embed: Embed? = nil
    ) -> [(sample: PersonalLearner.ReplaySample, prefix: String)] {
        let rows = heldOut.map { (scene: $0.scene, ts: $0.ts, surface: $0.surface) }
        let samples = PersonalLearner.replaySamples(from: rows, limit: limit)
        let corpus = PersonalCorpus()
        for commit in train.commits where commit.isMaterial {
            if let scene = PersonalScene(key: commit.scene) {
                corpus.add(scene: scene, text: commit.surface, ts: commit.ts)
            }
        }
        let semantic = parameters.semanticWeight > 0 ? embed : nil
        if let semantic {
            corpus.embedMissing { semantic($0, false) }
        }
        let saved = (PersonalCorpus.prefixCharacterBudget, PersonalCorpus.bm25K1, PersonalCorpus.bm25B, PersonalCorpus.semanticWeight)
        PersonalCorpus.prefixCharacterBudget = parameters.exemplarBudget
        PersonalCorpus.bm25K1 = parameters.bm25K1
        PersonalCorpus.bm25B = parameters.bm25B
        PersonalCorpus.semanticWeight = semantic == nil ? 0 : parameters.semanticWeight
        defer {
            (PersonalCorpus.prefixCharacterBudget, PersonalCorpus.bm25K1, PersonalCorpus.bm25B, PersonalCorpus.semanticWeight) = saved
        }
        return samples.map { sample in
            let query = String(sample.left.suffix(40))
            let queryVector = query.isEmpty ? nil : semantic?(query, true)
            return (sample, corpus.completionPrefix(
                style: .retrieve, scene: sample.scene, query: String(sample.context.suffix(40)), context: sample.context, queryVector: queryVector
            ))
        }
    }

    /// 続き予測の 1 位置の成績（節約した文字・外れを出したか）
    public static func completionOutcome(pieces: [NextTextCompletionEngine.Piece], gold: String, threshold: Float) -> (saved: Int, wrong: Bool) {
        guard let text = NextTextCompletionEngine.suggestion(from: pieces, threshold: threshold) else {
            return (0, false)
        }
        return Self.textOutcome(text: text, gold: gold)
    }

    /// 出す文字列が決まった後の節約文字。履歴の引用の測定にも同じ定義を使う。
    public static func textOutcome(text: String, gold: String) -> (saved: Int, wrong: Bool) {
        guard !text.isEmpty else { return (0, false) }
        let correct = gold.precomposedStringWithCompatibilityMapping.hasPrefix(text.precomposedStringWithCompatibilityMapping)
        return correct ? (text.count, false) : (0, true)
    }

    /// 今の版と案の、項目ごとの差（top1・節約文字・外れを出さなかった）
    public static func pairedItems(
        conversion: [(ts: Double, baseline: Bool, candidate: Bool)],
        completion: [(ts: Double, baseline: (saved: Int, wrong: Bool), candidate: (saved: Int, wrong: Bool))]
    ) -> [LabGate.Item] {
        conversion.map { item in
            LabGate.Item(day: Self.day(item.ts), diffs: ["top1": (item.candidate ? 1 : 0) - (item.baseline ? 1 : 0)])
        } + completion.map { item in
            LabGate.Item(day: Self.day(item.ts), diffs: [
                "saved": Double(item.candidate.saved - item.baseline.saved),
                "notWrong": Double((item.baseline.wrong ? 1 : 0) - (item.candidate.wrong ? 1 : 0)),
            ])
        }
    }
}

/// 変換の答え合わせ（取り置きの確定を、1 回目のスペースの第 1 候補で）
@MainActor
public final class LabConversionReplay {
    final class Context: SegmentManagerDelegate {
        var left = ""

        func getLeftSideContext(maxCount: Int) -> String? {
            String(self.left.suffix(maxCount))
        }

        func getRightSideContext(maxCount: Int) -> String? {
            nil
        }
    }

    final class Personalization: SegmentsManagerPersonalization {
        let learner: PersonalLearner
        var scene: PersonalScene?
        var now = Date()

        init(learner: PersonalLearner) {
            self.learner = learner
        }

        func personalPreferredSurface(forReading reading: String, leftContext: String) -> PersonalLearner.Entry? {
            self.scene.flatMap { self.learner.preferredEntry(forReading: reading, scene: $0, leftContext: leftContext) }
        }

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
    }

    let resources: URL
    /// 直前の run の、項目ごとの第 1 候補（毎回同じ結果になるかを確かめる用。ファイルには書かない）
    public private(set) var lastTop1: [String] = []

    public init(resources: URL) {
        self.resources = resources
    }

    /// 案の値で、学習側の状態から始めて取り置きの確定を順に再生する。項目ごとに第 1 候補が当たったか
    public func run(train: LabTrainView, items: [LabCommit], parameters: LabParameters) throws -> [Bool] {
        LabParameters.apply(parameters)
        let memory = FileManager.default.temporaryDirectory.appendingPathComponent("shizukulab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: memory)
        }
        let manager = SegmentsManager(
            kanaKanjiConverter: KanaKanjiConverter.withDefaultDictionary(), applicationDirectoryURL: memory, containerURL: nil,
            context: .init(useZenzai: true, resourcesDirectoryURL: self.resources)
        )
        let context = Context()
        manager.delegate = context
        let personalization = Personalization(learner: LabReplay.primedLearner(train))
        manager.personalization = personalization
        manager.activate()
        var results: [Bool] = []
        self.lastTop1 = []
        for item in items {
            guard let readingKatakana = item.reading else {
                results.append(false)
                self.lastTop1.append("")
                continue
            }
            let reading = readingKatakana.toHiragana()
            context.left = item.left ?? ""
            personalization.scene = PersonalScene(key: item.scene)
            personalization.now = Date(timeIntervalSince1970: item.ts)
            manager.insertAtCursorPosition(reading, inputStyle: .direct)
            manager.insertCompositionSeparator(inputStyle: .direct, skipUpdate: true)
            manager.updateForFirstCandidate()
            let top1 = manager.getCurrentMarkedText(inputState: .previewing).map(\.content).joined()
            results.append(top1 == item.surface)
            self.lastTop1.append(top1)
            // 本人が実際に確定した表記で確定する（次の項目の学習の状態を実際と同じにする）
            if top1 == item.surface {
                _ = manager.commitMarkedText(inputState: .previewing)
            } else {
                manager.update(requestRichCandidates: true)
                if case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting),
                   let index = candidates.firstIndex(where: { $0.text == item.surface }) {
                    manager.requestSelectingRow(index)
                    if let candidate = manager.selectedCandidate {
                        manager.prefixCandidateCommited(candidate, leftSideContext: context.left, kind: .selection)
                    }
                } else {
                    let candidate = Candidate(
                        text: item.surface, value: -10, composingCount: .surfaceCount(reading.count), lastMid: MIDData.一般.mid,
                        data: [DicdataElement(word: item.surface, ruby: readingKatakana, cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -10)]
                    )
                    manager.prefixCandidateCommited(candidate, leftSideContext: context.left, kind: .transform)
                }
            }
            manager.stopComposition()
        }
        return results
    }
}
