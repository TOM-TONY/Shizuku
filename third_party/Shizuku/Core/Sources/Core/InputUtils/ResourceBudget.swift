import Foundation

/// 先に一致した行を採る資源の表。明示選択は既定より優先する。
public enum ResourceBudget {
    public struct Environment: Sendable {
        public var onAC: Bool, battery: Double?, lowPower: Bool
        public var thermal: Int, memoryGB: Int
        public init(onAC: Bool = true, battery: Double? = nil, lowPower: Bool = false, thermal: Int = 0, memoryGB: Int) {
            self.onAC = onAC; self.battery = battery; self.lowPower = lowPower; self.thermal = thermal; self.memoryGB = memoryGB
        }
    }
    public struct Tier: Sendable, Equatable {
        public var name: String, completion: String
        public var idleSentences: Int
        public var allow12B: Bool, allow31B: Bool, replay: Bool
    }
    public struct Rule: Sendable {
        public var minimumMemory: Int
        public var constrained: Bool
        public var tier: Tier
    }
    public static let rules: [Rule] = [
        .init(minimumMemory: 0, constrained: true, tier: .init(name: "節電・高温", completion: "gemma4-e2b-ane", idleSentences: 1, allow12B: false, allow31B: false, replay: false)),
        .init(minimumMemory: 64, constrained: false, tier: .init(name: "64GB以上", completion: "gemma4-e4b-ane", idleSentences: 3, allow12B: true, allow31B: true, replay: true)),
        .init(minimumMemory: 24, constrained: false, tier: .init(name: "24GB以上", completion: "gemma4-e4b-ane", idleSentences: 3, allow12B: true, allow31B: false, replay: true)),
        .init(minimumMemory: 16, constrained: false, tier: .init(name: "16GB", completion: "gemma4-e4b-ane", idleSentences: 3, allow12B: false, allow31B: false, replay: true)),
        .init(minimumMemory: 0, constrained: false, tier: .init(name: "8GB", completion: "gemma4-e2b-ane", idleSentences: 1, allow12B: false, allow31B: false, replay: true))
    ]
    public static func resolve(_ environment: Environment) -> Tier {
        let constrained = environment.lowPower || environment.thermal >= 2 || (!environment.onAC && (environment.battery.map { $0 < 0.2 } ?? false))
        var tier = rules.first { $0.constrained == constrained && max(0, environment.memoryGB) >= $0.minimumMemory }!.tier
        tier.replay = tier.replay && environment.onAC && environment.thermal == 0
        if !environment.onAC { tier.idleSentences = 1 }
        return tier
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var environment = Environment(memoryGB: Int(ProcessInfo.processInfo.physicalMemory / (1 << 30)))
    public static func update(_ value: Environment) { lock.withLock { environment = value } }
    public static var current: Tier { lock.withLock { resolve(environment) } }
    public static var memoryGB: Int { lock.withLock { environment.memoryGB } }
    public static func completion(powerSaving: Bool, selected: String, tier: Tier) -> String {
        if !selected.isEmpty { return selected }
        return powerSaving ? "gemma4-e2b-ane" : tier.completion
    }
}
