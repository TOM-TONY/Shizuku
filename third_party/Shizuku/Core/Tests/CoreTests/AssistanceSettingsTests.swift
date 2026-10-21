import Foundation
import Testing
@testable import Core

@Test func assistanceMigrationPreservesEveryLegacyValueAndRunsOnlyOnce() {
    let prefix = "dev.tomonari.inputmethod.Shizuku.preference."
    var stored: [String: Any] = [
        prefix + "nextTextCompletion": true, prefix + "nextTextCompletion.idle": false,
        prefix + "nextTextCompletion.powerSaving": true, prefix + "personalLearning": true,
        prefix + "personalLearning.selfTuning": true, prefix + "personalLearning.paused": false,
        prefix + "lab.nightly": true, "test.idleDelay": 3.0,
    ]
    let before = stored as NSDictionary
    let legacy = AssistanceSettings.Legacy(completion: true, idle: false, learning: true, paused: false)
    let migrated = AssistanceSettings.migrate(legacy: legacy, read: { stored[$0] }, write: { stored[$0] = $1 })
    #expect(migrated)
    for (key, value) in before { #expect((stored[key as! String] as AnyObject).isEqual(value)) }
    #expect(stored[AssistanceSettings.timingKey] as? String == "typing")
    #expect(stored[AssistanceSettings.contentKey] as? String == "patterns")
    #expect(stored[AssistanceSettings.memoryKey] as? String == "local")
    #expect(AssistanceSettings.legacy(after: .typing, previous: legacy) == legacy)
    #expect(AssistanceSettings.legacy(after: AssistanceSettings.Memory.local, previous: legacy) == legacy)
    stored[AssistanceSettings.contentKey] = "past"
    let repeated = AssistanceSettings.migrate(legacy: legacy, read: { stored[$0] }, write: { stored[$0] = $1 })
    #expect(!repeated)
    #expect(stored[AssistanceSettings.contentKey] as? String == "past")
}

@Test func assistanceLegacyCustomStatesRemainCustomAndExplicitAxesUseTheTable() {
    let old = AssistanceSettings.Legacy(completion: true, idle: true, learning: true, paused: true)
    let initial = AssistanceSettings.initial(old)
    #expect(initial.0 == .custom && initial.1 == .body && initial.2 == .paused)
    #expect(AssistanceSettings.legacy(after: .custom, previous: old) == old)
    for row in AssistanceSettings.timingTable {
        let next = AssistanceSettings.legacy(after: row.timing, previous: old)
        #expect(next.completion == row.completion && next.idle == row.idle)
        #expect(next.learning == old.learning && next.paused == old.paused)
    }
    let local = AssistanceSettings.legacy(after: AssistanceSettings.Memory.local, previous: old)
    #expect(local.learning && !local.paused)
    let none = AssistanceSettings.legacy(after: AssistanceSettings.Memory.none, previous: old)
    #expect(!none.learning && none.paused)
}

@Test func assistanceContentGateMatchesQuoteCompletionAndBodyLevelsWithoutChangingExplicitCalls() {
    #expect(AssistanceSettings.permits(.skeleton, timing: .typing, content: .past))
    #expect(!AssistanceSettings.permits(.completion, timing: .typing, content: .past))
    #expect(AssistanceSettings.permits(.completion, timing: .typing, content: .patterns))
    #expect(!AssistanceSettings.permits(.idle, timing: .typing, content: .patterns))
    #expect(AssistanceSettings.permits(.idle, timing: .stopped, content: .body))
    #expect(!AssistanceSettings.permits(.completion, timing: .stopped, content: .body))
    #expect(!AssistanceSettings.permits(.skeleton, timing: .called, content: .body))
    #expect(AssistanceSettings.permits(.skeleton, timing: .called, content: .past, automatic: false))
    #expect(!AssistanceSettings.permits(.completion, timing: .typing, content: .body, tab: .yield))
    #expect(AssistanceSettings.permits(.completion, timing: .typing, content: .patterns, tab: .keep))
}
