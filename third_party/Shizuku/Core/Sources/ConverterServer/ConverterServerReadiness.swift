import Foundation

@objc private protocol ConverterReadinessXPCProtocol {
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}

enum ConverterServerReadiness {
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        func finish(_ ready: Bool) { lock.withLock { if value == nil { value = ready } } }
        func read() -> Bool? { lock.withLock { value } }
    }

    /// Installation waits here; the IME's key timeout is not extended.
    static func wait(timeout: TimeInterval = 180, makeConnection: () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: "dev.tomonari.inputmethod.Shizuku.ConverterServer")
    }) -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let outcome = Outcome()
            let connection = makeConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: ConverterReadinessXPCProtocol.self)
            connection.interruptionHandler = { outcome.finish(false) }
            connection.invalidationHandler = { outcome.finish(false) }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in outcome.finish(false) } as? ConverterReadinessXPCProtocol
            proxy?.ping("input-ready") { outcome.finish($0 == "ConverterServer: input-ready-v1") }
            if proxy == nil { outcome.finish(false) }
            let attemptDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 1)
            while outcome.read() == nil, ProcessInfo.processInfo.systemUptime < attemptDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let ready = outcome.read() == true
            connection.invalidate()
            if ready {
                print("converter_ready=1 wait_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
                return true
            }
            let delay = min(0.1, max(0, deadline - ProcessInfo.processInfo.systemUptime))
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        print("converter_ready=0 wait_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
        return false
    }
}
