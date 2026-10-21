import Testing
@testable import Core

@Test func idleGenerationIsOffOnlyWhenUnsetAndNeverOverridesAnExplicitChoice() {
    #expect(Config.NextTextCompletionIdle.resolved(nil) == false)
    #expect(Config.NextTextCompletionIdle.resolved(true) == true)
    #expect(Config.NextTextCompletionIdle.resolved(false) == false)
    #expect(Config.NextTextCompletionIdle.resolved("invalid") == false)
}
