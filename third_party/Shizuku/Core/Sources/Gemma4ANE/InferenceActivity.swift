import Foundation

/// 推論APIを占有したwall時間。物理デバイスの稼働率ではなく、呼び出し側のCPU処理も含む。
public enum InferenceActivity {
    public struct Event: Codable, Sendable {
        public var feature: String, device: String
        public var milliseconds: Double
        public var generation: UInt64
    }
    private static let fileLock = NSLock()
    public static func save(to url: URL) throws {
        fileLock.lock(); defer { fileLock.unlock() }
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = true
    nonisolated(unsafe) private static var generation: UInt64 = 0
    nonisolated(unsafe) private static var observer: (@Sendable (Event) -> Void)?
    nonisolated(unsafe) private static var totals: [String: Event] = [:]
    public static func configure(enabled value: Bool) { lock.withLock { if enabled != value { generation &+= 1 }; enabled = value } }
    public static func invalidate() { lock.withLock { generation &+= 1; totals.removeAll() } }
    public static func setObserver(_ value: (@Sendable (Event) -> Void)?) { lock.withLock { observer = value } }
    public static func ticket() -> UInt64? { lock.withLock { enabled ? generation : nil } }
    public static func isCurrent(_ event: Event) -> Bool { lock.withLock { enabled && generation == event.generation } }
    public static var snapshot: [Event] { lock.withLock { totals.keys.sorted().compactMap { totals[$0] } } }
    public static func report(feature: String, device: String, milliseconds: Double, ticket: UInt64?) {
        guard let ticket, milliseconds.isFinite, milliseconds >= 0 else { return }
        let event = Event(feature: feature, device: device, milliseconds: milliseconds, generation: ticket)
        let callback: (@Sendable (Event) -> Void)? = lock.withLock {
            guard enabled, generation == ticket else { return nil }
            let key = device + ":" + feature
            var total = totals[key] ?? Event(feature: feature, device: device, milliseconds: 0, generation: ticket)
            total.milliseconds += milliseconds
            totals[key] = total
            return observer
        }
        callback?(event)
    }
    public static func measure<T>(feature: String, device: String, _ body: () throws -> T) rethrows -> T {
        let ticket = ticket(), start = DispatchTime.now().uptimeNanoseconds
        defer { report(feature: feature, device: device, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, ticket: ticket) }
        return try body()
    }
}
