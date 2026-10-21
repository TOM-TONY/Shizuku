// Built only by test_client_initialization.py --lifetime; no real IMKServer or XPC.
import Cocoa
import Core
import InputMethodKit

private final class WeakController {
    weak var value: ShizukuInputController?
    init(_ value: ShizukuInputController) { self.value = value }
}

@main struct ClientLifetimeTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let preferences: [String: Any] = [
            Config.LiveConversion.key: false, Config.PersonalLearning.key: false,
            Config.PersonalInputModeSwitching.key: false, Config.NextTextCompletion.key: false,
            Config.NextTextCompletionIdle.key: false, Config.PromptHistory.key: Data("[]".utf8)
        ]
        Config.userDefaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        let client = InitializationClient()
        ShizukuInputController.initializationTestClient = client
        var requests: [ConverterKeyEventRequest] = [], owners: [WeakController] = []
        var held: [() -> Void] = [], serverCommands: [String] = [], sessions: Set<String> = []
        ConverterServerClient.initializationTestTransport = { command, reply in
            let session: ConverterSessionCommand
            switch command {
            case .openSession(let id, let c), .session(let id, let c): sessions.insert(id); session = c
            default: reply(nil); return
            }
            guard case .handleKeyEvent(let request) = session else {
                if case .lifecycle(.deactivate) = session { serverCommands.append("deactivate") }
                reply(nil); return
            }
            requests.append(request)
            let enter = request.event.keyCode == 36
            var snapshot = ConverterSessionSnapshot.empty
            snapshot.markedText = .init(elements: enter ? [] : [.init(content: "きょう", focus: .unfocused)],
                selectionRange: .init(location: enter ? 0 : 3, length: 0))
            snapshot.isEmpty = enter
            let response = ConverterServerResponse(effects: enter ? [.insertText("今日")] : [], inputState: enter ? .none : .composing, snapshot: snapshot)
            held.append { reply(response) }
        }
        func drain(_ seconds: Double = 0.04) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: deadline) }
        }
        func make() -> ShizukuInputController {
            let c = ShizukuInputController(server: nil, delegate: nil, client: client)!
            owners.append(WeakController(c)); return c
        }
        func key(_ controller: ShizukuInputController, _ code: UInt16, _ characters: String) -> Bool {
            controller.handle(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!, client: client)
        }
        let keys: [(UInt16, String)] = [(40, "k"), (16, "y"), (31, "o"), (32, "u"), (36, "\r")]
        // Control: exactly the same delayed connection, client and keys, with a stable owner.
        var stable: ShizukuInputController? = make()
        stable!.activateServer(client); drain()
        for (code, chars) in keys {
            _ = key(stable!, code, chars); drain()
            let callbacks = held; held.removeAll()
            for reply in callbacks { reply() }
            drain()
        }
        let stablePassed = client.inserted == "今日" && client.markedCalls >= 4 && client.insertedCalls == 1
        let stableRequests = requests.count
        stable!.deactivateServer(client); stable = nil; drain()
        func reset() {
            client.marked = ""; client.inserted = ""; client.markedCalls = 0; client.insertedCalls = 0
            requests.removeAll(); owners.removeAll(); sessions.removeAll(); serverCommands.removeAll(); held.removeAll()
        }
        // Isolate weak ownership from activation cancellation. Queue all five keys,
        // release IMK's reference without deactivating, then deliver delayed replies.
        func releaseOnly(dispatchBeforeRelease: Bool) -> [String: Any] {
            reset()
            var owner: ShizukuInputController? = make()
            owner!.activateServer(client); drain()
            var accepted = 0
            for (code, chars) in keys { if key(owner!, code, chars) { accepted += 1 } }
            if dispatchBeforeRelease { drain() }
            let beforeRelease = requests.count
            owner = nil
            let retainedBeforeReply = owners[0].value != nil
            for _ in 0..<6 {
                drain()
                let callbacks = held; held.removeAll()
                for reply in callbacks { reply() }
            }
            // Queue timeout callbacks retain their entry until the existing 1s deadline.
            drain(1.1)
            return ["handled": accepted, "requestsBeforeRelease": beforeRelease,
                "retainedBeforeReply": retainedBeforeReply, "retainedAfterReplies": owners[0].value != nil,
                "requests": requests.count, "sessions": sessions.count, "requestIDs": requests.map(\.eventID),
                "markedCalls": client.markedCalls, "insertCalls": client.insertedCalls,
                "passed": client.inserted == "今日" && requests.map(\.eventID) == [1, 2, 3, 4, 5] && sessions.count == 1]
        }
        let releasedBeforeDispatch = releaseOnly(dispatchBeforeRelease: false)
        let releasedAfterDispatch = releaseOnly(dispatchBeforeRelease: true)
        reset()
        // Retaining a response owner must not bypass a real activation change.
        var previous: ShizukuInputController? = make()
        previous!.activateServer(client); drain()
        _ = key(previous!, 40, "k"); drain()
        previous!.deactivateServer(client); previous = nil
        let otherClient = InitializationClient()
        ShizukuInputController.initializationTestClient = otherClient
        let otherController = ShizukuInputController(server: nil, delegate: nil, client: otherClient)!
        otherController.activateServer(otherClient); drain()
        do {
            let callbacks = held; held.removeAll()
            for reply in callbacks { reply() }
        }
        drain()
        let changedFieldDiscarded = client.markedCalls == 0 && client.insertedCalls == 0
            && otherClient.markedCalls == 0 && otherClient.insertedCalls == 0
        otherController.deactivateServer(otherClient)
        ShizukuInputController.initializationTestClient = client
        reset()
        var controller: ShizukuInputController? = make()
        controller!.activateServer(client); drain()
        var handled = 0
        for (code, chars) in keys {
            if key(controller!, code, chars) { handled += 1 }
            drain() // Let the request reach the fake connection, but hold its reply.
            controller!.deactivateServer(client)
            controller = nil
            drain()
            controller = make() // Same client/field, no activate: matches the observed inter-key sequence.
            let callbacks = held; held.removeAll()
            for reply in callbacks { reply() }
            drain()
        }
        let output: [String: Any] = [
            "replacementScope": "same_client_without_new_activate", "processID": ProcessInfo.processInfo.processIdentifier,
            "stableControllerPassed": stablePassed, "stableControllerRequests": stableRequests,
            "releasedBeforeDispatch": releasedBeforeDispatch, "releasedAfterDispatch": releasedAfterDispatch,
            "changedFieldDiscarded": changedFieldDiscarded,
            "keys": 5, "handled": handled, "requests": requests.count, "sessions": sessions.count,
            "requestIDs": requests.map(\.eventID), "activations": requests.filter { $0.activation != nil }.count,
            "markedCalls": client.markedCalls, "insertCalls": client.insertedCalls,
            "markedMatches": client.marked == "きょう", "insertMatches": client.inserted == "今日",
            "survivingPreviousControllers": owners.dropLast().filter { $0.value != nil }.count,
            "controllerCount": owners.count, "serverDeactivations": serverCommands.count,
            "survivedReplacement": client.inserted == "今日"
        ]
        try (JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]) + Data("\n".utf8))
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }
}
