import Foundation
import Testing
@testable import Core

@Test func microphoneGateUsesOnlyAnOpenObservedIntervalAndExpiresAtThirtyMinutes() {
    var environment = PersonalEnvironment()
    let scene = PersonalScene(app: "editor", shape: .line, mode: .new, reply: false)
    #expect(!environment.microphoneIsActive(now: 1))
    environment.configure(enabled: true, scene: scene)
    _ = environment.observeMicrophone(running: true, now: 10)
    #expect(environment.microphoneIsActive(now: 10))
    #expect(environment.microphoneIsActive(now: 1810))
    #expect(!environment.microphoneIsActive(now: 1810.001))
    _ = environment.observeMicrophone(running: true, now: 2000)
    #expect(!environment.microphoneIsActive(now: 2000))
    _ = environment.observeMicrophone(running: false, now: 2010)
    #expect(!environment.microphoneIsActive(now: 2010))
    _ = environment.observeMicrophone(running: true, now: 2020)
    #expect(environment.microphoneIsActive(now: 2021))
    environment.configure(enabled: false, scene: nil)
    #expect(!environment.microphoneIsActive(now: 2021))
}

@Test @MainActor func microphoneIsCheckedWhenQueuedGenerationStartsAndRefinementCanStillContinue() async {
    var microphone = false, generated = false, refined = false
    let task = Task { @MainActor in
        let value: String? = await AutomaticGenerationGate.generate(microphoneActive: { microphone }) {
            generated = true
            return "generated"
        }
        refined = true
        return value
    }
    microphone = true
    #expect(await task.value == nil)
    #expect(!generated && refined)
    microphone = false
    let value = await AutomaticGenerationGate.generate(microphoneActive: { microphone }) { "generated" }
    #expect(value == "generated")
}

@Test func microphoneHidesGenerationOnCachedRetriesAndPreservesEveryOtherResponseByte() throws {
    var snapshot = ConverterSessionSnapshot.empty
    snapshot.isEmpty = false
    snapshot.convertTarget = "test"
    snapshot.candidateWindow = .composing([.init(text: "candidate")], selectionIndex: 0)
    snapshot.predictionCandidates = [.init(displayText: "correction", appendText: "fixed")]
    snapshot.nextTextCompletion = "generated"
    var response = ConverterServerResponse(effects: [.insertText("committed")], inputState: .composing,
                                           snapshot: snapshot, localLLMResult: .init(text: "explicit"))
    response.idleCompletionDelay = 3
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(AutomaticGenerationGate.response(response, microphoneActive: false)) == encoder.encode(response))
    let muted = AutomaticGenerationGate.response(response, microphoneActive: true)
    #expect(muted.snapshot.nextTextCompletion == nil)
    let retryAfterUnmuting = AutomaticGenerationGate.response(muted, microphoneActive: false)
    #expect(retryAfterUnmuting.snapshot.nextTextCompletion == nil)
    var restored = muted
    restored.snapshot.nextTextCompletion = response.snapshot.nextTextCompletion
    #expect(try encoder.encode(restored) == encoder.encode(response))
    #expect(response.snapshot.nextTextCompletion == "generated")
}
