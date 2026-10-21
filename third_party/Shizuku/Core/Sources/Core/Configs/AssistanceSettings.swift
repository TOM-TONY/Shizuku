import Foundation

/// 軸と旧キーの対応。移行では旧キーを変更せず、本人が軸を選び直したときだけ写す。
public enum AssistanceSettings {
    public enum Timing: String, Codable, CaseIterable, Sendable {
        case typing, stopped, called, custom
        public var title: String {
            switch self {
            case .typing: "入力中"
            case .stopped: "手を止めたとき"
            case .called: "呼んだときだけ"
            case .custom: "詳細の組み合わせ"
            }
        }
    }
    public enum Content: String, Codable, CaseIterable, Sendable {
        case past, patterns, body
        public var title: String {
            switch self {
            case .past: "本人の過去文だけ"
            case .patterns: "型と語まで"
            case .body: "本文の生成まで"
            }
        }
        public var level: Int { switch self { case .past: 0; case .patterns: 1; case .body: 2 } }
    }
    public enum Memory: String, Codable, CaseIterable, Sendable {
        case none, local, paused
        public var title: String {
            switch self { case .none: "覚えない"; case .local: "このMacの中で覚える"; case .paused: "詳細（記録を一時停止）" }
        }
    }
    public enum Tab: String, Codable, CaseIterable, Sendable {
        case auto, yield, keep
        public var title: String { switch self { case .auto: "自動"; case .yield: "譲る"; case .keep: "譲らない" } }
    }
    public struct App: Codable, Equatable, Sendable {
        public var content: Content?
        public var tab: Tab
        public init(content: Content? = nil, tab: Tab = .auto) { self.content = content; self.tab = tab }
    }
    public struct Legacy: Equatable, Sendable {
        public var completion, idle, learning, paused: Bool
        public init(completion: Bool, idle: Bool, learning: Bool, paused: Bool) {
            self.completion = completion; self.idle = idle; self.learning = learning; self.paused = paused
        }
    }
    public struct TimingRow: Sendable {
        public let timing: Timing
        public let completion, idle: Bool
    }
    public static let timingTable: [TimingRow] = [
        .init(timing: .typing, completion: true, idle: false),
        .init(timing: .stopped, completion: true, idle: true),
        .init(timing: .called, completion: false, idle: false),
    ]
    public static let prefix = "dev.tomonari.inputmethod.Shizuku.preference.assistance."
    public static let timingKey = prefix + "timing"
    public static let contentKey = prefix + "content"
    public static let memoryKey = prefix + "memory"
    public static let appsKey = prefix + "apps"
    public static let migrationKey = prefix + "migration"
    public static let appContentPrefix = prefix + "appVoice."
    public static let appTabPrefix = prefix + "appTab."
    public static let axisKeys = [timingKey, contentKey, memoryKey]

    public static func initial(_ legacy: Legacy) -> (Timing, Content, Memory) {
        // 両方オン・潜在的なidle・予測オフでの訂正など、軸に収まらない旧設定は詳細に残す。
        (legacy.completion && !legacy.idle ? .typing : .custom,
         legacy.idle ? .body : .patterns,
         legacy.learning ? (legacy.paused ? .paused : .local) : .none)
    }
    public static func legacy(after timing: Timing, previous: Legacy) -> Legacy {
        guard let row = timingTable.first(where: { $0.timing == timing }) else { return previous }
        var next = previous; next.completion = row.completion; next.idle = row.idle; return next
    }
    public static func legacy(after memory: Memory, previous: Legacy) -> Legacy {
        var next = previous
        switch memory {
        case .none: next.learning = false
        case .local: next.learning = true; next.paused = false
        case .paused: break
        }
        return next
    }
    @discardableResult public static func migrate(
        legacy: Legacy, read: (String) -> Any?, write: (String, Any) -> Void
    ) -> Bool {
        guard (read(migrationKey) as? Int ?? 0) < 1 else { return false }
        let axes = initial(legacy)
        for (key, value) in [(timingKey, axes.0.rawValue), (contentKey, axes.1.rawValue), (memoryKey, axes.2.rawValue)] {
            if read(key) == nil { write(key, value) }
        }
        write(migrationKey, 1)
        return true
    }
    public static var legacy: Legacy {
        .init(completion: Config.NextTextCompletion().value, idle: Config.NextTextCompletionIdle().value,
              learning: Config.PersonalLearning().value, paused: Config.PersonalLearningPaused().value)
    }
    public static func migrateIfNeeded() {
        if migrate(legacy: legacy, read: { Config.object(forKey: $0) }, write: { Config.set($1, forKey: $0) }) {
            NSLog("Shizuku: assistance settings migration=1 timing=%@ content=%@ memory=%@; legacy values preserved",
                  timing.rawValue, content.rawValue, memory.rawValue)
        }
    }
    public static var timing: Timing {
        let selected = Config.string(forKey: timingKey).flatMap(Timing.init(rawValue:)) ?? initial(legacy).0
        if let row = timingTable.first(where: { $0.timing == selected }),
           row.completion != legacy.completion || row.idle != legacy.idle { return .custom }
        return selected
    }
    public static var content: Content { Config.string(forKey: contentKey).flatMap(Content.init(rawValue:)) ?? initial(legacy).1 }
    public static var memory: Memory { initial(legacy).2 }
    public static var apps: [String: App] {
        guard let data = Config.string(forKey: appsKey)?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: App].self, from: data)) ?? [:]
    }
    public static func app(_ id: String?) -> App { id.flatMap { apps[$0] } ?? App() }
    public static func setApp(_ value: App, id: String) {
        var all = apps; all[id] = value
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(all) { Config.set(String(decoding: data, as: UTF8.self), forKey: appsKey) }
    }
    public static func permits(_ kind: OfferKind, timing: Timing, content: Content, automatic: Bool = true, tab: Tab = .auto) -> Bool {
        let minimum: Int = switch kind {
        case .skeleton, .quote: 0
        case .idle: 2
        case .completion, .rewrite, .typo, .prediction, .cleanup: 1
        }
        guard content.level >= minimum else { return false }
        if automatic {
            if timing == .called { return false }
            if timing == .stopped, ![.idle, .skeleton, .cleanup].contains(kind) { return false }
            if tab == .yield, [.completion, .idle, .skeleton].contains(kind) { return false }
        }
        return true
    }
    public static func permits(_ kind: OfferKind, app id: String?, automatic: Bool = true) -> Bool {
        if automatic, kind == .cleanup, !Config.CleanUpAutoOffer().value { return false }
        let policy = app(id)
        return permits(kind, timing: timing, content: policy.content ?? content, automatic: automatic, tab: policy.tab)
    }
}
