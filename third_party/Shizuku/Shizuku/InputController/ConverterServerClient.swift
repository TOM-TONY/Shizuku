import Core
import Foundation

private enum ConverterServerXPC {
    static let machServiceName = "dev.tomonari.inputmethod.Shizuku.ConverterServer"
}

@objc private protocol ConverterServerXPCProtocol {
    func openSession(with reply: @escaping @Sendable (String) -> Void)
    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void)
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}

@MainActor
final class ConverterServerClient {
    private static let commandTimeout: TimeInterval = 1
    private static let resourcePreparationTimeout: TimeInterval = 180

    private var connection: NSXPCConnection?
    /// llm-ime: 時間のかかる依頼（ローカル LLM・続き予測の結果待ち）専用の接続。通常の命令がタイムアウトして
    /// `connection` を作り直しても、待っている依頼の応答が捨てられないように分ける
    private var longRequestConnection: NSXPCConnection?
    private var sessionID: String?
    private var hasOpenedSession = false
    private var shouldAttemptReconnect = false
    private var nextReconnectAttemptDate = Date.distantPast
    private let commandQueue = OrderedAsyncCommandQueue<ConverterServerResponse?>()

    nonisolated init() {}

    var inputTraceID: UInt64 = 0
    var onLog: ((String) -> Void)?
    var hasOpenSession: Bool {
        sessionID != nil
    }
    var canSendOrReconnect: Bool {
        sessionID != nil || !hasOpenedSession || (shouldAttemptReconnect && Date() >= nextReconnectAttemptDate)
    }
    var pendingCommandCount: Int {
        commandQueue.count
    }

    func closeSession() {
        guard let sessionID else {
            invalidateConnection()
            return
        }
        remoteObjectProxy { [weak self] proxy in
            proxy?.closeSession(sessionID) { _ in
                Task { @MainActor in
                    self?.invalidateConnection()
                }
            }
        }
    }

    func ping(_ message: String, completion: @escaping (String?) -> Void) {
        remoteObjectProxy { proxy in
            proxy?.ping(message) { response in
                completion(response)
            }
            if proxy == nil {
                completion(nil)
            }
        }
    }

    func listSettings(
        capabilities: ConverterSettingClientCapabilities,
        completion: @escaping ([ConverterSettingDescriptor]?) -> Void
    ) {
        enqueue(
            { _ in
                .settings(.list(capabilities: capabilities))
            },
            retriesOnFailure: false,
            reopenMissingSession: true,
            completion: { response in
                completion(response?.settings)
            }
        )
    }

    func updateSetting(
        key: String,
        value: ConverterSettingValue,
        completion: @escaping (Bool) -> Void
    ) {
        send(
            { _ in
                .settings(.update(key: key, value: value))
            },
            completion: { response in
                completion(response != nil)
            }
        )
    }

    func restartServer(completion: @escaping (Bool) -> Void) {
        enqueueGlobal(.shutdown) { [weak self] response in
            self?.invalidateConnection()
            completion(response != nil)
        }
    }

    func synchronizeUserDictionary(
        forceExport: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        // Startup model compilation can outlast a key's deadline. Keep dictionary
        // exports queued until ready, including edits made during preparation.
        enqueueGlobal(.maintenance(.synchronizeUserDictionary(forceExport: forceExport)),
                      timeout: Self.resourcePreparationTimeout) { response in
            completion(response != nil)
        }
    }

    func resetLearningData(completion: @escaping (Bool) -> Void) {
        enqueueGlobal(.maintenance(.resetLearningData)) { response in
            completion(response != nil)
        }
    }

    func send(
        _ commandBuilder: @escaping (String) -> ConverterSessionCommand,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        enqueue(commandBuilder, retriesOnFailure: false, completion: completion)
    }

    /// キーイベントはタイムアウトで捨てず、1件ずつ順番に Server へ送る。
    /// XPC が一時的に切断した場合も先頭イベントを保持して再接続後に再送する。
    func sendKeyEvent(
        _ request: ConverterKeyEventRequest,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        enqueue({ _ in .handleKeyEvent(request) }, retriesOnFailure: true, completion: completion)
    }

    func sendIfSessionOpen(
        _ commandBuilder: @escaping (String) -> ConverterSessionCommand,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        guard sessionID != nil else {
            InputTrace.event(.guardReturn, controller: self.inputTraceID, reason: .noSession)
            completion(nil)
            return
        }
        enqueue(commandBuilder, retriesOnFailure: false, completion: completion)
    }

    /// llm-ime: 順序付きキューを通さずに送る。続き予測の結果待ちのように時間がかかる要求で、
    /// 待っている間もキー入力を順番どおり送れるようにする（タイムアウト・再送なし）。
    func sendUnordered(
        _ commandBuilder: @escaping (String) -> ConverterSessionCommand,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        guard let sessionID else {
            // この入力欄でまだセッションを開いていない（打鍵していない）場合は、順序付きキューで開いてから送る
            self.send({ _ in .composition(.snapshot) }) { [weak self] response in
                guard let self, response != nil, self.sessionID != nil else {
                    InputTrace.event(.guardReturn, controller: self?.inputTraceID ?? 0, reason: .noSession)
                    completion(nil)
                    return
                }
                self.sendUnordered(commandBuilder, completion: completion)
            }
            return
        }
        sendResolved(.session(sessionID: sessionID, command: commandBuilder(sessionID)), useLongRequestConnection: true, completion: completion)
    }

    private func longRequestProxy(completion: @escaping (ConverterServerXPCProtocol?) -> Void) {
        let connection: NSXPCConnection
        if let existing = self.longRequestConnection {
            connection = existing
        } else {
            InputTrace.event(.transport, controller: self.inputTraceID, reason: .connect, number: 1)
            connection = NSXPCConnection(machServiceName: ConverterServerXPC.machServiceName, options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
            let forget: () -> Void = { [weak self, weak connection] in
                DispatchQueue.main.async {
                    if let self, self.longRequestConnection === connection {
                        InputTrace.event(.transport, controller: self.inputTraceID, reason: .invalidated, number: 1)
                        self.longRequestConnection = nil
                    }
                }
            }
            connection.interruptionHandler = forget
            connection.invalidationHandler = forget
            connection.resume()
            self.longRequestConnection = connection
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            DispatchQueue.main.async {
                InputTrace.event(.transport, controller: self?.inputTraceID ?? 0, reason: .proxyError, number: (error as NSError).code)
                self?.onLog?("ConverterServer long request XPC error")
                if self?.longRequestConnection === connection {
                    self?.longRequestConnection = nil
                }
                connection.invalidate()
                completion(nil)
            }
        }) as? ConverterServerXPCProtocol else {
            InputTrace.event(.guardReturn, controller: self.inputTraceID, reason: .noProxy)
            completion(nil)
            return
        }
        completion(proxy)
    }

    private func enqueue(
        _ commandBuilder: @escaping (String) -> ConverterSessionCommand,
        retriesOnFailure: Bool,
        reopenMissingSession: Bool = false,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        var proposedSessionID: String?
        var traceRequestID: UInt64 = 0
        var activeAttemptID: UUID?
        commandQueue.enqueue(
            timeout: Self.commandTimeout,
            timeoutOutcome: retriesOnFailure ? .retry : .finish(nil),
            onTimeout: { [weak self] in
                activeAttemptID = nil
                self?.handleCommandTimeout(requestID: traceRequestID)
            },
            operation: { [weak self] finish in
                guard let self else {
                    finish(.finish(nil))
                    return
                }
                let attemptID = UUID()
                activeAttemptID = attemptID
                let reconnectDelay = self.nextReconnectAttemptDate.timeIntervalSinceNow
                if self.shouldAttemptReconnect, reconnectDelay > 0 {
                    InputTrace.event(.transport, controller: self.inputTraceID, request: traceRequestID, reason: .reconnectWait)
                    DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) {
                        guard activeAttemptID == attemptID else { return }
                        activeAttemptID = nil
                        finish(.retry)
                    }
                    return
                }
                let sessionID = self.sessionID ?? proposedSessionID ?? UUID().uuidString
                proposedSessionID = sessionID
                let sessionCommand = commandBuilder(sessionID)
                traceRequestID = InputTrace.requestID(sessionCommand)
                let command: ConverterServerCommand = if self.sessionID == nil {
                    .openSession(sessionID: sessionID, command: sessionCommand)
                } else {
                    .session(sessionID: sessionID, command: sessionCommand)
                }
                self.sendResolved(command, reopenMissingSession: reopenMissingSession,
                                  isCurrent: { activeAttemptID == attemptID }) { [weak self] response in
                    activeAttemptID = nil
                    guard let self else {
                        finish(.finish(nil))
                        return
                    }
                    if response != nil, self.sessionID == nil {
                        self.acceptOpenedSession(sessionID)
                    }
                    if response == nil, retriesOnFailure {
                        InputTrace.event(.transport, controller: self.inputTraceID, request: traceRequestID, reason: .retry)
                        self.recordReconnectFailure()
                        finish(.retry)
                    } else {
                        finish(.finish(response))
                    }
                }
            },
            completion: { response in
                completion(response)
            }
        )
    }

    private func enqueueGlobal(
        _ command: ConverterServerCommand,
        timeout: TimeInterval? = nil,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        commandQueue.enqueue(
            timeout: timeout ?? Self.commandTimeout,
            timeoutOutcome: .finish(nil),
            onTimeout: { [weak self] in
                self?.handleCommandTimeout()
            },
            operation: { [weak self] finish in
                guard let self else {
                    finish(.finish(nil))
                    return
                }
                self.sendResolved(command) { response in
                    finish(.finish(response))
                }
            },
            completion: { response in
                completion(response)
            }
        )
    }

    private func remoteObjectProxy(completion: @escaping (ConverterServerXPCProtocol?) -> Void) {
        let connection = ensureConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            DispatchQueue.main.async {
                InputTrace.event(.transport, controller: self?.inputTraceID ?? 0, reason: .proxyError, number: (error as NSError).code)
                self?.onLog?("ConverterServer XPC error")
                if self?.connection === connection {
                    self?.resetConnection(preservingSession: true)
                }
                completion(nil)
            }
        }) as? ConverterServerXPCProtocol else {
            InputTrace.event(.guardReturn, controller: self.inputTraceID, reason: .noProxy)
            completion(nil)
            return
        }
        completion(proxy)
    }

    private func sendResolved(
        _ command: ConverterServerCommand,
        useLongRequestConnection: Bool = false,
        reopenMissingSession: Bool = false,
        isCurrent: @escaping () -> Bool = { true },
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        guard isCurrent() else { return }
        let traceRequestID = InputTrace.requestID(command)
        let traceID = self.inputTraceID
        do {
            let data = try ConverterServerCodec.encode(command)
            let proxyProvider = useLongRequestConnection ? self.longRequestProxy : self.remoteObjectProxy
            proxyProvider { proxy in
                guard isCurrent() else { return }
                guard let proxy else {
                    InputTrace.event(.guardReturn, controller: traceID, request: traceRequestID, reason: .noProxy)
                    completion(nil)
                    return
                }
                if traceRequestID != 0 { InputTrace.event(.send, controller: traceID, request: traceRequestID) }
                proxy.handleCommand(data) { [weak self] responseData, errorMessage in
                    let errorDescription = errorMessage.map(String.init)
                    DispatchQueue.main.async {
                        guard isCurrent() else { return }
                        if let errorDescription {
                            InputTrace.event(.transport, controller: traceID, request: traceRequestID, reason: .remoteError)
                            self?.onLog?("ConverterServer command failed")
                            if errorDescription.hasPrefix("Unknown converter session:") {
                                self?.resetConnection(preservingSession: false)
                                // A missing session rejects the read before execution. Reopen once;
                                // settings updates and actions must never be replayed here.
                                if reopenMissingSession, let self,
                                   case .session(let sessionID, let sessionCommand) = command {
                                    self.sendResolved(.openSession(sessionID: sessionID, command: sessionCommand),
                                                      isCurrent: isCurrent, completion: completion)
                                    return
                                }
                            }
                            completion(nil)
                            return
                        }
                        guard let responseData else {
                            InputTrace.event(.guardReturn, controller: traceID, request: traceRequestID, reason: .noData)
                            completion(nil)
                            return
                        }
                        do {
                            completion(try ConverterServerCodec.decodeResponse(from: responseData))
                        } catch {
                            InputTrace.event(.transport, controller: traceID, request: traceRequestID, reason: .decodeError)
                            completion(nil)
                        }
                    }
                }
            }
        } catch {
            InputTrace.event(.transport, controller: traceID, request: traceRequestID, reason: .encodeError)
            self.onLog?("ConverterServer encode failed")
            completion(nil)
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let connection {
            return connection
        }
        InputTrace.event(.transport, controller: self.inputTraceID, reason: .connect)
        let connection = NSXPCConnection(machServiceName: ConverterServerXPC.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
        connection.interruptionHandler = { [weak self, weak connection] in
            DispatchQueue.main.async {
                guard let self, self.connection === connection else { return }
                InputTrace.event(.transport, controller: self.inputTraceID, reason: .interrupted)
                self.onLog?("ConverterServer connection interrupted")
                self.resetConnection(preservingSession: true)
            }
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            DispatchQueue.main.async {
                guard let self, self.connection === connection else { return }
                InputTrace.event(.transport, controller: self.inputTraceID, reason: .invalidated)
                self.onLog?("ConverterServer connection invalidated")
                self.resetConnection(preservingSession: true)
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func resetConnection(preservingSession: Bool) {
        let connection = self.connection
        self.connection = nil
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        if sessionID != nil || hasOpenedSession {
            shouldAttemptReconnect = true
        }
        if !preservingSession {
            self.sessionID = nil
        }
    }

    private func invalidateConnection() {
        resetConnection(preservingSession: false)
    }

    private func recordReconnectFailure() {
        shouldAttemptReconnect = true
        nextReconnectAttemptDate = Date().addingTimeInterval(0.2)
    }

    private func acceptOpenedSession(_ sessionID: String) {
        self.sessionID = sessionID
        hasOpenedSession = true
        shouldAttemptReconnect = false
        nextReconnectAttemptDate = .distantPast
        onLog?("ConverterServer session opened: \(sessionID)")
    }

    private func handleCommandTimeout(requestID: UInt64 = 0) {
        InputTrace.event(.transport, controller: self.inputTraceID, request: requestID, reason: .timeout)
        onLog?("ConverterServer command timed out")
        recordReconnectFailure()
        resetConnection(preservingSession: true)
    }
}
