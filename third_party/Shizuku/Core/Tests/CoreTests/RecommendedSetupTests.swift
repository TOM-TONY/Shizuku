import Foundation
import Testing
@testable import Core

private func model(_ name: String, _ kind: ModelCatalog.Kind, problem: String? = nil, warning: String? = nil) -> ModelCatalog.Model {
    .init(name: name, kind: kind, displayName: name, detail: "", bytes: 1, problem: problem, warning: warning)
}

private let allModels = [
    model("gemma4-e4b-ane", .completion), model("gemma4-e2b-ane", .completion),
    model("gemma4-12b-it-mlx", .chat), model("gemma4-31b-it-mlx", .chat), model("ruri-v3-30m-coreml", .embedding),
]

/// 書き込みを辞書へ受ける（普段の設定には触れない）
private final class Store {
    var values: [String: Any] = [:]
    func write(_ key: String, _ value: Any?) { self.values[key] = value }
    func run(plan: RecommendedSetup.Plan) -> RecommendedSetup.FirstRunOutcome {
        RecommendedSetup.applyOnFirstRun(
            plan: { plan }, storedKeys: { Array(self.values.keys) }, read: { self.values[$0] }, write: self.write
        )
    }
}

@Test func recommendedModelsFollowMemoryBands() {
    func plan(_ memory: Int) -> RecommendedSetup.Plan {
        RecommendedSetup.plan(memoryGB: memory, models: allModels, foundationModelsAvailable: false)
    }
    #expect(plan(8).completionModel == "gemma4-e2b-ane" && plan(8).chatModel == nil && plan(8).backend == .off)
    #expect(plan(16).completionModel == "gemma4-e4b-ane" && plan(16).chatModel == nil && plan(16).backend == .off)
    #expect(plan(24).completionModel == "gemma4-e4b-ane" && plan(24).chatModel == "gemma4-12b-it-mlx" && plan(24).backend == .localLLM)
    #expect(plan(36).chatModel == "gemma4-12b-it-mlx")
    #expect(plan(64).chatModel == "gemma4-31b-it-mlx" && plan(128).chatModel == "gemma4-31b-it-mlx")
}

@Test func recommendedModelsUseWhatIsInstalled() {
    let onlyE4B = RecommendedSetup.plan(memoryGB: 8, models: [model("gemma4-e4b-ane", .completion)], foundationModelsAvailable: false)
    #expect(onlyE4B.completionModel == "gemma4-e4b-ane")
    // 64 GB でも 31B がなければ 12B
    let no31B = RecommendedSetup.plan(memoryGB: 64, models: [model("gemma4-12b-it-mlx", .chat)], foundationModelsAvailable: false)
    #expect(no31B.chatModel == "gemma4-12b-it-mlx" && no31B.completionModel == nil)
    // メモリが足りないモデルしかなければ選ばない
    let tooLarge = RecommendedSetup.plan(memoryGB: 24, models: [model("gemma4-31b-it-mlx", .chat)], foundationModelsAvailable: false)
    #expect(tooLarge.chatModel == nil && tooLarge.backend == .off)
    // 使えないモデルは数えない
    let broken = RecommendedSetup.plan(memoryGB: 128, models: [model("gemma4-e4b-ane", .completion, problem: "x"), model("gemma4-31b-it-mlx", .chat, problem: "x")], foundationModelsAvailable: false)
    #expect(!broken.hasAnyModel)
}

@Test func recommendedChatFallsBackToPlacedModelsAndFoundationModels() {
    let placed = RecommendedSetup.plan(memoryGB: 16, models: [model("Qwen3-8B-4bit", .chat), model("Huge-4bit", .chat, warning: "x")], foundationModelsAvailable: true)
    #expect(placed.chatModel == "Qwen3-8B-4bit" && placed.backend == .localLLM)
    let warned = RecommendedSetup.plan(memoryGB: 16, models: [model("Huge-4bit", .chat, warning: "x")], foundationModelsAvailable: false)
    #expect(warned.chatModel == nil && warned.backend == .off)
    let foundation = RecommendedSetup.plan(memoryGB: 16, models: allModels, foundationModelsAvailable: true)
    #expect(foundation.chatModel == nil && foundation.backend == .foundationModels)
}

@Test func recommendedChangesKeepCompletionAutomaticAndLeavePrivacyAlone() throws {
    let plan = RecommendedSetup.plan(memoryGB: 64, models: allModels, foundationModelsAvailable: false)
    let changes = RecommendedSetup.changes(for: plan)
    let values = Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.value) })
    #expect(values[Config.NextTextCompletion.key] as? Bool == true)
    #expect(values[Config.NextTextCompletionIdle.key] as? Bool == true)
    #expect(values[Config.NextTextCompletionModel.key] as? String == "")
    #expect(values[Config.LocalLLMModel.key] as? String == "gemma4-31b-it-mlx")
    #expect(values.keys.contains(Config.LocalLLMLargeModel.key) && values[Config.LocalLLMLargeModel.key]! == nil)
    let backend = try #require(values[Config.AIBackendPreference.key] as? Data)
    #expect(try JSONDecoder().decode(Config.AIBackendPreference.Value.self, from: backend) == .localLLM)
    #expect(values[AssistanceSettings.contentKey] as? String == "body")
    #expect(values[AssistanceSettings.timingKey] as? String == "custom")
    for key in [Config.PersonalLearning.key, Config.PersonalLearningPaused.key, Config.WindowContextEnabled.key, AssistanceSettings.memoryKey] {
        #expect(!values.keys.contains(key))
    }

    let without = RecommendedSetup.changes(for: .init(memoryGB: 8, completionModel: nil, chatModel: nil, backend: .off))
    let off = Dictionary(uniqueKeysWithValues: without.map { ($0.key, $0.value) })
    #expect(off[Config.NextTextCompletion.key] as? Bool == false)
    #expect(off[AssistanceSettings.timingKey] as? String == "called")
    #expect(!off.keys.contains(AssistanceSettings.contentKey))
}

@Test func recommendedSummaryNamesTheChoices() {
    let plan = RecommendedSetup.plan(memoryGB: 24, models: allModels, foundationModelsAvailable: false)
    #expect(plan.summary.contains("24 GB") && plan.summary.contains("Gemma 4 E4B") && plan.summary.contains("Gemma 4 12B"))
    let small = RecommendedSetup.plan(memoryGB: 8, models: allModels, foundationModelsAvailable: false)
    #expect(small.summary.contains("Gemma 4 E2B") && small.summary.contains("いい感じ変換 オフ"))
}

@Test func firstRunAppliesOnlyOnFreshInstall() {
    let plan = RecommendedSetup.plan(memoryGB: 24, models: allModels, foundationModelsAvailable: false)
    let fresh = Store()
    // 初回判断に関係しないキーがあっても新規として扱う
    fresh.values["dev.tomonari.inputmethod.Shizuku.migration.preferencesFromAzooKey"] = true
    #expect(fresh.run(plan: plan) == .applied)
    #expect(fresh.values[Config.NextTextCompletion.key] as? Bool == true)
    #expect(fresh.values[Config.LocalLLMModel.key] as? String == "gemma4-12b-it-mlx")
    // 2 回目は本人が変えた値を上書きしない
    fresh.values[Config.NextTextCompletion.key] = false
    #expect(fresh.run(plan: plan) == .alreadyDone)
    #expect(fresh.values[Config.NextTextCompletion.key] as? Bool == false)
}

@Test func firstRunKeepsExistingSettings() {
    let plan = RecommendedSetup.plan(memoryGB: 128, models: allModels, foundationModelsAvailable: false)
    let existing = Store()
    existing.values[AssistanceSettings.migrationKey] = 1
    #expect(existing.run(plan: plan) == .keptExisting)
    #expect(existing.values[Config.NextTextCompletion.key] == nil && existing.values[Config.LocalLLMModel.key] == nil)
    #expect(existing.run(plan: plan) == .alreadyDone)

    let manual = Store()
    manual.values["hasSetAIBackendManually"] = true
    #expect(manual.run(plan: plan) == .keptExisting)
    #expect(manual.values[Config.AIBackendPreference.key] == nil)
}

@Test func firstRunWaitsForModelsAcrossLaunches() {
    let empty = RecommendedSetup.Plan(memoryGB: 16, completionModel: nil, chatModel: nil, backend: .off)
    let ready = RecommendedSetup.plan(memoryGB: 16, models: allModels, foundationModelsAvailable: false)
    let store = Store()
    #expect(store.run(plan: empty) == .waitingForModels)
    #expect(store.values[Config.NextTextCompletion.key] == nil)
    // 起動時の移行が書いたキーは本人の選択として数えない
    store.values[AssistanceSettings.timingKey] = "custom"
    store.values[AssistanceSettings.migrationKey] = 1
    #expect(store.run(plan: empty) == .waitingForModels)
    #expect(store.run(plan: ready) == .applied)
    #expect(store.values[Config.NextTextCompletion.key] as? Bool == true)

    let chose = Store()
    #expect(chose.run(plan: empty) == .waitingForModels)
    chose.values[Config.NextTextCompletion.key] = false
    #expect(chose.run(plan: ready) == .keptExisting)
    #expect(chose.values[Config.NextTextCompletion.key] as? Bool == false)
}
