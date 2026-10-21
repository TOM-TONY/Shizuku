import AppKit
import Core
import CoreAudio
import CoreGraphics
import Foundation
import Gemma4ANE

/// Serverだけの観測。マイクの既知の区間だけは生成の門にも使う。
@MainActor
final class PersonalSensing {
    static let shared = PersonalSensing()
    private let gate = PersonalObservationGate()
    private let hidQueue = DispatchQueue(label: "Shizuku.personal.hid", qos: .utility)
    private var owner: ObjectIdentifier?
    private var scene: PersonalScene?
    private var monitoring = false
    private var hidEnabled = false
    private var environment = PersonalEnvironment()
    private var generation = 0
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var lastKey = Date().timeIntervalSince1970
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private struct Pending {
        var scene: PersonalScene
        var ts: Double
        var hid: PersonalStall.HID?
        var first: (PersonalStall.Action, Double)?
        var away: Bool
        var interval: Bool
    }
    private var pending: [String: Pending] = [:]

    func configure(scene: PersonalScene?) {
        let recording = PersonalLearner.isRecording
        InferenceActivity.configure(enabled: recording)
        let allowed = recording && scene.map { !PersonalPrivacy.isExcluded(app: $0.app) } == true
        self.scene = allowed ? scene : nil
        self.environment.configure(enabled: recording, scene: self.scene)
        let changed = recording != self.monitoring
        if changed || allowed != self.hidEnabled {
            self.generation += 1
            self.hidEnabled = allowed
            self.gate.set(enabled: allowed, generation: self.generation)
        }
        self.monitoring = recording
        if !allowed { self.owner = nil; self.pending.removeAll() }
        guard changed else { return }
        if !recording { self.stopObservers(); return }
        self.lastKey = Date().timeIntervalSince1970
        // 登録・CoreAudioの最初の読みもキー応答の外へ出す。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.monitoring, PersonalLearner.isRecording, self.timer == nil else { return }
            self.startObservers()
        }
    }
    func forget() {
        InferenceActivity.invalidate()
        self.configure(scene: nil)
        self.environment.forget()
        self.lastKey = Date().timeIntervalSince1970
    }

    var microphoneActive: Bool {
        PersonalLearner.isRecording && environment.microphoneIsActive(now: Date().timeIntervalSince1970)
    }
    func muteGeneration(kind: String, scene: PersonalScene?, record: Bool = true) -> Bool {
        guard microphoneActive else { return false }
        if record, let scene, !PersonalPrivacy.isExcluded(app: scene.app) {
            PersonalLearner.shared.recordReaction(kind: kind + "_muted_mic", scene: scene)
        }
        return true
    }

    func release(session: ConverterSession) {
        if self.owner == ObjectIdentifier(session) {
            self.owner = nil
            self.pending.removeAll()
        }
    }
    func isActive(session: ConverterSession) -> Bool {
        self.monitoring && self.owner == ObjectIdentifier(session)
    }

    func noteKey(session: ConverterSession, scene: PersonalScene, action: PersonalStall.Action, now: Double) -> Bool {
        self.configure(scene: scene)
        guard self.monitoring, self.scene != nil else { return false }
        self.owner = ObjectIdentifier(session)
        if session.personal.sensingGeneration != self.generation {
            session.personal.sensingGeneration = self.generation
            session.personal.stalls.lastKey = nil
            session.personal.stalls.intervalRecord = nil
            session.personal.stalls.pending.removeAll()
            session.personal.stalls.burstCharacters = 0
        }
        self.lastKey = now
        let returned = self.environment.isAway || self.environment.lastReturn.map { now >= $0 && now - $0 <= 5 } == true
        self.endAway(now: now)
        for id in Array(self.pending.keys) {
            guard var value = self.pending[id] else { continue }
            if value.interval { continue }
            if now - value.ts > 5 { self.pending[id] = nil; continue }
            guard value.first == nil, value.scene.app == scene.app else { continue }
            value.first = (action, now - value.ts)
            self.pending[id] = value
            self.annotate(id)
        }
        return returned
    }

    func sample(_ record: PersonalStall.Record, first: PersonalStall.Action? = nil, away: Bool = false) {
        guard self.monitoring, PersonalLearner.isRecording, self.scene?.app == record.scene.app else { return }
        self.pending[record.id] = Pending(scene: record.scene, ts: record.ts, first: first.map { ($0, 0) }, away: away, interval: record.event == .interval)
        let generation = self.generation
        let gate = self.gate
        self.hidQueue.async {
            guard let hid = gate.sample(generation: generation, Self.readHID) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation, PersonalLearner.isRecording else { return }
                guard var value = self.pending[record.id] else {
                    if record.event == .interval { PersonalLearner.shared.annotateStall(id: record.id, hid: hid, label: .unknown) }
                    return
                }
                value.hid = hid
                self.pending[record.id] = value
                self.annotate(record.id)
            }
        }
    }

    /// 間のあと最初のキーでだけ読み直す。台帳のHIDは止まった時点のままにする。
    func returnedInterval(_ record: PersonalStall.Record, action: PersonalStall.Action, away: Bool) {
        guard self.monitoring, PersonalLearner.isRecording else { return }
        self.pending[record.id] = nil
        let generation = self.generation, gate = self.gate
        self.hidQueue.async {
            guard let hid = gate.sample(generation: generation, Self.readHID) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation, PersonalLearner.isRecording else { return }
                let label = PersonalStall.label(action: action, delay: 0, hid: hid, away: away)
                PersonalLearner.shared.annotateStall(id: record.id, label: label)
            }
        }
    }

    /// 放置タイマーが切れた瞬間だけ。新しい事象・表示は作らない。
    func idleTimer(scene: PersonalScene?) {
        guard self.monitoring, PersonalLearner.isRecording, let scene, self.scene?.app == scene.app else { return }
        let generation = self.generation
        let gate = self.gate
        self.hidQueue.async {
            guard let hid = gate.sample(generation: generation, Self.readHID) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation, PersonalLearner.isRecording else { return }
                // 数だけを反応に残す。キーごとのHID観測は行わない。
                let encoded = [hid.mouse, hid.scroll, hid.click].map { $0.map(String.init) ?? "null" }.joined(separator: ",")
                PersonalLearner.shared.recordReaction(kind: "idle_hid", scene: scene, a: encoded)
            }
        }
    }

    nonisolated private static func readHID() -> PersonalStall.HID {
        .init(mouse: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
              scroll: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel),
              click: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown))
    }
    private func annotate(_ id: String) {
        guard let value = self.pending[id], let hid = value.hid else { return }
        var label = value.first.map { PersonalStall.label(action: $0.0, delay: $0.1, hid: hid, away: value.away) } ?? .unknown
        // 読みの推測は分位を超えた間から戻った瞬間のHIDだけ。
        if label == .reading && !(value.interval && value.first?.1 == 0) { label = .unknown }
        PersonalLearner.shared.annotateStall(id: id, hid: hid, label: label)
        if value.first != nil { self.pending[id] = nil }
    }
    private func beginAway(now: Double, usingPreviousScene: Bool = false) {
        guard self.monitoring, PersonalLearner.isRecording else { return }
        if let scene = self.environment.beginAway(now: now, usingPreviousScene: usingPreviousScene) {
            PersonalLearner.shared.recordReaction(kind: "away_begin", scene: scene, now: Date(timeIntervalSince1970: now))
        }
    }
    private func endAway(now: Double) {
        guard self.monitoring, PersonalLearner.isRecording else { return }
        if let interval = self.environment.endAway(now: now) {
            if !interval.beginRecorded {
                PersonalLearner.shared.recordReaction(kind: "away_begin", scene: interval.scene, now: Date(timeIntervalSince1970: interval.start))
            }
            PersonalLearner.shared.recordReaction(kind: "away_return", scene: interval.scene,
                n: Int(max(0, interval.end - interval.start).rounded()), now: Date(timeIntervalSince1970: interval.end))
        }
    }
    private func startObservers() {
        let distributed = DistributedNotificationCenter.default()
        for (name, begin) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            let token = distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.monitoring, PersonalLearner.isRecording else { return }
                    if begin { self.beginAway(now: Date().timeIntervalSince1970, usingPreviousScene: true) } else { self.endAway(now: Date().timeIntervalSince1970) }
                }
            }
            self.notifications.append((distributed, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        // 欄を離れても、同じ許可アプリで続いているマイクの時刻は保つ。除外アプリに移ったら監視ごと捨てる。
        let activation = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let bundle = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, self.monitoring, PersonalLearner.isRecording, let bundle else { return }
                PersonalContextMemory.shared.observe(app: bundle, enabled: true, now: Date().timeIntervalSince1970)
                if PersonalPrivacy.isExcluded(app: bundle) { self.configure(scene: nil) }
                else if bundle != self.scene?.app { self.owner = nil }
            }
        }
        self.notifications.append((workspace, activation))
        for (name, begin) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.monitoring, PersonalLearner.isRecording else { return }
                    if begin { self.beginAway(now: Date().timeIntervalSince1970, usingPreviousScene: true) } else { self.endAway(now: Date().timeIntervalSince1970) }
                }
            }
            self.notifications.append((workspace, token))
        }
        self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.monitoring, PersonalLearner.isRecording else { return }
                let now = Date().timeIntervalSince1970
                self.pending = self.pending.filter { now - $0.value.ts <= ($0.value.interval ? 600 : 5) }
                if let begin = PersonalStall.awayStart(lastKey: self.lastKey, now: now) { self.beginAway(now: begin) }
            }
        }
        var address = Self.defaultAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.observeDefaultMicrophone() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            self.defaultListener = listener
        }
        self.observeDefaultMicrophone()
    }
    private static var defaultAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static var runningAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private func observeDefaultMicrophone() {
        guard self.monitoring, PersonalLearner.isRecording else { return }
        self.removeDeviceListener()
        self.finishMicrophone(now: Date().timeIntervalSince1970)
        var address = Self.defaultAddress
        var device = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return }
        self.device = device
        var running = Self.runningAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.observeMicrophone() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &running, .main, listener) == noErr { self.deviceListener = listener }
        self.observeMicrophone()
    }
    private func observeMicrophone() {
        guard self.monitoring, PersonalLearner.isRecording else { return }
        var address = Self.runningAddress, value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(self.device, &address, 0, nil, &size, &value) == noErr else { self.environment.configure(enabled: true, scene: nil); return }
        let now = Date().timeIntervalSince1970
        self.recordMicrophone(self.environment.observeMicrophone(running: value != 0, now: now))
        if self.microphoneActive { NextTextCompletionEngine.shared.cancel() }
    }
    private func finishMicrophone(now: Double) {
        self.recordMicrophone(self.environment.observeMicrophone(running: false, now: now))
    }
    private func recordMicrophone(_ interval: PersonalEnvironment.Interval?) {
        guard self.monitoring, PersonalLearner.isRecording, let interval,
              let seconds = PersonalStall.microphoneDuration(start: interval.start, end: interval.end) else { return }
        PersonalLearner.shared.recordReaction(kind: "mic_session", scene: interval.scene,
            a: String(interval.start), b: String(interval.end), n: seconds, now: Date(timeIntervalSince1970: interval.end))
    }
    private func removeDeviceListener() {
        if let listener = self.deviceListener {
            var address = Self.runningAddress
            AudioObjectRemovePropertyListenerBlock(self.device, &address, .main, listener)
        }
        self.deviceListener = nil; self.device = AudioObjectID(kAudioObjectUnknown)
    }
    private func stopObservers() {
        self.timer?.invalidate(); self.timer = nil
        for (center, token) in self.notifications { center.removeObserver(token) }
        self.notifications.removeAll()
        self.removeDeviceListener()
        if let listener = self.defaultListener {
            var address = Self.defaultAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.defaultListener = nil
    }
}
