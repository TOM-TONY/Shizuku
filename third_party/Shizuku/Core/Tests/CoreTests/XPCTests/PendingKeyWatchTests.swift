import Core
import Foundation
import Testing

@Test func pendingKeyWatchIsIdleUntilAKeyWaits() {
    let watch = PendingKeyWatch(limit: 3)
    #expect(watch.remaining(at: 100) == nil)
    #expect(!watch.isStalled(at: 100))
    #expect(watch.waited(at: 100) == 0)
}

@Test func pendingKeyWatchStallsOnlyAfterTheLimitWithoutAnAnswer() {
    var watch = PendingKeyWatch(limit: 3)
    watch.keyQueued(at: 10)
    // Later keys behind the first one do not restart the clock.
    watch.keyQueued(at: 11)
    watch.keyQueued(at: 12)
    #expect(watch.remaining(at: 12) == 1)
    #expect(!watch.isStalled(at: 12.9))
    #expect(watch.isStalled(at: 13))
    #expect(watch.waited(at: 14) == 4)
}

@Test func pendingKeyWatchRestartsOnEachAnswerWhileKeysRemain() {
    var watch = PendingKeyWatch(limit: 3)
    watch.keyQueued(at: 10)
    // A slow but answering Server is not a stall: every answer restarts the clock.
    watch.keyAnswered(at: 12.5, stillPending: true)
    #expect(!watch.isStalled(at: 15))
    #expect(watch.isStalled(at: 15.5))
    watch.keyAnswered(at: 15.4, stillPending: false)
    #expect(watch.remaining(at: 20) == nil)
    #expect(!watch.isStalled(at: 20))
}

@Test func pendingKeyWatchResetStopsTheClock() {
    var watch = PendingKeyWatch(limit: 3)
    watch.keyQueued(at: 10)
    watch.reset()
    #expect(!watch.isStalled(at: 100))
    watch.keyQueued(at: 100)
    #expect(watch.remaining(at: 101) == 2)
}
