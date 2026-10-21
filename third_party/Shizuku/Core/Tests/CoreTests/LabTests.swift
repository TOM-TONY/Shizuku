import Foundation
import Testing
@testable import Core

// MARK: - 解析と学習 段階 A

@Test func labDefaultsAreTheConstantsBeforeTheLab() {
    let defaults = LabParameters.defaults
    #expect(defaults.exemplarBudget == 160)
    #expect(defaults.bm25K1 == 1.2 && defaults.bm25B == 0.75)
    #expect(defaults.sceneThreshold == 2)
    #expect(defaults.promotionMargin == 3.0 && defaults.contextPromotionMargin == 2.0)
    #expect(defaults.isWithinBounds)
    #expect(!LabParameters(exemplarBudget: 1000).isWithinBounds)
}

@Test func labUndoRestoresThePreviousVersionByteForByte() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LabVersionStore(directory: directory)
    // 一度も採用していなければ既定
    #expect(store.currentVersion == 0)
    #expect(store.appliedParameters.canonicalJSON() == LabParameters.defaults.canonicalJSON())
    let first = LabParameters(exemplarBudget: 200, bm25K1: 1.5)
    let second = LabParameters(exemplarBudget: 120, sceneThreshold: 3)
    try store.adopt(parameters: first, decision: nil, runID: "a", split: 1, dataFrom: 0, dataTo: 2)
    try store.adopt(parameters: second, decision: nil, runID: "b", split: 1, dataFrom: 0, dataTo: 2)
    #expect(store.currentVersion == 2)
    #expect(store.appliedParameters.canonicalJSON() == second.canonicalJSON())
    try store.undo()
    #expect(store.currentVersion == 1)
    #expect(store.appliedParameters.canonicalJSON() == first.canonicalJSON())
    try store.undo()
    #expect(store.currentVersion == 0)
    #expect(store.appliedParameters.canonicalJSON() == LabParameters.defaults.canonicalJSON())
    // 範囲外の値は採用しない
    #expect(throws: LabError.outOfBounds) {
        try store.adopt(parameters: LabParameters(bm25B: 2), decision: nil, runID: "c", split: nil, dataFrom: nil, dataTo: nil)
    }
}

@Test func labForgetInvalidatesVersionsWithTextArtifactsAndFallsBack() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LabVersionStore(directory: directory)
    let plain = LabParameters(exemplarBudget: 200)
    try store.adopt(parameters: plain, decision: nil, runID: "a", split: nil, dataFrom: nil, dataTo: nil)
    try FileManager.default.createDirectory(at: store.folder(of: 2), withIntermediateDirectories: true)
    try Data("style".utf8).write(to: store.folder(of: 2).appendingPathComponent("style.json"))
    try store.adopt(
        parameters: LabParameters(exemplarBudget: 120), decision: nil, runID: "b", split: nil, dataFrom: nil, dataTo: nil,
        artifacts: ["style": "style.json"]
    )
    try store.invalidateTextArtifacts()
    #expect(!FileManager.default.fileExists(atPath: store.folder(of: 2).appendingPathComponent("style.json").path))
    #expect(store.manifest(2)?.invalid == true)
    // 今の版は、文章から作ったものを持たない最も新しい祖先に戻る
    #expect(store.currentVersion == 1)
    #expect(store.appliedParameters == plain)
}

@Test func labHeldOutNeverReachesTheTrainingSide() {
    let day = 86400.0
    let commits = (0..<40).map { i in
        LabCommit(ts: Double(i) * day, scene: "app|line|new|-", kind: "enter", reading: nil, surface: i >= 26 ? "取り置き\(i)" : "学習\(i)", first: nil, left: nil)
    }
    let split = LabSplit.make(lastCommit: commits.last!.ts)
    let train = LabTrainView(commits, split: split)
    let heldOut = LabHeldOut(commits, split: split)
    #expect(train.commits.count + heldOut.commits.count == commits.count)
    #expect(train.commits.allSatisfy { $0.ts < split.split })
    #expect(!train.commits.contains { $0.surface.hasPrefix("取り置き") })
    #expect(heldOut.commits.allSatisfy { $0.ts >= split.split })
    // 学習側から作る手本（PersonalCorpus）に、取り置きの文が入らない
    let corpus = PersonalCorpus()
    for commit in train.commits {
        corpus.add(scene: PersonalScene(key: commit.scene)!, text: commit.surface + "。", ts: commit.ts)
    }
    #expect(!corpus.sentences.contains { $0.text.contains("取り置き") })
}

@Test func labGateAcceptsAClearGainAndRejectsAWorseCandidate() {
    // 30 日、1 日 20 項目。案は節約文字を少し増やし、top1 は変えない
    var better: [LabGate.Item] = []
    var worse: [LabGate.Item] = []
    for day in 0..<30 {
        for i in 0..<20 {
            let gain = (i % 4 == 0) ? 1.0 : 0.0
            better.append(.init(day: day, diffs: ["saved": gain, "top1": 0]))
            worse.append(.init(day: day, diffs: ["saved": gain, "top1": (i % 5 == 0) ? -1 : 0]))
        }
    }
    let rules = [LabGate.Rule(metric: "saved", primary: true, margin: 0), LabGate.Rule(metric: "top1", primary: false, margin: 0.002)]
    let accepted = LabGate.decide(items: better, rules: rules, seed: 42)
    #expect(accepted.accepted)
    #expect((accepted.intervals["saved"]?.lower ?? 0) > 0)
    // 主な指標が良くなっても、ほかの指標が悪くなる案は捨てる
    let rejected = LabGate.decide(items: worse, rules: rules, seed: 42)
    #expect(!rejected.accepted)
    #expect(rejected.reasons.contains { $0.hasPrefix("top1") })
    // 同じ項目・同じ種なら同じ判定（ConverterServer が計算し直しても同じ）
    #expect(LabGate.decide(items: better, rules: rules, seed: 42) == accepted)
    // 差がほとんどない（偶然の範囲）なら採用しない
    let noise = (0..<30).flatMap { day in (0..<20).map { i in LabGate.Item(day: day, diffs: ["saved": (day == 3 && i == 0) ? 1 : 0]) } }
    #expect(!LabGate.decide(items: noise, rules: rules, seed: 42).accepted)
}

@Test func labOutcomeAdoptsOnlyAVerifiedPassingResult() throws {
    let baseline = LabParameters.defaults
    let candidate = LabParameters(sceneThreshold: 3)
    let gain = (0..<30).flatMap { day in (0..<20).map { i in LabGate.Item(day: day, diffs: ["top1": i % 4 == 0 ? 1 : 0, "notWrong": 0]) } }
    func result(
        runID: String = "r", snapshotID: String = "s", split: Double = 100, baseline: LabParameters = baseline, candidate: LabParameters? = candidate,
        items: [LabGate.Item] = gain
    ) -> Data {
        try! JSONEncoder().encode(LabRunResult(
            runID: runID, snapshotID: snapshotID, split: split, status: .candidate, baseline: baseline, candidate: candidate, seed: 7,
            items: items, decision: nil, counts: [:], skipped: [], notes: [], dataFrom: nil, dataTo: nil, elapsed: 1
        ))
    }
    func decide(_ data: Data?, status: Int32 = 0, stop: String? = nil) -> LabOutcome {
        LabOutcome.decide(exitStatus: status, stopReason: stop, resultData: data, runID: "r", snapshotID: "s", split: 100, baseline: baseline)
    }
    guard case .adopt(_, let adopted, _) = decide(result()) else {
        Issue.record("passing result was not adopted")
        return
    }
    #expect(adopted == candidate)
    // 途中で止めた・失敗した・結果がない: 何も採用しない
    #expect(decide(result(), stop: "本人が止めた") == .stopped("本人が止めた"))
    #expect(decide(result(), status: 15) == .failed)
    #expect(decide(nil) == .failed)
    #expect(decide(Data("{".utf8)) == .failed)
    // 今回の写し・実行のものでない、範囲外、悪くなる案: 採用しない
    if case .adopt = decide(result(snapshotID: "other")) { Issue.record("adopted a result for another snapshot") }
    if case .adopt = decide(result(runID: "other")) { Issue.record("adopted a result for another run") }
    // ShizukuLab が言う今の値が、渡した値と違う（変えた組を少なく見せる）: 採用しない
    if case .adopt = decide(result(baseline: candidate, candidate: LabParameters(sceneThreshold: 3, promotionMargin: 2.5))) {
        Issue.record("adopted a result whose baseline differs from the one passed in")
    }
    // 判定の種は結果に書いた値ではなく決まった値（ShizukuLab が都合の良い種を選べない）
    #expect(LabRules.verify(
        try JSONDecoder().decode(LabRunResult.self, from: result()), runID: "r", snapshotID: "s", split: 100, baseline: baseline
    )?.decision == LabGate.decide(items: gain, rules: LabRules.rules(for: [.lexicon]), seed: LabRules.seed))
    if case .adopt = decide(result(candidate: LabParameters(exemplarBudget: 999))) { Issue.record("adopted out of bounds") }
    let worse = gain.map { LabGate.Item(day: $0.day, diffs: ["top1": -($0.diffs["top1"] ?? 0)]) }
    if case .adopt = decide(result(items: worse)) { Issue.record("adopted a worse candidate") }
}

@Test func labSnapshotReadsCommitsIncludingKeywordColumns() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("personal.sqlite")
    let store = try PersonalStore(url: url)
    try store.queue.sync {
        for (i, surface) in ["申請", "了解しました"].enumerated() {
            try store.execute(
                "INSERT INTO commits(id, ts, composition, scene, app, shape, mode, reply, kind, reading, surface, first, left, keys, backspaces) VALUES(?, ?, 0, 'a|line|new|-', 'a', 'line', 'new', 0, 'selection', 'シンセイ', ?, '新生', '経費の', 0, 0)",
                [.int(Int64(i + 1)), .double(Double(100 + i)), .text(surface)]
            )
        }
    }
    let snapshot = directory.appendingPathComponent("snapshot.sqlite")
    try store.queue.sync { try store.snapshot(to: snapshot) }
    let commits = try LabSnapshot.readCommits(url: snapshot)
    #expect(commits.map(\.surface) == ["申請", "了解しました"])
    #expect(commits.first?.first == "新生" && commits.first?.left == "経費の")
}

@Test func testStoreDeletionNeverTargetsTheRealStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lab-del-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("personal", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let test = root.appendingPathComponent(PersonalLearner.testStoreDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: test, withIntermediateDirectories: true)
    // 正しい確かめ用の場所は消してよい
    #expect(PersonalLearner.safeTestStoreDeletionTarget(test, realDirectory: real)?.lastPathComponent == PersonalLearner.testStoreDirectoryName)
    // 本当の記録の場所・その親・名前の違う場所は消さない
    #expect(PersonalLearner.safeTestStoreDeletionTarget(real, realDirectory: real) == nil)
    #expect(PersonalLearner.safeTestStoreDeletionTarget(root, realDirectory: real) == nil)
    #expect(PersonalLearner.safeTestStoreDeletionTarget(root.appendingPathComponent("other"), realDirectory: real) == nil)
    // 決まった名前でも、本当の記録の場所へのリンク・本当の記録の場所の親や子なら消さない
    let other = FileManager.default.temporaryDirectory.appendingPathComponent("lab-del2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: other) }
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let link = other.appendingPathComponent(PersonalLearner.testStoreDirectoryName)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(PersonalLearner.safeTestStoreDeletionTarget(link, realDirectory: real) == nil)
    let realNamedLikeTest = root.appendingPathComponent(PersonalLearner.testStoreDirectoryName + "-parent/" + PersonalLearner.testStoreDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: realNamedLikeTest, withIntermediateDirectories: true)
    #expect(PersonalLearner.safeTestStoreDeletionTarget(test, realDirectory: test) == nil)
    #expect(PersonalLearner.safeTestStoreDeletionTarget(test, realDirectory: test.appendingPathComponent("personal")) == nil)
    #expect(FileManager.default.fileExists(atPath: real.path))
}

/// 答え合わせを毎回同じにする: 同じ点の手本は新しい文から、同じ時刻の続き予測の位置は決まった順で選ぶ
/// （Set・Dictionary の順はプロセスごとに変わるので、順に頼らない）
@Test func replayOrderDoesNotDependOnHashOrder() {
    let scene = PersonalScene(app: "test.app", shape: .short, mode: .append, reply: false)
    let corpus = PersonalCorpus()
    // 同じ長さ・同じ 2-gram の重なりの文（BM25 の点が同じ）
    corpus.add(scene: scene, text: "経費の件Aです。", ts: 0)
    corpus.add(scene: scene, text: "経費の件Bです。", ts: 1)
    corpus.add(scene: scene, text: "経費の件Cです。", ts: 2)
    #expect(corpus.retrieve(query: "経費の件", scene: scene, excluding: "").map(\.text) == ["経費の件Cです。", "経費の件Bです。", "経費の件Aです。"])
    let a = "a.app|short|append|-", b = "b.app|short|append|-"
    let rows = [(scene: b, ts: 10.0, surface: "同じ時刻の句です"), (scene: a, ts: 10.0, surface: "同じ時刻の句でした")]
    let samples = PersonalLearner.replaySamples(from: rows, limit: 1)
    #expect(samples.count == 1 && samples[0].scene.key == b)
    #expect(PersonalLearner.replaySamples(from: rows.reversed(), limit: 2).map(\.scene.key) == [b, a])
}

/// 段階 B の値（意味の近さの重み）: 既定は 0、前の版の manifest（重みがない）も読める、変えたら手本の組、範囲は 0〜2
@Test func semanticWeightParameter() throws {
    #expect(LabParameters.defaults.semanticWeight == 0)
    let old = #"{"bm25B":0.75,"bm25K1":1.6,"contextPromotionMargin":2,"exemplarBudget":160,"promotionMargin":3,"sceneThreshold":2}"#
    let decoded = try JSONDecoder().decode(LabParameters.self, from: Data(old.utf8))
    #expect(decoded == LabParameters(bm25K1: 1.6))
    #expect(LabRules.families(baseline: .defaults, candidate: LabParameters(semanticWeight: 0.5)) == [.corpus])
    #expect(LabParameters(semanticWeight: 1).isWithinBounds && !LabParameters(semanticWeight: 3).isWithinBounds)
    #expect(try JSONDecoder().decode(LabParameters.self, from: LabParameters(semanticWeight: 0.5).canonicalJSON()).semanticWeight == 0.5)
}

extension CorpusStaticTests {
/// 解析の続き予測の手本: 重みが 0・embed なしなら BM25 だけ。重みがあれば、句を打ち始める前の左文脈で意味の近さを足す
@Test func labCompletionItemsUseLeftContextForMeaning() {
    let savedWeight = PersonalCorpus.semanticWeight
    let scene = "test.app|short|append|-"
    let day = 86400.0
    let trainCommits = ["経費の申請をお願いします。", "経費精算の締め切りは金曜日です。", "領収書を添付して提出してください。", "明日の会議は十時からです。"]
        .enumerated().map { LabCommit(ts: Double($0.offset) * 100, scene: scene, kind: "selection", reading: nil, surface: $0.element, first: nil, left: nil) }
    let heldOut = [
        LabCommit(ts: 30 * day, scene: scene, kind: "selection", reading: nil, surface: "書類の件ですが、", first: nil, left: nil),
        LabCommit(ts: 30 * day + 5, scene: scene, kind: "selection", reading: nil, surface: "経費の締め切りを", first: nil, left: nil),
    ]
    let split = LabSplit(split: 20 * day)
    let train = LabTrainView(trainCommits + heldOut, split: split)
    var queries: [String] = []
    let embed: LabReplay.Embed = { text, asQuery in
        if asQuery {
            queries.append(text)
            return [0, 0, 1]
        }
        return text.contains("領収書") ? [0, 0, 1] : [1, 0, 0]
    }
    let plain = LabReplay.completionItems(train: train, heldOut: heldOut, parameters: .defaults, limit: 10, embed: embed)
    #expect(queries.isEmpty)
    let fused = LabReplay.completionItems(train: train, heldOut: heldOut, parameters: LabParameters(semanticWeight: 1), limit: 10, embed: embed)
    // 2 つ目の句の問いは、1 つ目の句（打ち始める前の左文脈）
    #expect(queries == ["書類の件ですが、"])
    let second = fused.first { $0.sample.left == "書類の件ですが、" }
    #expect(second?.prefix.contains("領収書") == true)
    #expect(plain.first { $0.sample.left == "書類の件ですが、" }?.prefix.contains("領収書") == false)
    #expect(PersonalCorpus.semanticWeight == savedWeight)
}
}
