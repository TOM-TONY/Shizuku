import Foundation

/// 離席とマイクの観測だけを扱う。本文は保持せず、記録してよい区間だけを返す。
public struct PersonalEnvironment: Sendable {
    public struct Interval: Sendable, Equatable {
        public var scene: PersonalScene
        public var start: Double
        public var end: Double
        public var beginRecorded = true
    }
    private struct Away: Sendable { var scene: PersonalScene?; var start: Double; var end: Double?; var beginRecorded: Bool }
    private struct Microphone: Sendable { var scene: PersonalScene?; var start: Double; var eligible: Bool }
    private var away: Away?
    private var microphone: Microphone?
    private var enabled = false
    private var lastScene: PersonalScene?
    private var scene: PersonalScene?
    public private(set) var lastReturn: Double?
    public var isAway: Bool { self.away != nil }
    public func microphoneIsActive(now: Double) -> Bool {
        guard enabled, let microphone, now.isFinite else { return false }
        return now >= microphone.start && now - microphone.start <= 1800
    }
    public init() {}

    public mutating func configure(enabled: Bool, scene: PersonalScene?) {
        self.enabled = enabled
        self.scene = scene
        if let scene { self.lastScene = scene }
        if !enabled { self.forget() }
        else if scene == nil { self.microphone?.eligible = false }
    }
    public mutating func forget() {
        self.away = nil; self.microphone = nil; self.lastReturn = nil; self.scene = nil; self.lastScene = nil
    }
    public mutating func beginAway(now: Double, usingPreviousScene: Bool = false) -> PersonalScene? {
        guard self.enabled, self.away == nil, now.isFinite else { return nil }
        self.away = Away(scene: self.scene ?? (usingPreviousScene ? self.lastScene : nil), start: now, beginRecorded: self.scene != nil)
        return self.scene
    }
    /// 除外中のunlockは時刻だけ保つ。次の許可された欄で、元の場面のreturnを記録する。
    public mutating func endAway(now: Double) -> Interval? {
        guard self.enabled, var away = self.away else { return nil }
        if away.end == nil { away.end = max(away.start, now) }
        self.away = away
        guard self.scene != nil else { return nil }
        self.away = nil
        guard let scene = away.scene else { return nil }
        let end = away.end ?? now
        self.lastReturn = end
        return Interval(scene: scene, start: away.start, end: end, beginRecorded: away.beginRecorded)
    }
    public mutating func observeMicrophone(running: Bool, now: Double) -> Interval? {
        guard self.enabled, now.isFinite else { return nil }
        if running {
            if self.microphone == nil { self.microphone = Microphone(scene: self.scene, start: now, eligible: self.scene != nil) }
            return nil
        }
        guard let microphone = self.microphone else { return nil }
        self.microphone = nil
        guard microphone.eligible, self.scene != nil, let scene = microphone.scene,
              PersonalStall.microphoneDuration(start: microphone.start, end: now) != nil else { return nil }
        return Interval(scene: scene, start: microphone.start, end: now)
    }
}
