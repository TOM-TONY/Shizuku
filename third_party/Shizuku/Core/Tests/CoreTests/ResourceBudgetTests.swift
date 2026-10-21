import Foundation
import Testing
@testable import Core

@Test func resourceTableUsesMemoryBandsAndPreservesExplicitCompletionChoice() {
    let full = ResourceBudget.resolve(.init(memoryGB: 128))
    #expect(full.completion == "gemma4-e4b-ane" && full.idleSentences == 3 && full.allow12B && full.allow31B && full.replay)
    let medium = ResourceBudget.resolve(.init(memoryGB: 16))
    #expect(medium.completion == "gemma4-e4b-ane" && !medium.allow12B && !medium.allow31B)
    let small = ResourceBudget.resolve(.init(memoryGB: 8))
    #expect(small.completion == "gemma4-e2b-ane" && small.idleSentences == 1)
    #expect(ResourceBudget.completion(powerSaving: false, selected: "chosen", tier: small) == "chosen")
    #expect(ResourceBudget.resolve(.init(memoryGB: 24)).allow12B)
    #expect(!ResourceBudget.resolve(.init(memoryGB: 24)).allow31B)
    for environment in [ResourceBudget.Environment(onAC: false, battery: 0.1, memoryGB: 128), .init(lowPower: true, memoryGB: 128), .init(thermal: 2, memoryGB: 128)] {
        let tier = ResourceBudget.resolve(environment)
        #expect(tier.completion == "gemma4-e2b-ane" && !tier.replay && tier.idleSentences == 1)
    }
}

@Test @MainActor func resourceMillisecondsAreNumericDailyReactionsAndFollowExportRetentionAndDeletion() async throws {
    let directory = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? Foundation.FileManager.default.removeItem(at: directory) }
    let store = try PersonalStore(url: directory.appendingPathComponent("personal.sqlite"))
    let learner = PersonalLearner(storeURL: nil); learner.attachStoreForTesting(store)
    learner.recordResourceUsage(feature: "completion", device: "ANE", milliseconds: 123.4)
    learner.flush()
    #expect(try store.scalarInt("SELECT SUM(n) FROM reactions WHERE kind='resource_ms'") == 123)
    #expect(learner.resourceUsageSummary().contains("ANE completion 123 ms"))
    let exported = try learner.export(to: directory.appendingPathComponent("export.jsonl"))
    #expect(try String(contentsOf: exported, encoding: .utf8).contains("resource_ms"))
    learner.deleteAll(); learner.flush()
    #expect(learner.resourceUsageSummary() == "推論API時間 0 ms")
    try await Task.sleep(for: .milliseconds(30)); learner.flush()
}

@Test func idleSentenceBudgetRestartsAfterTheClientStopsOrAcceptsWithoutARecordedReaction() {
    var budget = IdleSentenceBudget()
    let first = budget.permits(contextHash: "a", limit: 1)
    #expect(first)
    budget.emitted(nextContextHash: "b")
    let second = budget.permits(contextHash: "b", limit: 1)
    #expect(!second)
    let afterTabWithoutReaction = budget.permits(contextHash: "b", limit: 1)
    #expect(afterTabWithoutReaction)
    budget.emitted(nextContextHash: "c")
    budget.reset()
    for (current, next) in [("a", "b"), ("b", "c"), ("c", "d")] {
        let allowed = budget.permits(contextHash: current, limit: 3)
        #expect(allowed)
        budget.emitted(nextContextHash: next)
    }
    let afterThreeSentences = budget.permits(contextHash: "d", limit: 3)
    #expect(afterThreeSentences)
}
