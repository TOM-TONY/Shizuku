import Foundation

@objc private protocol ReadinessFixtureProtocol {
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}

private final class Fixture: NSObject, NSXPCListenerDelegate, ReadinessFixtureProtocol, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var readyAt = Double.infinity
    private var delay: TimeInterval = 0
    private var echo = false
    var replyDelay: TimeInterval {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }
    var legacyEcho: Bool {
        get { lock.withLock { echo } }
        set { lock.withLock { echo = newValue } }
    }

    override init() { super.init(); listener.delegate = self; listener.resume() }
    func prepare(after delay: TimeInterval) { lock.withLock { readyAt = ProcessInfo.processInfo.systemUptime + delay } }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ReadinessFixtureProtocol.self)
        connection.exportedObject = self; connection.resume(); return true
    }
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void) {
        let (ready, delay, echo) = lock.withLock { (ProcessInfo.processInfo.systemUptime >= readyAt, self.delay, self.echo) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            reply(echo ? "ConverterServer: \(message)" :
                (ready ? "ConverterServer: input-ready-v1" : "ConverterServer: input-unavailable"))
        }
    }
    func connection() -> NSXPCConnection { NSXPCConnection(listenerEndpoint: listener.endpoint) }
}

@main struct ConverterReadinessTests {
    static func main() throws {
        let fixture = Fixture()
        let started = ProcessInfo.processInfo.systemUptime
        precondition(!ConverterServerReadiness.wait(timeout: 0.15, makeConnection: fixture.connection))
        precondition(ProcessInfo.processInfo.systemUptime - started < 0.5)
        fixture.prepare(after: 0.2)
        let preparing = ProcessInfo.processInfo.systemUptime
        precondition(ConverterServerReadiness.wait(timeout: 2, makeConnection: fixture.connection))
        precondition(ProcessInfo.processInfo.systemUptime - preparing >= 0.2)
        fixture.replyDelay = 0.3
        precondition(!ConverterServerReadiness.wait(timeout: 0.05, makeConnection: fixture.connection))
        fixture.replyDelay = 0
        fixture.prepare(after: 10)
        // A successful reply from the expired attempt must not satisfy another wait.
        precondition(!ConverterServerReadiness.wait(timeout: 0.4, makeConnection: fixture.connection))
        fixture.prepare(after: 0)
        fixture.legacyEcho = true
        precondition(!ConverterServerReadiness.wait(timeout: 0.15, makeConnection: fixture.connection))
        fixture.listener.invalidate()
        print("readiness_tests=5 PASS; real_anonymous_xpc=1 personal_records_accessed=0")
    }
}
