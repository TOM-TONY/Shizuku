import Foundation
import Testing
@testable import Core

private func modelFixture(_ root: URL) throws -> LabModelStamp {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
    try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))
    try Data("tokenizer".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
    return try LabModelStamp.read(directory: root)
}

@Test func analystOnlyReadsTrainingAndRejectsInventedToolsAndPhrases() throws {
    let scene = "editor|short|new|-"
    let rows = [LabCommit(ts: 1, scene: scene, kind: "enter", reading: "かくにん", surface: "確認しました。", first: "確認", left: nil),
                LabCommit(ts: 3, scene: scene, kind: "enter", reading: "ひみつ", surface: "取り置きだけの文", first: nil, left: nil)]
    let data = LabAnalystData(train: LabTrainView(rows, split: LabSplit(split: 2)), topics: [], vectors: [:])
    #expect(!data.examples(scope: "*").contains("取り置き"))
    #expect(data.supports(.init(scope: scene, style: "です・ます調", phrases: ["確認"])))
    #expect(!data.supports(.init(scope: scene, style: "です・ます調", phrases: ["取り置き"])))
    for output in ["{\"tool\":\"shell\",\"command\":\"cat\"}", "{\"tool\":\"inspect\",\"sql\":\"SELECT *\"}",
                   "{\"tool\":\"examples\",\"scope\":\"unknown\"}", "{\"tool\":\"evaluate\",\"file\":\"/tmp/x\"}"] {
        #expect(throws: (any Error).self) { try LabAnalystCall.parse(output, scopes: data.scopes) }
    }
    let parsed = try LabAnalystCall.parse("{\"tool\":\"inspect\"}", scopes: data.scopes)
    #expect(parsed.tool == .inspect)
}

@Test func topicsAreDeterministicAndBackOffBeforeTheAppOnlyForMagic() throws {
    let topics = LabKnowledge.cluster(vectors: (0..<200).map { $0 < 100 ? [Float(1), 0] : [0, 1] })
    #expect(topics.count == 2)
    #expect(topics == LabKnowledge.cluster(vectors: (0..<200).map { $0 < 100 ? [Float(1), 0] : [0, 1] }))
    let corpus = PersonalCorpus()
    let scene = PersonalScene(key: "editor|short|new|-")!
    let sameApp = PersonalScene(key: "editor|line|new|-")!
    let otherApp = PersonalScene(key: "chat|short|new|-")!
    for (i, s) in [sameApp, sameApp, otherApp, otherApp].enumerated() {
        corpus.add(scene: s, text: "確認\(i)をお願いします。", ts: Double(i))
    }
    for item in corpus.sentencesWithoutVectors(limit: 10) {
        corpus.setVector(item.id < 2 ? [0, 1] : [1, 0], id: item.id, text: item.text)
    }
    let before = corpus.retrieve(query: "確認", scene: scene, excluding: "", queryVector: [1, 0]).map(\.app)
    corpus.magicTopics = topics
    #expect(corpus.retrieve(query: "確認", scene: scene, excluding: "", queryVector: [1, 0]).map(\.app) == before)
    #expect(corpus.retrieve(query: "確認", scene: scene, excluding: "", queryVector: [1, 0], useTopics: true).allSatisfy { $0.app == "chat" })
    corpus.remove(before: 2)
    #expect(corpus.sentences.allSatisfy { $0.ts >= 2 })
}

@Test func assetsRejectTamperingLinksAndHeldOutDatesAndRestoreAllFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try modelFixture(root.appendingPathComponent("model"))
    let staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let knowledge = LabKnowledge(model: model, cards: [.init(scope: "*", style: "です・ます調")])
    let url = staging.appendingPathComponent("knowledge.json")
    try JSONEncoder().encode(knowledge).write(to: url)
    let artifact = try LabArtifact.measure(kind: .knowledge, root: staging, dataFrom: 0, dataTo: 9)
    #expect(artifact.verified(root: staging, split: 10))
    #expect(!artifact.verified(root: staging, split: 9))
    let store = LabVersionStore(directory: root.appendingPathComponent("lab"))
    var parameters = LabParameters.defaults; parameters.knowledgeID = artifact.digest
    let decision = LabGate.decide(items: [.init(day: 1, diffs: ["f1": 1])], rules: [], seed: 1)
    let result = LabRunResult(runID: "r", snapshotID: "s", split: 10, status: .candidate, baseline: .defaults, candidate: parameters,
                             seed: 1, items: [], decision: nil, counts: [:], skipped: [], notes: [], dataFrom: 0, dataTo: 20,
                             elapsed: 1, artifacts: [artifact])
    try store.adopt(result: result, candidate: parameters, decision: decision, staging: staging, note: "")
    #expect(store.currentAsset(.knowledge) != nil)
    var next = parameters; next.sceneThreshold = 3
    var numeric = result; numeric.artifacts = []; numeric.baseline = parameters
    try store.adopt(result: numeric, candidate: next, decision: decision, staging: staging, note: "")
    #expect(store.currentAsset(.knowledge) != nil)
    try store.undo()
    #expect(store.appliedParameters == parameters)
    try store.export(to: root.appendingPathComponent("export"))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("export/versions/1/knowledge.json").path))
    try Data("tampered".utf8).write(to: url)
    #expect(!artifact.verified(root: staging, split: 10))
    #expect(throws: (any Error).self) { try store.adopt(result: result, candidate: parameters, decision: decision, staging: staging, note: "") }
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("model/config.json"))
    #expect(throws: (any Error).self) { try LabArtifact.measure(kind: .knowledge, root: staging, dataFrom: 0, dataTo: 1) }
    try store.invalidateTextArtifacts()
    #expect(store.currentVersion == 0)
    #expect(store.allVersions().allSatisfy { $0.invalid })
    #expect(!FileManager.default.fileExists(atPath: store.folder(of: 1).appendingPathComponent("knowledge.json").path))
}

@Test func modelStampDetectsDifferentWeightsAndMagicGateNeedsPairedLatencyAndEnoughDays() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try modelFixture(root)
    #expect(stamp.matches(directory: root))
    try Data("changed weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))
    #expect(!stamp.matches(directory: root))
    let baseline = LabParameters.defaults
    var candidate = baseline; candidate.knowledgeID = String(repeating: "a", count: 64)
    var result = LabRunResult(runID: "r", snapshotID: "s", split: 100, status: .candidate, baseline: baseline, candidate: candidate,
                             seed: 1, items: (0..<70).map { .init(day: $0 / 5, diffs: ["f1": 0.1, "magicTime": 0]) },
                             decision: nil, counts: [:], skipped: [], notes: [], dataFrom: 0, dataTo: 90, elapsed: 1)
    #expect(LabRules.verify(result, runID: "r", snapshotID: "s", split: 100, baseline: baseline) != nil)
    result.items = (0..<70).map { .init(day: $0 / 5, diffs: ["f1": 0.1]) }
    #expect(LabRules.verify(result, runID: "r", snapshotID: "s", split: 100, baseline: baseline) == nil)
    result.items = (0..<70).map { _ in .init(day: 1, diffs: ["f1": 0.1, "magicTime": 0]) }
    #expect(LabRules.verify(result, runID: "r", snapshotID: "s", split: 100, baseline: baseline) == nil)
    #expect(LabMagic.f1("確認", "確認") == 1 && LabMagic.f1("確認", "終了") == 0)
    #expect(baseline.merging(lexicon: baseline, corpus: LabParameters(semanticWeight: 1)).semanticWeight == 1)
}
