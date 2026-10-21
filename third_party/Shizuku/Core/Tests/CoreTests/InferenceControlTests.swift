import Foundation
import Testing
import Gemma4ANE
@testable import Core

@Test func forwardChecksCancellationBetweenChunksAndAfterTheLastChunk() throws {
    var cancelled = false, visited: [Int] = []
    #expect(throws: CancellationError.self) {
        try Gemma4ChunkExecution.run(0..<4, isCancelled: { cancelled }) {
            visited.append($0)
            if $0 == 1 { cancelled = true }
        }
    }
    #expect(visited == [0, 1])
    visited = []; cancelled = false
    #expect(throws: CancellationError.self) {
        try Gemma4ChunkExecution.run([0], isCancelled: { cancelled }) { visited.append($0); cancelled = true }
    }
    #expect(visited == [0])
}
@Test func pendingKeysBoundTheWaitAndExcludeNewInference() {
    let gate = InferencePreemption()
    #expect(gate.enter())
    var requested: TimeInterval = 0, waited = false
    gate.waitOverride = { seconds in waited = true; requested = seconds; return false }
    #expect(!gate.beginKey(maxWait: 1))
    #expect(waited && requested == 0.008)
    #expect(gate.keyPending && !gate.enter())
    gate.endKey(); gate.leave()
    #expect(gate.enter()); gate.leave()
    #expect(gate.beginKey()); gate.endKey()
}
@Test func completedInferenceWakesTheKeyBeforeItsDeadline() {
    let gate = InferencePreemption()
    #expect(gate.enter())
    gate.waitOverride = { _ in gate.leave(); return true }
    defer { gate.waitOverride = nil }
    #expect(gate.beginKey())
    #expect(gate.keyPending)
    gate.endKey()
}
@Test func displayOnlyReplacesExtensionsAtBoundariesOrTwelveCharactersAndChangesAtTheFront() {
    #expect(!CompletionDisplayPolicy.shouldReplace("続きを", with: "続きを書き"))
    #expect(CompletionDisplayPolicy.shouldReplace("続きを", with: "続きを書く。"))
    #expect(CompletionDisplayPolicy.shouldReplace("続き", with: "続きを"))
    #expect(CompletionDisplayPolicy.shouldReplace("続き", with: "別の文"))
    #expect(CompletionDisplayPolicy.shouldReplace("あ", with: "あ" + String(repeating: "い", count: 12)))
    #expect(!CompletionDisplayPolicy.shouldReplace("あ", with: "あ" + String(repeating: "い", count: 11)))
}

@Test func activityCountsOnlyEnabledCurrentGenerationAndWritesNumbersWithoutText() throws {
    InferenceActivity.invalidate(); InferenceActivity.configure(enabled: true)
    defer { InferenceActivity.invalidate(); InferenceActivity.configure(enabled: true) }
    #expect(throws: CancellationError.self) {
        try InferenceActivity.measure(feature: "completion", device: "ANE") { throw CancellationError() }
    }
    #expect(InferenceActivity.snapshot.count == 1)
    let ticket = InferenceActivity.ticket()
    InferenceActivity.invalidate()
    InferenceActivity.report(feature: "completion", device: "ANE", milliseconds: 50, ticket: ticket)
    #expect(InferenceActivity.snapshot.isEmpty)
    InferenceActivity.configure(enabled: false)
    InferenceActivity.measure(feature: "idle", device: "ANE") {}
    #expect(InferenceActivity.snapshot.isEmpty)
    InferenceActivity.configure(enabled: true)
    InferenceActivity.measure(feature: "completion", device: "ANE") {}
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try InferenceActivity.save(to: file)
    let rows = try JSONDecoder().decode([InferenceActivity.Event].self, from: Data(contentsOf: file))
    #expect(rows.count == 1 && rows[0].device == "ANE" && rows[0].feature == "completion" && rows[0].milliseconds >= 0)
}
