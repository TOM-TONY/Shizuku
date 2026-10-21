import Foundation

/// 観測の符号と数だけ。提案の選択や待ち時間には使わない。
public enum PersonalStall {
    public enum Event: String, Codable, Sendable, CaseIterable { case interval = "a", abandoned = "b", depth = "c", deleted = "d", empty = "e" }
    public enum Position: Int, Codable, Sendable, CaseIterable {
        case paragraph, sentence, particle, conversion, candidates, confirmation, middle
    }
    public enum Label: Int, Codable, Sendable, CaseIterable { case unknown, thinking, reading, away }
    public enum Action: Sendable { case backspace, reconvert, continuation, typing, other }
    public struct HID: Equatable, Sendable {
        public var interactionAge: Double?
        public var recentInteraction: Bool
        public var mouse: Int?
        public var scroll: Int?
        public var click: Int?
        public init(mouse: Double?, scroll: Double?, click: Double?) {
            func rounded(_ value: Double?) -> Int? {
                guard let value, value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
                return Int(min(value, 86400).rounded())
            }
            self.interactionAge = [scroll, click].compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }.min()
            self.recentInteraction = [scroll, click].contains { $0.map { $0.isFinite && $0 >= 0 && $0 <= 1 } == true }
            self.mouse = rounded(mouse); self.scroll = rounded(scroll); self.click = rounded(click)
        }
    }
    public struct Record: Sendable {
        public var id: String
        public var ts: Double
        public var scene: PersonalScene
        public var event: Event
        public var position: Position
        public var seconds: Double?
        public var depth: Int?
        public var deleted: Int?
        public init(scene: PersonalScene, event: Event, position: Position, seconds: Double? = nil, depth: Int? = nil,
                    deleted: Int? = nil, now: Double) {
            self.id = UUID().uuidString; self.ts = now; self.scene = scene; self.event = event; self.position = position
            self.seconds = seconds; self.depth = depth; self.deleted = deleted
        }
    }
    /// 末尾の最大2文字しか読まない。入力の状態が明確ならそちらを優先する。
    public static func position(left: String?, composing: Bool, candidates: Bool, confirming: Bool) -> Position {
        if candidates { return .candidates }
        if confirming { return .confirmation }
        if composing { return .conversion }
        guard let left else { return .middle }
        guard let last = left.last else { return .paragraph }
        if last.isNewline { return .paragraph }
        if "。！？!?".contains(last) { return .sentence }
        if "はがをにでともへの".contains(last) { return .particle }
        return .middle
    }
    /// 候補の上下移動は再変換に数えない。いったん変換した未確定を開き直した場合だけ。
    public static func action(_ action: ClientAction, composing: Bool, knownContinuation: Bool, convertedBefore: Bool) -> Action {
        switch action {
        case .removeLastMarkedText: return .backspace
        case .enterCandidateSelectionMode: return convertedBefore ? .reconvert : .other
        case .appendToMarkedText, .appendPieceToMarkedText: return composing || knownContinuation ? .continuation : .typing
        default: return .other
        }
    }
    public static func label(action: Action, delay: Double, hid: HID?, away: Bool) -> Label {
        if away { return .away }
        guard delay >= 0, delay <= 5 else { return .unknown }
        if action == .backspace || action == .reconvert || action == .continuation { return .thinking }
        if action == .typing, let age = hid?.interactionAge, age + delay <= 1 { return .reading }
        return .unknown
    }
    public static func threshold(scene: PersonalScene, intervals: [String: PersonalRhythm.Histogram]) -> Double? {
        for key in scene.levelKeys {
            if let histogram = intervals[key], histogram.total >= 200 { return PersonalRhythm.quantile(histogram, 0.9) }
        }
        return nil
    }
    public static func awayStart(lastKey: Double, now: Double) -> Double? {
        guard now.isFinite, lastKey.isFinite, now - lastKey >= 90 else { return nil }
        return lastKey + 90
    }
    public static func microphoneDuration(start: Double, end: Double) -> Int? {
        guard start.isFinite, end.isFinite, end >= start, end - start <= 1800 else { return nil }
        return Int((end - start).rounded())
    }
    public struct Burst: Codable, Equatable, Sendable {
        public var counts: [Int: Int] = [:]
        public init() {}
        public mutating func add(_ characters: Int) {
            guard characters > 0 else { return }
            counts[min(characters, 2000), default: 0] += 1
            if self.counts.values.reduce(0, +) > 4000 { self.counts = self.counts.mapValues { $0 / 2 }.filter { $0.value > 0 } }
        }
        public var median: Double {
            let total = self.counts.values.reduce(0, +)
            guard total > 0 else { return 0 }
            let lower = (total - 1) / 2, upper = total / 2
            var count = 0, low: Int?, high: Int?
            for key in self.counts.keys.sorted() {
                count += self.counts[key] ?? 0
                if low == nil, count > lower { low = key }
                if count > upper { high = key; break }
            }
            return Double((low ?? 0) + (high ?? 0)) / 2
        }
    }

    /// 欄の一時状態。文字は持たず、確定との関連付けもこの欄だけに限定する。
    public struct Tracker: Sendable {
        public var entered: Double
        public var entryKnown: Bool
        public var firstKey = true
        public var lastKey: Double?
        public var intervalRecord: Record?
        public var burstCharacters = 0
        public var depthRecorded = false
        public var convertedBefore = false
        public var lastDeleted = 0
        public var didCommit = false
        public var position: Position = .paragraph
        public var pending: [(id: String, ts: Double)] = []
        public init(now: Double = Date().timeIntervalSince1970, entryKnown: Bool = false) { self.entered = now; self.entryKnown = entryKnown }
        public mutating func beforeKey(scene: PersonalScene, now: Double, composing: Bool, position: Position,
                                       threshold: Double?, emptyField: Bool, deletedCharacters: Int) -> [Record] {
            self.didCommit = false; self.position = position
            var records: [Record] = []
            if self.firstKey, self.entryKnown, emptyField, now - self.entered > 10 {
                records.append(.init(scene: scene, event: .empty, position: position, seconds: now - self.entered, now: now))
            }
            self.firstKey = false
            if self.intervalRecord == nil, composing, let last = self.lastKey, let threshold, now - last > threshold {
                records.append(.init(scene: scene, event: .interval, position: position, seconds: now - last, now: now))
            }
            if deletedCharacters >= 4, self.lastDeleted < 4 {
                records.append(.init(scene: scene, event: .deleted, position: position, deleted: deletedCharacters, now: now))
            }
            self.lastDeleted = deletedCharacters
            self.lastKey = now
            return records
        }
        public mutating func afterKey(scene: PersonalScene, now: Double, wasComposing: Bool, isEmpty: Bool, depth: Int?) -> [Record] {
            var records: [Record] = []
            if isEmpty, wasComposing, !self.didCommit {
                records.append(.init(scene: scene, event: .abandoned, position: self.position, now: now))
            }
            if let depth, depth >= 3, !self.depthRecorded {
                self.depthRecorded = true
                records.append(.init(scene: scene, event: .depth, position: .candidates, depth: depth, now: now))
            }
            if isEmpty { self.depthRecorded = false; self.convertedBefore = false }
            return records
        }
        public mutating func linkable(now: Double) -> [String] {
            let ids = self.pending.filter { now >= $0.ts && now - $0.ts <= 120 }.map(\.id)
            self.pending.removeAll()
            return ids
        }
        public mutating func append(_ record: Record) {
            self.pending.removeAll { record.ts - $0.ts > 120 }
            if self.pending.count >= 1000 { self.pending.removeFirst() }
            self.pending.append((record.id, record.ts))
        }
    }

    static func insert(_ record: Record, store: PersonalStore) throws {
        try store.execute("INSERT INTO stalls(id,ts,scene,app,event,position,seconds,depth,deleted_chars,weak_label) VALUES(?,?,?,?,?,?,?,?,?,0)",
                          [.text(record.id), .double(record.ts), .text(record.scene.key), .text(record.scene.app), .text(record.event.rawValue),
                           .int(Int64(record.position.rawValue)), record.seconds.map { .double($0) } ?? .null,
                           record.depth.map { .int(Int64($0)) } ?? .null, record.deleted.map { .int(Int64($0)) } ?? .null])
    }
    static func intervalRows(store: PersonalStore) throws -> [String: PersonalRhythm.Histogram] {
        var values: [String: PersonalRhythm.Histogram] = [:]
        try store.query("SELECT level,json FROM stall_intervals") {
            if let data = $0.text(1)?.data(using: .utf8), let histogram = try? JSONDecoder().decode(PersonalRhythm.Histogram.self, from: data) {
                values[$0.text(0) ?? ""] = histogram
            }
        }
        return values
    }
}

/// 無効化が終わったあとに、待ち行列に残った観測がOSへ問い合わせないための門。
public final class PersonalObservationGate: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var generation = 0
    private var enabled = false
    public func set(enabled: Bool, generation: Int) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.enabled = enabled; self.generation = generation
    }
    public func sample(generation: Int, _ body: () -> PersonalStall.HID) -> PersonalStall.HID? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.enabled, self.generation == generation else { return nil }
        return body()
    }
}

