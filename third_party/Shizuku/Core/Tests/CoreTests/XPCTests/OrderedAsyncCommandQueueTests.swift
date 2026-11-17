import Core
import Testing

@MainActor
@Test func orderedQueueWaitsForEachReplyAndPreservesCompletionOrder() {
    let queue = OrderedAsyncCommandQueue<Int>()
    var finishes: [OrderedAsyncCommandQueue<Int>.Finish] = []
    var completed: [Int] = []

    for _ in 1...3 {
        queue.enqueue(
            operation: { finish in
                finishes.append(finish)
            },
            completion: { completed.append($0) }
        )
    }

    #expect(queue.count == 3)
    #expect(finishes.count == 1)

    finishes[0](.finish(1))
    #expect(completed == [1])
    #expect(finishes.count == 2)

    finishes[1](.finish(2))
    #expect(completed == [1, 2])
    #expect(finishes.count == 3)

    finishes[2](.finish(3))
    #expect(completed == [1, 2, 3])
    #expect(queue.count == 0)
}

@MainActor
@Test func orderedQueueRetainsHeadCommandAcrossRetry() {
    var scheduledRetry: (@MainActor @Sendable () -> Void)?
    let queue = OrderedAsyncCommandQueue<Int>(scheduleRetry: { action in
        scheduledRetry = action
    })
    var attempts = 0
    var finishCurrentAttempt: OrderedAsyncCommandQueue<Int>.Finish?
    var completed: [Int] = []

    queue.enqueue(
        operation: { finish in
            attempts += 1
            finishCurrentAttempt = finish
        },
        completion: { completed.append($0) }
    )

    finishCurrentAttempt?(.retry)
    #expect(queue.count == 1)
    #expect(completed.isEmpty)
    #expect(attempts == 1)

    scheduledRetry?()
    #expect(attempts == 2)

    finishCurrentAttempt?(.finish(7))
    #expect(completed == [7])
    #expect(queue.count == 0)
}

@MainActor
@Test func orderedQueueTimesOutAndIgnoresLateReply() {
    var scheduledTimeout: (@MainActor @Sendable () -> Void)?
    let queue = OrderedAsyncCommandQueue<Int>(scheduleTimeout: { _, action in
        scheduledTimeout = action
    })
    var firstFinish: OrderedAsyncCommandQueue<Int>.Finish?
    var didStartSecondOperation = false
    var completed: [Int] = []
    var timeoutCount = 0

    queue.enqueue(
        timeout: 1,
        timeoutOutcome: .finish(-1),
        onTimeout: { timeoutCount += 1 },
        operation: { firstFinish = $0 },
        completion: { completed.append($0) }
    )
    queue.enqueue(
        operation: { finish in
            didStartSecondOperation = true
            finish(.finish(2))
        },
        completion: { completed.append($0) }
    )

    scheduledTimeout?()
    #expect(timeoutCount == 1)
    #expect(didStartSecondOperation)
    #expect(completed == [-1, 2])
    #expect(queue.count == 0)

    firstFinish?(.finish(1))
    #expect(completed == [-1, 2])
}

@MainActor
@Test func orderedQueueCancelAllFinishesEveryCommandInOrderAndIgnoresLateReplies() {
    var scheduledTimeout: (@MainActor @Sendable () -> Void)?
    var scheduledRetry: (@MainActor @Sendable () -> Void)?
    let queue = OrderedAsyncCommandQueue<Int?>(
        scheduleRetry: { scheduledRetry = $0 },
        scheduleTimeout: { _, action in scheduledTimeout = action }
    )
    var finishes: [OrderedAsyncCommandQueue<Int?>.Finish] = []
    var completed: [Int?] = []
    var timeouts = 0

    for _ in 1...3 {
        queue.enqueue(
            timeout: 1,
            timeoutOutcome: .retry,
            onTimeout: { timeouts += 1 },
            operation: { finishes.append($0) },
            completion: { completed.append($0) }
        )
    }
    #expect(finishes.count == 1)

    queue.cancelAll(finishingWith: nil)
    #expect(completed == [nil, nil, nil])
    #expect(queue.count == 0)
    // Nothing behind the cancelled head may start.
    #expect(finishes.count == 1)

    // The cancelled head's reply, timeout and retry arrive late and must change nothing.
    finishes[0](.finish(7))
    scheduledTimeout?()
    scheduledRetry?()
    #expect(completed == [nil, nil, nil])
    #expect(timeouts == 0)
    #expect(finishes.count == 1)

    // The queue keeps working after a cancellation.
    queue.enqueue(operation: { finishes.append($0) }, completion: { completed.append($0) })
    #expect(finishes.count == 2)
    finishes[1](.finish(9))
    #expect(completed == [nil, nil, nil, 9])
}

@MainActor
@Test func orderedQueueCancelAllWhileRetryIsScheduledDoesNotRestartTheCancelledCommand() {
    var scheduledRetry: (@MainActor @Sendable () -> Void)?
    let queue = OrderedAsyncCommandQueue<Int?>(scheduleRetry: { scheduledRetry = $0 })
    var attempts = 0
    var finish: OrderedAsyncCommandQueue<Int?>.Finish?
    var completed: [Int?] = []

    queue.enqueue(operation: { attempts += 1; finish = $0 }, completion: { completed.append($0) })
    finish?(.retry)
    #expect(attempts == 1)

    queue.cancelAll(finishingWith: nil)
    scheduledRetry?()
    #expect(attempts == 1)
    #expect(completed == [nil])
}

@MainActor
@Test func orderedQueueCancelAllOnAnEmptyQueueDoesNothing() {
    let queue = OrderedAsyncCommandQueue<Int?>()
    queue.cancelAll(finishingWith: nil)
    #expect(queue.count == 0)
}
