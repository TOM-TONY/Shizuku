import Foundation
import Testing
@testable import Core

private let upperScene = "editor|short|new|-"
private actor UpperBoundReplayCalls {
    var sizes: [Int] = []
    func record(_ size: Int) { sizes.append(size) }
    func result() -> [Int] { sizes }
}
private func upperRow(_ ts: Double, _ text: String, scene: String = upperScene, kind: String = "enter", first: String? = nil, left: String? = nil) -> LabCommit {
    LabCommit(ts: ts, scene: scene, kind: kind, reading: nil, surface: text, first: first, left: left)
}
private func upperFixture() -> [LabCommit] {
    [upperRow(0, "甲乙丙丁。"), upperRow(1000, "甲乙丙丁。"), upperRow(2000, "甲乙戊己。"),
     upperRow(3000, "甲乙丙丁。", scene: "editor|line|new|-"), upperRow(4000, "甲乙丙丁。", scene: "chat|line|new|-"),
     upperRow(5000, "未未来来。", kind: "ai"), upperRow(6000, "未未来来。"), upperRow(6000, "未未来来。"),
     upperRow(7000, "甲乙丙丁。", kind: "idle"), upperRow(8000, "甲乙丙丁。", kind: "rewrite"),
     upperRow(9000, "甲乙丙丁。", kind: "skeleton"), upperRow(10000, "甲乙丙丁。", kind: "completion")]
}

@Test func upperBoundOracleMatchesTwelveHandCountedRowsWithoutFutureOrGeneratedText() async throws {
    let report = try await LabUpperBound.measure(commits: upperFixture())
    let global = try #require(report.group(position: "start", tier: "global"))
    #expect(report.commits == 12 && report.positions == ["mid": 12, "start": 12])
    #expect(global.oracle.count == 12)
    // 0,5,2,5,5,0,0,0,5,5,5,5。F1は7個の1と1個の1/4。
    #expect(global.oracle.totals["lcp"] == 37)
    #expect(global.oracle.totals["prefix2"] == 8)
    #expect(global.oracle.totals["prefix4"] == 7)
    #expect(global.oracle.totals["prefix8"] == 0)
    #expect(global.oracle.totals["f1"] == 7.25)
    #expect(global.oracle.totals["f1AtLeast07"] == 7)
    let otherScene = try #require(report.groups.first { $0.position == "start" && $0.tier == "scene" && $0.scope == "scene" && $0.key == "editor|line|new|-" && $0.kind == "all" })
    #expect(otherScene.oracle.totals["prefix4"] == 0)
    let app = try #require(report.groups.first { $0.position == "start" && $0.tier == "app" && $0.scope == "scene" && $0.key == "editor|line|new|-" && $0.kind == "all" })
    #expect(app.oracle.totals["prefix4"] == 1)
    #expect(report.replay.isEmpty && report.completionStatus == "no-model")
}

@Test func upperBoundPositionsKeepTheExistingReplayCutsAndContext() {
    let rows = (0..<12).map { upperRow(Double($0 * 20), "今日も確認をお願いします。", left: "保存済みの左文脈") }
    let old = PersonalLearner.replaySamples(from: rows.map { (scene: $0.scene, ts: $0.ts, surface: $0.surface) }, limit: 100)
    // 既存の再生の固定例。先頭と12番目は2字で切り、nextは40字に達するまで句を丸ごと足す。
    #expect(old.first?.left == String(repeating: "今日も確認をお願いします。", count: 11))
    #expect(old.first?.context == String(repeating: "今日も確認をお願いします。", count: 11) + "今日")
    #expect(old.first?.gold == "も確認をお願いします。")
    #expect(old.last?.context == "今日")
    #expect(old.last?.gold == "も確認をお願いします。" + String(repeating: "今日も確認をお願いします。", count: 4))
    let positions = LabUpperBound.positions(rows)
    for sample in old {
        let found = positions.first { $0.type == "mid" && $0.ts == sample.ts }
        #expect(found?.context == sample.context && found?.gold == sample.gold && found?.left == sample.left)
    }
    #expect(positions.filter { $0.type == "start" }.count == 12)
    let contexts = PersonalLearner.replayContexts(from: rows.map { (scene: $0.scene, ts: $0.ts, surface: $0.surface) })
    for item in contexts {
        let position = positions.first { $0.type == "start" && $0.index == item.index }
        #expect(position?.gold == rows[item.index].surface + item.next)
        #expect(position?.context == item.left)
    }
}

@Test func upperBoundBm25UsesProductionTiesAndItsTopOneAndThree() async throws {
    let rows = [upperRow(0, "甲乙戊己。"), upperRow(1, "甲乙丙丁。"), upperRow(1000, "甲乙"), upperRow(1001, "甲乙丙丁。")]
    let report = try await LabUpperBound.measure(commits: rows, limit: 1)
    let retrieval = try #require(report.group(position: "start", tier: "production"))
    #expect(retrieval.retrieval.count == 1)
    #expect(retrieval.retrieval.means["top1F1"] == 1)
    #expect(retrieval.retrieval.means["top3F1"] == 1)
    #expect(retrieval.retrieval.totals["lcp"] == 5)
    #expect(retrieval.retrieval.totals["saved"] == 5)
    for tier in ["scene", "app", "global", "production-scene"] {
        #expect(report.group(position: "start", tier: tier)?.retrieval.totals["saved"] == 5)
    }
    // 新しい同点の文を違うものにするとtop1だけ外れ、top3には正解が残る。
    var reversed = rows
    reversed.swapAt(0, 1); reversed[0].ts = 0; reversed[1].ts = 1
    let other = try await LabUpperBound.measure(commits: reversed, limit: 1)
    let wrong = try #require(other.group(position: "start", tier: "production"))
    #expect(wrong.retrieval.means["top1F1"] == 0 && wrong.retrieval.means["top3F1"] == 1)
    #expect(wrong.retrieval.totals["lcp"] == 2 && wrong.retrieval.totals["saved"] == 0)
}

@Test func upperBoundStopsAndNetGainAgreeWithHandCounts() async throws {
    let gold = "私の本は青い。", text = "私の本は赤い。次です。"
    let cuts = LabUpperBound.cuts(text)
    #expect(cuts["oneChunk"] == "私の")
    #expect(cuts["twoChunks"] == "私の本は")
    #expect(cuts["punctuation"] == "私の本は赤い。" && cuts["sentence"] == cuts["punctuation"])
    #expect(LabUpperBound.stoppingScore(cuts["oneChunk"]!, gold: gold) == ["net": 2, "lcp": 2, "saved": 2])
    #expect(LabUpperBound.stoppingScore(cuts["twoChunks"]!, gold: gold) == ["net": 4, "lcp": 4, "saved": 4])
    #expect(LabUpperBound.stoppingScore(cuts["sentence"]!, gold: gold) == ["net": 1, "lcp": 4, "saved": 0])
    #expect(LabUpperBound.stoppingScore(text, gold: gold) == ["net": -3, "lcp": 4, "saved": 0])
    let rows = (0..<12).map { upperRow(Double($0 * 1000), gold) }
    let report = try await LabUpperBound.measure(commits: rows, completionStatus: "E4B", generate: { items in
        items.map { _ in [.init(text: text, logProb: -0.9)] }
    })
    let group = try #require(report.group(position: "start", tier: "production"))
    #expect(group.bestStopping == "twoChunks")
    #expect(group.stopping["twoChunks"]?.totals["net"] == 48)
    #expect(group.stopping["twoChunks"]?.totals["saved"] == 48)
    #expect(group.shadow["retrieve"]?["default"]?.totals["shown"] == 0)
    #expect(group.shadow["retrieve"]?["-1.0"]?.totals["shown"] == 12)
    #expect(group.shadow["retrieve"]?["none"]?.totals["wrong"] == 12)
}

@Test func upperBoundShadowShowsSavingsThatTheDefaultThresholdHides() async throws {
    let text = "確認しました。"
    let rows = (0..<12).map { upperRow(Double($0 * 1000), text) }
    let report = try await LabUpperBound.measure(commits: rows, completionStatus: "E4B", generate: { items in
        items.map { _ in [.init(text: text, logProb: -1.2)] }
    })
    let group = try #require(report.group(position: "start", tier: "production"))
    #expect(group.shadow["retrieve"]?["default"]?.totals["saved"] == 0)
    #expect(group.shadow["retrieve"]?["-1.0"]?.totals["shown"] == 0)
    #expect(group.shadow["retrieve"]?["-1.5"]?.totals["saved"] == 84)
    #expect(group.shadow["retrieve"]?["-2.0"]?.totals["saved"] == 84)
    #expect(group.shadow["retrieve"]?["none"]?.totals["saved"] == 84)
    #expect(group.completion["retrieve"]?.totals["hiddenLcp"] == 84)
}

@Test func upperBoundSceneInventoryIsCountedWithoutCopyingAnyText() async throws {
    var rows = upperFixture()
    rows[1].first = "異なる表記"
    rows[1].left = "文脈"
    var auxiliary = LabUpperBound.Auxiliary()
    auxiliary.rewrites[upperScene] = 2; auxiliary.totalRewrites = 2
    auxiliary.pauses[upperScene] = 3; auxiliary.totalPauses = 3
    auxiliary.phrases[upperScene] = 4
    auxiliary.pauses["pause-only|line|new|-"] = 2
    let report = try await LabUpperBound.measure(commits: rows, auxiliary: auxiliary)
    let row = try #require(report.scenes.first { $0.scene == upperScene })
    #expect(row.commits == 10 && row.nonDefault == 1 && row.emptyLeft == 9)
    #expect(row.kinds["normal"] == 5 && row.kinds["ai"] == 1 && row.kinds["completion"] == 1)
    #expect(row.rewrites == 2 && row.pauses == 3 && row.commitsPerDay == 10)
    #expect(row.inventory["phrases"]?.available == 4 && row.inventory["phrases"]?.optimisticDays == 1.6)
    #expect(row.inventory["rewrite"]?.optimisticDays == 0.1)
    let pauseOnly = try #require(report.scenes.first { $0.scene == "pause-only|line|new|-" })
    #expect(pauseOnly.commits == 0 && pauseOnly.pauses == 2 && pauseOnly.commitsPerDay == 0)
    #expect(pauseOnly.inventory["closing"]?.optimisticDays == nil)
    let json = String(decoding: try report.canonicalJSON(), as: UTF8.self)
    for secret in ["甲乙丙丁", "未未来来", "異なる表記", "文脈"] { #expect(!json.contains(secret)) }
}

@Test func upperBoundIsDeterministicAndNeverEntersTheAdoptionBranch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let names = ["versions.json", "last.json", "parameters.json", "personal.sqlite", "exemplars.json", "dictionary.json"]
    for name in names { try Data("unchanged".utf8).write(to: root.appendingPathComponent(name)) }
    let first = try await LabUpperBound.measure(commits: upperFixture())
    let second = try await LabUpperBound.measure(commits: upperFixture())
    #expect(try first.canonicalJSON() == second.canonicalJSON())
    var measured = false, adopted = false
    LabJobKind.upperBound.finish(upperBound: {
        measured = true
        try? first.canonicalJSON().write(to: root.appendingPathComponent("last-upper-bound.json"))
    }, analysis: {
        adopted = true
        for name in names { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
    })
    #expect(measured && !adopted)
    for name in names { #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data("unchanged".utf8)) }
    // 上限の結果は、通常のLab採否としても読めない。
    let outcome = LabOutcome.decide(exitStatus: 0, stopReason: nil, resultData: try first.canonicalJSON(),
                                    runID: "run", snapshotID: "snapshot", split: 0, baseline: .defaults)
    guard case .failed = outcome else { Issue.record("測定結果が採否の入力になった"); return }
}

@Test func upperBoundRejectsMissingReplayPositionsAndKeepsE2bColumnsEmpty() async throws {
    await #expect(throws: (any Error).self) {
        _ = try await LabUpperBound.measure(commits: upperFixture(), generate: { _ in [] })
    }
    let report = try await LabUpperBound.measure(commits: upperFixture(), completionStatus: "E2B-skipped")
    #expect(report.replay.isEmpty)
    #expect(report.groups.allSatisfy { $0.completion.isEmpty && $0.shadow.isEmpty && $0.stopping.isEmpty })
}

@Test func upperBoundFingerprintsUseTheSameCharacterBigramF1() {
    for a in ["", "あ", "ＡＢ", "あいう", "あああ", "😀あ"] {
        for b in ["", "い", "AB", "あうい", "ああ", "😀い"] {
            #expect(LabMagic.f1(a, b) == LabMagic.f1(LabMagic.Fingerprint(a), LabMagic.Fingerprint(b)))
        }
    }
    #expect(LabMagic.f1("甲乙戊己。", "甲乙丙丁。") == 0.25)
}

@Test func upperBoundCapsEachE4bPositionTypeAtTheNewestThreeHundred() async throws {
    let rows = (0..<312).map { upperRow(Double($0 * 1000), "今日は予定を確認しました。") }
    let calls = UpperBoundReplayCalls()
    let report = try await LabUpperBound.measure(commits: rows, completionStatus: "E4B", generate: { items in
        await calls.record(items.count)
        return items.map { _ in [.init(text: "確認", logProb: -0.1)] }
    })
    #expect(await calls.result() == [1200])
    #expect(report.positions == ["mid": 312, "start": 312])
    #expect(report.replay.count == 1200)
    #expect(report.replay.allSatisfy { $0.index >= 12 })
    for type in ["mid", "start"] {
        #expect(report.group(position: type, tier: "production")?.completion["retrieve"]?.count == 300)
        #expect(report.group(position: type, tier: "global")?.oracle.count == 312)
        #expect(report.group(position: type, tier: "global", subset: "matched")?.oracle.count == 300)
    }
    #expect(report.groups.contains { $0.subset == "body" && $0.position == "start" && $0.oracle.count == 312 })
}

@Test func upperBoundReadsOnlySnapshotCountsAndDoesNotWriteSidecars() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try PersonalStore(url: root.appendingPathComponent("source.sqlite"))
    var histogram = PersonalRhythm.Histogram()
    histogram.total = 3; histogram.counts[0] = 3
    let encoded = String(decoding: try JSONEncoder().encode(histogram), as: UTF8.self)
    try source.queue.sync {
        try source.execute("INSERT INTO pauses(level,json) VALUES(?,?)", [.text(upperScene), .text(encoded)])
        try source.execute("INSERT INTO pauses(level,json) VALUES('global',?)", [.text(encoded)])
        try source.execute("INSERT INTO rewrites(ts,scene,deleted,written) VALUES(1,?,'秘密の読み','秘密の表記')", [.text(upperScene)])
        try source.execute("INSERT INTO lexicon(scene,app,reading,surface,count,last) VALUES(?,'editor','ごく','確認しました',3,1)", [.text(upperScene)])
        try source.snapshot(to: root.appendingPathComponent("snapshot.sqlite"))
    }
    let snapshot = root.appendingPathComponent("snapshot.sqlite")
    let bytes = try Data(contentsOf: snapshot)
    let info = try FileManager.default.attributesOfItem(atPath: snapshot.path)
    let auxiliary = try LabSnapshot.readUpperBoundAuxiliary(url: snapshot)
    #expect(auxiliary.totalPauses == 3 && auxiliary.totalRewrites == 1)
    #expect(auxiliary.rewrites[upperScene] == 1 && auxiliary.phrases[upperScene] == 1)
    #expect(try Data(contentsOf: snapshot) == bytes)
    #expect(try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date == info[.modificationDate] as? Date)
    #expect(!FileManager.default.fileExists(atPath: snapshot.path + "-wal"))
    #expect(!FileManager.default.fileExists(atPath: snapshot.path + "-shm"))
}

@Test func upperBoundQuoteSavingsUseTheSameFollowingTextAsCompletionOutcome() async throws {
    let rows = [upperRow(0, "甲乙戊己。"), upperRow(1, "甲乙丙丁。"), upperRow(1000, "甲乙"),
                upperRow(1001, "甲乙"), upperRow(1002, "丙丁。")]
    let report = try await LabUpperBound.measure(commits: rows, limit: 2)
    let group = try #require(report.group(position: "start", tier: "production"))
    // 内容のF1は当該確定だけ。LCPと節約文字はE4Bと同じgold（後続の確定を含む）。
    #expect(group.retrieval.totals["saved"] == 5)
    #expect(group.retrieval.totals["lcp"] == 5)
    #expect(group.retrieval.totals["top1F1"] == 0)
}

@Test func upperBoundInspectionExposesOnlyHashesAndCountsAndExcludesItsResultAndRuns() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data("見せない本文".utf8).write(to: root.appendingPathComponent("last.json"))
    let first = LabUpperBound.inspection(directory: root)
    #expect(first.unreadable == 0 && first.protectedFiles.count == 1)
    let result = Data("{\"count\":12}\n".utf8)
    try result.write(to: root.appendingPathComponent("last-upper-bound.json"))
    let run = root.appendingPathComponent("runs/one/staging")
    try fm.createDirectory(at: run, withIntermediateDirectories: true)
    try Data("写しの本文".utf8).write(to: run.deletingLastPathComponent().appendingPathComponent("snapshot.sqlite"))
    try Data("{}".utf8).write(to: run.appendingPathComponent("result.json"))
    let next = LabUpperBound.inspection(directory: root, running: true)
    #expect(next.protectedFiles == first.protectedFiles)
    #expect(next.running && next.runFiles == 2 && next.snapshots == 1)
    #expect(next.resultHash == LabUpperBound.hash(result))
    let json = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
    #expect(!json.contains("本文") && !json.contains("last.json") && !json.contains("snapshot.sqlite"))
}
