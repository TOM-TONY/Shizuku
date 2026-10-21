import Core
import Foundation

@objc private protocol ConverterShutdownXPCProtocol {
    func openSession(with reply: @escaping @Sendable (String) -> Void)
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
}

@main struct ConverterShutdownTests {
    static func main() throws {
        let connection = NSXPCConnection(machServiceName: "dev.tomonari.inputmethod.Shizuku.ConverterServer")
        connection.remoteObjectInterface = NSXPCInterface(with: ConverterShutdownXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in exit(1) } as! ConverterShutdownXPCProtocol
        var sessionID = ""
        proxy.openSession { sessionID = $0 }
        func send(_ command: ConverterServerCommand) throws -> ConverterServerResponse {
            var response: ConverterServerResponse?
            proxy.handleCommand(try ConverterServerCodec.encode(command)) { data, error in
                if error == nil, let data { response = try? ConverterServerCodec.decodeResponse(from: data) }
            }
            guard let response else { throw Failure.commandFailed }
            return response
        }
        func settings() throws -> [ConverterSettingDescriptor] {
            try send(.session(sessionID: sessionID, command: .settings(.list(capabilities:
                .init(supportedCustomSurfaces: ["upperBoundInspection"]))))).settings
        }
        let initialSettings = try settings()
        guard case .string(let inspectionText) = initialSettings.first(where: { $0.key == Config.labUpperBoundInspectionKey })?.value,
              let inspection = try JSONSerialization.jsonObject(with: Data(inspectionText.utf8)) as? [String: Any],
              inspection["usesTestStore"] as? Bool == true else { throw Failure.testStoreRequired }
        guard initialSettings.first(where: { $0.key == Config.NextTextCompletion.key })?.value == .bool(false)
        else { throw Failure.generationMustBeOff }
        func pauses(_ items: [ConverterSettingDescriptor]) throws -> Int {
            guard case .string(let summary) = items.first(where: { $0.key == Config.personalLearningSummaryKey })?.value,
                  let match = summary.range(of: "手を止めた記録 [0-9]+ 回", options: .regularExpression) else { throw Failure.countUnavailable }
            return Int(summary[match].filter(\.isNumber))!
        }
        let before = try pauses(initialSettings)
        var eventID: UInt64 = 0
        let scene = ConverterSceneObservation(bundleID: "dev.tomonari.xpcprobe.shutdown", documentLength: 0, startedEmpty: true)
        func key(_ text: String, code: UInt16) throws {
            eventID += 1
            let request = ConverterKeyEventRequest(eventID: eventID,
                event: KeyEventCore(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: code),
                inputStyle: .defaultRomanToKana, liveConversionEnabled: false, enableDebugWindow: false, enableSuggestion: false,
                context: .init(leftSideContext: ""), scene: scene)
            _ = try send(.session(sessionID: sessionID, command: .handleKeyEvent(request)))
        }
        func word(_ vowel: String, code: UInt16) throws {
            try key("k", code: 40); try key(vowel, code: code); try key("\r", code: 36)
        }
        _ = try send(.session(sessionID: sessionID, command: .lifecycle(.activate)))
        try word("a", code: 0)
        Thread.sleep(forTimeInterval: 1)
        try word("i", code: 34)
        let beforeShutdown = try pauses(settings())
        Thread.sleep(forTimeInterval: 1)
        _ = try send(.shutdown)
        // This key arrives after shutdown's first flush, during the 200ms grace period.
        try word("u", code: 32)
        let afterAcknowledgement = try pauses(settings())
        guard beforeShutdown == before + 1, afterAcknowledgement == before + 2 else { throw Failure.unexpectedCount }
        let result: [String: Any] = ["testStoreVerified": true, "before": before, "beforeShutdown": beforeShutdown,
            "afterShutdownAcknowledgement": afterAcknowledgement, "keyAcceptedDuringShutdownWindow": true,
            "realXPCUsed": true, "syntheticInputOnly": true]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
    enum Failure: Error { case commandFailed, testStoreRequired, generationMustBeOff, countUnavailable, unexpectedCount }
}
