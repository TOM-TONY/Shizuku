import Core
import Foundation

@MainActor final class SettingsReconnectProxy: NSObject, ConverterServerXPCProtocol {
    enum Reply {
        case success, unknownSession, otherError, malformed, delayed, delayedUnknownSession
    }
    static var replies: [Reply] = []
    static var commands: [ConverterServerCommand] = []
    static var delayedReply: (() -> Void)?
    static let capabilities = ConverterSettingClientCapabilities(supportedKinds: [.toggle, .selector])
    static let descriptors = [ConverterSettingDescriptor(key: "fixture.mode", title: "Fixture", section: "Fixture", kind: .toggle, value: .bool(true))]

    func openSession(with reply: @escaping @Sendable (String) -> Void) { preconditionFailure("Unexpected proxy API") }
    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void) { preconditionFailure("Unexpected proxy API") }
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void) { preconditionFailure("Unexpected proxy API") }
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void) {
        let command = try! ConverterServerCodec.decodeCommand(from: data)
        Self.commands.append(command)
        check(!Self.replies.isEmpty, "Unexpected extra request")
        let response = try! ConverterServerCodec.encode(ConverterServerResponse(settings: Self.descriptors, snapshot: .empty))
        switch Self.replies.removeFirst() {
        case .success: reply(response, nil)
        case .unknownSession: reply(nil, "Unknown converter session: fixture")
        case .otherError: reply(nil, "Unknown converter setting: fixture")
        case .malformed: reply(Data([255]), nil)
        case .delayed: Self.delayedReply = { reply(response, nil) }
        case .delayedUnknownSession: Self.delayedReply = { reply(nil, "Unknown converter session: fixture") }
        }
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8)); exit(1)
    }
}

@main struct ConverterSettingsReconnectTests {
    @MainActor static func wait(_ condition: () -> Bool, seconds: TimeInterval = 3) {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        check(condition(), "Completion must arrive within the deadline")
    }

    @MainActor static func main() throws {
        let client = ConverterServerClient()
        var checks: [String: Bool] = [:]
        var completions = 0
        var latest: [ConverterSettingDescriptor]?
        func list(_ replies: [SettingsReconnectProxy.Reply], expectSuccess: Bool) {
            SettingsReconnectProxy.replies = replies
            let before = completions
            client.listSettings(capabilities: SettingsReconnectProxy.capabilities) { descriptors in
                completions += 1; latest = descriptors
            }
            wait { completions > before }
            check(completions == before + 1, "Exactly one completion per list request")
            check(expectSuccess ? latest == SettingsReconnectProxy.descriptors : latest == nil, "Unexpected listing result")
            check(SettingsReconnectProxy.replies.isEmpty, "Expected request was not sent")
        }
        func requestIsOpen(_ index: Int) -> Bool {
            if case .openSession = SettingsReconnectProxy.commands[index] { return true }; return false
        }

        list([.success], expectSuccess: true)
        check(requestIsOpen(0), "Initial listing opens a session")
        checks["initialList"] = true

        list([.unknownSession, .success], expectSuccess: true)
        check(!requestIsOpen(1) && requestIsOpen(2), "First refresh after restart must reopen the stale session")
        list([.success], expectSuccess: true)
        check(!requestIsOpen(3), "Next refresh must reuse the recovered session")
        for command in SettingsReconnectProxy.commands {
            let id: String, session: ConverterSessionCommand
            switch command {
            case .openSession(let s, let c), .session(let s, let c): id = s; session = c
            default: preconditionFailure("Unexpected global command")
            }
            check(!id.isEmpty, "Session identity must survive recovery")
            guard case .settings(.list(let capabilities)) = session else { preconditionFailure("Expected list") }
            check(capabilities == SettingsReconnectProxy.capabilities, "Recovery must preserve client capabilities")
        }
        checks["firstRefreshAfterRestart"] = true
        checks["recoveredSessionReused"] = true
        checks["capabilitiesPreserved"] = true

        SettingsReconnectProxy.replies = [.unknownSession, .success, .success]
        let beforeQueued = completions
        var order: [Int] = []
        for index in 0..<2 {
            client.listSettings(capabilities: SettingsReconnectProxy.capabilities) { descriptors in
                check(descriptors == SettingsReconnectProxy.descriptors, "Queued listing must recover")
                completions += 1; order.append(index)
            }
        }
        wait { completions == beforeQueued + 2 }
        check(order == [0, 1] && client.pendingCommandCount == 0, "Recovery must retain queue order")
        checks["queuedRefreshOrder"] = true

        let beforeBound = SettingsReconnectProxy.commands.count
        list([.unknownSession, .unknownSession], expectSuccess: false)
        check(SettingsReconnectProxy.commands.count == beforeBound + 2, "Recovery must stop after one reopen")
        list([.success], expectSuccess: true)
        checks["recoveryBoundedAndNextRefreshWorks"] = true

        for failure in [SettingsReconnectProxy.Reply.otherError, .malformed] {
            let before = SettingsReconnectProxy.commands.count
            list([failure], expectSuccess: false)
            check(SettingsReconnectProxy.commands.count == before + 1, "Unrelated errors must not trigger recovery")
        }
        checks["otherErrorsNotReplayed"] = true

        SettingsReconnectProxy.replies = [.unknownSession]
        let beforeUpdate = SettingsReconnectProxy.commands.count
        var updateResults: [Bool] = []
        client.updateSetting(key: "fixture.action", value: .bool(true)) { updateResults.append($0) }
        wait { !updateResults.isEmpty }
        check(updateResults == [false] && SettingsReconnectProxy.commands.count == beforeUpdate + 1,
              "Settings updates and actions must never be replayed")
        checks["updateNotReplayed"] = true

        list([.success], expectSuccess: true)
        let beforeTimeout = SettingsReconnectProxy.commands.count
        let beforeCompletion = completions
        list([.delayed], expectSuccess: false)
        SettingsReconnectProxy.delayedReply?(); SettingsReconnectProxy.delayedReply = nil
        let settle = Date().addingTimeInterval(0.1)
        while Date() < settle { _ = RunLoop.current.run(mode: .default, before: settle) }
        check(completions == beforeCompletion + 1 && SettingsReconnectProxy.commands.count == beforeTimeout + 1,
              "Timeout and late reply must not replay the read or complete twice")
        list([.success], expectSuccess: true)
        checks["timeoutAndLateReplyBounded"] = true

        for afterNextCompletion in [false, true] {
            list([.delayedUnknownSession], expectSuccess: false)
            let stale = SettingsReconnectProxy.delayedReply!
            SettingsReconnectProxy.delayedReply = nil
            let beforeNext = completions
            let beforeRequests = SettingsReconnectProxy.commands.count
            SettingsReconnectProxy.replies = afterNextCompletion ? [.success] : [.delayed]
            client.listSettings(capabilities: SettingsReconnectProxy.capabilities) { descriptors in
                check(descriptors == SettingsReconnectProxy.descriptors, "Next listing must survive stale errors")
                completions += 1
            }
            if afterNextCompletion { wait { completions == beforeNext + 1 } }
            else { wait { SettingsReconnectProxy.delayedReply != nil } }
            stale()
            let settle = Date().addingTimeInterval(0.05)
            while Date() < settle { _ = RunLoop.current.run(mode: .default, before: settle) }
            check(SettingsReconnectProxy.commands.count == beforeRequests + 1,
                  "Expired listing must not reopen a session outside the queue")
            if !afterNextCompletion {
                SettingsReconnectProxy.delayedReply?(); SettingsReconnectProxy.delayedReply = nil
                wait { completions == beforeNext + 1 }
            }
            check(client.hasOpenSession, "Stale errors must not invalidate the next session")
            list([.success], expectSuccess: true)
            check(!requestIsOpen(SettingsReconnectProxy.commands.count - 1), "Next session must remain reusable")
            checks[afterNextCompletion ? "lateMissingSessionAfterNextCompletionIgnored" : "lateMissingSessionDuringNextRequestIgnored"] = true
        }
        check(client.pendingCommandCount == 0, "Queue must drain")

        SettingsReconnectProxy.replies = [.delayed, .success]
        let beforeDictionary = SettingsReconnectProxy.commands.count
        var dictionaryResults: [Bool] = []
        client.synchronizeUserDictionary(forceExport: false) { dictionaryResults.append($0) }
        client.synchronizeUserDictionary(forceExport: true) { dictionaryResults.append($0) }
        let preparationWait = Date().addingTimeInterval(1.2)
        while Date() < preparationWait { _ = RunLoop.current.run(mode: .default, before: preparationWait) }
        check(dictionaryResults.isEmpty && SettingsReconnectProxy.commands.count == beforeDictionary + 1,
              "Dictionary preparation must survive the key deadline and preserve queued edits")
        SettingsReconnectProxy.delayedReply?(); SettingsReconnectProxy.delayedReply = nil
        wait { dictionaryResults.count == 2 }
        check(dictionaryResults == [true, true], "Both dictionary operations must complete once")
        for (index, force) in [false, true].enumerated() {
            guard case .maintenance(.synchronizeUserDictionary(let sentForce)) = SettingsReconnectProxy.commands[beforeDictionary + index]
            else { preconditionFailure("Expected dictionary maintenance") }
            check(sentForce == force, "Startup synchronization and explicit export must retain their order")
        }
        checks["dictionaryPreparationRetainsQueuedEdits"] = true

        let result: [String: Any] = ["checks": checks, "testsPassed": true, "checkCount": checks.count,
                                    "realXPCUsed": false, "preferencesWritten": false]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("settings reconnect: \(checks.count) checks passed")
    }
}
